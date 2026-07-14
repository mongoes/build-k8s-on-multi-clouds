#!/bin/bash
# K8S就绪可用性确保脚本
# 功能：确保K8S环境就绪可用，包含：
#   - kubectl安装与集群连通性检查
#   - 云平台识别与StorageClass自动创建（腾讯云/阿里云/华为云/AWS/GCP）
#   - 节点池与节点规格一致性检查
#   - Pod调度、起服、网络联通性验证

# ==================== 配置部分 ====================
# 本次运行时间戳: 日志与测试物料目录共用同一戳, 便于一一对应
RUN_TS="$(date +'%Y-%m-%d_%H%M%S')"
LOG_FILE="k8sAvailCheckResult_${RUN_TS}.log"
# 测试物料与异常详情落盘目录(与日志同级, 绝对路径)。
# 即使脚本回收了测试资源, 用户仍可凭此目录下的 yaml/describe 用 kubectl apply -f 复现并排查。
ARTIFACT_DIR="$(pwd)/k8sAvailCheckArtifacts_${RUN_TS}"
NAMESPACE="debug"
# 脚本完成标志：用于EXIT trap判断是否异常退出，异常退出时清理残留测试资源
SCRIPT_COMPLETED=false

# ==================== 版本配置（跟随K8S社区迭代更新） ====================
K8S_VERSION="1.34"
K8S_MAJOR_VERSION="1"
K8S_MINOR_VERSION="34"
# 可用性检查统一从数数镜像仓库拉取, 与实际服务部署来源保持一致(不再走 docker hub / GCR 备用)。
# 若从此仓库拉取失败, 大概率是容器集群网络策略未放行, 视为不符合部署需求并强提示。
NGINX_IMAGE="docker-ta.thinkingdata.cn/te/nginx:1.20"
# 拉取失败时的统一强提示文案(容器集群网络策略未放行 docker-ta.thinkingdata.cn)
IMAGE_PULL_FAIL_HINT="从 docker-ta.thinkingdata.cn 仓库拉取镜像失败，不符合部署需求，请确认容器集群访问配置妥当&&放行后重试检查。"

# ==================== 期望节点池规划（按云平台差异化映射） ====================
# 背景: on-demand(按量付费)/spot 弹性节点池默认期望节点数为0,空闲时无任何节点对象,
#       kubectl get nodes 无法发现 -> 无法证明集群具备弹性扩容能力。
#       故 Pod部署启动检查 主动为每个期望节点池起服探测(逼弹性池 autoscaler 0->1),
#       验证"各节点池能否调度起 Pod"(只验可调度性,不再做规格/付费类型契约校验)。
#
# 各云平台节点池规划存在客观差异(由各家弹性能力决定),按 detect_cloud_platform
# 结果选择对应映射。节点池名须与节点 node.k8s.te/nodepool-name 标签一致。
#  - alibaba/huawei : 4池。阿里 ACK 在 spot 资源不足时自动 fallback 到 on-demand,
#                     故无需独立 od-32c128g 池
#  - tencent/volc   : 5池(reserved/od/spot 全谱)
#  - google(GKE)/aws(EKS): 无原生包年包月(reserved)实例,常驻节点运维可能命名为 reserved-*
#                     或 od-*。故 4c32g/32c128g 两档各为"reserved 或 od 二选一"(用 | 分隔的
#                     OR 组,组内任一别名可调度即算该档通过),spot-32c128g 唯一。
#                     (注:AWS EKS 当前在 main 中经 auto_build_nodepool 提前 return,实际跑不到
#                      节点池探测;此处一并定义以保持逻辑正确、未来若启用探测即生效。)
#  - 未覆盖云平台    : 用 google 风格的 od 三池兜底
#  - 物理机/自建     : 不检查节点池(映射为空),仅起一个无 nodeSelector 的 Pod
# OR 组语法: 同一档的多个候选用 | 连接(无空格),如 reserved-4c32g|od-4c32g;不同档用空格分隔。
get_expected_nodepools() {
    case "$1" in
    *alibaba* | *ali* | *huawei*)
        echo "reserved-4c32g od-4c32g reserved-32c128g spot-32c128g"
        ;;
    *tencent* | *volc*)
        echo "reserved-4c32g od-4c32g reserved-32c128g od-32c128g spot-32c128g"
        ;;
    *google* | *aws*)
        echo "reserved-4c32g|od-4c32g reserved-32c128g|od-32c128g spot-32c128g"
        ;;
    vmware | kvm | qemu | baremetal)
        echo ""
        ;;
    *) # 未覆盖云平台(azure 等)用 google 风格 od 三池兜底
        echo "od-4c32g od-32c128g spot-32c128g" ;;
    esac
}
# Pod探测就绪总超时(秒)。云资源扩容通常1~2分钟内完成,超过3分钟多半是
# 节点池异常或未打标签,不再傻等;另结合 Pod events 提前识别"无匹配节点池"。
POD_PROBE_TIMEOUT=180
# 探测Deployment名称前缀,用于统一清理(含EXIT trap兜底)
PROBE_PREFIX="np-probe"
# 节点组契约校验: 池实际 capacity 与池名声明规格的相对差值容差。
# 云厂商容器实例预留机制(系统组件/内核/kubelet 占用)导致 capacity 略小于标称规格,
# 例如 32Gi 规格实际 capacity 常为 ~31.2Gi(偏差约2.5%)。<=6% 视为正常预留, 不告警。
SPEC_TOLERANCE=0.06

# ==================== 混合部署网络错配探测配置 ====================
# 集群外置 MySQL(与业务云主机混合部署)探测: 从业务服务配置文件解析 datasource。
# 目的: 验证 Pod -> 集群内 MySQL 的 TCP 可达性, 以及 Pod -> MySQL 所在云主机的网络延迟,
# 提前暴露混合部署下安全组/路由错配(典型: Pod 网段未被云主机侧安全组放行)。
APP_CONFIG_FILE="/data/home/ta/base_server_ta/application.yml"
# Pod -> 云主机延迟阈值(毫秒)。混合部署要求同 VPC 低延迟内网, >50ms 多为跨可用区/跨域错配。
HOST_LATENCY_THRESHOLD_MS=50
# 延迟采样次数(取均值, 削峰抖动)。TCP 握手计时近似 RTT(略高于 ICMP 但同量级)。
HOST_LATENCY_SAMPLES=5

# 端到端存储验证 PVC 请求容量。各云块存储有最小容量下限且不一:腾讯 CBS [10,32000]、
# 火山 ESSD/阿里 cloud_essd(默认PL1) 等下限 10~20 GiB; 请求过小(如 1Gi)会被云 API 拒
# (ProvisioningFailed: disk size is invalid / InvalidVolumeSize), 这是测试参数不合规、
# 非 CSI 故障。取 20Gi 可一次性越过全部云下限(阿里 PL1 的 20 是最高门槛); 盘随测试几分钟
# 即删, 瞬时计费可忽略。AWS gp3 下限仅 1Gi, 取 20 同样合规。
E2E_PVC_SIZE="20Gi"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ==================== 横幅宽度工具 ====================
# 所有 ==== 章节横幅统一为固定总宽, 标题居中, 两侧 '=' 补齐, 解决横幅长短参差。
BANNER_WIDTH=100

# 计算字符串显示宽度: 中文/全角按2列, ASCII按1列。
# 纯字节实现, 不依赖 locale: UTF-8 续字节(0x80-0xBF)不增显示列,
# 每个 CJK(3字节=1主字节+2续字节)显示2列 => 显示宽 = 字节数 - 续字节数/2
_disp_width() {
    local s="$1" bytes cont
    bytes=$(printf '%s' "$s" | LC_ALL=C wc -c)
    cont=$(printf '%s' "$s" | LC_ALL=C tr -dc '\200-\277' | LC_ALL=C wc -c)
    echo $((bytes - cont / 2))
}

# 生成固定总宽(BANNER_WIDTH)的居中横幅串: 标题居中, 两侧用 '=' 补齐
_banner_line() {
    local title="$1" w pad left right
    w=$(_disp_width "$title")
    pad=$((BANNER_WIDTH - w))
    ((pad < 2)) && pad=2
    left=$((pad / 2))
    right=$((pad - left))
    printf '%s%s%s' \
        "$(printf '%*s' "$left" '' | tr ' ' '=')" \
        "$title" \
        "$(printf '%*s' "$right" '' | tr ' ' '=')"
}

# 生成整行(BANNER_WIDTH宽)的 '=' 分隔规则线
_banner_rule() {
    printf '%*s' "$BANNER_WIDTH" '' | tr ' ' '='
}

# 按显示宽度(CJK按2列)左对齐补空格到目标宽度, 用于表格列对齐
_pad_disp() {
    local s="$1" target="$2" w n
    w=$(_disp_width "$s")
    n=$((target - w))
    ((n < 0)) && n=0
    printf '%s%*s' "$s" "$n" ''
}

# ==================== 日志函数 ====================
log_info() {
    echo -e "$1" >&2
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1" >>"$LOG_FILE"
}

log_success() {
    echo -e "\e[32m\e[1m$1 \e[0m" >&2
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] $1" >>"$LOG_FILE"
}

log_warning() {
    echo -e "\e[33m\e[1m$1 \e[0m" >&2
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WARNING] $1" >>"$LOG_FILE"
}

log_error() {
    echo -e "\e[31m\e[1m$1 \e[0m" >&2
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" >>"$LOG_FILE"
}

log_step() {
    local line
    line=$(_banner_line "$1")
    echo -e "\n${BOLD}${line}${NC}" >&2
    echo "$line" >>"$LOG_FILE"
}

log_section() {
    echo -e "\n${BLUE}--- $1 ---${NC}" >&2
    echo "--- $1 ---" >>"$LOG_FILE"
}

# ==================== 测试物料/异常详情落盘 ====================
# 懒创建测试物料目录(首次用到时才建)。所有测试 yaml 与异常 describe 都落到此目录,
# 资源被回收后仍可凭此目录用 kubectl apply -f 复现问题。返回绝对路径目录。
_ensure_artifact_dir() {
    if [[ ! -d "$ARTIFACT_DIR" ]]; then
        mkdir -p "$ARTIFACT_DIR" 2>/dev/null
    fi
}

# ==================== 检查结果登记表 ====================
# 全程不阻断: 每个检查项执行完调用 record_result 登记结果(不中途 exit),
# 脚本末尾由 print_summary 统一输出所有检查项的成功/失败总览。
# 状态取值: PASS(通过) / WARN(通过但有需关注项) / FAIL(未通过) / SKIP(跳过未执行)
RESULT_NAMES=()
RESULT_STATUS=()
RESULT_DETAIL=()
record_result() {
    RESULT_NAMES+=("$1")
    RESULT_STATUS+=("$2")
    RESULT_DETAIL+=("${3:-}")
}

# 打印最终汇总总览(彩色), 并统计 PASS/WARN/FAIL/IMPORTANT/SKIP 数量
print_summary() {
    log_step "检查结果总览"
    local pass=0 warn=0 fail=0 important=0 skip=0
    local i

    # 先求所有检查项名的最大显示宽度, 供右补空格对齐 '——' 详情列
    local maxw=0 w
    for i in "${!RESULT_NAMES[@]}"; do
        w=$(_disp_width "${RESULT_NAMES[$i]}")
        ((w > maxw)) && maxw=$w
    done

    for i in "${!RESULT_NAMES[@]}"; do
        local name="${RESULT_NAMES[$i]}"
        local st="${RESULT_STATUS[$i]}"
        local detail="${RESULT_DETAIL[$i]}"
        local tag color
        case "$st" in
        PASS)
            tag="[ 通过 ]"
            color="$GREEN"
            ((pass++))
            ;;
        WARN)
            tag="[ 关注 ]"
            color="$YELLOW"
            ((warn++))
            ;;
        FAIL)
            tag="[ 失败 ]"
            color="$RED"
            ((fail++))
            ;;
        IMPORTANT)
            # 重要后续动作项(如 iptables 持久化): 红色高亮, 不计入检查项总数, 不影响交付判定
            tag="[ 重要提醒 ]"
            color="$RED"
            ((important++))
            ;;
        *)
            tag="[ 跳过 ]"
            color="$BLUE"
            ((skip++))
            st="SKIP"
            ;;
        esac
        # 检查项名右补空格至 maxw 显示宽, 使各行 '——' 起始列对齐
        local nw
        nw=$(_disp_width "$name")
        local padded="${name}$(printf '%*s' $((maxw - nw)) '')"
        local line="  ${tag} ${padded}"
        [[ -n "$detail" ]] && line="${line} —— ${detail}"
        echo -e "${color}${BOLD}${line}${NC}" >&2
        echo "${tag} ${name}${detail:+ —— $detail}" >>"$LOG_FILE"
    done

    echo "" >&2
    # [重要提醒]项不计入检查项总数(它是后续动作项, 非检查项), 总数与检查计划对齐
    local total=$((${#RESULT_NAMES[@]} - important))
    local stat="共 ${total} 项: 通过 ${pass} / 失败 ${fail} / 关注 ${warn} / 跳过 ${skip}"
    echo "${stat}" >>"$LOG_FILE"
    local important_note=""
    [[ $important -gt 0 ]] && important_note=" 另有[重要提醒]项需关注执行！"
    if [[ $fail -gt 0 ]]; then
        log_error "${stat}。存在失败检查项，请按上述[失败]条目排查处理！${important_note}"
    elif [[ $warn -gt 0 ]]; then
        log_warning "${stat}。全部检查项均无致命失败，但有[关注]项建议跟进。${important_note}"
    elif [[ $important -gt 0 ]]; then
        log_warning "${stat}。全部检查项通过。${important_note}"
    else
        log_success "${stat}。全部检查项通过。"
    fi
}

# ==================== 工具函数 ====================
# 将K8S quantity字符串转为人类可读格式
# K8S标准单位: Ki, Mi, Gi, Ti, Pi, Ei (都是1024进制)
# 纯大数字(>1000000)按字节处理
format_resource() {
    local val="$1"
    if [[ -z "$val" ]]; then
        echo "0"
        return
    fi

    # 提取数字部分和单位后缀
    local num="${val//[A-Za-z]/}"
    local suffix="${val//[0-9]/}"

    # 无后缀: 判断是字节还是CPU核心
    if [[ -z "$suffix" ]]; then
        if [[ "$num" =~ ^[0-9]+$ ]]; then
            if [[ $num -gt 1000000 ]]; then
                # 大于100万，当作字节处理
                awk "BEGIN {printf \"%.1fGi\", $num/1024/1024/1024}"
            else
                # 小数，当作CPU核心数
                echo "${num}"
            fi
        else
            echo "${num}"
        fi
        return
    fi

    # CPU毫核: 3920m -> 3.9C
    if [[ "$suffix" == "m" ]]; then
        awk "BEGIN {printf \"%.1fC\", $num/1000}"
        return
    fi

    # 存储单位转换 (K8S使用1024进制: Ki=1024bytes, Mi=1024Ki, etc.)
    case "$suffix" in
    Ki) # Kibibytes: 1 Ki = 1024 bytes = 1/1048576 Gi
        awk "BEGIN {printf \"%.1fGi\", $num/1024/1024}"
        ;;
    Mi) # Mebibytes: 1 Mi = 1024 Ki = 1/1024 Gi
        awk "BEGIN {printf \"%.1fGi\", $num/1024}"
        ;;
    Gi) # Gibibytes: 1 Gi = 1024 Mi
        awk "BEGIN {printf \"%.1fGi\", $num}"
        ;;
    Ti) # Tebibytes: 1 Ti = 1024 Gi
        awk "BEGIN {printf \"%.1fTi\", $num}"
        ;;
    Pi) # Pebibytes: 1 Pi = 1024 Ti
        awk "BEGIN {printf \"%.1fPi\", $num}"
        ;;
    Ei) # Exbibytes: 1 Ei = 1024 Pi
        awk "BEGIN {printf \"%.1fEi\", $num}"
        ;;
    k)
        # 虚拟节点CPU: 1920k -> 1920C (k=1000millicores)
        awk "BEGIN {printf \"%.0fC\", $num}"
        ;;
    *)
        echo "${num}${suffix}"
        ;;
    esac
}

# 将CPU值转为可读格式
format_cpu() {
    local cpu="$1"
    if [[ -z "$cpu" ]]; then
        echo "0"
        return
    fi

    local num="${cpu//[A-Za-z]/}"
    local suffix="${cpu//[0-9]/}"

    # 毫核: 3920m -> 3.9C
    if [[ "$suffix" == "m" ]]; then
        awk "BEGIN {printf \"%.1fC\", $num/1000}"
        return
    fi

    # 虚拟节点CPU: 1920k -> 1920C
    if [[ "$suffix" == "k" ]]; then
        echo "${num}C"
        return
    fi

    # 整数核心数
    echo "${cpu}C"
}

# ==================== 通用检查函数 ====================
SYS_USER=root
CURRENT_USER=$(whoami)
checkUser() {
    if [ "${CURRENT_USER}" != "$SYS_USER" ]; then
        log_error "请使用${SYS_USER}用户执行脚本，当前执行用户为${CURRENT_USER}"
        exit 1
    fi
}

# ==================== kubectl检查 ====================
install_kubectl() {
    log_step "kubectl检查"

    ARCH=$(uname -m)
    case $ARCH in
    x86_64)
        TARGET_ARCH="amd64"
        ;;
    aarch64)
        TARGET_ARCH="arm64"
        ;;
    *)
        log_error "不支持的架构: $ARCH"
        exit 1
        ;;
    esac

    if ! command -v kubectl &>/dev/null; then
        log_info "未检测到kubectl，开始安装 K8S ${K8S_VERSION}"
    else
        # 从 v1.34.0 中提取主版本号(X)和次版本号(Y)，忽略补丁号(Z)
        local installed_full=$(kubectl version --client 2>/dev/null | head -1)
        local installed_major=$(echo "$installed_full" | grep -oP 'v\K[0-9]+' | head -1)
        local installed_minor=$(echo "$installed_full" | grep -oP 'v[0-9]+\.\K[0-9]+' | head -1)
        log_info "检测到已安装kubectl，版本: $installed_full"
        log_info "目标版本: ${K8S_VERSION} (Major=${K8S_MAJOR_VERSION}, Minor=${K8S_MINOR_VERSION})"
        log_info "当前版本: $installed_major.$installed_minor"

        if [[ "$installed_major" == "${K8S_MAJOR_VERSION}" && "$installed_minor" == "${K8S_MINOR_VERSION}" ]]; then
            log_success "kubectl版本($installed_major.$installed_minor)已匹配目标版本(${K8S_VERSION})，无需重新安装"
            return 0
        else
            log_info "kubectl版本($installed_major.$installed_minor)与目标版本(${K8S_VERSION})不一致，开始更新"
            # 保存原始kubectl路径，备份后command -v将失效，故此处先记录
            ORIG_KUBECTL_PATH="$(command -v kubectl)"
            BACKUP_FILE="/usr/local/bin/kubectl_bak_$(date +%Y%m%d_%H%M%S)"
            mv "${ORIG_KUBECTL_PATH}" "${BACKUP_FILE}"
            log_info "已将老版本kubectl备份至: $BACKUP_FILE"
        fi
    fi

    local kubectl_url="https://download-thinkingdata.oss-cn-shanghai.aliyuncs.com/ta/tools/kubectl-${K8S_VERSION}-${TARGET_ARCH}"
    log_info "架构: $ARCH -> ${TARGET_ARCH}, 下载地址: $kubectl_url"
    if ! curl -sLO "$kubectl_url"; then
        log_error "kubectl下载失败，请参考K8S官网文档手动下载https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/#install-kubectl-on-linux"
        if [[ -n "${BACKUP_FILE}" ]] && [[ -f "${BACKUP_FILE}" ]]; then
            mv "${BACKUP_FILE}" "${ORIG_KUBECTL_PATH}"
            log_info "已回滚到备份版本: ${ORIG_KUBECTL_PATH}"
        fi
        exit 1
    fi
    cp -f "kubectl-${K8S_VERSION}-${TARGET_ARCH}" /usr/local/bin/kubectl
    chmod +x /usr/local/bin/kubectl
    log_success "kubectl安装完成, 版本: $(kubectl version --client 2>/dev/null | head -1)"
}

test_k8s_connection() {
    log_step "K8S集群连通性检查"
    if [[ -z "${KUBECONFIG}" ]] || [[ ! -f "${KUBECONFIG}" ]]; then
        log_error "未找到KUBECONFIG文件，请参考SOP配置K8S访问凭证"
        exit 1
    fi
    if ! kubectl cluster-info &>/dev/null; then
        log_error "无法连接到Kubernetes集群，请检查配置"
        exit 1
    fi
    log_success "K8S集群连接正常"
    # kubectl version --short 在 v1.28+ 已移除，改用 -o json (全版本稳定支持，无需jq)
    local version_json=$(kubectl version -o json 2>/dev/null)
    local client_ver=$(echo "$version_json" | grep -m1 -oE '"gitVersion": *"[^"]+"' | head -1 | grep -oE 'v[0-9][^"]*')
    local server_ver=$(echo "$version_json" | grep -oE '"gitVersion": *"[^"]+"' | tail -1 | grep -oE 'v[0-9][^"]*')
    log_info "kubectl客户端版本: ${client_ver:-未知}, 集群服务端版本: ${server_ver:-未知}"
}

ensure_namespace() {
    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
        kubectl create namespace "$NAMESPACE" >/dev/null
        log_info "创建命名空间: $NAMESPACE"
    fi
}

# ==================== 节点池自动发现与归类检测 ====================
# 功能：
#   1. 发现K8S内所有节点，按 node.k8s.te/nodepool-name 标签归类
#   2. 先进行详细检测(规格/标签/污点一致性)
#   3. 再统一打印节点池汇总信息
discover_and_check_nodes() {
    log_step "节点池与节点配置检查"

    local all_nodes=$(kubectl get nodes --no-headers 2>/dev/null)
    if [[ -z "$all_nodes" ]]; then
        log_error "未获取到任何节点，请确认集群是否已添加节点"
        return 1
    fi

    local total_nodes=$(echo "$all_nodes" | wc -l | tr -d ' ')

    local all_node_names=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    # 按nodepool-name标签归类
    declare -A pool_nodes_map
    for node in $all_node_names; do
        local nodepool_name=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node\.k8s\.te/nodepool-name}' 2>/dev/null)
        if [[ -z "$nodepool_name" ]]; then
            nodepool_name="<未打nodepool标签>"
        fi
        pool_nodes_map["$nodepool_name"]="${pool_nodes_map[$nodepool_name]} $node"
    done

    # -------- 仅当存在异常时才打印详情 --------
    local has_issues=false

    for pool_name in "${!pool_nodes_map[@]}"; do
        local nodes_in_pool="${pool_nodes_map[$pool_name]}"
        local first_node=$(echo $nodes_in_pool | awk '{print $1}')
        local node_count=$(echo $nodes_in_pool | tr ' ' '\n' | grep -c .)

        # -- 规格一致性检测（内存和磁盘允许1%容差，同规格节点内核上报值可能有微小差异） --
        local prev_cpu=""
        local prev_mem=""
        local prev_disk=""
        local spec_homo=true
        for node in $nodes_in_pool; do
            local cpu=$(kubectl get node "$node" -o jsonpath='{.status.capacity.cpu}' 2>/dev/null)
            local mem=$(kubectl get node "$node" -o jsonpath='{.status.capacity.memory}' 2>/dev/null)
            local sys_disk=$(kubectl get node "$node" -o jsonpath='{.status.capacity.ephemeral-storage}' 2>/dev/null)
            if [[ -n "$prev_cpu" ]]; then
                if [[ "$cpu" != "$prev_cpu" ]]; then
                    spec_homo=false
                fi
                local mem_num="${mem//[A-Za-z]/}"
                local prev_mem_num="${prev_mem//[A-Za-z]/}"
                if [[ -n "$mem_num" && -n "$prev_mem_num" && "$mem_num" -gt 0 ]]; then
                    local mem_diff=$(awk "BEGIN {d=($mem_num-$prev_mem_num)/$prev_mem_num; print (d<0?-d:d)}")
                    if awk "BEGIN {exit !($mem_diff > 0.01)}"; then
                        spec_homo=false
                    fi
                elif [[ "$mem" != "$prev_mem" ]]; then
                    spec_homo=false
                fi
                local disk_num="${sys_disk//[A-Za-z]/}"
                local prev_disk_num="${prev_disk//[A-Za-z]/}"
                if [[ -n "$disk_num" && -n "$prev_disk_num" && "$disk_num" -gt 0 ]]; then
                    local disk_diff=$(awk "BEGIN {d=($disk_num-$prev_disk_num)/$prev_disk_num; print (d<0?-d:d)}")
                    if awk "BEGIN {exit !($disk_diff > 0.01)}"; then
                        spec_homo=false
                    fi
                elif [[ "$sys_disk" != "$prev_disk" ]]; then
                    spec_homo=false
                fi
            fi
            prev_cpu="$cpu"
            prev_mem="$mem"
            prev_disk="$sys_disk"
        done

        # -- 标签一致性检测 --
        local te_labels_base=$(kubectl get node "$first_node" -o jsonpath='{.metadata.labels}' 2>/dev/null |
            jq -r 'to_entries[] | select(.key | startswith("node.k8s.te/")) | "\(.key)=\(.value)"' 2>/dev/null | sort)
        local label_homo=true
        if [[ -n "$te_labels_base" ]]; then
            for node in $nodes_in_pool; do
                local node_te_labels=$(kubectl get node "$node" -o jsonpath='{.metadata.labels}' 2>/dev/null |
                    jq -r 'to_entries[] | select(.key | startswith("node.k8s.te/")) | "\(.key)=\(.value)"' 2>/dev/null | sort)
                if [[ "$node_te_labels" != "$te_labels_base" ]]; then
                    label_homo=false
                fi
            done
        fi

        # -- 污点一致性检测 --
        local te_taints_base=$(kubectl get node "$first_node" -o jsonpath='{.spec.taints}' 2>/dev/null |
            jq -r '.[] | select(.key | startswith("node.k8s.te/")) | "\(.key)=\(.value):\(.effect)"' 2>/dev/null | sort)
        local taint_homo=true
        if [[ -n "$te_taints_base" ]]; then
            for node in $nodes_in_pool; do
                local node_te_taints=$(kubectl get node "$node" -o jsonpath='{.spec.taints}' 2>/dev/null |
                    jq -r '.[] | select(.key | startswith("node.k8s.te/")) | "\(.key)=\(.value):\(.effect)"' 2>/dev/null | sort)
                if [[ "$node_te_taints" != "$te_taints_base" ]]; then
                    taint_homo=false
                fi
            done
        fi

        # 仅当存在不一致时打印详情
        if ! $spec_homo || ! $label_homo || ! $taint_homo; then
            has_issues=true
            echo ""
            echo -e "  ${YELLOW}! 发现节点池[$pool_name]配置不一致${NC}"
            echo "  ! 发现节点池[$pool_name]配置不一致" >>${LOG_FILE}

            if ! $spec_homo; then
                echo -e "    ${YELLOW}  规格不一致:${NC}"
                echo "    规格不一致:" >>${LOG_FILE}
                for node in $nodes_in_pool; do
                    local cpu=$(kubectl get node "$node" -o jsonpath='{.status.capacity.cpu}' 2>/dev/null)
                    local mem=$(kubectl get node "$node" -o jsonpath='{.status.capacity.memory}' 2>/dev/null)
                    local sys_disk=$(kubectl get node "$node" -o jsonpath='{.status.capacity.ephemeral-storage}' 2>/dev/null)
                    echo -e "    ${YELLOW}    - $node: CPU=$(format_cpu $cpu) / 内存=$(format_resource $mem) / 磁盘空间=$(format_resource $sys_disk)${NC}"
                    echo "    - $node: CPU=$(format_cpu $cpu) / 内存=$(format_resource $mem) / 磁盘空间=$(format_resource $sys_disk)" >>${LOG_FILE}
                done
            fi

            if ! $label_homo; then
                echo -e "    ${YELLOW}  标签不一致:${NC}"
                echo "    标签不一致:" >>${LOG_FILE}
                for node in $nodes_in_pool; do
                    local node_te_labels=$(kubectl get node "$node" -o jsonpath='{.metadata.labels}' 2>/dev/null |
                        jq -r 'to_entries[] | select(.key | startswith("node.k8s.te/")) | "\(.key)=\(.value)"' 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
                    [[ -z "$node_te_labels" ]] && node_te_labels="无"
                    echo -e "    ${YELLOW}    - $node: ${node_te_labels}${NC}"
                    echo "    - $node: ${node_te_labels}" >>${LOG_FILE}
                done
            fi

            if ! $taint_homo; then
                echo -e "    ${YELLOW}  污点不一致:${NC}"
                echo "    污点不一致:" >>${LOG_FILE}
                for node in $nodes_in_pool; do
                    local node_te_taints=$(kubectl get node "$node" -o jsonpath='{.spec.taints}' 2>/dev/null |
                        jq -r '.[] | select(.key | startswith("node.k8s.te/")) | "\(.key)=\(.value):\(.effect)"' 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
                    [[ -z "$node_te_taints" ]] && node_te_taints="无"
                    echo -e "    ${YELLOW}    - $node: ${node_te_taints}${NC}"
                    echo "    - $node: ${node_te_taints}" >>${LOG_FILE}
                done
            fi
        fi
    done

    if $has_issues; then
        log_warning "节点池检测完成，部分节点池内存在配置不一致，请查看上述详情"
    fi

    # -------- 节点池汇总 (属性为列的对齐表, 标签/污点多值多行堆叠) --------
    echo "" >&2
    echo -e "  ${BOLD}节点池汇总${NC}" >&2
    echo "" >>${LOG_FILE}
    echo "==================== 节点池汇总 ====================" >>${LOG_FILE}

    # 列定义
    local cols=("节点池名" "节点数" "CPU" "内存" "磁盘空间" "可分配CPU" "可分配内存" "可分配磁盘" "标签" "污点")
    local ncol=${#cols[@]}
    local gap="  "
    local SEP=$'\x1f' # 单元格分隔符(不可见字符, 避免与内容冲突)

    # 收集所有展开行(每池占 max(标签数,污点数) 行), 同时求每列最大显示宽
    local table_rows=()
    local colw=()
    local c
    for ((c = 0; c < ncol; c++)); do colw[c]=$(_disp_width "${cols[c]}"); done

    local pool_count=0
    for pool_name in "${!pool_nodes_map[@]}"; do
        ((pool_count++))
        local nodes_in_pool="${pool_nodes_map[$pool_name]}"
        local first_node=$(echo $nodes_in_pool | awk '{print $1}')
        local node_count=$(echo $nodes_in_pool | tr ' ' '\n' | grep -c .)

        local cpu=$(kubectl get node "$first_node" -o jsonpath='{.status.capacity.cpu}' 2>/dev/null)
        local mem=$(kubectl get node "$first_node" -o jsonpath='{.status.capacity.memory}' 2>/dev/null)
        local sys_disk=$(kubectl get node "$first_node" -o jsonpath='{.status.capacity.ephemeral-storage}' 2>/dev/null)
        local alloc_cpu=$(kubectl get node "$first_node" -o jsonpath='{.status.allocatable.cpu}' 2>/dev/null)
        local alloc_mem=$(kubectl get node "$first_node" -o jsonpath='{.status.allocatable.memory}' 2>/dev/null)
        local alloc_disk=$(kubectl get node "$first_node" -o jsonpath='{.status.allocatable.ephemeral-storage}' 2>/dev/null)

        # 标签/污点: 去 node.k8s.te/ 前缀以紧凑展示, 各值为数组(多值多行堆叠)
        local labels_raw=$(kubectl get node "$first_node" -o jsonpath='{.metadata.labels}' 2>/dev/null |
            jq -r 'to_entries[] | select(.key | startswith("node.k8s.te/")) | "\(.key|sub("node.k8s.te/";""))=\(.value)"' 2>/dev/null | sort)
        local taints_raw=$(kubectl get node "$first_node" -o jsonpath='{.spec.taints}' 2>/dev/null |
            jq -r '.[] | select(.key | startswith("node.k8s.te/")) | "\(.key|sub("node.k8s.te/";""))=\(.value):\(.effect)"' 2>/dev/null | sort)
        local label_arr=() taint_arr=()
        local l
        while IFS= read -r l; do [[ -n "$l" ]] && label_arr+=("$l"); done <<<"$labels_raw"
        while IFS= read -r l; do [[ -n "$l" ]] && taint_arr+=("$l"); done <<<"$taints_raw"
        [[ ${#label_arr[@]} -eq 0 ]] && label_arr=("<none>")
        [[ ${#taint_arr[@]} -eq 0 ]] && taint_arr=("<none>")

        local nrows=${#label_arr[@]}
        [[ ${#taint_arr[@]} -gt $nrows ]] && nrows=${#taint_arr[@]}

        local r
        for ((r = 0; r < nrows; r++)); do
            local vals=()
            if [[ $r -eq 0 ]]; then
                vals=("$pool_name" "$node_count" "$(format_cpu ${cpu})" "$(format_resource ${mem})"
                "$(format_resource ${sys_disk})" "$(format_cpu ${alloc_cpu})"
                "$(format_resource ${alloc_mem})" "$(format_resource ${alloc_disk})"
                "${label_arr[0]:-}" "${taint_arr[0]:-}")
            else
                vals=("" "" "" "" "" "" "" "" "${label_arr[r]:-}" "${taint_arr[r]:-}")
            fi
            local rowstr=""
            for ((c = 0; c < ncol; c++)); do
                rowstr+="${vals[c]}$SEP"
                local w=$(_disp_width "${vals[c]}")
                ((w > colw[c])) && colw[c]=$w
            done
            table_rows+=("$rowstr")
        done
    done

    # 打印表头 + 整宽分隔线 + 数据行(终端与日志同步)
    local hdr=""
    for ((c = 0; c < ncol; c++)); do
        hdr+="$(_pad_disp "${cols[c]}" "${colw[c]}")"
        ((c < ncol - 1)) && hdr+="$gap"
    done
    local total=0
    for ((c = 0; c < ncol; c++)); do total=$((total + colw[c])); done
    total=$((total + (ncol - 1) * ${#gap}))
    local ruleline=$(printf '%*s' "$total" '' | tr ' ' '-')
    echo "$hdr" | tee -a ${LOG_FILE}
    echo "$ruleline" | tee -a ${LOG_FILE}
    local row
    for row in "${table_rows[@]}"; do
        local cells=()
        IFS="$SEP" read -r -a cells <<<"$row"
        local line=""
        for ((c = 0; c < ncol; c++)); do
            line+="$(_pad_disp "${cells[c]}" "${colw[c]}")"
            ((c < ncol - 1)) && line+="$gap"
        done
        # 去行尾多余空格
        echo "${line%"${line##*[![:space:]]}"}" | tee -a ${LOG_FILE}
    done

    echo "" | tee -a ${LOG_FILE}
    echo "共发现: ${pool_count} 个节点池，${total_nodes} 个节点" | tee -a ${LOG_FILE}

    # -------- 全局节点资源概览 (直接调用kubectl) --------
    echo "" | tee -a ${LOG_FILE}
    echo "节点资源全局概览:" | tee -a ${LOG_FILE}
    kubectl get nodes -L node.k8s.te/nodepool-name 2>/dev/null | tee -a ${LOG_FILE}

    echo "" >>${LOG_FILE}

    if $has_issues; then
        return 1
    fi
    log_success "节点池检测完成，节点池归类与规格标签一致性检查通过"
    return 0
}

# ==================== 节点组契约校验(规格/付费类型/污点 vs 池名声明) ====================
# 与 discover_and_check_nodes(查"池内是否自洽")互补: 本函数查"池实际配置是否符合 nodepool-name 声明"。
# 节点组检测需求核心: 防云管理员错配规格/付费类型/污点导致容器与大数据云主机供需错位或误调度。
# 处置分级(已与需求方确认):
#   - 污点错配(spot池漏污点 / 污点value与池名付费类型不符) -> BLOCK(return 1), 安全关键且语义无歧义
#   - 规格/billing-mode标签错配 -> WARNING 不阻断(风格同 discover_and_check_nodes 的一致性告警)
# 期望规格来源: 解析 node.k8s.te/nodepool-name(必须标签, 形如 ${billing}-${spec}) 中的 -${spec} 段,
#   对比实际 status.capacity; 云厂商预留导致 capacity 略小于标称, 相对差值 <= SPEC_TOLERANCE 视为正常。
#   (instancespec 标签非必须, 不作为权威来源)

# od 与 on-demand 视为等价付费类型
_billing_match() {
    local a="$1" b="$2"
    [[ "$a" == "$b" ]] && return 0
    case "${a}|${b}" in
    "od|on-demand" | "on-demand|od") return 0 ;;
    esac
    return 1
}

check_nodepool_contract() {
    log_step "节点组契约校验(规格/付费类型/污点 vs 池名声明)"

    local platform="$1"
    local expected_str=$(get_expected_nodepools "$platform")
    if [[ -z "$expected_str" ]]; then
        log_info "  当前环境(${platform})无节点组规划(物理机/自建)，跳过节点组契约校验"
        record_result "节点组契约校验(规格/付费类型/污点)" "SKIP" "物理机/自建环境无节点组规划"
        return 0
    fi

    # 按 nodepool-name 标签归类(同 discover_and_check_nodes)
    local all_node_names=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    declare -A pool_nodes_map
    local node
    for node in $all_node_names; do
        local np=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node\.k8s\.te/nodepool-name}' 2>/dev/null)
        [[ -z "$np" ]] && np="<未打nodepool标签>"
        pool_nodes_map["$np"]="${pool_nodes_map[$np]} $node"
    done

    # taint_bad: 污点错配(安全关键, 计入FAIL); has_warn: 规格/标签/对账类(计入WARN)
    local taint_bad=false
    local has_warn=false
    local pool_name
    for pool_name in "${!pool_nodes_map[@]}"; do
        [[ "$pool_name" == "<未打nodepool标签>" ]] && continue
        local nodes_in_pool="${pool_nodes_map[$pool_name]}"
        local first_node=$(echo $nodes_in_pool | awk '{print $1}')

        # -- 解析池名: ${billing}-${cpu}c${mem}g --
        local billing="" exp_cpu="" exp_mem=""
        if [[ "$pool_name" =~ ^(reserved|od|on-demand|spot)-([0-9]+)c([0-9]+)g$ ]]; then
            billing="${BASH_REMATCH[1]}"
            exp_cpu="${BASH_REMATCH[2]}"
            exp_mem="${BASH_REMATCH[3]}"
        else
            log_warning "  节点池[${pool_name}]池名不符合规范 \${付费类型}-\${规格}(如 spot-32c128g)，无法据池名做契约校验，请核对 node.k8s.te/nodepool-name 标签拼写"
            has_warn=true
            continue
        fi

        # -- b. 规格契约(WARNING): 期望规格 vs 实际 capacity, 相对差值 <= SPEC_TOLERANCE 视为正常 --
        local cap_cpu=$(kubectl get node "$first_node" -o jsonpath='{.status.capacity.cpu}' 2>/dev/null)
        local cap_mem=$(kubectl get node "$first_node" -o jsonpath='{.status.capacity.memory}' 2>/dev/null)
        local cap_cpu_cores="${cap_cpu//[A-Za-z]/}"
        [[ "$cap_cpu" == *m ]] && cap_cpu_cores=$(awk "BEGIN{printf \"%.3f\", $cap_cpu_cores/1000}")
        # memory: K8S 通常上报 Ki, 换算为 Gi
        local cap_mem_num="${cap_mem//[A-Za-z]/}"
        local cap_mem_gi=$(awk "BEGIN{printf \"%.2f\", ${cap_mem_num:-0}/1024/1024}")
        if [[ -n "$cap_cpu_cores" ]] && awk "BEGIN{d=($cap_cpu_cores-$exp_cpu)/$exp_cpu; d=(d<0?-d:d); exit !(d>$SPEC_TOLERANCE)}"; then
            log_warning "  节点池[${pool_name}]CPU规格与池名声明不符: 期望 ${exp_cpu}C, 实际 capacity $(format_cpu $cap_cpu)(超出容差${SPEC_TOLERANCE})"
            has_warn=true
        elif [[ -n "$cap_cpu_cores" ]] && awk "BEGIN{exit !($cap_cpu_cores+0 < $exp_cpu+0)}"; then
            log_info "  节点池[${pool_name}]CPU capacity $(format_cpu $cap_cpu) 略低于标称 ${exp_cpu}C, 在容差${SPEC_TOLERANCE}内, 系容器实例预留机制(系统/内核占用)所致, 属正常现象"
        fi
        if [[ -n "$cap_mem_num" ]] && awk "BEGIN{d=($cap_mem_gi-$exp_mem)/$exp_mem; d=(d<0?-d:d); exit !(d>$SPEC_TOLERANCE)}"; then
            log_warning "  节点池[${pool_name}]内存规格与池名声明不符: 期望 ${exp_mem}Gi, 实际 capacity $(format_resource $cap_mem)(超出容差${SPEC_TOLERANCE})"
            has_warn=true
        elif [[ -n "$cap_mem_num" ]] && awk "BEGIN{exit !($cap_mem_gi+0 < $exp_mem+0)}"; then
            log_info "  节点池[${pool_name}]内存 capacity $(format_resource $cap_mem) 略低于标称 ${exp_mem}Gi, 在容差${SPEC_TOLERANCE}内, 系容器实例预留机制(系统/内核/kubelet占用)所致, 属正常现象"
        fi

        # -- c. billing-mode 标签契约(WARNING): 标签值 vs 池名前缀(od/on-demand 互认) --
        for node in $nodes_in_pool; do
            local node_billing=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node\.k8s\.te/billing-mode}' 2>/dev/null)
            if ! _billing_match "$node_billing" "$billing"; then
                log_warning "  节点池[${pool_name}]节点[${node}]付费类型标签与池名不符: node.k8s.te/billing-mode=${node_billing:-<空>}，池名声明为 ${billing}"
                has_warn=true
            fi
        done

        # -- d. 污点契约(FAIL): 污点错配是安全关键错误, 全程不阻断但在总览中标记为失败 --
        for node in $nodes_in_pool; do
            local taint_val=$(kubectl get node "$node" -o jsonpath='{.spec.taints[?(@.key=="node.k8s.te/billing-mode")].value}' 2>/dev/null)
            local taint_eff=$(kubectl get node "$node" -o jsonpath='{.spec.taints[?(@.key=="node.k8s.te/billing-mode")].effect}' 2>/dev/null)
            # d1. spot 池必须有 spot:NoSchedule 污点(不接受中断的服务不应被调度过来)
            if [[ "$billing" == "spot" ]]; then
                if [[ "$taint_val" != "spot" || "$taint_eff" != "NoSchedule" ]]; then
                    log_error "  [污点错配] spot池[${pool_name}]节点[${node}]缺失 node.k8s.te/billing-mode=spot:NoSchedule 污点(当前: ${taint_val:-无}:${taint_eff:-无})，不接受中断的服务可能被误调度到spot节点！"
                    taint_bad=true
                fi
            fi
            # d2. 任一池: 已打 billing-mode 污点但 value 与池名付费类型不符 -> 主动错配
            if [[ -n "$taint_val" ]] && ! _billing_match "$taint_val" "$billing"; then
                log_error "  [污点错配] 节点池[${pool_name}]节点[${node}]污点 node.k8s.te/billing-mode=${taint_val} 与池名付费类型(${billing})不符，存在主动错配风险！"
                taint_bad=true
            fi
        done
    done

    # -- e. 期望/实际对账(WARNING) --
    local p
    for pool_name in "${!pool_nodes_map[@]}"; do
        if [[ "$pool_name" == "<未打nodepool标签>" ]]; then
            log_warning "  存在未打 node.k8s.te/nodepool-name 标签的节点，无法纳入节点组管理，请补打标签"
            has_warn=true
            continue
        fi
        local found=false
        for p in $expected_str; do
            # p 可能是 OR 组 token(如 reserved-4c32g|od-4c32g): 命中任一候选即视为在期望内
            case "|${p}|" in
            *"|${pool_name}|"*)
                found=true
                break
                ;;
            esac
        done
        $found || {
            log_warning "  发现计划外节点池[${pool_name}](不在平台[${platform}]期望节点组[${expected_str}]内)，请确认是否多配或池名拼写错误"
            has_warn=true
        }
    done

    # 全程不阻断: 仅登记结果, 不 exit。污点错配->FAIL, 规格/标签/对账->WARN, 否则 PASS。
    if $taint_bad; then
        log_error "节点组契约校验发现污点错配(详见上述[污点错配]条目)，已记录为失败项，请修复后重跑"
        record_result "节点组契约校验(规格/付费类型/污点)" "FAIL" "存在污点错配(spot池漏污点或污点与池名付费类型不符)，详见日志"
    elif $has_warn; then
        log_warning "节点组契约校验完成: 污点契约通过，但存在规格/付费类型/对账类需关注项"
        record_result "节点组契约校验(规格/付费类型/污点)" "WARN" "污点契约通过；规格/付费类型/对账存在需关注项"
    else
        log_success "节点组契约校验通过(污点/规格/付费类型均符合池名声明)"
        record_result "节点组契约校验(规格/付费类型/污点)" "PASS" "污点/规格/付费类型均符合池名声明"
    fi
    return 0
}

# ==================== Pod部署启动检查（并发启动pod,探测所有节点池） ====================
# 解决"on-demand/spot弹性池0节点时kubectl不可见"的检测漏洞:
#   阶段A 按云平台映射(get_expected_nodepools)为每个期望池并发起带nodeSelector的探测Deployment
#         (逼0节点弹性池autoscaler 0->1扩容); 物理机/自建无节点池规划 -> 起单个无nodeSelector Pod
#   阶段B 统一等待全部Pod就绪(总超时180s); 对pending池检测events提前识别"无匹配节点池"
#         结论: 预期X个节点池可调度, 实际Y个可调度; Y<X 阻断交付
# 探测后由 main 调用 discover_and_check_nodes 枚举节点池现状(弹性池节点此时已可见),
# 并对每个就绪池的 Pod 做双向网络连通性测试。

# 生成单个探测Deployment
#  label_pool : probe-pool 标签值(始终非空, 物理机占位用 "default"), 供阶段B按 -l probe-pool=<x> 查询
#  selector_pool : nodeSelector 锁定的真实节点池名; 为空(物理机/自建)则不加 nodeSelector, 任意节点起服
# 解耦二者: 历史bug是标签值与nodeSelector复用同一参数, 物理机传空导致 probe-pool 标签为空串,
#           而查询用 probe-pool=default 永远查不到 -> Pod起来了却被误判超时。
# 三类 billing-mode 污点统一容忍。
_apply_probe_deployment() {
    local dname="$1"
    local label_pool="$2"
    local selector_pool="$3"
    local image="$4"
    local node_selector=""
    [[ -n "$selector_pool" ]] && node_selector="
      nodeSelector:
        node.k8s.te/nodepool-name: \"${selector_pool}\""
    # 物料落盘: 先写 yaml 到测试物料目录, 再 kubectl apply -f 该文件(资源回收后仍可凭此复现)
    _ensure_artifact_dir
    local manifest="${ARTIFACT_DIR}/${dname}.yaml"
    cat >"$manifest" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${dname}
  namespace: $NAMESPACE
  labels:
    app: ${PROBE_PREFIX}
    probe-pool: "${label_pool}"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PROBE_PREFIX}
      probe-pool: "${label_pool}"
  template:
    metadata:
      labels:
        app: ${PROBE_PREFIX}
        probe-pool: "${label_pool}"
    spec:${node_selector}
      containers:
      - name: nginx-probe
        image: ${image}
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5
      tolerations:
      - effect: NoSchedule
        key: node.k8s.te/billing-mode
        operator: Equal
        value: reserved
      - effect: NoSchedule
        key: node.k8s.te/billing-mode
        operator: Equal
        value: od
      - effect: NoSchedule
        key: node.k8s.te/billing-mode
        operator: Equal
        value: spot
EOF
    kubectl apply -f "$manifest" >/dev/null 2>&1
}

# 删除所有探测Deployment和临时NodePort Service(弹性池节点随之被autoscaler缩回0)
_clean_probe_deployments() {
    kubectl delete deployment -n "$NAMESPACE" -l app="${PROBE_PREFIX}" --ignore-not-found --wait=false >/dev/null 2>&1
    kubectl delete service -n "$NAMESPACE" -l app="${PROBE_PREFIX}" --ignore-not-found --wait=false >/dev/null 2>&1
}

# 节点池未通过状态的可读解释(供失败行附带说明, 帮助用户定位修复方向)
_pool_fail_reason() {
    case "$1" in
    timeout)
        echo "存在对应标签的节点池但调度异常(常见为出现预期外的污点/节点NotReady/资源不足)"
        ;;
    no-nodepool)
        echo "autoscaler未匹配到该节点池(常见为未采购创建该池/nodepool-name标签拼写错误)"
        ;;
    *)
        echo "未知状态"
        ;;
    esac
}

# 探测Pod容忍的业务污点(与 _apply_probe_deployment 的 tolerations 保持一致)。
# 形如 node.k8s.te/billing-mode=reserved:NoSchedule
_probe_tolerated_taint() {
    case "$1" in
    node.k8s.te/billing-mode=reserved:NoSchedule | \
        node.k8s.te/billing-mode=od:NoSchedule | \
        node.k8s.te/billing-mode=spot:NoSchedule)
        return 0
        ;;
    esac
    return 1
}

# 识别"云平台生命周期机制"自动打的污点(非业务误配), 命中则返回其人类可读释义, 否则返回空。
# 依据上一轮 CCE 实测: route-unreachable / autoscaler 缩容候选 等均由控制面自动管理。
_platform_taint_explain() {
    local key="$1"
    case "$key" in
    node.kubernetes.io/route-unreachable)
        echo "节点路由未就绪或正在缩容(CCE Yangtse 云原生网络在 VPC 路由写好前打此污点, 平台机制)"
        ;;
    node.kubernetes.io/not-ready | node.kubernetes.io/unreachable)
        echo "节点未就绪/失联(kubelet 未上报就绪, 平台内置条件污点)"
        ;;
    node.kubernetes.io/network-unavailable)
        echo "节点网络未就绪(CNI/路由未完成, 平台内置条件污点)"
        ;;
    node.kubernetes.io/unschedulable)
        echo "节点被封锁(cordon, 平台内置条件污点)"
        ;;
    node.kubernetes.io/memory-pressure | node.kubernetes.io/disk-pressure | node.kubernetes.io/pid-pressure)
        echo "节点资源压力(kubelet 内置条件污点)"
        ;;
    node.cloudprovider.kubernetes.io/uninitialized | node.cloudprovider.kubernetes.io/shutdown)
        echo "节点云侧未初始化/关机(cloud-controller 机制)"
        ;;
    DeletionCandidateOfClusterAutoscaler | ToBeDeletedByClusterAutoscaler)
        echo "autoscaler 正在缩容该弹性池(空闲节点被标记为删除候选, 平台机制; 可重试或确认是否需要常驻)"
        ;;
    *)
        echo ""
        ;;
    esac
}

# 诊断 timeout 节点池: 按 nodepool-name 标签过滤节点, 逐节点分析就绪状态与污点,
# 区分"探测已容忍的业务污点 / 已知平台机制污点 / 预期外污点(红色告警)"。
# 解释为何"标签节点存在却调度失败"。结果同时打印并存盘到 desc_file。
_diagnose_timeout_pool() {
    local pname="$1" desc_file="$2"
    local nodes
    nodes=$(kubectl get nodes -l node.k8s.te/nodepool-name="$pname" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    if [[ -z "$nodes" ]]; then
        log_warning "     诊断: 未发现带标签 node.k8s.te/nodepool-name=${pname} 的节点(可能 autoscaler 已将其缩回, 或标签确实缺失)"
        echo "==== timeout 节点池[${pname}] 诊断: 无匹配标签节点 ====" >>"$desc_file"
        return 0
    fi

    local node
    for node in $nodes; do
        local ready
        ready=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        local unsched
        unsched=$(kubectl get node "$node" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)
        if [[ "$ready" != "True" ]]; then
            log_error "     诊断[${node}]: 节点未就绪(Ready=${ready:-未知})，调度器不会向其派发Pod，请排查节点健康/kubelet"
        else
            log_info "     诊断[${node}]: 节点 Ready=True${unsched:+, unschedulable=$unsched}"
        fi

        # 逐条污点分析: 仅 NoSchedule/NoExecute 会阻断调度; PreferNoSchedule 为软污点(单独不致Pending)
        local taints
        taints=$(kubectl get node "$node" -o jsonpath='{range .spec.taints[*]}{.key}={.value}:{.effect}{"\n"}{end}' 2>/dev/null)
        if [[ -z "$taints" ]]; then
            log_info "     诊断[${node}]: 无污点。若仍Pending请排查资源不足/nodeSelector/亲和性"
        fi
        local t key effect kv explain blocker_found=false
        while IFS= read -r t; do
            [[ -z "$t" ]] && continue
            key="${t%%=*}"
            effect="${t##*:}"
            kv="${t%:*}" # key=value
            # 探测已容忍的业务污点 -> 不是阻断原因
            if _probe_tolerated_taint "$t"; then
                log_info "     诊断[${node}]: 污点[${t}] 探测Pod已容忍，非阻断原因"
                continue
            fi
            # PreferNoSchedule 软污点单独不致Pending
            if [[ "$effect" == "PreferNoSchedule" ]]; then
                explain=$(_platform_taint_explain "$key")
                log_info "     诊断[${node}]: 软污点[${t}]${explain:+ —— $explain}(PreferNoSchedule不强制阻断)"
                continue
            fi
            # 硬污点(NoSchedule/NoExecute)且探测未容忍 -> 阻断
            blocker_found=true
            explain=$(_platform_taint_explain "$key")
            if [[ -n "$explain" ]]; then
                log_warning "     诊断[${node}]: 阻断污点[${t}] —— ${explain}。探测Pod未容忍故Pending(平台机制, 非业务误配)"
            else
                log_error "     诊断[${node}]: 预期外污点[${t}]!! 该污点非业务/平台已知类型且为${effect}，探测Pod未容忍导致调度失败，请确认是否人为误打或第三方组件注入，按需为业务Pod补容忍或清除该污点"
            fi
        done <<<"$taints"

        if [[ "$ready" == "True" && "$blocker_found" == false && -n "$taints" ]]; then
            log_info "     诊断[${node}]: 未发现阻断性硬污点，超时可能为弹性池扩容竞速/资源不足，可重试确认"
        fi

        # 节点污点快照存盘, 便于事后核对
        {
            echo "==== timeout 节点池[${pname}] 节点[${node}] Ready=${ready} 污点快照 ===="
            echo "${taints:-<无污点>}"
        } >>"$desc_file"
    done
    return 0
}

# 探测结果(供 main 中 item6 枚举之后的网络连通性测试遍历使用):
#   PROBE_READY_POOLS  空格分隔的就绪池名列表(物理机无池时为单个 "default")
#   PROBE_POD_NAME / PROBE_POD_IP  以池名为key的就绪Pod名/IP
declare -gA PROBE_POD_NAME PROBE_POD_IP
PROBE_READY_POOLS=""

# iptables 跨网段持久化提醒(由 ensure_iptables_for_pod_cidr 命中跨/8网段时填充, 供总览登记关注项)
IPTABLES_PERSIST_CIDR=""
IPTABLES_PERSIST_POD_IP=""
IPTABLES_PERSIST_LOCAL_IP=""

pod_deploy_check() {
    log_step "Pod部署启动检查(并发探测所有节点池)"
    ensure_namespace

    local platform="$1"
    local pools_str=$(get_expected_nodepools "$platform")

    # ---- 槽位(slot)模型: 每个 slot 是一档需求, 可能是单池名, 也可能是 "A|B" 二选一 OR 组 ----
    #   slot_order[]      : 各档的原始 token(如 "reserved-4c32g|od-4c32g" 或 "spot-32c128g")
    #   SLOT_MEMBERS[i]   : 该档实际探测的池名(空格分隔), 由 OR 组裁决后确定
    #   POOL_SLOT[name]   : 池名 -> 所属 slot 下标(供就绪后短路同档兄弟)
    #   pool_order[]      : 所有待探测池名的扁平列表(沿用阶段A/B 既有按池名探测的机制)
    local slot_order=()
    declare -A SLOT_MEMBERS
    declare -A POOL_SLOT
    local pool_order=()

    if [[ -z "$pools_str" ]]; then
        # 物理机/自建: 无节点池规划, 用占位池名 default 起一个无 nodeSelector 的 Pod
        # (注意: 占位名须为合法的K8S资源名/标签值, 不能含 <> 等字符)
        slot_order=("default")
        SLOT_MEMBERS[0]="default"
        POOL_SLOT[default]=0
        pool_order=("default")
        log_info "  当前环境无节点池规划(物理机/自建)，起单个无 nodeSelector 探测 Pod"
    else
        read -r -a slot_order <<<"$pools_str"
        # OR 组裁决: 先按现存节点的 nodepool-name 标签选"存在的那个", 都不存在则回退探测全部候选
        local existing_np=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.labels.node\.k8s\.te/nodepool-name}{"\n"}{end}' 2>/dev/null)
        local i token
        for i in "${!slot_order[@]}"; do
            token="${slot_order[$i]}"
            if [[ "$token" != *"|"* ]]; then
                # 单池档: 直接探测
                SLOT_MEMBERS[$i]="$token"
            else
                local cands=() existing=() c
                IFS='|' read -r -a cands <<<"$token"
                for c in "${cands[@]}"; do
                    echo "$existing_np" | grep -qx "$c" && existing+=("$c")
                done
                if [[ ${#existing[@]} -gt 0 ]]; then
                    SLOT_MEMBERS[$i]="${existing[*]}"
                    log_info "  二选一档[${token}]按现存节点标签选定: ${BOLD}${existing[*]}${NC}"
                else
                    SLOT_MEMBERS[$i]="${cands[*]}"
                    log_info "  二选一档[${token}]无候选有现存节点，回退并发探测全部候选(任一就绪即过，胜出后即清理其余避免多起弹性节点): ${cands[*]}"
                fi
            fi
            local m
            for m in ${SLOT_MEMBERS[$i]}; do
                POOL_SLOT[$m]=$i
                pool_order+=("$m")
            done
        done
    fi

    declare -A POOL_EXIST
    local current_image="${NGINX_IMAGE}"
    local total_slots=${#slot_order[@]}

    # -------- 阶段A: 按平台映射并发起服探测 --------
    log_section "阶段A: 为${total_slots}档期望节点池(共${#pool_order[@]}个探测目标)并发起服探测"
    local pname
    for pname in "${pool_order[@]}"; do
        POOL_EXIST[$pname]="pending"
        # label_pool 用 pname(始终非空, 供阶段B查询); selector_pool 在物理机占位 default 时传空(不锁节点池)
        local sel_pool="$pname"
        [[ "$pname" == "default" ]] && sel_pool=""
        log_info "  起服探测: ${BOLD}${pname}${NC}"
        _apply_probe_deployment "${PROBE_PREFIX}-${pname}" "$pname" "$sel_pool" "$current_image"
    done

    # -------- 阶段B: 统一等待全部就绪(180s),并对pending池识别"无匹配节点池" --------
    log_section "阶段B: 等待探测Pod就绪(总超时${POD_PROBE_TIMEOUT}s,弹性池冷启动需1~2分钟)"
    local elapsed=0
    local interval=10
    while [[ $elapsed -lt $POD_PROBE_TIMEOUT ]]; do
        local all_done=true
        local image_pull_failing=false

        for pname in "${pool_order[@]}"; do
            # ready / no-nodepool / sibling-skip 为终态, 不再等待
            case "${POOL_EXIST[$pname]}" in
            ready | no-nodepool | sibling-skip) continue ;;
            esac

            local phase=$(kubectl get pods -n $NAMESPACE -l probe-pool=${pname} -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
            local waiting_reason=$(kubectl get pods -n $NAMESPACE -l probe-pool=${pname} \
                -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)

            if [[ "$phase" == "Running" ]]; then
                POOL_EXIST[$pname]="ready"
                PROBE_POD_NAME[$pname]=$(kubectl get pods -n $NAMESPACE -l probe-pool=${pname} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
                PROBE_POD_IP[$pname]=$(kubectl get pods -n $NAMESPACE -l probe-pool=${pname} -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
                # 同档兄弟短路: 该档已有就绪池, 其余仍 pending 的兄弟立即停探并删除其探测Deployment,
                # 避免 OR 组回退场景下同时拉起多个弹性节点(计费)。
                local myslot="${POOL_SLOT[$pname]}"
                local sib
                for sib in ${SLOT_MEMBERS[$myslot]}; do
                    if [[ "$sib" != "$pname" && "${POOL_EXIST[$sib]}" == "pending" ]]; then
                        POOL_EXIST[$sib]="sibling-skip"
                        kubectl delete deployment "${PROBE_PREFIX}-${sib}" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1
                        log_info "  二选一档已由[${pname}]就绪满足，停探并清理同档候选[${sib}](避免多起弹性节点)"
                    fi
                done
                continue
            fi

            # pending池: 检测该池Pod自身events是否为autoscaler"拒绝扩容/无匹配节点池"。
            # 仅匹配 autoscaler 明确拒绝的签名(NotTriggerScaleUp),不匹配裸 "0/N nodes are available"
            # ——后者在弹性池0->1正常扩容等待期间也会出现,会误判健康池。命中则提前判负不再等待。
            local pod_desc=$(kubectl describe pods -n $NAMESPACE -l probe-pool=${pname} 2>/dev/null)
            if echo "${pod_desc}" | grep -qiE "didn't trigger scale-up|did not trigger scale-up|missing matching nodepool|no matching node group|pod didn't trigger scale-up"; then
                POOL_EXIST[$pname]="no-nodepool"
                log_warning "  节点池[${pname}]无匹配节点池/autoscaler拒绝扩容(疑似未打标签或未采购该池)，停止等待"
                continue
            fi

            all_done=false
            if [[ "$waiting_reason" == "ErrImagePull" || "$waiting_reason" == "ImagePullBackOff" ]]; then
                image_pull_failing=true
            fi
        done

        $all_done && break

        # 镜像拉取失败 -> 与实际部署来源(docker-ta.thinkingdata.cn)一致, 无备用仓库可回退。
        # 拉取失败大概率是容器集群网络策略未放行该仓库, 直接强提示并停止等待(不再切换备用镜像)。
        if $image_pull_failing; then
            log_error "  ${IMAGE_PULL_FAIL_HINT}"
            kubectl get pods -n $NAMESPACE -l app=${PROBE_PREFIX} -o wide >>${LOG_FILE} 2>&1
            break
        fi

        # 进度按"档"统计就绪(OR 组任一就绪即算该档就绪)
        local ready_slots_now=0 si
        for si in "${!slot_order[@]}"; do
            local mm
            for mm in ${SLOT_MEMBERS[$si]}; do
                [[ "${POOL_EXIST[$mm]}" == "ready" ]] && {
                    ((ready_slots_now++))
                    break
                }
            done
        done

        sleep $interval
        ((elapsed += interval))
        log_info "  探测中... 已等待${elapsed}s/${POD_PROBE_TIMEOUT}s (就绪 ${ready_slots_now}/${total_slots} 档)"
    done

    # 未达终态的池标记为timeout(sibling-skip 不算超时),并将describe落盘到测试物料目录便于排查
    for pname in "${pool_order[@]}"; do
        case "${POOL_EXIST[$pname]}" in
        ready | no-nodepool | sibling-skip) ;;
        *)
            POOL_EXIST[$pname]="timeout"
            log_warning "  节点池[${pname}]探测超时: 请确认该池节点的 node.k8s.te/nodepool-name 标签是否存在且拼写与期望池名[${pname}]完全一致(常见为标签拼写错误或未采购该池)"
            ;;
        esac
    done

    # 为所有未通过节点池(timeout/no-nodepool)统一保存 Pod describe 到测试物料目录
    _ensure_artifact_dir
    for pname in "${pool_order[@]}"; do
        case "${POOL_EXIST[$pname]}" in
        ready | sibling-skip) ;;
        *)
            local desc_file="${ARTIFACT_DIR}/describe_pod_${PROBE_PREFIX}-${pname}.txt"
            {
                echo "==== 未通过节点池[${pname}] 状态=${POOL_EXIST[$pname]} Pod describe ===="
                kubectl describe pods -n "$NAMESPACE" -l probe-pool=${pname} 2>&1
            } >"$desc_file"
            ;;
        esac
    done

    # -------- 阶段性结论: 按"档"统计 预期X档可调度 / 实际Y档可调度(OR 组任一就绪即该档通过) --------
    # 不阻断策略: 未通过的档红色标注原因, 就绪档继续后续检查(网络连通性等)。
    local expected=$total_slots
    local ready=0
    local failed_slots=""
    PROBE_READY_POOLS=""
    local si
    for si in "${!slot_order[@]}"; do
        local token="${slot_order[$si]}"
        local slot_ready=false
        local m
        for m in ${SLOT_MEMBERS[$si]}; do
            if [[ "${POOL_EXIST[$m]}" == "ready" ]]; then
                slot_ready=true
                PROBE_READY_POOLS="${PROBE_READY_POOLS} ${m}"
            fi
        done
        if $slot_ready; then
            ((ready++))
        else
            # 该档所有候选均未就绪: 逐候选红色标注原因 + 落盘/诊断
            failed_slots="${failed_slots} [${token}]"
            for m in ${SLOT_MEMBERS[$si]}; do
                local st="${POOL_EXIST[$m]}"
                local desc_file="${ARTIFACT_DIR}/describe_pod_${PROBE_PREFIX}-${m}.txt"
                log_error "  ✗ 节点池[${m}]未通过: 状态=${st} —— $(_pool_fail_reason "$st")"
                log_error "     排查详情(describe)已存盘: ${desc_file}"
                [[ "$st" == "timeout" ]] && _diagnose_timeout_pool "$m" "$desc_file"
            done
            [[ "$token" == *"|"* ]] && log_error "  (二选一档[${token}]的候选均未就绪，该档判未通过)"
        fi
    done
    log_info "阶段性结论: 预期 ${expected} 档节点池可调度，实际 ${ready} 档可调度"

    if [[ $ready -lt $expected ]]; then
        log_error "Pod部署启动检查: 存在未通过节点池档[${failed_slots# }]，原因已红色标注于上。按非阻断策略不中断流程，继续对 ${ready} 档就绪节点池执行后续检查"
        log_error "请到控制台检查修复节点池配置(污点/标签/采购)，并重试确认所有节点池就绪后再进行业务服部署！如客户需求仅需部分节点池就绪可忽略本提示。"
        if [[ $ready -eq 0 ]]; then
            record_result "Pod部署启动检查(节点池可调度性)" "FAIL" "预期${expected}档节点池，0档可调度，全部未通过:${failed_slots# }"
        else
            record_result "Pod部署启动检查(节点池可调度性)" "FAIL" "预期${expected}档，仅${ready}档可调度；未通过:${failed_slots# }"
        fi
    else
        log_success "Pod部署启动检查通过：全部${expected}档节点池均可调度起Pod(弹性池autoscaler 0->1已验证)"
        record_result "Pod部署启动检查(节点池可调度性)" "PASS" "全部${expected}档节点池均可调度(弹性池0->1已验证)"
    fi
    # 注意: 不在此清理探测资源——就绪池的探测Deployment需存活到 run_network_checks_per_pool 做完网络测试后统一清理
    return 0
}

# ==================== Pod部署与镜像拉取函数 ====================
# 逻辑：创建deployment -> 检测镜像拉取失败 -> patch新镜像并等待RS重建 -> 避免多RS残留
deploy_test_nginx() {
    log_step "测试K8S环境部署Pod"

    local current_image="${NGINX_IMAGE}"
    local deployment_name="nginx-test"

    log_info "使用镜像: ${current_image}"

    # 使用声明式Deployment模版，支持spot和reserved两种billing-mode污点容忍
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-test
  namespace: $NAMESPACE
  labels:
    app: nginx-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-test
  template:
    metadata:
      labels:
        app: nginx-test
    spec:
      containers:
      - name: nginx-test
        image: ${current_image}
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5
      tolerations:
      - effect: NoSchedule
        key: node.k8s.te/billing-mode
        operator: Equal
        value: spot
      - effect: NoSchedule
        key: node.k8s.te/billing-mode
        operator: Equal
        value: reserved
EOF

    # 等待Pod启动
    echo "等待Pod启动, 预期2分钟内启动..."
    sleep 5
    local TIMEOUT=120
    local elapsed=0
    local POD_READY=false
    POD_NAME=""
    POD_IP=""

    while [ $elapsed -lt $TIMEOUT ]; do
        local pod_phase=$(kubectl get pods -n $NAMESPACE -l app=${deployment_name} -o jsonpath='{.items[0].status.phase}' 2>/dev/null)

        # 检测镜像拉取失败（通过 containerStatus 判断）
        local container_state=$(kubectl get pods -n $NAMESPACE -l app=${deployment_name} \
            -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)

        if [[ "$container_state" == "ErrImagePull" || "$container_state" == "ImagePullBackOff" ]]; then
            # 镜像统一来自 docker-ta.thinkingdata.cn(与实际部署一致), 无备用仓库可回退。
            # 拉取失败大概率是容器集群网络策略未放行该仓库 —— 强提示并判负。
            log_error "${IMAGE_PULL_FAIL_HINT}"
            kubectl describe pods -n $NAMESPACE -l app=${deployment_name} >>${LOG_FILE} 2>&1
            return 1
        fi

        if [[ "$pod_phase" == "Running" ]]; then
            POD_READY=true
            POD_NAME=$(kubectl get pods -n $NAMESPACE -l app=${deployment_name} -o jsonpath='{.items[0].metadata.name}')
            POD_IP=$(kubectl get pods -n $NAMESPACE -l app=${deployment_name} -o jsonpath='{.items[0].status.podIP}')
            break
        fi

        echo "等待Pod启动... (状态: ${pod_phase:-未知})"
        sleep 5
        ((elapsed += 5))
    done

    if ! $POD_READY; then
        log_error "Pod未在${TIMEOUT}秒内启动，请执行以下命令人工排查:"
        log_error "常见原因："
        log_error "  1. 镜像仓库 docker-ta.thinkingdata.cn 无法访问(大概率容器集群网络策略未放行): ${IMAGE_PULL_FAIL_HINT}"
        log_error "  2. K8S无可用实例资源供调度"
        log_error "  3. 节点存在spot和reserved两种billing-mode污点之外其他意外污点"
        log_error "kubectl describe pods -n $NAMESPACE -l app=${deployment_name}"
        kubectl describe pods -n $NAMESPACE -l app=${deployment_name} >>${LOG_FILE} 2>&1
        return 1
    fi

    log_info "Pod Name: $POD_NAME"
    log_info "Pod IP: $POD_IP"
    log_info "使用镜像: $current_image"
    log_success "K8S环境部署Pod正常"
    kubectl get pods -n $NAMESPACE -l app=${deployment_name} -o wide >>${LOG_FILE}
    return 0
}

# ==================== iptables放行Pod网段 ====================
# 当Pod IP与本机IP不在同一/8网段时，在本机iptables放行Pod所在/8网段，
# 确保后续本地服务器<->Pod双向网络连通性检查不会因iptables拦截而失败。
# 注意：仅在脚本执行所在机(ta1)本地放行；分布式集群其余节点需用户手动配置。
ensure_iptables_for_pod_cidr() {
    log_section "确保iptables放行Pod网段"

    if [[ -z "$POD_IP" ]]; then
        log_warning "未获取到Pod IP，跳过iptables放行"
        return 0
    fi

    # 本机IP：复用脚本约定，从 /etc/hosts 取 ta1 对应IP
    local local_ip=$(grep -w ta1 /etc/hosts | head -1 | awk '{print $1}')
    if [[ -z "$local_ip" ]]; then
        log_warning "未在 /etc/hosts 找到 ta1 条目，无法确定本机IP，跳过同网段判断"
        return 0
    fi

    # 取首段做/8网段比较
    local pod_octet1="${POD_IP%%.*}"
    local local_octet1="${local_ip%%.*}"

    if [[ "$pod_octet1" == "$local_octet1" ]]; then
        log_success "Pod IP(${POD_IP})与本机IP(${local_ip})处于同一/8网段(${local_octet1}.0.0.0/8)，无需额外放行"
        return 0
    fi

    local pod_cidr="${pod_octet1}.0.0.0/8"
    log_info "Pod IP(${POD_IP})与本机IP(${local_ip})不在同一/8网段，本机iptables放行Pod网段: ${pod_cidr}"
    # 记录跨网段事实, 供总览登记"需在 install.properties 持久化放行"的关注项(取首次命中的Pod IP)
    IPTABLES_PERSIST_CIDR="$pod_cidr"
    IPTABLES_PERSIST_POD_IP="$POD_IP"
    IPTABLES_PERSIST_LOCAL_IP="$local_ip"

    if ! command -v iptables &>/dev/null; then
        log_warning "未检测到iptables命令，跳过自动放行，请手动放行Pod网段: ${pod_cidr}"
        return 0
    fi

    # 幂等放行：规则已存在(-C成功)则跳过，否则追加(-A)
    local proto
    for proto in udp tcp; do
        if iptables -C INPUT -s "${pod_cidr}" -p "${proto}" -j ACCEPT &>/dev/null; then
            log_info "iptables已存在放行规则(${proto} ${pod_cidr})，跳过"
        else
            iptables -A INPUT -s "${pod_cidr}" -p "${proto}" -j ACCEPT
            log_info "已添加iptables放行规则: -A INPUT -s ${pod_cidr} -p ${proto} -j ACCEPT"
        fi
    done

    # 持久化iptables规则
    service iptables save &>/dev/null && log_info "iptables规则已持久化(service iptables save)" ||
        log_warning "iptables规则持久化失败(service iptables save)，重启后可能失效，请手动确认"

    log_success "本机iptables已放行Pod网段: ${pod_cidr}"
    log_error "请将cloud.intranet.segment=${pod_cidr}策略持久化到install.properties中确保全集群内网放行！"

    # 分布式集群提示：除ta1外若存在其他ta节点，本脚本不自动处理，提醒用户在install.properties配置Pod网段
    local ta_hosts_count=$(grep -E -c '[[:space:]]ta[0-9]+([[:space:]]|$)' /etc/hosts 2>/dev/null)
    if [[ "${ta_hosts_count:-0}" -gt 1 ]]; then
        log_error "检测到分布式集群环境(本脚本仅放行了本机ta1的iptables)，请务必在install.properties中配置 cloud.intranet.segment=${pod_cidr} 持久化放行全集群内网！"
    fi

    return 0
}

test_localhost_to_pod_connectivity() {
    log_step "本地服务器访问Pod网络连通性检查(兼容性验证)"
    if curl --fail --silent --show-error --connect-timeout 5 --max-time 10 "http://${POD_IP}/" >/dev/null 2>&1; then
        log_success "测试本地服务器访问POD网络正常"
        return 0
    fi
    log_warning "本地服务器无法直连Pod IP(${POD_IP})，这属于兼容性关注项，可能原因："
    log_warning "  1. 本地服务器和K8S绑定的安全组未相互放行所有流量"
    log_warning "  2. K8S CNI未允许直连Pod ip，常见于内置/自建K8S"
    log_warning "可能影响：这并不意味着无法部署服务，请以下方探测K8S service结果为准；如service探测通过则认为网络通畅，反之则一定不通畅需要检查放行网络安全策略！"
    return 1
}

_capture_service_diagnostics() {
    local service_name="$1" detail="${ARTIFACT_DIR}/describe_service_${1}.txt"
    {
        echo "==== Service ${service_name} ===="
        kubectl describe service "$service_name" -n "$NAMESPACE" 2>&1
        echo "==== Endpoints ${service_name} ===="
        kubectl get endpoints "$service_name" -n "$NAMESPACE" -o yaml 2>&1
        echo "==== EndpointSlices selector service-name=${service_name} ===="
        kubectl get endpointslice -n "$NAMESPACE" -l "kubernetes.io/service-name=${service_name}" -o yaml 2>&1
    } >"$detail"
    log_error "Service诊断已存盘: ${detail}"
}

# 为指定节点池创建临时 NodePort Service，先验证集群内 Service，再验证 NodePort 和 ta1 入口。
test_localhost_to_service_connectivity() {
    local pname="$1" service_name="${PROBE_PREFIX}-${pname}-svc"
    local manifest="${ARTIFACT_DIR}/${service_name}.yaml"
    local pod_node node_ip node_port cluster_ip endpoint_ips elapsed=0
    local body rc stage_file

    log_step "本地服务器访问Kubernetes Service连通性检查(NodePort)"
    _ensure_artifact_dir
    cat >"$manifest" <<EOF_SERVICE
apiVersion: v1
kind: Service
metadata:
  name: ${service_name}
  namespace: ${NAMESPACE}
  labels:
    app: ${PROBE_PREFIX}
    probe-pool: "${pname}"
spec:
  type: NodePort
  externalTrafficPolicy: Cluster
  selector:
    app: ${PROBE_PREFIX}
    probe-pool: "${pname}"
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: 80
EOF_SERVICE
    if ! kubectl apply -f "$manifest" >/dev/null 2>&1; then
        log_error "节点池[${pname}]创建NodePort Service失败: ${service_name}，请检查Service创建RBAC权限"
        return 1
    fi

    node_port=$(kubectl get service "$service_name" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
    cluster_ip=$(kubectl get service "$service_name" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    pod_node=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    node_ip=$(kubectl get node "$pod_node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    if [[ -z "$node_port" || -z "$cluster_ip" || -z "$pod_node" || -z "$node_ip" ]]; then
        log_error "节点池[${pname}]无法获取Service ClusterIP/NodePort或探测Pod所在节点InternalIP(service=${service_name}, clusterIP=${cluster_ip:-未知}, node=${pod_node:-未知}, port=${node_port:-未知})"
        _capture_service_diagnostics "$service_name"
        return 1
    fi

    while [[ $elapsed -lt 30 ]]; do
        endpoint_ips=$(kubectl get endpoints "$service_name" -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
        if printf '%s\n' "$endpoint_ips" | tr ' ' '\n' | grep -qx "$POD_IP"; then break; fi
        sleep 2
        ((elapsed += 2))
    done
    if ! printf '%s\n' "$endpoint_ips" | tr ' ' '\n' | grep -qx "$POD_IP"; then
        log_error "节点池[${pname}]的Service ${service_name} 在30秒内未发现就绪Endpoint(PodIP=${POD_IP})，无法确认集群内Service正常"
        _capture_service_diagnostics "$service_name"
        return 1
    fi

    stage_file="${ARTIFACT_DIR}/curl_service_${service_name}_clusterip.txt"
    body=$(kubectl exec "$POD_NAME" -n "$NAMESPACE" -- curl --fail --silent --show-error --connect-timeout 5 --max-time 10 "http://${cluster_ip}:80/" 2>&1); rc=$?
    printf 'stage=集群内Service(ClusterIP)\nexit_code=%s\n%s\n' "$rc" "$body" >"$stage_file"
    if [[ $rc -ne 0 || "$body" != *"Welcome to nginx!"* ]]; then
        log_error "节点池[${pname}]集群内Service(ClusterIP)异常: ${cluster_ip}:80，NodePort入口测试无意义"
        _capture_service_diagnostics "$service_name"
        return 1
    fi
    log_success "节点池[${pname}]集群内Service(ClusterIP)正常: ${cluster_ip}:80"

    stage_file="${ARTIFACT_DIR}/curl_service_${service_name}_pod_nodeport.txt"
    body=$(kubectl exec "$POD_NAME" -n "$NAMESPACE" -- curl --fail --silent --show-error --connect-timeout 5 --max-time 10 "http://${node_ip}:${node_port}/" 2>&1); rc=$?
    printf 'stage=Pod内访问NodePort\nexit_code=%s\n%s\n' "$rc" "$body" >"$stage_file"
    if [[ $rc -ne 0 || "$body" != *"Welcome to nginx!"* ]]; then
        log_error "节点池[${pname}]Pod内访问NodePort失败: ${node_ip}:${node_port}，请排查NodePort数据面、kube-proxy或CNI"
        _capture_service_diagnostics "$service_name"
        return 1
    fi
    log_success "节点池[${pname}]Pod内访问NodePort正常: ${node_ip}:${node_port}"

    log_info "测试本地服务器 -> NodePort Service: ${node_ip}:${node_port} -> ${service_name} -> 节点池[${pname}]探测Pod"
    stage_file="${ARTIFACT_DIR}/curl_service_${service_name}_ta1_nodeport.txt"
    body=$(curl --fail --silent --show-error --connect-timeout 5 --max-time 10 "http://${node_ip}:${node_port}/" 2>&1); rc=$?
    printf 'stage=ta1访问NodePort\nexit_code=%s\n%s\n' "$rc" "$body" >"$stage_file"
    if [[ $rc -eq 0 && "$body" == *"Welcome to nginx!"* ]]; then
        log_success "节点池[${pname}]本地服务器访问Kubernetes Service正常(Node=${node_ip}, NodePort=${node_port})"
        return 0
    fi
    log_error "节点池[${pname}]本地服务器无法访问Kubernetes Service(${node_ip}:${node_port}, service=${service_name})"
    log_error "可能原因：1. 本地服务器和K8S绑定的安全组未相互放行所有流量；2. 本地服务器、K8S Node路由异常，特殊Case可团队内沟通反馈"
    _capture_service_diagnostics "$service_name"
    return 1
}


test_pod_to_localhost_connectivity() {
    log_step "Pod访问本地服务器网络连通性检查"
    LOCAL_SERVER_IP=$(grep -w ta1 /etc/hosts | head -1 | awk '{print $1}')
    LOCAL_SERVER_PORT=19039

    if [[ -z "$LOCAL_SERVER_IP" ]]; then
        log_error "未在 /etc/hosts 中找到 ta1 主机条目，无法确定本地服务器IP，跳过Pod访问本地服务器检测"
        log_error "  请确认 /etc/hosts 中已配置 ta1 -> 本地服务器IP 映射"
        return 1
    fi

    if nc -z -w 2 $LOCAL_SERVER_IP $LOCAL_SERVER_PORT 2>/dev/null; then
        log_info "确认本地ta1监听的监控端口: $LOCAL_SERVER_IP:$LOCAL_SERVER_PORT [OK]"
    else
        LOCAL_SERVER_PORT=9100
        log_info "切换为exporter端口: $LOCAL_SERVER_IP:$LOCAL_SERVER_PORT"
    fi

    log_info "测试从Pod访问本地服务器: $LOCAL_SERVER_IP:$LOCAL_SERVER_PORT"

    if kubectl exec "$POD_NAME" -n "$NAMESPACE" -- curl -LsS -m 10 "http://$LOCAL_SERVER_IP:$LOCAL_SERVER_PORT/metrics" &>/dev/null; then
        log_success "测试Pod访问本地服务器正常"
        return 0
    else
        log_error "错误：Pod无法访问本地服务器，可能原因："
        log_error "1. 本地服务器iptables阻止了与K8S之间的通信"
        return 1
    fi
}

# ==================== 混合部署: 解析集群外置 MySQL 探测目标 ====================
# 从业务配置 application.yml 的 spring.datasource.url 解析 jdbc:mysql://主机名:端口,
# 由于 Pod 内 DNS 解析不了业务主机名(如 ta3), 用宿主机 /etc/hosts 把主机名翻成 IP,
# 拼成 IP:PORT 作为 Pod 侧真实探测地址。仅做 TCP 可达探测, 不解析账密、不登录 MySQL。
# 解析成功置全局 MYSQL_PROBE_IP / MYSQL_PROBE_PORT / MYSQL_HOST_RAW 并返回 0; 失败返回 1。
MYSQL_PROBE_IP=""
MYSQL_PROBE_PORT=""
MYSQL_HOST_RAW=""
parse_mysql_target() {
    if [[ ! -r "$APP_CONFIG_FILE" ]]; then
        log_warning "未找到业务配置文件 ${APP_CONFIG_FILE}, 跳过 Pod->MySQL 相关探测"
        return 1
    fi

    # 取 datasource.url 行的 jdbc:mysql://host:port 段(容忍前导空格/制表符)。
    local url
    url=$(grep -E '^[[:space:]]*url:[[:space:]]*jdbc:mysql://' "$APP_CONFIG_FILE" | head -1)
    if [[ -z "$url" ]]; then
        log_warning "${APP_CONFIG_FILE} 的 datasource 段未解析到 jdbc:mysql:// url, 跳过 Pod->MySQL 相关探测"
        return 1
    fi

    # 从 jdbc:mysql://HOST:PORT/db?... 中提取 HOST 与 PORT。
    local hostport
    hostport=$(echo "$url" | sed -E 's#.*jdbc:mysql://([^/?]+).*#\1#')
    MYSQL_HOST_RAW="${hostport%%:*}"
    local port="${hostport##*:}"
    [[ "$port" == "$hostport" || -z "$port" ]] && port="3306" # url 未显式带端口时默认 3306
    MYSQL_PROBE_PORT="$port"

    if [[ -z "$MYSQL_HOST_RAW" ]]; then
        log_warning "无法从 url 解析 MySQL 主机名(${hostport}), 跳过 Pod->MySQL 相关探测"
        return 1
    fi

    # 主机名 -> IP: 容器无法识别业务主机名, 必须用宿主机 /etc/hosts 翻译。
    # 形如 "10.214.0.239  ta3" 取第一列 IP。精确匹配主机名整词, 避免 ta3 误中 ta30。
    local ip
    ip=$(grep -E "[[:space:]]${MYSQL_HOST_RAW}([[:space:]]|\$)" /etc/hosts 2>/dev/null | grep -v '^[[:space:]]*#' | head -1 | awk '{print $1}')
    if [[ -z "$ip" ]]; then
        log_warning "在 /etc/hosts 中未找到主机名 ${MYSQL_HOST_RAW} 的 IP 映射, 跳过 Pod->MySQL 相关探测"
        log_warning "  请确认 /etc/hosts 已配置 ${MYSQL_HOST_RAW} -> MySQL 所在云主机 IP"
        return 1
    fi
    MYSQL_PROBE_IP="$ip"

    log_info "解析到集群外置 MySQL: 配置主机名 ${MYSQL_HOST_RAW}:${MYSQL_PROBE_PORT} -> Pod侧探测地址 ${MYSQL_PROBE_IP}:${MYSQL_PROBE_PORT}"
    return 0
}

# ==================== 混合部署: Pod -> 集群内 MySQL TCP 连通性 ====================
# 复用就绪 nginx Pod(debian 基础镜像自带 bash, 支持 /dev/tcp), 三次握手成功即判连通。
# 只验"网络+端口可达"(安全组/路由是否放行), 不登录、不依赖 mysql 客户端。
test_pod_to_mysql_connectivity() {
    log_step "Pod访问集群内MySQL连通性检查"
    log_info "测试从Pod访问MySQL: ${MYSQL_PROBE_IP}:${MYSQL_PROBE_PORT} (配置主机名 ${MYSQL_HOST_RAW})"

    if kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
        bash -c "timeout 5 bash -c 'exec 3<>/dev/tcp/${MYSQL_PROBE_IP}/${MYSQL_PROBE_PORT}' 2>/dev/null" &>/dev/null; then
        log_success "测试Pod访问集群内MySQL正常(TCP ${MYSQL_PROBE_IP}:${MYSQL_PROBE_PORT} 可达)"
        return 0
    else
        log_error "错误：Pod无法连通集群内MySQL(${MYSQL_PROBE_IP}:${MYSQL_PROBE_PORT})，可能原因："
        log_error "  1. MySQL所在云主机安全组未放行Pod网段到${MYSQL_PROBE_PORT}端口"
        log_error "  2. 混合部署下Pod网段与云主机不在同一VPC/路由未打通"
        log_error "  3. MySQL服务未监听或未对外暴露${MYSQL_PROBE_PORT}端口"
        return 1
    fi
}

# ==================== 混合部署: Pod -> MySQL 所在云主机延迟 ====================
# 云主机 IP 即 MySQL 所在主机 IP(同机)。规避 ICMP 常被云安全组拦截, 用对 MySQL 端口
# 多次 TCP 握手计时取均值近似 RTT, 低于阈值(默认50ms)判通过。Pod 内用 GNU date +%s%N 计时。
test_pod_to_host_latency() {
    log_step "Pod访问集群内云主机网络延迟检查"
    log_info "测试从Pod到云主机 ${MYSQL_PROBE_IP} 的网络延迟(TCP握手近似RTT, ${HOST_LATENCY_SAMPLES}次取均值, 阈值<${HOST_LATENCY_THRESHOLD_MS}ms)"

    # 在 Pod 内循环: 每次 TCP 连 IP:PORT 计纳秒耗时, 成功则累加, 末尾输出 "均值ms 成功次数"。
    local out
    out=$(kubectl exec "$POD_NAME" -n "$NAMESPACE" -- bash -c "
        total=0; ok=0
        for i in \$(seq 1 ${HOST_LATENCY_SAMPLES}); do
            s=\$(date +%s%N)
            if timeout 2 bash -c 'exec 3<>/dev/tcp/${MYSQL_PROBE_IP}/${MYSQL_PROBE_PORT}' 2>/dev/null; then
                e=\$(date +%s%N)
                total=\$((total + (e - s) / 1000000))
                ok=\$((ok + 1))
            fi
        done
        if [ \$ok -gt 0 ]; then echo \"\$((total / ok)) \$ok\"; else echo \"-1 0\"; fi
    " 2>/dev/null)

    local avg_ms="${out%% *}"
    local ok_cnt="${out##* }"

    if [[ -z "$avg_ms" || "$avg_ms" == "-1" || "${ok_cnt:-0}" -eq 0 ]]; then
        log_error "错误：Pod到云主机 ${MYSQL_PROBE_IP}:${MYSQL_PROBE_PORT} 全部探测失败，无法测得延迟(端口不可达, 详见连通性检查项)"
        HOST_LATENCY_LAST_MS="-1"
        return 1
    fi

    HOST_LATENCY_LAST_MS="$avg_ms"
    if [[ "$avg_ms" -lt "$HOST_LATENCY_THRESHOLD_MS" ]]; then
        log_success "测试Pod到云主机延迟正常(均值 ${avg_ms}ms < ${HOST_LATENCY_THRESHOLD_MS}ms, ${ok_cnt}/${HOST_LATENCY_SAMPLES}次成功)"
        return 0
    else
        log_error "错误：Pod到云主机延迟偏高(均值 ${avg_ms}ms >= ${HOST_LATENCY_THRESHOLD_MS}ms)，可能为跨可用区/跨域错配或网络拥塞"
        return 1
    fi
}

# ==================== 遍历每个就绪节点池做双向网络连通性测试 ====================
# 用 pod_deploy_check 记录的各就绪池 Pod(PROBE_READY_POOLS / PROBE_POD_NAME / PROBE_POD_IP),
# 逐池设置全局 POD_NAME/POD_IP 后复用既有 iptables 放行 + 双向连通性检查。
# 不抽样: 每个节点池内启动的 Pod 都要验证与本地主机网络互通。完成后统一清理探测资源。
run_network_checks_per_pool() {
    if [[ -z "${PROBE_READY_POOLS// /}" ]]; then
        log_warning "无任何就绪探测Pod，跳过网络连通性测试"
        _clean_probe_deployments
        record_result "本地服务器访问Pod网络连通性" "SKIP" "无就绪节点池可供测试"
        record_result "本地服务器访问Kubernetes Service连通性" "SKIP" "无就绪节点池可供测试"
        record_result "Pod访问本地服务器网络连通性" "SKIP" "无就绪节点池可供测试"
        record_result "Pod访问集群内MySQL连通性" "SKIP" "无就绪节点池可供测试"
        record_result "Pod访问集群内云主机延迟(<50ms)" "SKIP" "无就绪节点池可供测试"
        return 0
    fi

    # 混合部署探测目标(集群外置 MySQL/云主机)解析一次, 供所有就绪池复用。
    # 解析失败(无配置文件/无 hosts 映射)则两新项整体 SKIP, 不影响既有双向连通性检查。
    local mysql_ready=1
    parse_mysql_target || mysql_ready=0

    local pname
    local l2p_total=0 l2p_fail=0 l2s_total=0 l2s_fail=0 p2l_total=0 p2l_fail=0
    local l2p_failed_pools="" l2s_failed_pools="" p2l_failed_pools=""
    local mysql_total=0 mysql_fail=0 lat_total=0 lat_fail=0
    local mysql_failed_pools="" lat_failed_pools="" lat_detail=""
    for pname in $PROBE_READY_POOLS; do
        POD_NAME="${PROBE_POD_NAME[$pname]}"
        POD_IP="${PROBE_POD_IP[$pname]}"
        if [[ -z "$POD_NAME" || -z "$POD_IP" ]]; then
            log_warning "节点池[${pname}]缺少就绪Pod信息，跳过其网络测试"
            continue
        fi
        log_section "节点池[${pname}] 网络连通性测试 (Pod: ${POD_NAME} / ${POD_IP})"

        ((l2p_total++))
        test_localhost_to_pod_connectivity || {
            ((l2p_fail++))
            l2p_failed_pools="${l2p_failed_pools} ${pname}"
        }

        ((l2s_total++))
        test_localhost_to_service_connectivity "$pname" || {
            ((l2s_fail++))
            l2s_failed_pools="${l2s_failed_pools} ${pname}"
        }

        # Pod -> 本地服务器仍依赖本机对Pod网段的iptables放行，保持既有实施口径。
        ensure_iptables_for_pod_cidr
        ((p2l_total++))
        test_pod_to_localhost_connectivity || {
            ((p2l_fail++))
            p2l_failed_pools="${p2l_failed_pools} ${pname}"
        }

        # 混合部署两新项: 仅在 MySQL 目标解析成功时逐池执行。
        if [[ $mysql_ready -eq 1 ]]; then
            ((mysql_total++))
            test_pod_to_mysql_connectivity || {
                ((mysql_fail++))
                mysql_failed_pools="${mysql_failed_pools} ${pname}"
            }

            ((lat_total++))
            if test_pod_to_host_latency; then
                lat_detail="${lat_detail} ${pname}:${HOST_LATENCY_LAST_MS}ms"
            else
                ((lat_fail++))
                lat_failed_pools="${lat_failed_pools} ${pname}(${HOST_LATENCY_LAST_MS}ms)"
            fi
        fi
    done

    # 逐方向聚合各池结果登记: 全通过=PASS, 部分失败=FAIL(列出失败池)
    if [[ $l2p_total -eq 0 ]]; then
        record_result "本地服务器访问Pod网络连通性" "SKIP" "无可测试的就绪Pod"
    elif [[ $l2p_fail -eq 0 ]]; then
        record_result "本地服务器访问Pod网络连通性" "PASS" "${l2p_total}个就绪节点池均连通"
    else
        record_result "本地服务器访问Pod网络连通性" "WARN" "${l2p_fail}/${l2p_total}个节点池无法直连Pod IP:${l2p_failed_pools# }；此为兼容性关注项，请以Kubernetes Service连通性结果为准"
    fi
    if [[ $l2s_total -eq 0 ]]; then
        record_result "本地服务器访问Kubernetes Service连通性" "SKIP" "无可测试的就绪Pod"
    elif [[ $l2s_fail -eq 0 ]]; then
        record_result "本地服务器访问Kubernetes Service连通性" "PASS" "${l2s_total}个就绪节点池均可经NodePort Service访问"
    else
        record_result "本地服务器访问Kubernetes Service连通性" "FAIL" "${l2s_fail}/${l2s_total}个节点池Service不通:${l2s_failed_pools# }(请检查NodePort范围、安全组、节点路由和Service Endpoint)"
    fi
    if [[ $p2l_total -eq 0 ]]; then
        record_result "Pod访问本地服务器网络连通性" "SKIP" "无可测试的就绪Pod"
    elif [[ $p2l_fail -eq 0 ]]; then
        record_result "Pod访问本地服务器网络连通性" "PASS" "${p2l_total}个就绪节点池均连通"
    else
        record_result "Pod访问本地服务器网络连通性" "FAIL" "${p2l_fail}/${p2l_total}个节点池不通:${p2l_failed_pools# }(疑似安全组/iptables拦截)"
    fi

    # 混合部署两新项聚合: MySQL 目标未解析则 SKIP(附原因), 否则按各池结果 PASS/FAIL。
    if [[ $mysql_ready -eq 0 ]]; then
        record_result "Pod访问集群内MySQL连通性" "SKIP" "未解析到MySQL目标(无${APP_CONFIG_FILE}或/etc/hosts缺主机映射)"
        record_result "Pod访问集群内云主机延迟(<${HOST_LATENCY_THRESHOLD_MS}ms)" "SKIP" "未解析到MySQL所在云主机IP"
    else
        if [[ $mysql_total -eq 0 ]]; then
            record_result "Pod访问集群内MySQL连通性" "SKIP" "无可测试的就绪Pod"
        elif [[ $mysql_fail -eq 0 ]]; then
            record_result "Pod访问集群内MySQL连通性" "PASS" "${mysql_total}个就绪节点池均连通${MYSQL_PROBE_IP}:${MYSQL_PROBE_PORT}"
        else
            record_result "Pod访问集群内MySQL连通性" "FAIL" "${mysql_fail}/${mysql_total}个节点池不通${MYSQL_PROBE_IP}:${MYSQL_PROBE_PORT}:${mysql_failed_pools# }(疑似云主机安全组未放行Pod网段)"
        fi
        if [[ $lat_total -eq 0 ]]; then
            record_result "Pod访问集群内云主机延迟(<${HOST_LATENCY_THRESHOLD_MS}ms)" "SKIP" "无可测试的就绪Pod"
        elif [[ $lat_fail -eq 0 ]]; then
            record_result "Pod访问集群内云主机延迟(<${HOST_LATENCY_THRESHOLD_MS}ms)" "PASS" "${lat_total}个就绪节点池均达标:${lat_detail# }"
        else
            record_result "Pod访问集群内云主机延迟(<${HOST_LATENCY_THRESHOLD_MS}ms)" "FAIL" "${lat_fail}/${lat_total}个节点池延迟超标或不可达:${lat_failed_pools# }(疑似跨可用区/跨域错配)"
        fi
    fi

    # iptables 持久化重要项: 若探测期间发现 Pod 网段与本机不在同一/8(已本机临时放行),
    # 标记为[重要]后续动作——必须在 install.properties 持久化 cloud.intranet.segment,
    # 否则全集群/重启后内网未放行。红色高亮但不计入失败。
    if [[ -n "$IPTABLES_PERSIST_CIDR" ]]; then
        record_result "Pod网段iptables放行(install.properties持久化)" "IMPORTANT" \
            "【重要提醒】Pod IP(${IPTABLES_PERSIST_POD_IP})与本机IP(${IPTABLES_PERSIST_LOCAL_IP})不在同一/8网段，请将 cloud.intranet.segment=${IPTABLES_PERSIST_CIDR} 持久化到 install.properties 确保全集群内网放行！"
    fi

    log_info "清理探测Deployment/Service(弹性池节点将被autoscaler缩回0，请关注计费窗口)..."
    _clean_probe_deployments
}

# ==================== 清理测试资源 ====================
clean_check_resource() {
    log_step "清理测试资源"
    local deployment_name="nginx-test"

    kubectl scale deployment ${deployment_name} -n $NAMESPACE --replicas=0 &>/dev/null
    sleep 3

    kubectl delete deployment ${deployment_name} -n $NAMESPACE --wait=true --grace-period=30 &>/dev/null
    kubectl delete rs -n $NAMESPACE -l app=${deployment_name} --ignore-not-found --wait=true &>/dev/null
    kubectl delete pods -n $NAMESPACE -l app=${deployment_name} --force --grace-period=0 &>/dev/null

    if kubectl get deployment ${deployment_name} -n $NAMESPACE &>/dev/null; then
        log_error "deployment删除失败，手动清理: kubectl delete deployment ${deployment_name} -n $NAMESPACE"
    else
        log_success "测试资源已清理(deployment已删除)"
    fi
}

# ==================== 云平台检测函数 ====================
detect_cloud_platform() {
    log_step "K8S所属环境检查"

    # 判定对象是 kubeconfig 指向的 K8S 集群, 而非脚本执行的宿主机:二者一般同环境,
    # 但宿主机 dmidecode 误判(如火山 VKE 宿主机报 ByteDance->旧逻辑落到 kvm)、或自建集群
    # 跑在云主机上时都会错。故以 K8S 集群侧信号为主判据, dmidecode 仅作底层基础设施信息展示。
    #
    # 判据顺序(六云实测命中率: 节点标签 6/6 > gitVersion 5/6 > providerID 4/6):
    #   ① 节点标签厂商域名(主) ② serverVersion.gitVersion 厂商后缀 ③ providerID scheme(末层兜底)
    #   三层云厂商信号全缺 -> 判 baremetal(自建, 含跑在云主机上的 te-k8s+longhorn 集群),
    #   不回退 dmidecode 猜底层云(否则自建会被误判成底层云, 错建云盘 SC)。
    # 性能: 全部取单节点 .items[0], 不全量 dump 所有节点标签。
    local cloud_provider="unknown"

    # jq 用于解析 ② gitVersion; dmidecode 用于底层基础设施信息。缺失不阻断(②会自然跳过)。
    for pkg in jq dmidecode; do
        command -v "$pkg" &>/dev/null || yum -y install "$pkg" &>/dev/null
    done

    # —— ① 节点标签厂商域名(主判据, 6/6) —— 匹配够具体防误伤(华为只认 cce, 标签里无 everest)
    local labels=$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels}' 2>/dev/null)
    if echo "$labels" | grep -Eq 'volcengine\.com'; then
        cloud_provider="volcengine"
    elif echo "$labels" | grep -Eq 'alibabacloud|aliyun'; then
        cloud_provider="alibaba"
    elif echo "$labels" | grep -Eq 'cloud\.tencent\.com|qcloud'; then
        cloud_provider="tencent"
    elif echo "$labels" | grep -Eq 'cce\.cloud\.com|huaweicloud'; then
        cloud_provider="huawei"
    elif echo "$labels" | grep -Eq 'amazonaws|cloud-provider-aws'; then
        cloud_provider="aws"
    elif echo "$labels" | grep -Eq 'cloud\.google\.com'; then
        cloud_provider="google"
    fi
    [[ "$cloud_provider" != "unknown" ]] && log_info "  [主判据] 节点标签厂商域名命中: ${cloud_provider}"

    # —— ② serverVersion.gitVersion 厂商后缀(第二层, 5/6; 华为无厂商后缀靠①) ——
    if [[ "$cloud_provider" == "unknown" ]]; then
        local gitver=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' 2>/dev/null)
        case $gitver in
        *-vke.*) cloud_provider="volcengine" ;;
        *-aliyun.*) cloud_provider="alibaba" ;;
        *-tke.*) cloud_provider="tencent" ;;
        *-eks-*) cloud_provider="aws" ;;
        *-gke.*) cloud_provider="google" ;;
        esac
        [[ "$cloud_provider" != "unknown" ]] && log_info "  [第二层] serverVersion(${gitver}) 厂商后缀命中: ${cloud_provider}"
    fi

    # —— ③ providerID scheme(末层兜底, 4/6; 阿里/华为无 scheme 靠①②) ——
    if [[ "$cloud_provider" == "unknown" ]]; then
        local pid=$(kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null)
        case $pid in
        volcengine://*) cloud_provider="volcengine" ;;
        qcloud://*) cloud_provider="tencent" ;;
        aws://*) cloud_provider="aws" ;;
        gce://*) cloud_provider="google" ;;
        azure://*) cloud_provider="azure" ;;
        esac
        [[ "$cloud_provider" != "unknown" ]] && log_info "  [末层] providerID(${pid}) 命中: ${cloud_provider}"
    fi

    # —— 三层云厂商信号全缺 -> 自建/物理机(走 local-path 分支), 不回退 dmidecode 猜底层云 ——
    if [[ "$cloud_provider" == "unknown" ]]; then
        local hostname=$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels.kubernetes\.io/hostname}' 2>/dev/null)
        local annos=$(kubectl get nodes -o jsonpath='{.items[0].metadata.annotations}' 2>/dev/null)
        cloud_provider="baremetal"
        if echo "$hostname" | grep -q 'te-k8s' || echo "$annos" | grep -q 'longhorn\.io'; then
            log_info "  未命中任何云厂商信号, 但节点名含 te-k8s / 驱动含 longhorn -> 判定为自建 K8S(baremetal)"
        else
            log_info "  未命中任何云厂商信号 -> 判定为物理机/自建(baremetal)"
        fi
    fi

    # —— dmidecode 仅作底层基础设施信息(不参与裁决), 失败不影响 ——
    if command -v dmidecode &>/dev/null || [[ -x /usr/sbin/dmidecode ]]; then
        local manufacturer=$(/usr/sbin/dmidecode -q 2>/dev/null | grep "Manufacturer" | head -1 |
            awk -F'[:]' '{print $2}' | sed 's/^ //g')
        [[ -n "$manufacturer" ]] && log_info "  [底层基础设施信息] 宿主机制造商: ${manufacturer}(仅供参考, 不参与云平台裁决)"
    fi

    log_info "检测到k8s所属环境: ${BOLD}${cloud_provider}${NC}"
    echo "$cloud_provider"
}

# ==================== 内置K8S节点标签统一 ====================
# 内置K8S(自建)节点默认无 node.k8s.te/billing-mode 标签, 而下游节点池汇总/契约校验按该标签
# 归类付费类型。内置K8S节点名通常含 te-k8s, 且均为常驻自建节点(无弹性/竞价语义), 故自动为
# 这些节点补打 billing-mode=reserved, 与各云平台统一语义。
# 仅对自建/物理机环境且节点名含 te-k8s 的节点处理; 真物理机(无 te-k8s 命名)与云平台一律跳过,
# 避免误改既有(云平台节点的 billing-mode 由各云正确打好, 不应覆盖)。
label_internal_k8s_nodes() {
    local platform="$1"
    case "$platform" in
    vmware | kvm | qemu | baremetal) ;;
    *) return 0 ;;
    esac

    local te_nodes=$(kubectl get nodes -o name 2>/dev/null | grep 'te-k8s')
    if [[ -z "$te_nodes" ]]; then
        return 0 # 非内置K8S(无 te-k8s 节点名), 跳过
    fi

    log_step "内置K8S节点标签统一(billing-mode=reserved)"
    log_info "检测到内置K8S节点(名含 te-k8s)，自动补打 node.k8s.te/billing-mode=reserved 以统一各平台语义"
    local n ok=0 fail=0
    for n in $te_nodes; do
        if kubectl label "$n" node.k8s.te/billing-mode=reserved --overwrite >/dev/null 2>&1; then
            log_success "  已标记 ${n}: node.k8s.te/billing-mode=reserved"
            ((ok++))
        else
            log_warning "  标记失败 ${n}: 请确认当前账号有 node label 权限"
            ((fail++))
        fi
    done
    if [[ $fail -eq 0 ]]; then
        record_result "内置K8S节点标签统一(billing-mode=reserved)" "PASS" "已为${ok}个 te-k8s 节点打 billing-mode=reserved"
    else
        record_result "内置K8S节点标签统一(billing-mode=reserved)" "WARN" "${ok}个成功/${fail}个失败，请确认 node label 权限"
    fi
}

# ==================== StorageClass 确保函数 ====================
# 根据云平台自动创建默认StorageClass，统一命名为 te-disk，确保K8S存储就绪。
# 模版依据飞书《云厂商CSI安装配置》(wiki JnFaw5Ep4imMXikpEFPcuQoNnyh)。
# 特殊处理:
#   - 内置K8S(vmware/kvm/qemu/baremetal): 统一为 te-disk(基于 Longhorn, provisioner driver.longhorn.io)
#   - AWS: 除 te-disk 外还需 te-nfs(EFS文件存储), 但 te-nfs 依赖控制台返回的文件系统ID,
#          无法自动获取, 故输出模版供用户拿到 fileSystemId 后手动创建
ensure_storageclass() {
    local cloud_platform="$1"
    log_step "StorageClass就绪检查"

    # 默认SC统一逻辑: 已有 te-disk 则就绪; 否则按现有默认SC命名决定处置:
    #   - 非 te- 开头(如云厂商内置 alicloud-disk-essd / 客户自建 default 等): 直接初始化(摘注解+建 te-disk)
    #   - te- 开头但非 te-disk(旧命名 te-cbs / te-disk-essd / te-gp3 等, 可能仍被业务 PVC 使用):
    #     必须交互式请用户确认是否重新初始化, 避免擅自改动 TE 既有默认SC 影响存量业务
    # 内置K8S(baremetal, 基于 Longhorn)同样走此统一逻辑, 统一默认SC为 te-disk。
    local existing_default_sc=$(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    if [[ -n "$existing_default_sc" ]]; then
        if echo "$existing_default_sc" | grep -qx "te-disk"; then
            log_success "已存在默认StorageClass: te-disk，无需创建"
            return 0
        fi
        # 现有默认SC均非 te-disk。检查是否存在 te- 开头(非 te-disk)的默认SC, 命中则需用户确认。
        local te_prefixed_sc=$(echo "$existing_default_sc" | grep -E '^te-' || true)
        if [[ -n "$te_prefixed_sc" ]]; then
            local te_list=$(echo "$te_prefixed_sc" | tr '\n' ' ')
            log_warning "检测到已有 te- 开头(非 te-disk)的默认StorageClass: ${te_list}—— 该SC可能正被存量业务PVC使用，重新初始化将摘除其default注解并改为 te-disk"
            local confirm=""
            if [[ -r /dev/tty ]]; then
                printf "%b" "\e[33m\e[1m是否重新初始化默认SC为 te-disk? 输入 y 确认, 其它任意键保留现有默认SC: \e[0m" >/dev/tty
                read -r confirm </dev/tty
            else
                log_warning "当前为非交互式运行(无 /dev/tty)，无法确认，按安全默认【保留现有默认SC】，不重新初始化"
            fi
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                log_info "用户选择保留现有默认StorageClass(${te_list})，跳过 te-disk 初始化"
                record_result "StorageClass就绪检查(保留现有默认SC)" "WARN" "保留现有默认SC(${te_list})，未统一为 te-disk，请确认其与业务匹配"
                return 0
            fi
            log_info "用户确认重新初始化默认SC为 te-disk"
        fi
        # 摘除现有所有默认SC的default注解, 统一让位 te-disk
        for sc_name in $existing_default_sc; do
            log_info "移除现有默认SC [${sc_name}] 的default注解(统一默认SC命名为 te-disk)"
            kubectl annotate sc "$sc_name" storageclass.kubernetes.io/is-default-class- 2>/dev/null
            kubectl annotate sc "$sc_name" storageclass.beta.kubernetes.io/is-default-class- 2>/dev/null
        done
    fi

    # 根据云平台创建对应 te-disk
    case $cloud_platform in
    *tencent*)
        log_info "创建腾讯云默认StorageClass: te-disk (CBS块存储)"
        cat <<'EOF' | kubectl apply -f -
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
  name: te-disk
parameters:
  type: cbs
provisioner: com.tencent.cloud.csi.cbs
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
        ;;
    *alibaba* | *ali*)
        log_info "创建阿里云默认StorageClass: te-disk (cloud_essd块存储)"
        cat <<'EOF' | kubectl apply -f -
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
  name: te-disk
parameters:
  type: cloud_essd
provisioner: diskplugin.csi.alibabacloud.com
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
        ;;
    *huawei*)
        log_info "创建华为云默认StorageClass: te-disk (everest SAS块存储)"
        cat <<'EOF' | kubectl apply -f -
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
  name: te-disk
parameters:
  csi.storage.k8s.io/csi-driver-name: disk.csi.everest.io
  csi.storage.k8s.io/fstype: ext4
  everest.io/disk-volume-type: SAS
  everest.io/passthrough: "true"
provisioner: everest-csi-provisioner
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
        ;;
    *google*)
        log_info "创建GCP默认StorageClass: te-disk (pd-balanced块存储)"
        cat <<'EOF' | kubectl apply -f -
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
  labels:
    addonmanager.kubernetes.io/mode: EnsureExists
  name: te-disk
parameters:
  type: pd-balanced
provisioner: pd.csi.storage.gke.io
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
        ;;
    *volc*)
        log_info "创建火山引擎(VKE)默认StorageClass: te-disk (ESSD_PL0块存储)"
        cat <<'EOF' | kubectl apply -f -
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
  name: te-disk
parameters:
  ChargeType: PostPaid
  fsType: ext4
  projectName: default
  type: ESSD_PL0
provisioner: ebs.csi.volcengine.com
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
        ;;
    *aws*)
        # AWS需先验证EBS CSI Driver是否已安装
        local csi_driver_exists=$(kubectl get csidrivers ebs.csi.aws.com 2>/dev/null)
        if [[ -z "$csi_driver_exists" ]]; then
            log_warning "未检测到EBS CSI Driver (ebs.csi.aws.com)，请先在EKS控制台安装Amazon EBS CSI Driver插件"
            log_info "参考文档: https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html"
            log_info "仍将创建StorageClass定义，但PVC将无法正常绑定直至CSI插件就绪"
        fi
        log_info "创建AWS默认StorageClass: te-disk (gp3块存储)"
        cat <<'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
  name: te-disk
parameters:
  fsType: ext4
  type: gp3
provisioner: ebs.csi.aws.com
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
        # te-nfs(EFS文件存储)由 ensure_nfs_storageclass 统一处理(依赖控制台 fileSystemId, 打印模版供手动创建)
        ;;
    vmware | kvm | qemu | baremetal)
        # 内置K8S(自建, 基于 Longhorn): 统一创建默认StorageClass te-disk(provisioner driver.longhorn.io)
        log_info "创建内置K8S(Longhorn)默认StorageClass: te-disk (driver.longhorn.io, 3副本)"
        cat <<'EOF' | kubectl apply -f -
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
  name: te-disk
parameters:
  backupTargetName: default
  dataEngine: v1
  dataLocality: disabled
  disableRevisionCounter: "true"
  fromBackup: ""
  fsType: ext4
  numberOfReplicas: "3"
  staleReplicaTimeout: "30"
  unmapMarkSnapChainRemoved: ignored
provisioner: driver.longhorn.io
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
        ;;
    *)
        log_warning "未知云平台(${cloud_platform})，无法自动创建StorageClass，请手动配置默认SC: te-disk"
        return 1
        ;;
    esac

    # 验证创建结果
    sleep 2
    local new_default_sc=$(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null)
    if [[ -n "$new_default_sc" ]]; then
        log_success "默认StorageClass就绪: ${new_default_sc}"
        kubectl get sc 2>/dev/null | tee -a ${LOG_FILE}
        return 0
    else
        log_error "StorageClass创建失败，请检查CSI插件是否正常运行"
        kubectl get sc 2>/dev/null | tee -a ${LOG_FILE}
        return 1
    fi
}

# ==================== 网络存储 StorageClass 确保函数(te-nfs) ====================
# 各云 K8S 都需要一个基于网络存储(NFS/文件存储)的 SC, 统一命名为 te-nfs, 供网络存储端到端验证。
# 两类处置:
#   A. 客户在云控制台创建(阿里ACK/腾讯TKE/火山VKE): 脚本只 kubectl get sc te-nfs 确认存在,
#      存在即进端到端测试; 不存在则打印该平台参考模版并记 WARN(不自动建, 依赖控制台侧 NAS/CFS 资源)。
#   B. 脚本侧创建:
#      - 内置K8S(nfs-provisioner)/华为CCE(everest nas): 模版自洽, 直接 kubectl apply 自动创建;
#        华为 te-nfs 依赖 VPCEP, 端到端不可用时由 verify 段追加 VPCEP 提示。
#      - AWS(efs): 依赖控制台返回的 fileSystemId, 无法自动获取, 打印模版供手动填充创建, 记 WARN。
#      - Google(GCP): 模版待补充(TODO), 记 SKIP。
# 返回 0 表示 te-nfs 已存在(可进端到端); 非 0 表示未就绪(打印了模版/TODO), 由 main 据此跳过网络 e2e。
ensure_nfs_storageclass() {
    local cloud_platform="$1"
    log_step "网络存储StorageClass就绪检查(te-nfs)"

    # 已存在 te-nfs 则直接就绪(无论客户建还是脚本建, 幂等)
    if kubectl get sc te-nfs &>/dev/null; then
        log_success "已存在网络存储StorageClass: te-nfs，无需创建"
        return 0
    fi

    case $cloud_platform in
    *alibaba* | *ali*)
        log_warning "未发现 te-nfs：阿里云ACK 的 te-nfs 需在云控制台(NAS)创建后由集群自动可见，请按下方模版在控制台创建对应 NAS 文件系统与 te-nfs SC(server/挂载点需替换为实际值):"
        cat <<'EOF' | tee -a "$LOG_FILE"
---------------- 阿里云ACK te-nfs.yaml (控制台侧创建, server 需替换为实际 NAS 挂载点) ----------------
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: te-nfs
mountOptions:
- nolock,tcp,noresvport
- vers=3
parameters:
  server: 121y67cz0q5i73b9p3t-kcv39.cn-hongkong.nas.aliyuncs.com:/te-nfs
  volumeAs: subpath
provisioner: nasplugin.csi.alibabacloud.com
reclaimPolicy: Retain
volumeBindingMode: Immediate
--------------------------------------------------------------------------------------------------
EOF
        record_result "网络存储SC就绪检查(te-nfs)" "WARN" "未发现 te-nfs，阿里ACK 需控制台创建 NAS 后 te-nfs 才可见，已打印模版"
        return 1
        ;;
    *tencent*)
        log_warning "未发现 te-nfs：腾讯云TKE 的 te-nfs 需在云控制台(CFS)创建后由集群自动可见，请按下方模版在控制台创建对应 CFS 与 te-nfs SC(vpcid/subnetid/zone 等需替换为实际值):"
        cat <<'EOF' | tee -a "$LOG_FILE"
---------------- 腾讯云TKE te-nfs.yaml (控制台侧创建, vpcid/subnetid/zone 需替换为实际值) ----------------
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: te-nfs
parameters:
  pgroupid: pgroupbasic
  storagetype: SD
  subdir-share: "true"
  subnetid: subnet-40a7tsls
  vers: "3"
  vpcid: vpc-48n29yeb
  zone: ap-guangzhou-6
provisioner: com.tencent.cloud.csi.tcfs.te-nfs
reclaimPolicy: Retain
volumeBindingMode: Immediate
------------------------------------------------------------------------------------------------------
EOF
        record_result "网络存储SC就绪检查(te-nfs)" "WARN" "未发现 te-nfs，腾讯TKE 需控制台创建 CFS 后 te-nfs 才可见，已打印模版"
        return 1
        ;;
    *volc*)
        log_warning "未发现 te-nfs：火山云VKE 的 te-nfs 需客户在控制台完成 CSI 安装与 NAS 文件系统创建后由集群自动可见，请按下方模版在控制台创建对应 NAS 与 te-nfs SC(fsId/server 需替换为实际值):"
        cat <<'EOF' | tee -a "$LOG_FILE"
---------------- 火山云VKE te-nfs.yaml (控制台侧创建, fsId/server 需替换为实际值) ----------------
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: te-nfs
mountOptions:
- nolock,proto=tcp,noresvport
- vers=3
parameters:
  ChargeType: PostPaid
  fsId: enas-cngzc0e5ba70650337
  fsType: Extreme
  server: cngzc0e5ba70650337.vpc-36td87hux629s383g0w6ff785.nas.ivolces.com
  subPath: /
  volumeAs: subpath
provisioner: nas.csi.volcengine.com
reclaimPolicy: Retain
volumeBindingMode: Immediate
------------------------------------------------------------------------------------------------
EOF
        record_result "网络存储SC就绪检查(te-nfs)" "WARN" "未发现 te-nfs，火山VKE 需控制台安装CSI+创建NAS 后 te-nfs 才可见，已打印模版"
        return 1
        ;;
    *huawei*)
        # 华为CCE(everest nas): 模版自洽, 自动创建。但依赖 VPCEP 配置, 端到端不可用时由 verify 段追加 VPCEP 提示。
        log_info "创建华为云CCE 网络存储StorageClass: te-nfs (everest nas, SFS3.0)"
        cat <<'EOF' | kubectl apply -f -
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: te-nfs
parameters:
  csi.storage.k8s.io/csi-driver-name: nas.csi.everest.io
  csi.storage.k8s.io/fstype: nfs
  everest.io/sfs-version: sfs3.0
  everest.io/share-access-level: rw
  everest.io/share-access-to: b35d40d7-1d27-4914-beb9-79c8f3a31174
provisioner: everest-csi-provisioner
reclaimPolicy: Retain
volumeBindingMode: Immediate
EOF
        log_warning "华为CCE te-nfs 依赖 VPCEP(VPC 终端节点)配置才能正常挂载；若稍后网络存储端到端测试不可用，请先确认 VPCEP 是否已配置"
        ;;
    *aws*)
        # AWS EFS: 依赖控制台返回的 fileSystemId, 无法自动获取, 打印模版供手动填充创建。
        log_warning "未发现 te-nfs：AWS EKS 的 te-nfs(EFS)依赖控制台返回的文件系统ID(fileSystemId)，无法自动创建。请在EFS控制台创建文件系统并获取 fileSystemId(形如 fs-00ca782a22033a2xx)后，填充下方模版并手动 kubectl apply:"
        cat <<'EOF' | tee -a "$LOG_FILE"
---------------- AWS EKS te-nfs.yaml (请替换 fileSystemId 后手动创建) ----------------
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: te-nfs
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: fs-00ca782a22033a2xx   # ← 替换为EFS控制台返回的实际文件系统ID
  directoryPerms: "700"
reclaimPolicy: Retain
-----------------------------------------------------------------------------------
EOF
        record_result "网络存储SC就绪检查(te-nfs)" "WARN" "未发现 te-nfs，AWS EFS 依赖控制台 fileSystemId，请填充模版后手动创建"
        return 1
        ;;
    *google*)
        # TODO: Google GCP 网络存储(Filestore/GCS FUSE) te-nfs 模版待补充, 下次完善
        log_warning "Google GCP 网络存储 te-nfs 模版暂缺(待办项)，本次跳过其创建与端到端验证，后续补充完善"
        record_result "网络存储SC就绪检查(te-nfs)" "SKIP" "Google GCP te-nfs 模版待补充(TODO)，后续完善"
        return 1
        ;;
    vmware | kvm | qemu | baremetal)
        # 内置K8S: nfs-provisioner, 模版自洽, 自动创建
        log_info "创建内置K8S 网络存储StorageClass: te-nfs (nfs-provisioner)"
        cat <<'EOF' | kubectl apply -f -
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: te-nfs
mountOptions:
- vers=4.1
- retrans=2
- timeo=30
provisioner: nfs-provisioner
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF
        ;;
    *)
        log_warning "未知云平台(${cloud_platform})，无法自动创建网络存储SC，请手动配置 te-nfs"
        record_result "网络存储SC就绪检查(te-nfs)" "WARN" "未知云平台，请手动配置 te-nfs"
        return 1
        ;;
    esac

    # 验证创建结果(仅脚本侧自动创建的平台: 华为/内置K8S 会走到此)
    sleep 2
    if kubectl get sc te-nfs &>/dev/null; then
        log_success "网络存储StorageClass就绪: te-nfs"
        return 0
    else
        log_error "网络存储StorageClass(te-nfs)创建失败，请检查网络存储 CSI 插件是否正常运行"
        return 1
    fi
}
# ==================== 端到端存储验证 (SC -> PVC -> Pod 挂载) ====================
# CSI 就绪性的唯一金标准是"真实建 PVC + 起挂载它的 Pod"(见下 verify_storage_e2e)。
# 此前按平台 grep 期望的 CSIDriver 对象名/controller/node DaemonSet 的预检查已删除:
#   StorageClass.provisioner(纯字符串)与 CSIDriver 对象解耦、无外键约束 —— 缺期望的
#   CSIDriver 对象不阻断动态供给(腾讯 TKE 实证: CFS-only 集群无 .cbs 对象, CBS PVC 照样
#   Bound 并被业务用 18 天), 按平台写死驱动/组件关键字的 grep 只增误报与噪声。
#   故不再做组件级预检查, 直接以端到端建 PVC 为准。
# 显式按 StorageClass 与 accessMode 验证存储，不回退至其他默认 SC。
# 单 Pod 读写用于验证 PVC 供给、挂载及实际可写性；RWX 跨节点共享由独立函数验证。
_storage_e2e_cleanup() {
    local pvc="$1"
    shift
    local pod
    for pod in "$@"; do
        kubectl delete pod "$pod" -n "$NAMESPACE" --force --grace-period=0 --ignore-not-found &>/dev/null
    done
    kubectl delete pvc "$pvc" -n "$NAMESPACE" --ignore-not-found &>/dev/null
}

_storage_e2e_capture_diagnostics() {
    local pvc="$1" prefix="$2"
    shift 2
    local detail="${ARTIFACT_DIR}/describe_storage_${prefix}.txt" pod
    {
        echo "==== PVC ${pvc} ===="
        kubectl describe pvc "$pvc" -n "$NAMESPACE" 2>&1
        for pod in "$@"; do
            echo "==== Pod ${pod} ===="
            kubectl describe pod "$pod" -n "$NAMESPACE" 2>&1
        done
    } >"$detail"
    log_error "排查详情(describe)已存盘: ${detail}"
}

_apply_csi_check_pod() {
    # 参数: pod pvc image role test_label; role=reader 时强制与 writer 分布到不同节点。
    local pod="$1" pvc="$2" image="$3" role="${4:-single}" test_label="${5:-storage-e2e}"
    local anti_affinity=""
    if [[ "$role" == "reader" ]]; then
        anti_affinity="
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: te-csi-check
            e2e-test: ${test_label}
            e2e-role: writer
        topologyKey: kubernetes.io/hostname"
    fi
    _ensure_artifact_dir
    local manifest="${ARTIFACT_DIR}/${pod}.yaml"
    cat >"$manifest" <<EOF_POD
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${NAMESPACE}
  labels:
    app: te-csi-check
    e2e-test: ${test_label}
    e2e-role: ${role}
spec:${anti_affinity}
  containers:
  - name: csi-check
    image: ${image}
    command: ["/bin/sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: ${pvc}
  tolerations:
  - effect: NoSchedule
    key: node.k8s.te/billing-mode
    operator: Equal
    value: reserved
  - effect: NoSchedule
    key: node.k8s.te/billing-mode
    operator: Equal
    value: od
  - effect: NoSchedule
    key: node.k8s.te/billing-mode
    operator: Equal
    value: spot
EOF_POD
    kubectl apply -f "$manifest" >/dev/null 2>&1
}

_wait_for_storage_pod() {
    local pod="$1" timeout="${2:-240}" elapsed=0 interval=10
    while [[ $elapsed -lt $timeout ]]; do
        local phase wreason
        phase=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
        wreason=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
        [[ "$phase" == "Running" ]] && return 0
        if [[ "$wreason" == "ErrImagePull" || "$wreason" == "ImagePullBackOff" ]]; then
            log_error "${IMAGE_PULL_FAIL_HINT}"
            return 1
        fi
        sleep "$interval"
        ((elapsed += interval))
    done
    return 1
}

verify_storage_e2e() {
    # 参数: StorageClass 类别 资源前缀 accessMode 失败附加提示。
    local storage_class="$1" category="$2" res_prefix="$3" access_mode="$4" extra_hint="${5:-}"
    local pvc_name="${res_prefix}-pvc" pod_name="${res_prefix}-pod" image="${NGINX_IMAGE}"
    local token="storage-e2e-${RUN_TS}-${RANDOM}" token_file="/data/.${res_prefix}-token"
    log_step "端到端存储验证(${category}: ${access_mode} PVC->Pod挂载->读写)"
    ensure_namespace

    if ! kubectl get sc "$storage_class" &>/dev/null; then
        log_warning "未发现目标StorageClass ${storage_class}，不回退至其他默认SC，跳过本项验证"
        return 1
    fi

    _storage_e2e_cleanup "$pvc_name" "$pod_name"
    _ensure_artifact_dir
    cat >"${ARTIFACT_DIR}/${pvc_name}.yaml" <<EOF_PVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc_name}
  namespace: ${NAMESPACE}
  labels:
    app: te-csi-check
    e2e-test: ${res_prefix}
spec:
  accessModes: [${access_mode}]
  storageClassName: ${storage_class}
  resources:
    requests:
      storage: ${E2E_PVC_SIZE}
EOF_PVC
    if ! kubectl apply -f "${ARTIFACT_DIR}/${pvc_name}.yaml" >/dev/null 2>&1; then
        log_error "创建${access_mode} PVC失败: ${pvc_name}"
        _storage_e2e_capture_diagnostics "$pvc_name" "$res_prefix" "$pod_name"
        return 1
    fi
    _apply_csi_check_pod "$pod_name" "$pvc_name" "$image" "single" "$res_prefix"

    if ! _wait_for_storage_pod "$pod_name"; then
        log_warning "${category} PVC未Bound或挂载Pod未Running"
        _storage_e2e_capture_diagnostics "$pvc_name" "$res_prefix" "$pod_name"
        [[ -n "$extra_hint" ]] && log_error "  ${extra_hint}"
        _storage_e2e_cleanup "$pvc_name" "$pod_name"
        return 1
    fi

    if ! kubectl exec "$pod_name" -n "$NAMESPACE" -- sh -c "printf '%s\\n' '${token}' > '${token_file}'" >/dev/null 2>&1; then
        log_error "${category} Pod已挂载PVC但写入校验文件失败"
        _storage_e2e_capture_diagnostics "$pvc_name" "$res_prefix" "$pod_name"
        _storage_e2e_cleanup "$pvc_name" "$pod_name"
        return 1
    fi
    local read_token
    read_token=$(kubectl exec "$pod_name" -n "$NAMESPACE" -- sh -c "cat '${token_file}'" 2>/dev/null)
    if [[ "$read_token" != "$token" ]]; then
        log_error "${category} Pod已挂载PVC但读取校验文件失败"
        _storage_e2e_capture_diagnostics "$pvc_name" "$res_prefix" "$pod_name"
        _storage_e2e_cleanup "$pvc_name" "$pod_name"
        return 1
    fi

    log_success "${category}验证通过: ${storage_class}/${access_mode} PVC已挂载且单Pod读写成功"
    _storage_e2e_cleanup "$pvc_name" "$pod_name"
    return 0
}

verify_nfs_rwx_cross_node() {
    # 参数: StorageClass 资源前缀 失败附加提示。调用方负责确保至少两个可调度节点。
    local storage_class="$1" res_prefix="$2" extra_hint="${3:-}"
    local pvc_name="${res_prefix}-pvc" writer="${res_prefix}-writer" reader="${res_prefix}-reader" image="${NGINX_IMAGE}"
    local token="rwx-e2e-${RUN_TS}-${RANDOM}" token_file="/data/.${res_prefix}-token"
    local writer_node reader_node read_token
    log_step "端到端存储验证(文件存储 te-nfs: RWX跨节点共享读写)"
    ensure_namespace

    _storage_e2e_cleanup "$pvc_name" "$writer" "$reader"
    _ensure_artifact_dir
    cat >"${ARTIFACT_DIR}/${pvc_name}.yaml" <<EOF_RWX_PVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc_name}
  namespace: ${NAMESPACE}
  labels:
    app: te-csi-check
    e2e-test: ${res_prefix}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ${storage_class}
  resources:
    requests:
      storage: ${E2E_PVC_SIZE}
EOF_RWX_PVC
    if ! kubectl apply -f "${ARTIFACT_DIR}/${pvc_name}.yaml" >/dev/null 2>&1; then
        log_error "创建RWX跨节点验证PVC失败: ${pvc_name}"
        _storage_e2e_capture_diagnostics "$pvc_name" "$res_prefix" "$writer" "$reader"
        return 1
    fi

    _apply_csi_check_pod "$writer" "$pvc_name" "$image" "writer" "$res_prefix"
    if ! _wait_for_storage_pod "$writer"; then
        log_error "RWX Writer Pod未能挂载并启动"
        _storage_e2e_capture_diagnostics "$pvc_name" "$res_prefix" "$writer" "$reader"
        [[ -n "$extra_hint" ]] && log_error "  ${extra_hint}"
        _storage_e2e_cleanup "$pvc_name" "$writer" "$reader"
        return 1
    fi
    writer_node=$(kubectl get pod "$writer" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    if ! kubectl exec "$writer" -n "$NAMESPACE" -- sh -c "printf '%s\\n' '${token}' > '${token_file}'" >/dev/null 2>&1; then
        log_error "RWX Writer Pod挂载成功但写入共享文件失败"
        _storage_e2e_capture_diagnostics "$pvc_name" "$res_prefix" "$writer" "$reader"
        _storage_e2e_cleanup "$pvc_name" "$writer" "$reader"
        return 1
    fi

    _apply_csi_check_pod "$reader" "$pvc_name" "$image" "reader" "$res_prefix"
    if ! _wait_for_storage_pod "$reader"; then
        log_error "RWX Reader Pod未能在不同节点挂载并启动"
        _storage_e2e_capture_diagnostics "$pvc_name" "$res_prefix" "$writer" "$reader"
        [[ -n "$extra_hint" ]] && log_error "  ${extra_hint}"
        _storage_e2e_cleanup "$pvc_name" "$writer" "$reader"
        return 1
    fi
    reader_node=$(kubectl get pod "$reader" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    if [[ -z "$writer_node" || -z "$reader_node" || "$writer_node" == "$reader_node" ]]; then
        log_error "RWX Writer/Reader未分布到不同节点(writer=${writer_node:-未知}, reader=${reader_node:-未知})"
        _storage_e2e_capture_diagnostics "$pvc_name" "$res_prefix" "$writer" "$reader"
        _storage_e2e_cleanup "$pvc_name" "$writer" "$reader"
        return 1
    fi
    read_token=$(kubectl exec "$reader" -n "$NAMESPACE" -- sh -c "cat '${token_file}'" 2>/dev/null)
    if [[ "$read_token" != "$token" ]]; then
        log_error "RWX Reader未读取到Writer写入的正确内容，跨节点共享读写失败"
        _storage_e2e_capture_diagnostics "$pvc_name" "$res_prefix" "$writer" "$reader"
        _storage_e2e_cleanup "$pvc_name" "$writer" "$reader"
        return 1
    fi

    log_success "te-nfs RWX跨节点共享验证通过: Writer=${writer_node}, Reader=${reader_node}"
    _storage_e2e_cleanup "$pvc_name" "$writer" "$reader"
    return 0
}

# ==================== 云平台特性检查函数(CSI 之外的平台专属附加项) ====================
check_tencent_cloud_features() {
    echo "当前云平台：腾讯云(TKE)，开始执行特性检查"

    log_info "检查imc-operator镜像缓存插件..."
    local imc_deploy=$(kubectl get deployment -n kube-system --no-headers 2>/dev/null | grep "imc" | awk '{print $1}')
    if [[ -n "$imc_deploy" ]]; then
        local imc_status=$(kubectl get deployment -n kube-system "$imc_deploy" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
        if [[ "$imc_status" == "True" ]]; then
            log_success "imc-operator插件运行正常 (deployment: ${imc_deploy})"
        else
            log_warning "imc-operator插件状态异常 (deployment: ${imc_deploy})"
        fi
    else
        log_warning "未检测到imc-operator插件，腾讯云生产环境建议安装"
        log_info "参考文档: https://cloud.tencent.com/document/product/457/78134"
    fi
}

check_aws_cloud_features() {
    log_info "当前云平台：AWS(EKS) 开始执行特性检查"

    local script_path="/tmp/thinkingai/auto_build_nodepool.sh"
    local script_url="https://download-thinkingdata.oss-cn-shanghai.aliyuncs.com/ta/tools/auto_build_nodepool.sh"

    mkdir -p /tmp/thinkingai
    if ! wget -O "${script_path}" "${script_url}"; then
        log_error "auto_build_nodepool.sh 下载失败，请检查网络或手动下载: ${script_url}"
        return 1
    fi
    if [[ ! -s "${script_path}" ]]; then
        log_error "auto_build_nodepool.sh 下载内容为空，请检查下载地址: ${script_url}"
        return 1
    fi
    log_info "auto_build_nodepool.sh 下载成功，开始执行"

    sh "${script_path}"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        log_error "auto_build_nodepool.sh 执行失败 (退出码: ${rc})，请查看上述输出排查"
        return 1
    fi
    log_success "auto_build_nodepool.sh 执行完成"
    return 0
}
# ==================== 主执行流程 ====================
main() {
    echo -e "${BOLD}$(_banner_rule)"
    log_info "K8S 就绪可用性确保脚本 v3.0"
    log_info "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "日志文件: $LOG_FILE"
    log_info "测试物料/异常详情目录: $ARTIFACT_DIR (测试 yaml 与异常 describe 落盘于此, 资源回收后仍可凭此 kubectl apply -f 复现)"
    echo -e "$(_banner_rule)${NC}"

    echo -e "\n${BOLD}$(_banner_line "检查计划")${NC}"

    log_info "1. kubectl检查"
    log_info "2. K8S集群连通性检查"
    log_info "3. K8S所属环境检查"
    log_info "4. StorageClass就绪检查(块存储 te-disk)"
    log_info "5. 网络存储StorageClass就绪检查(te-nfs)"
    log_info "6. Pod部署启动检查(并发探测所有节点池)"
    log_info "7. 节点池与节点配置检查"
    log_info "8. 节点组契约校验(规格/付费类型/污点 vs 池名声明)"
    log_info "9. 本地服务器访问Pod网络连通性检查(兼容性验证)"
    log_info "10. 本地服务器访问Kubernetes Service连通性检查(NodePort)"
    log_info "11. Pod访问本地服务器网络连通性检查"
    log_info "12. Pod访问集群内MySQL连通性检查(混合部署网络错配探测)"
    log_info "13. Pod访问集群内云主机延迟检查(<${HOST_LATENCY_THRESHOLD_MS}ms, TCP握手近似RTT)"
    log_info "14. 端到端存储验证(块存储 te-disk, RWO: PVC->单Pod挂载->读写)"
    log_info "15. 端到端存储验证(文件存储 te-nfs, RWX: PVC->单Pod挂载->读写)"
    log_info "16. 端到端存储验证(文件存储 te-nfs, RWX跨节点共享读写)"
    log_info "    (端到端 SC->PVC->Pod 起服为 CSI 就绪的唯一金标准)"
    echo ""

    checkUser
    install_kubectl
    record_result "kubectl检查" "PASS" "kubectl已就绪(版本匹配目标${K8S_VERSION})"
    test_k8s_connection
    record_result "K8S集群连通性检查" "PASS" "集群连接正常"

    cloud_platform=$(detect_cloud_platform)
    record_result "K8S所属环境检查" "PASS" "识别到环境: ${cloud_platform}"

    # 内置K8S(自建, 节点名含 te-k8s): 自动为节点补打 billing-mode=reserved, 统一各平台语义。
    # 须在 ensure_storageclass / pod_deploy_check 之前, 以便下游节点池归类/契约校验看到该标签。
    label_internal_k8s_nodes "$cloud_platform"

    # CSI 不再做组件级预检查(SC.provisioner 与 CSIDriver 对象解耦, grep 期望组件只增误报);
    # CSI 就绪由末尾 verify_storage_e2e 端到端真实建 PVC + 起挂载 Pod 作唯一金标准。
    if ensure_storageclass "$cloud_platform"; then
        record_result "StorageClass就绪检查" "PASS" "默认StorageClass(te-disk)就绪"
    else
        record_result "StorageClass就绪检查" "WARN" "默认StorageClass未就绪，请确认CSI插件与手动配置指引"
    fi

    # 网络存储SC(te-nfs)就绪检查: 客户控制台建(阿里/腾讯/火山)只确认存在, 脚本侧建(内置K8S/华为/AWS)按平台处置。
    # nfs_ready=1 表示 te-nfs 已存在可进网络存储端到端验证; 0 表示未就绪(打印了模版/TODO), 跳过网络 e2e。
    # 须在 AWS 提前 return 之前调用, 以便 AWS 也能打印 te-nfs 模版。
    local nfs_ready=1
    if ensure_nfs_storageclass "$cloud_platform"; then
        record_result "网络存储SC就绪检查(te-nfs)" "PASS" "网络存储StorageClass(te-nfs)已就绪"
    else
        nfs_ready=0
        # WARN/SKIP 已由 ensure_nfs_storageclass 内部按平台登记, 此处不重复登记
    fi

    # 平台专属附加项(CSI 之外): 腾讯 imc-operator、AWS auto_build_nodepool。其余平台无附加项。
    case $cloud_platform in
    *tencent*) check_tencent_cloud_features ;;
    *aws*)
        check_aws_cloud_features
        log_info "AWS EKS环境经由特殊流程(auto_build_nodepool.sh)处理，不再进行其他检测"
        record_result "AWS EKS特殊流程(auto_build_nodepool)" "PASS" "已执行auto_build_nodepool.sh"
        print_summary
        SCRIPT_COMPLETED=true
        return 0
        ;;
    esac

    # Pod部署启动检查: 按平台节点池映射并发探测各池可调度性(弹性池触发 autoscaler 0->1)。
    # 全程不阻断: 未通过的节点池红色标注原因, 就绪节点池继续后续检查。结果由函数内部登记。
    pod_deploy_check "$cloud_platform"

    # 节点池和节点配置检查: 探测之后调用, 弹性池节点此时已拉起可见, 枚举规格/标签/污点
    if discover_and_check_nodes; then
        record_result "节点池与节点配置检查(池内一致性)" "PASS" "节点池归类与规格/标签/污点一致性通过"
    else
        record_result "节点池与节点配置检查(池内一致性)" "WARN" "部分节点池内存在规格/标签/污点不一致，详见日志"
    fi

    # 节点组契约校验: 池实际规格/付费类型/污点 vs 池名声明。全程不阻断, 结果由函数内部登记。
    check_nodepool_contract "$cloud_platform"

    # 对每个就绪节点池的 Pod 做双向网络连通性测试, 完成后清理探测资源。结果由函数内部登记。
    run_network_checks_per_pool

    # 块存储验证固定针对 te-disk，不依赖其他默认 StorageClass。
    if verify_storage_e2e "te-disk" "块存储 te-disk RWO" "te-csi-check-disk" "ReadWriteOnce"; then
        record_result "端到端存储验证(块存储 te-disk, RWO)" "PASS" "RWO PVC动态供给、挂载与单Pod读写成功"
    else
        record_result "端到端存储验证(块存储 te-disk, RWO)" "WARN" "te-disk 缺失或RWO PVC未Bound、挂载或读写失败，请排查块存储CSI"
    fi

    # 文件存储 te-nfs: RWX 基础读写 + 条件性的跨节点共享读写验证。
    if [[ $nfs_ready -eq 1 ]]; then
        local nfs_hint=""
        case $cloud_platform in
        *huawei*) nfs_hint="华为CCE te-nfs 依赖 VPCEP(VPC 终端节点)配置，若失败请先确认 VPCEP 是否已正确配置" ;;
        esac
        if verify_storage_e2e "te-nfs" "文件存储 te-nfs RWX基础" "te-csi-check-nfs" "ReadWriteMany" "$nfs_hint"; then
            record_result "端到端存储验证(文件存储 te-nfs, RWX基础)" "PASS" "RWX PVC动态供给、挂载与单Pod读写成功"
            local schedulable_nodes
            schedulable_nodes=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /^Ready/ && $2 !~ /SchedulingDisabled/ {n++} END {print n+0}')
            if [[ "$schedulable_nodes" -lt 2 ]]; then
                record_result "端到端存储验证(文件存储 te-nfs, RWX跨节点共享)" "SKIP" "仅${schedulable_nodes}个可调度节点，无法验证跨节点共享；RWX基础读写已通过"
            elif verify_nfs_rwx_cross_node "te-nfs" "te-csi-check-nfs-rwx" "$nfs_hint"; then
                record_result "端到端存储验证(文件存储 te-nfs, RWX跨节点共享)" "PASS" "Writer/Reader位于不同节点，跨节点共享读写成功"
            else
                record_result "端到端存储验证(文件存储 te-nfs, RWX跨节点共享)" "WARN" "跨节点RWX挂载或共享读写失败，请查看测试物料与describe${nfs_hint:+(${nfs_hint})}"
            fi
        else
            record_result "端到端存储验证(文件存储 te-nfs, RWX基础)" "WARN" "RWX PVC未Bound、挂载或单Pod读写失败，请排查文件存储CSI${nfs_hint:+(${nfs_hint})}"
            record_result "端到端存储验证(文件存储 te-nfs, RWX跨节点共享)" "SKIP" "RWX基础验证未通过，跳过跨节点共享验证"
        fi
    else
        record_result "端到端存储验证(文件存储 te-nfs, RWX基础)" "SKIP" "te-nfs 未就绪(见网络存储SC就绪检查)，跳过RWX验证"
        record_result "端到端存储验证(文件存储 te-nfs, RWX跨节点共享)" "SKIP" "te-nfs 未就绪，跳过跨节点共享验证"
    fi

    print_summary

    log_info "K8S可用性检查结束  $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "如有异常信息提示请跟进确认处理！完整日志已保存至: $LOG_FILE"
    if [[ -d "$ARTIFACT_DIR" ]]; then
        log_info "测试物料与异常详情(yaml/describe)已保存至: $ARTIFACT_DIR，可用 kubectl apply -f 复现并排查"
    fi
    SCRIPT_COMPLETED=true
}

# ==================== 资源清理(异常退出兜底) ====================
# EXIT trap: 脚本未正常完成时清理可能残留的测试资源，避免nginx-test/np-probe-*遗留计费节点
cleanup_on_exit() {
    if ! $SCRIPT_COMPLETED; then
        # 兼容旧测试资源(nginx-test)与新探测资源(np-probe-*),按label批量清理
        if kubectl get deployment -n "$NAMESPACE" -l app=nginx-test 2>/dev/null | grep -q . ||
            kubectl get deployment -n "$NAMESPACE" -l app="${PROBE_PREFIX}" 2>/dev/null | grep -q . ||
            kubectl get service -n "$NAMESPACE" -l app="${PROBE_PREFIX}" 2>/dev/null | grep -q .; then
            log_warning "检测到脚本异常退出，清理残留测试资源(nginx-test/${PROBE_PREFIX}-*)，避免弹性池遗留计费节点..."
            kubectl delete deployment -n "$NAMESPACE" -l app=nginx-test --force --grace-period=0 &>/dev/null
            kubectl delete deployment -n "$NAMESPACE" -l app="${PROBE_PREFIX}" --force --grace-period=0 &>/dev/null
            kubectl delete pods -n "$NAMESPACE" -l app=nginx-test --force --grace-period=0 &>/dev/null
            kubectl delete pods -n "$NAMESPACE" -l app="${PROBE_PREFIX}" --force --grace-period=0 &>/dev/null
            kubectl delete service -n "$NAMESPACE" -l app="${PROBE_PREFIX}" --ignore-not-found &>/dev/null
        fi
        # 端到端存储验证残留(te-csi-check Pod/PVC): PVC 残留会持续占用并计费底层云盘, 务必清理
        if kubectl get pvc -n "$NAMESPACE" -l app=te-csi-check 2>/dev/null | grep -q . ||
            kubectl get pod -n "$NAMESPACE" -l app=te-csi-check 2>/dev/null | grep -q .; then
            log_warning "检测到脚本异常退出，清理端到端存储验证残留(te-csi-check Pod/PVC)，避免遗留计费云盘..."
            kubectl delete pod -n "$NAMESPACE" -l app=te-csi-check --force --grace-period=0 &>/dev/null
            kubectl delete pvc -n "$NAMESPACE" -l app=te-csi-check --ignore-not-found &>/dev/null
        fi
    fi
}

trap 'log_error "脚本执行中断"; exit 1' INT TERM
trap cleanup_on_exit EXIT

main "$@"
