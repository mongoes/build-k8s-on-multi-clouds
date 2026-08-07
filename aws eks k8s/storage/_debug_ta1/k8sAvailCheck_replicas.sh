#!/bin/bash
# K8S就绪可用性确保脚本
# 功能：确保K8S环境就绪可用，包含：
#   - kubectl安装与集群连通性检查
#   - 云平台识别与StorageClass自动创建（腾讯云/阿里云/华为云/AWS/GCP）
#   - 节点池与节点规格一致性检查
#   - Pod调度、起服、网络联通性验证

# ==================== 配置部分 ====================
LOG_FILE="k8sAvailCheckResult_$(date +'%Y-%m-%d_%H%M%S').log"
NAMESPACE="debug"
# 脚本完成标志：用于EXIT trap判断是否异常退出，异常退出时清理残留测试资源
SCRIPT_COMPLETED=false

# ==================== 版本配置（跟随K8S社区迭代更新） ====================
K8S_VERSION="1.34"
K8S_MAJOR_VERSION="1"
K8S_MINOR_VERSION="34"
#默认访问docker hub
NGINX_IMAGE="nginx:1.20"
NGINX_IMAGE_TA="docker-ta.thinkingdata.cn/te/nginx:1.20"
NGINX_IMAGE_GCR="docker.m.daocloud.io/library/nginx:1.20"

# ==================== 期望节点池契约（交付工程师按本次采购编辑） ====================
# 背景: on-demand(按量付费)弹性节点池默认期望节点数为0,空闲时无任何节点对象,
#       kubectl get nodes 无法发现 -> 无法证明集群具备弹性扩容能力。
#       故需在此显式声明本次采购的全部节点池作为交付契约,由脚本主动探测验证。
# 格式: nodepool-name;billing-mode;cpu核数;内存GiB;最小节点数
#  - nodepool-name 须与节点 node.k8s.te/nodepool-name 标签一致(节点池唯一性标签)
#  - billing-mode  须与节点 node.k8s.te/billing-mode  标签一致(reserved/od/spot)
#                  注: TKE/ACK口径用 od(非on-demand),与本数组保持一致
#  - 最小节点数=0  表示弹性池(默认0节点),脚本将主动起服触发autoscaler 0->1扩容验证
#  - 数组中每一行(未注释)均视为"必选池",失败将阻断交付;
#    本次未采购的可选池(常驻/弹性高开销引擎),请注释(#)对应行
EXPECTED_NODEPOOLS=(
    "reserved-4c32g;reserved;4;32;2"      # 基础服务(必选)
    "od-4c32g;od;4;32;0"                  # 基础服务弹性池(必选,默认0节点)
    "reserved-32c128g;reserved;32;128;1"  # 常驻高开销引擎(可选)
    "od-32c128g;od;32;128;0"              # 弹性高开销引擎(可选,默认0节点)
    "spot-32c128g;spot;32;128;1"          # 弹性高开销引擎-竞价(可选)
)
# 弹性池(0节点)扩容探测总超时(秒)。0->1冷启动在TKE/ACK上通常需3~7分钟
ELASTIC_PROBE_TIMEOUT=420
# 弹性池冷启动宽限窗口(秒)。在此窗口内Pod处于Pending/Unschedulable视为"正常冷启动中";
# 超过此窗口仍Unschedulable且autoscaler明确拒绝扩容(NotTriggerScaleUp)则判定该池不可调度,
# 快速失败、不再死等到ELASTIC_PROBE_TIMEOUT。区分"真在扩容"与"永远起不来"。
ELASTIC_COLD_START_GRACE=120
# 探测Deployment名称前缀,用于统一清理(含EXIT trap兜底)
PROBE_PREFIX="np-probe"
# 内存规格匹配容差(相对偏差),容忍内核上报差异;不同量级规格相差数倍,15%足以区分
MEM_TOLERANCE=0.15

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

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
    echo -e "\n${BOLD}==================== $1 ====================${NC}" >&2
    echo "==================== $1 ====================" >>"$LOG_FILE"
}

log_section() {
    echo -e "\n${BLUE}--- $1 ---${NC}" >&2
    echo "--- $1 ---" >>"$LOG_FILE"
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

# ==================== kubectl安装 ====================
install_kubectl() {
    log_step "kubectl安装"

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
    log_step "测试K8S集群连接"
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
    log_step "节点池与节点配置检测"

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

    # -------- 节点池汇总 (Markdown格式) --------
    echo ""
    echo -e "  ${BOLD}节点池汇总${NC}"
    echo "  ==================== 节点池汇总 ====================" >>${LOG_FILE}

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

        # 获取标签列表
        local te_labels=$(kubectl get node "$first_node" -o jsonpath='{.metadata.labels}' 2>/dev/null |
            jq -r 'to_entries[] | select(.key | startswith("node.k8s.te/")) | "  - `\(.key)=\(.value)`"' 2>/dev/null | sort)
        [[ -z "$te_labels" ]] && te_labels="  - \`<none>\`"

        # 获取污点列表
        local te_taints=$(kubectl get node "$first_node" -o jsonpath='{.spec.taints}' 2>/dev/null |
            jq -r '.[] | select(.key | startswith("node.k8s.te/")) | "  - `\(.key)=\(.value):\(.effect)`"' 2>/dev/null | sort)
        [[ -z "$te_taints" ]] && te_taints="  - \`<none>\`"

        echo "" | tee -a ${LOG_FILE}
        echo "### 节点池: \`${pool_name}\`" | tee -a ${LOG_FILE}
        echo "" | tee -a ${LOG_FILE}
        echo "| 属性 | 值 |" | tee -a ${LOG_FILE}
        echo "|------|-----|" | tee -a ${LOG_FILE}
        echo "| 节点数 | ${node_count} |" | tee -a ${LOG_FILE}
        echo "| CPU | \`$(format_cpu ${cpu})\` |" | tee -a ${LOG_FILE}
        echo "| 内存 | \`$(format_resource ${mem})\` |" | tee -a ${LOG_FILE}
        echo "| 磁盘空间 | \`$(format_resource ${sys_disk})\` |" | tee -a ${LOG_FILE}
        echo "| 可分配CPU | \`$(format_cpu ${alloc_cpu})\` |" | tee -a ${LOG_FILE}
        echo "| 可分配内存 | \`$(format_resource ${alloc_mem})\` |" | tee -a ${LOG_FILE}
        echo "| 可分配磁盘 | \`$(format_resource ${alloc_disk})\` |" | tee -a ${LOG_FILE}
        echo "" | tee -a ${LOG_FILE}
        echo "**标签列表:**" | tee -a ${LOG_FILE}
        echo "${te_labels}" | tee -a ${LOG_FILE}
        echo "" | tee -a ${LOG_FILE}
        echo "**污点列表:**" | tee -a ${LOG_FILE}
        echo "${te_taints}" | tee -a ${LOG_FILE}
    done

    echo "" | tee -a ${LOG_FILE}
    echo "共发现: **${pool_count}** 个节点池，**${total_nodes}** 个节点" | tee -a ${LOG_FILE}

    # -------- 全局节点资源概览 (直接调用kubectl) --------
    echo "**节点资源全局概览**"
    kubectl get nodes 2>/dev/null | tee -a ${LOG_FILE}

    echo "" >>${LOG_FILE}

    if $has_issues; then
        return 1
    fi
    log_success "节点池检测完成，节点池归类与规格标签一致性检查通过"
    return 0
}

# ==================== 期望节点池契约校验（主动探测弹性池） ====================
# 解决"on-demand弹性池0节点时kubectl不可见"的检测漏洞:
#   阶段A 为每个期望池并发起带nodeSelector的探测Deployment(逼0节点弹性池扩容)
#   阶段B 统一等待全部Pod就绪(弹性池冷启动0->1需数分钟)
#   阶段C 复用discover_and_check_nodes()打印完整节点池现状(此时弹性池节点已可见)
#   阶段D 防错打标签: 用Pod落点节点实际规格与契约声明交叉校验
#   阶段E 契约汇总, 必选池失败则阻断交付(return 1)
#   阶段F 网络连通性测试 + 清理探测资源(弹性池节点随之缩回0)

# 生成单个探测Deployment(nodeSelector锁定节点池唯一标签 + 容忍三类billing-mode污点)
_apply_probe_deployment() {
    local dname="$1"
    local pool="$2"
    local image="$3"
    local apply_err
    apply_err=$(cat <<EOF | kubectl apply -f - 2>&1 >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${dname}
  namespace: $NAMESPACE
  labels:
    app: ${PROBE_PREFIX}
    probe-pool: "${pool}"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PROBE_PREFIX}
      probe-pool: "${pool}"
  template:
    metadata:
      labels:
        app: ${PROBE_PREFIX}
        probe-pool: "${pool}"
    spec:
      nodeSelector:
        node.k8s.te/nodepool-name: "${pool}"
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
)
    if [[ -n "$apply_err" ]]; then
        log_warning "  探测Deployment[${dname}]创建报错: ${apply_err}"
        return 1
    fi
    return 0
}

# 删除所有探测Deployment(弹性池节点随之被autoscaler缩回0)
_clean_probe_deployments() {
    kubectl delete deployment -n "$NAMESPACE" -l app="${PROBE_PREFIX}" --ignore-not-found --wait=false >/dev/null 2>&1
}

# 校验结果转✅/❌/—标记
_mark() { [[ "$1" == "yes" ]] && echo "✅" || { [[ "$1" == "no" ]] && echo "❌" || echo "—"; }; }

verify_expected_nodepools() {
    log_step "期望节点池契约校验（主动探测弹性池）"

    if [[ ${#EXPECTED_NODEPOOLS[@]} -eq 0 ]]; then
        log_warning "未配置期望节点池契约(EXPECTED_NODEPOOLS为空)，跳过契约校验"
        return 0
    fi

    ensure_namespace

    declare -A POOL_BILLING POOL_CPU POOL_MEM POOL_MIN POOL_DEPLOY
    declare -A POOL_EXIST POOL_NODE POOL_CPU_OK POOL_MEM_OK POOL_BILL_OK
    local pool_order=()
    local current_image="${NGINX_IMAGE}"
    local image_idx=0 # 0=dockerhub 1=TA 2=GCR

    # -------- 阶段A: 并发起服探测 --------
    log_section "阶段A: 为${#EXPECTED_NODEPOOLS[@]}个期望节点池并发起服探测"
    local entry
    for entry in "${EXPECTED_NODEPOOLS[@]}"; do
        local pname pbilling pcpu pmem pmin
        IFS=';' read -r pname pbilling pcpu pmem pmin <<<"$entry"
        [[ -z "$pname" ]] && continue
        pool_order+=("$pname")
        POOL_BILLING[$pname]="$pbilling"
        POOL_CPU[$pname]="$pcpu"
        POOL_MEM[$pname]="$pmem"
        POOL_MIN[$pname]="$pmin"
        POOL_DEPLOY[$pname]="${PROBE_PREFIX}-${pname}"
        POOL_EXIST[$pname]="pending"

        local elastic_note=""
        [[ "$pmin" == "0" ]] && elastic_note=" ${YELLOW}(弹性池,将触发autoscaler 0->1扩容)${NC}"
        log_info "  起服探测: ${BOLD}${pname}${NC} [${pbilling} ${pcpu}c${pmem}g min=${pmin}]${elastic_note}"
        _apply_probe_deployment "${POOL_DEPLOY[$pname]}" "$pname" "$current_image"
    done

    # -------- 阶段B: 统一等待全部就绪 --------
    log_section "阶段B: 等待探测Pod就绪(总超时${ELASTIC_PROBE_TIMEOUT}s,弹性池冷启动需数分钟)"
    local elapsed=0
    local interval=10
    while [[ $elapsed -lt $ELASTIC_PROBE_TIMEOUT ]]; do
        local all_done=true
        local image_pull_failing=false
        local ready_count=0
        local status_line=""

        local pname
        for pname in "${pool_order[@]}"; do
            # 已终态(就绪/不可调度)的池不再轮询
            if [[ "${POOL_EXIST[$pname]}" == "ready" ]]; then
                ((ready_count++))
                status_line+=" ${pname}[✅就绪]"
                continue
            fi
            if [[ "${POOL_EXIST[$pname]}" == "unschedulable" ]]; then
                status_line+=" ${pname}[❌不可调度]"
                continue
            fi

            local phase=$(kubectl get pods -n $NAMESPACE -l probe-pool=${pname} -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
            local waiting_reason=$(kubectl get pods -n $NAMESPACE -l probe-pool=${pname} \
                -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)

            if [[ "$phase" == "Running" ]]; then
                POOL_EXIST[$pname]="ready"
                POOL_NODE[$pname]=$(kubectl get pods -n $NAMESPACE -l probe-pool=${pname} -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
                ((ready_count++))
                status_line+=" ${pname}[✅就绪]"
                continue
            fi

            # 调度态判定: PodScheduled=False/Unschedulable 表示当前无节点可落
            local sched_status=$(kubectl get pods -n $NAMESPACE -l probe-pool=${pname} \
                -o jsonpath='{.items[0].status.conditions[?(@.type=="PodScheduled")].status}' 2>/dev/null)
            local sched_reason=$(kubectl get pods -n $NAMESPACE -l probe-pool=${pname} \
                -o jsonpath='{.items[0].status.conditions[?(@.type=="PodScheduled")].reason}' 2>/dev/null)

            if [[ "$sched_status" == "False" && "$sched_reason" == "Unschedulable" ]]; then
                # 超过冷启动宽限窗口仍不可调度,且autoscaler明确拒绝扩容 -> 快速失败,不再死等
                local no_scaleup=$(kubectl get events -n $NAMESPACE --field-selector reason=NotTriggerScaleUp 2>/dev/null \
                    | grep -c "probe-pool=${pname}\|${POOL_DEPLOY[$pname]}")
                # 事件按involvedObject匹配不到时,退化为按Pod名匹配
                if [[ "$no_scaleup" == "0" ]]; then
                    local podname=$(kubectl get pods -n $NAMESPACE -l probe-pool=${pname} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
                    [[ -n "$podname" ]] && no_scaleup=$(kubectl get events -n $NAMESPACE 2>/dev/null | grep -c "NotTriggerScaleUp.*${podname}")
                fi
                if [[ $elapsed -ge $ELASTIC_COLD_START_GRACE && "$no_scaleup" != "0" ]]; then
                    POOL_EXIST[$pname]="unschedulable"
                    status_line+=" ${pname}[❌不可调度:autoscaler拒绝扩容]"
                    echo "==== 不可调度节点池[${pname}] 快速失败(elapsed=${elapsed}s) Pod describe ====" >>"$LOG_FILE"
                    kubectl describe pods -n $NAMESPACE -l probe-pool=${pname} >>"$LOG_FILE" 2>&1
                    continue
                fi
                all_done=false
                status_line+=" ${pname}[⏳待调度/扩容${elapsed}s]"
            elif [[ "$waiting_reason" == "ErrImagePull" || "$waiting_reason" == "ImagePullBackOff" ]]; then
                all_done=false
                image_pull_failing=true
                status_line+=" ${pname}[⚠镜像拉取失败]"
            else
                all_done=false
                status_line+=" ${pname}[${phase:-创建中}]"
            fi
        done

        $all_done && break

        # 镜像拉取失败 -> 全局切换下一备用镜像并patch所有探测Deployment(三级回退共享)
        if $image_pull_failing && [[ $image_idx -lt 2 ]]; then
            ((image_idx++))
            if [[ $image_idx -eq 1 ]]; then
                current_image="${NGINX_IMAGE_TA}"
            else
                current_image="${NGINX_IMAGE_GCR}"
            fi
            log_info "  检测到镜像拉取失败，全局切换备用镜像: ${current_image}"
            kubectl get deploy -n $NAMESPACE -l app=${PROBE_PREFIX} -o name 2>/dev/null |
                xargs -r -I{} kubectl patch {} -n $NAMESPACE --type merge \
                    -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"nginx-probe\",\"image\":\"${current_image}\"}]}}}}" >/dev/null 2>&1
        fi

        sleep $interval
        ((elapsed += interval))
        log_info "  探测中(${elapsed}s/${ELASTIC_PROBE_TIMEOUT}s 就绪${ready_count}/${#pool_order[@]}):${status_line}"
    done

    # 标记仍未就绪且非快速失败的池为timeout,并将describe写入日志便于排查
    local pname
    for pname in "${pool_order[@]}"; do
        if [[ "${POOL_EXIST[$pname]}" != "ready" && "${POOL_EXIST[$pname]}" != "unschedulable" ]]; then
            POOL_EXIST[$pname]="timeout"
            echo "==== 探测超时节点池[${pname}] Pod describe ====" >>"$LOG_FILE"
            kubectl describe pods -n $NAMESPACE -l probe-pool=${pname} >>"$LOG_FILE" 2>&1
        fi
    done

    # -------- 阶段C: 复用discover_and_check_nodes打印完整节点池现状 --------
    log_section "阶段C: 节点池完整现状枚举(弹性池节点已拉起,现可见)"
    discover_and_check_nodes

    # -------- 阶段D: 防错打标签交叉校验(Pod落点节点实际规格 vs 契约声明) --------
    log_section "阶段D: 节点池规格契约交叉校验(防错打标签)"
    for pname in "${pool_order[@]}"; do
        # 未就绪的池无落点节点,规格校验留空(以存在性失败为准)
        if [[ "${POOL_EXIST[$pname]}" != "ready" ]]; then
            POOL_CPU_OK[$pname]="-"
            POOL_MEM_OK[$pname]="-"
            POOL_BILL_OK[$pname]="-"
            continue
        fi
        local node="${POOL_NODE[$pname]}"
        local want_cpu="${POOL_CPU[$pname]}"
        local want_mem="${POOL_MEM[$pname]}"
        local want_bill="${POOL_BILLING[$pname]}"

        local act_cpu=$(kubectl get node "$node" -o jsonpath='{.status.capacity.cpu}' 2>/dev/null)
        local act_mem_raw=$(kubectl get node "$node" -o jsonpath='{.status.capacity.memory}' 2>/dev/null)
        local act_bill=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node\.k8s\.te/billing-mode}' 2>/dev/null)

        # CPU: 精确匹配(强信号)
        if [[ "$act_cpu" == "$want_cpu" ]]; then
            POOL_CPU_OK[$pname]="yes"
        else
            POOL_CPU_OK[$pname]="no"
        fi

        # 内存: 换算GiB后相对偏差<=MEM_TOLERANCE
        local act_mem_num="${act_mem_raw//[A-Za-z]/}"
        local act_mem_unit="${act_mem_raw//[0-9]/}"
        local act_mem_gib=$(awk -v n="$act_mem_num" -v u="$act_mem_unit" 'BEGIN{
            if(u=="Ki") printf "%.2f", n/1024/1024;
            else if(u=="Mi") printf "%.2f", n/1024;
            else if(u=="Gi") printf "%.2f", n;
            else printf "%.2f", n/1024/1024/1024;  # 无单位按字节
        }')
        if awk -v a="$act_mem_gib" -v w="$want_mem" -v t="$MEM_TOLERANCE" \
            'BEGIN{d=(a-w)/w; if(d<0)d=-d; exit !(d<=t)}'; then
            POOL_MEM_OK[$pname]="yes"
        else
            POOL_MEM_OK[$pname]="no"
        fi

        # billing-mode标签: 精确匹配
        if [[ "$act_bill" == "$want_bill" ]]; then
            POOL_BILL_OK[$pname]="yes"
        else
            POOL_BILL_OK[$pname]="no"
        fi

        # 任一项不符,打印"声明 vs 实测"对照
        if [[ "${POOL_CPU_OK[$pname]}" == "no" || "${POOL_MEM_OK[$pname]}" == "no" || "${POOL_BILL_OK[$pname]}" == "no" ]]; then
            log_warning "  节点池[${pname}]规格与契约不符(疑似错打标签),落点节点: ${node}"
            log_warning "    声明: CPU=${want_cpu}c 内存=${want_mem}Gi 付费=${want_bill}"
            log_warning "    实测: CPU=${act_cpu}c 内存=$(printf '%.1f' "$act_mem_gib")Gi 付费=${act_bill:-<未打billing-mode标签>}"
        fi
    done

    # -------- 阶段E: 契约汇总(Markdown) + 交付结论 --------
    log_section "阶段E: 期望节点池契约校验汇总"
    echo "" | tee -a "$LOG_FILE"
    echo "| 节点池 | 付费类型 | 期望规格 | 存在性 | CPU | 内存 | 付费类型 |" | tee -a "$LOG_FILE"
    echo "|--------|---------|---------|--------|-----|------|---------|" | tee -a "$LOG_FILE"
    local fail_count=0
    for pname in "${pool_order[@]}"; do
        local exist_mark="❌"
        [[ "${POOL_EXIST[$pname]}" == "ready" ]] && exist_mark="✅"
        [[ "${POOL_EXIST[$pname]}" == "unschedulable" ]] && exist_mark="❌(不可调度)"
        [[ "${POOL_EXIST[$pname]}" == "timeout" ]] && exist_mark="❌(超时)"
        local cpu_m=$(_mark "${POOL_CPU_OK[$pname]}")
        local mem_m=$(_mark "${POOL_MEM_OK[$pname]}")
        local bill_m=$(_mark "${POOL_BILL_OK[$pname]}")
        local elastic_tag=""
        [[ "${POOL_MIN[$pname]}" == "0" ]] && elastic_tag="(弹性)"
        echo "| \`${pname}\`${elastic_tag} | ${POOL_BILLING[$pname]} | ${POOL_CPU[$pname]}c${POOL_MEM[$pname]}g | ${exist_mark} | ${cpu_m} | ${mem_m} | ${bill_m} |" | tee -a "$LOG_FILE"

        # 失败判定: 存在性失败,或任一规格项为no
        if [[ "${POOL_EXIST[$pname]}" != "ready" ]] ||
            [[ "${POOL_CPU_OK[$pname]}" == "no" || "${POOL_MEM_OK[$pname]}" == "no" || "${POOL_BILL_OK[$pname]}" == "no" ]]; then
            ((fail_count++))
        fi
    done
    echo "" | tee -a "$LOG_FILE"
    echo "> 弹性池(min=0)存在性✅ 即证明集群具备充足弹性扩容能力(autoscaler已成功0->1)" | tee -a "$LOG_FILE"

    # -------- 阶段F: 网络连通性测试(挑首个就绪池的Pod) + 清理 --------
    log_section "阶段F: 网络连通性测试 + 清理探测资源"
    POD_NAME=""
    POD_IP=""
    local net_pool=""
    for pname in "${pool_order[@]}"; do
        if [[ "${POOL_EXIST[$pname]}" == "ready" ]]; then
            net_pool="$pname"
            POD_NAME=$(kubectl get pods -n $NAMESPACE -l probe-pool=${pname} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            POD_IP=$(kubectl get pods -n $NAMESPACE -l probe-pool=${pname} -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
            break
        fi
    done

    if [[ -n "$POD_NAME" && -n "$POD_IP" ]]; then
        log_info "使用节点池[${net_pool}]的Pod(${POD_NAME} / ${POD_IP})进行网络连通性测试"
        ensure_iptables_for_pod_cidr
        test_localhost_to_pod_connectivity
        test_pod_to_localhost_connectivity
    else
        log_warning "无任何探测Pod就绪，跳过网络连通性测试"
    fi

    log_info "清理探测Deployment(弹性池节点将被autoscaler缩回0，请关注计费窗口)..."
    _clean_probe_deployments

    if [[ $fail_count -gt 0 ]]; then
        log_error "期望节点池契约校验未通过：${fail_count}个节点池存在性或规格不符，交付阻断！请查看上述汇总表与日志"
        return 1
    fi
    log_success "期望节点池契约校验通过：全部${#pool_order[@]}个节点池存在、规格匹配、弹性能力已验证"
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
            if [[ "$current_image" == "${NGINX_IMAGE}" ]]; then
                log_info "镜像拉取失败(${current_image})，自动切换到备用镜像: ${NGINX_IMAGE_TA}"
                current_image="${NGINX_IMAGE_TA}"
                # 删除旧RS，再patch新镜像
                kubectl delete rs -n $NAMESPACE -l app=${deployment_name} --ignore-not-found
                kubectl patch deployment ${deployment_name} -n $NAMESPACE -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"nginx-test\",\"image\":\"${current_image}\"}]}}}}"
                # 等待RS重建后再检查
                sleep 10
                ((elapsed += 10))
                continue
            elif [[ "$current_image" == "${NGINX_IMAGE_TA}" ]]; then
                log_info "备用镜像也拉取失败，尝试GCR镜像: ${NGINX_IMAGE_GCR}"
                current_image="${NGINX_IMAGE_GCR}"
                kubectl delete rs -n $NAMESPACE -l app=${deployment_name} --ignore-not-found
                kubectl patch deployment ${deployment_name} -n $NAMESPACE -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"nginx-test\",\"image\":\"${current_image}\"}]}}}}"
                sleep 10
                ((elapsed += 10))
                continue
            else
                log_error "所有镜像仓库均无法访问，请检查网络配置"
                kubectl describe pods -n $NAMESPACE -l app=${deployment_name} >>${LOG_FILE} 2>&1
                return 1
            fi
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
        log_error "  1. 所有镜像仓库均无法访问(已尝试: docker hub -> 备用 -> GCR)"
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
    log_step "确保iptables放行Pod网段"

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

    # 分布式集群提示：除ta1外若存在其他ta节点，本脚本不自动处理，提醒用户在install.properties配置Pod网段
    local ta_hosts_count=$(grep -E -c '[[:space:]]ta[0-9]+([[:space:]]|$)' /etc/hosts 2>/dev/null)
    if [[ "${ta_hosts_count:-0}" -gt 1 ]]; then
        log_error "检测到分布式集群环境(本脚本仅放行了本机ta1的iptables)，请在install.properties中配置pod网段 e.g. ${pod_cidr} 保障iptables充分放行！"
    fi

    return 0
}

test_localhost_to_pod_connectivity() {
    log_step "测试本地服务器访问Pod"
    if curl -s -m 10 "http://$POD_IP" | grep -q "Welcome to nginx!"; then
        log_success "测试本地服务器访问POD网络正常"
    else
        log_error "错误：测试本地服务器访问POD网络异常，可能原因："
        log_error "  1. 本地服务器和K8S绑定的安全组未相互放行所有流量"
    fi
}

test_pod_to_localhost_connectivity() {
    log_step "测试Pod访问本地服务器"
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

    if kubectl exec -it $POD_NAME -n $NAMESPACE -- curl -LsS -m 10 "http://$LOCAL_SERVER_IP:$LOCAL_SERVER_PORT/metrics" &>/dev/null; then
        log_success "测试Pod访问本地服务器正常"
    else
        log_error "错误：Pod无法访问本地服务器，可能原因："
        log_error "1. 本地服务器iptables阻止了与K8S之间的通信"
        return 1
    fi
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
    log_step "检测k8s所属环境"

    local cloud_provider="unknown"

    for pkg in dmidecode jq; do
        if ! command -v $pkg &>/dev/null; then
            yum -y install $pkg &>/dev/null
        fi
    done

    local manufacturer=$(/usr/sbin/dmidecode -q 2>/dev/null | grep "Manufacturer" | head -1 |
        awk -F'[:]' '{print $2}' | sed 's/^ //g' | tr '[:upper:]' '[:lower:]')

    case $manufacturer in
    *Amazon* | *amazon* | *aws*) cloud_provider="aws" ;;
    *Ali* | *ali* | *alibaba*) cloud_provider="alibaba" ;;
    *Tencent* | *tencent* | *cvm*) cloud_provider="tencent" ;;
    *Huawei* | *huawei* | *openstack*) cloud_provider="huawei" ;;
    *Microsoft* | *microsoft* | *azure*) cloud_provider="azure" ;;
    *Gcp* | *gcp* | *google*) cloud_provider="google" ;;
    *Volc* | *volc* | *volcano*) cloud_provider="volcengine" ;;
    esac

    if [[ "$cloud_provider" == "unknown" ]] && command -v systemd-detect-virt &>/dev/null; then
        local virt=$(systemd-detect-virt 2>/dev/null)
        case $virt in
        *vmware*) cloud_provider="vmware" ;;
        *kvm*) cloud_provider="kvm" ;;
        *qemu*) cloud_provider="qemu" ;;
        *physical*) cloud_provider="baremetal" ;;
        esac
    fi

    log_info "检测到k8s所属环境: ${BOLD}${cloud_provider}${NC}"
    echo "$cloud_provider"
}

# ==================== StorageClass 确保函数 ====================
# 根据云平台自动创建对应的默认StorageClass，确保K8S存储就绪
ensure_storageclass() {
    local cloud_platform="$1"
    log_step "确保默认StorageClass就绪"

    # 检查是否已存在 te- 前缀的默认SC
    local existing_default_sc=$(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

    if [[ -n "$existing_default_sc" ]]; then
        local te_sc=$(echo "$existing_default_sc" | grep "^te-")
        if [[ -n "$te_sc" ]]; then
            log_success "已存在te前缀默认StorageClass: ${te_sc}，无需创建"
            return 0
        fi
        # 存在非te-前缀的默认SC，移除其default注解
        for sc_name in $existing_default_sc; do
            log_info "移除非标准默认SC [${sc_name}] 的default注解"
            kubectl annotate sc "$sc_name" storageclass.kubernetes.io/is-default-class- 2>/dev/null
            kubectl annotate sc "$sc_name" storageclass.beta.kubernetes.io/is-default-class- 2>/dev/null
        done
    fi

    # 根据云平台创建对应SC
    case $cloud_platform in
    *tencent*)
        log_info "创建腾讯云StorageClass: te-cbs"
        cat <<'EOF' | kubectl apply -f -
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
  name: te-cbs
parameters:
  type: cbs
provisioner: com.tencent.cloud.csi.cbs
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
        ;;
    *alibaba* | *ali*)
        log_info "创建阿里云StorageClass: te-disk-essd"
        cat <<'EOF' | kubectl apply -f -
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
  name: te-disk-essd
parameters:
  type: cloud_essd
provisioner: diskplugin.csi.alibabacloud.com
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
        ;;
    *huawei*)
        log_info "创建华为云StorageClass: te-csi-disk"
        cat <<'EOF' | kubectl apply -f -
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
  name: te-csi-disk
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
        log_info "创建GCP StorageClass: te-standard-rwo"
        cat <<'EOF' | kubectl apply -f -
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
  labels:
    addonmanager.kubernetes.io/mode: EnsureExists
  name: te-standard-rwo
parameters:
  type: pd-balanced
provisioner: pd.csi.storage.gke.io
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
        log_info "创建AWS StorageClass: te-gp3"
        cat <<'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
  name: te-gp3
parameters:
  fsType: ext4
  type: gp3
provisioner: ebs.csi.aws.com
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
        ;;
    vmware | kvm | qemu | baremetal)
        # TE内置K8S需要ta-admin操作，仅输出指引
        local local_path_sc=$(kubectl get sc -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.provisioner}{"\n"}{end}' 2>/dev/null | grep "local-path")
        if [[ -n "$local_path_sc" ]]; then
            log_success "已存在local-path StorageClass，TE内置K8S存储就绪"
            return 0
        fi
        log_warning "TE内置K8S环境未检测到local-path-provisioner StorageClass"
        log_info "请执行以下手动操作:"
        log_info "  1. 在 install.properties 中配置: local.path.provisioner.enabled=true"
        log_info "  2. 执行: ./ta-admin update -v 6.0"
        log_info "  3. 执行: ./ta-admin local-path-provisioner install"
        log_info "  4. 验证: kubectl get sc"
        log_info "注意: ta-admin 需要 4.23 及之后的版本才支持此功能"
        return 1
        ;;
    *)
        log_warning "未知云平台(${cloud_platform})，无法自动创建StorageClass，请手动配置"
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

# ==================== 通用CSI就绪检查 ====================
# 背景: CSI(容器存储接口)是 StorageClass/PVC/挂载卷Pod 的底层依赖。
#       若 CSI 插件缺失或异常 -> PVC 无法 Bound -> 使用 PVC 的 Pod 无法启动 -> 上层应用存储全部异常。
# 判据(不以 CSIDriver 对象为唯一标准, 因部分云(如华为)provisioner名 != CSIDriver对象名):
#   1) controller(Deployment) 可用副本 >=1  —— 负责 CreateVolume/attach 等控制面操作
#                                              (GKE 等控制面托管的云此项不可见, 传空跳过)
#   2) node(DaemonSet) numberReady >=1 且 == desiredNumberScheduled —— 负责节点本机挂载
#   3) CSIDriver 对象存在性 —— 仅作辅助信息打印, 不作硬判据
# 参数: $1=平台显示名 $2=CSIDriver名 $3=controller-Deployment名关键字(空=控制面托管不可见) $4=node-DaemonSet名关键字
# 返回: 0=就绪 1=存在异常(本脚本统一 warning 不阻断, 由调用方决定)
check_csi_ready() {
    local platform="$1" driver="$2" ctrl_kw="$3" node_kw="$4"
    log_section "${platform} CSI 插件就绪检查 (驱动: ${driver})"
    local issue=0

    # -- 1. 控制面 controller(Deployment) --
    if [[ -n "$ctrl_kw" ]]; then
        local ctrl=$(kubectl get deploy -n kube-system --no-headers 2>/dev/null | grep -E "$ctrl_kw" | awk '{print $1}' | head -1)
        if [[ -z "$ctrl" ]]; then
            log_warning "  未找到 CSI controller (kube-system 内匹配 '${ctrl_kw}' 的 Deployment)，PVC 动态供给将不可用"
            issue=1
        else
            local avail=$(kubectl get deploy -n kube-system "$ctrl" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
            avail=${avail:-0}
            if [[ "$avail" -ge 1 ]]; then
                log_success "  CSI controller 就绪: ${ctrl} (可用副本 ${avail})"
            else
                log_warning "  CSI controller 未就绪: ${ctrl} (可用副本 0)，PVC 将无法 Bound"
                issue=1
            fi
        fi
    else
        log_info "  CSI controller 由云平台托管(用户侧不可见)，跳过 controller 检查，以 node 插件 + 端到端验证为准"
    fi

    # -- 2. 节点面 node(DaemonSet) --
    local ds=$(kubectl get ds -n kube-system --no-headers 2>/dev/null | grep -E "$node_kw" | awk '{print $1}' | head -1)
    if [[ -z "$ds" ]]; then
        log_warning "  未找到 CSI node 插件 (kube-system 内匹配 '${node_kw}' 的 DaemonSet)，节点卷挂载将不可用"
        issue=1
    else
        local nready=$(kubectl get ds -n kube-system "$ds" -o jsonpath='{.status.numberReady}' 2>/dev/null)
        local ndesired=$(kubectl get ds -n kube-system "$ds" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
        nready=${nready:-0}
        ndesired=${ndesired:-0}
        if [[ "$nready" -ge 1 && "$nready" -eq "$ndesired" ]]; then
            log_success "  CSI node 插件就绪: ${ds} (${nready}/${ndesired} Ready)"
        elif [[ "$nready" -ge 1 ]]; then
            log_warning "  CSI node 插件部分就绪: ${ds} (${nready}/${ndesired} Ready)，部分节点卷挂载可能异常"
            issue=1
        else
            log_warning "  CSI node 插件未就绪: ${ds} (0/${ndesired} Ready)，节点卷挂载将不可用"
            issue=1
        fi
    fi

    # -- 3. CSIDriver 对象(辅助信息, 不作硬判据) --
    if kubectl get csidriver "$driver" &>/dev/null; then
        log_info "  CSIDriver 对象已注册: ${driver}"
    else
        log_info "  提示: 未发现名为 '${driver}' 的 CSIDriver 对象(部分云不显式声明该对象，以上控制器/节点检查为准)"
    fi

    if [[ $issue -eq 0 ]]; then
        log_success "${platform} CSI 插件检查通过"
        return 0
    fi
    log_warning "${platform} CSI 插件存在异常，若业务使用持久化存储(PVC)请优先排查，否则 SC/PVC/Pod 将工作异常"
    return 1
}

# ==================== 端到端存储验证 (SC -> PVC -> Pod 挂载) ====================
# CSI 控制器就绪仅证明"组件在跑"；本函数进一步用默认 te- StorageClass 真实创建 PVC，
# 并起一个挂载该 PVC 的 Pod。使用了 PVC 的 Pod 能 Running，即等价于:
#   PVC 已 Bound(动态供给成功) + 卷 attach/mount 成功 == 底层 CSI 存储端到端就绪可用。
# 注: 默认 SC 多为 WaitForFirstConsumer，PVC 须由 Pod 调度触发绑定，故 PVC 与 Pod 一并创建。
_apply_csi_check_pod() {
    local pod="$1" pvc="$2" image="$3"
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${NAMESPACE}
  labels:
    app: te-csi-check
spec:
  containers:
  - name: csi-check
    image: ${image}
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
EOF
}

verify_storage_e2e() {
    log_step "端到端存储验证 (SC -> PVC -> Pod 挂载)"
    ensure_namespace

    # 取 te- 前缀默认 SC(由 ensure_storageclass 确保)；无默认 SC 则跳过
    local default_sc=$(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1)
    if [[ -z "$default_sc" ]]; then
        log_warning "未发现默认 StorageClass，跳过端到端存储验证(请先确保 CSI 与默认 SC 就绪)"
        return 1
    fi
    log_info "使用默认 StorageClass: ${default_sc}"

    local pvc_name="te-csi-check-pvc"
    local pod_name="te-csi-check-pod"
    local image="${NGINX_IMAGE}"

    # 清理可能的历史残留(幂等)
    kubectl delete pod "$pod_name" -n "$NAMESPACE" --force --grace-period=0 &>/dev/null
    kubectl delete pvc "$pvc_name" -n "$NAMESPACE" --ignore-not-found &>/dev/null

    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc_name}
  namespace: ${NAMESPACE}
  labels:
    app: te-csi-check
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ${default_sc}
  resources:
    requests:
      storage: 1Gi
EOF
    _apply_csi_check_pod "$pod_name" "$pvc_name" "$image"

    log_info "等待 PVC 绑定 + Pod 启动(块存储动态供给+attach 通常 1~3 分钟)..."
    local timeout=240 elapsed=0 interval=10
    local pod_ready=false
    while [[ $elapsed -lt $timeout ]]; do
        local phase=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
        local wreason=$(kubectl get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
        if [[ "$phase" == "Running" ]]; then
            pod_ready=true
            break
        fi
        # 镜像拉取失败 -> 切换备用镜像并重建 Pod(避免把镜像问题误判为存储问题)
        if [[ "$wreason" == "ErrImagePull" || "$wreason" == "ImagePullBackOff" ]]; then
            local next=""
            if [[ "$image" == "${NGINX_IMAGE}" ]]; then
                next="${NGINX_IMAGE_TA}"
            elif [[ "$image" == "${NGINX_IMAGE_TA}" ]]; then
                next="${NGINX_IMAGE_GCR}"
            fi
            if [[ -n "$next" ]]; then
                log_info "  镜像拉取失败(${image})，切换备用镜像: ${next}"
                image="$next"
                kubectl delete pod "$pod_name" -n "$NAMESPACE" --force --grace-period=0 &>/dev/null
                _apply_csi_check_pod "$pod_name" "$pvc_name" "$image"
            fi
        fi
        sleep $interval
        ((elapsed += interval))
    done

    local pvc_phase=$(kubectl get pvc "$pvc_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)

    if $pod_ready; then
        log_success "端到端存储验证通过: PVC[${pvc_name}]=${pvc_phase}，挂载 PVC 的 Pod 已 Running —— 底层 CSI 存储就绪可用"
    else
        if [[ "$pvc_phase" != "Bound" ]]; then
            log_warning "PVC[${pvc_name}] 未 Bound (当前: ${pvc_phase:-未知})，CSI 动态供给可能异常，请排查 CSI controller/provisioner"
        else
            log_warning "PVC 已 Bound 但挂载 PVC 的 Pod 未 Running，卷 attach/mount 可能异常或镜像不可达，详见日志 describe"
        fi
        echo "==== 端到端存储验证 PVC describe ====" >>"$LOG_FILE"
        kubectl describe pvc "$pvc_name" -n "$NAMESPACE" >>"$LOG_FILE" 2>&1
        echo "==== 端到端存储验证 Pod describe ====" >>"$LOG_FILE"
        kubectl describe pod "$pod_name" -n "$NAMESPACE" >>"$LOG_FILE" 2>&1
    fi

    # 清理(reclaimPolicy=Delete 时底层卷随 PVC 删除一并回收)
    kubectl delete pod "$pod_name" -n "$NAMESPACE" --force --grace-period=0 &>/dev/null
    kubectl delete pvc "$pvc_name" -n "$NAMESPACE" --ignore-not-found &>/dev/null

    $pod_ready && return 0 || return 1
}

# ==================== 云平台特性检查函数 ====================
check_tencent_cloud_features() {
    echo "当前云平台：腾讯云(TKE)，开始执行特性检查"

    check_csi_ready "腾讯云(TKE)" "com.tencent.cloud.csi.cbs" "csi-cbs-controller" "csi-cbs-node"

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

    check_csi_ready "AWS(EKS)" "ebs.csi.aws.com" "ebs-csi-controller" "ebs-csi-node"

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

check_alibaba_cloud_features() {
    echo "当前云平台：阿里云(ACK)，开始执行特性检查"

    # 阿里 ACK 为聚合式: 节点端单个 csi-plugin DaemonSet 内含 disk/nas/oss 驱动;
    # controller 为独立的 csi-provisioner Deployment。驱动名以块存储 diskplugin 为代表。
    check_csi_ready "阿里云(ACK)" "diskplugin.csi.alibabacloud.com" "csi-provisioner" "csi-plugin"

    local cluster_status=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [[ "$cluster_status" == "True" ]]; then
        log_success "ACK集群节点状态正常"
    else
        log_warning "ACK集群存在非就绪节点"
    fi
}

check_volcengine_cloud_features() {
    echo "当前云平台：火山引擎(VKE)，开始执行特性检查"

    check_csi_ready "火山引擎(VKE)" "ebs.csi.volcengine.com" "csi-ebs-controller" "csi-ebs-node"

    local ready_nodes=$(kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -o "True" | wc -l)
    local total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    log_info "VKE节点就绪状态: ${ready_nodes}/${total_nodes}"
}

check_huawei_cloud_features() {
    echo "当前云平台：华为云(CCE)，开始执行特性检查"

    # 华为 CCE 为单体 Everest: controller=everest-csi-controller(Deploy), node=everest-csi-driver(DS);
    # provisioner 名为 everest-csi-provisioner(非 CSIDriver 对象名), 故以控制器/节点就绪为准。
    check_csi_ready "华为云(CCE)" "disk.csi.everest.io" "everest-csi-controller" "everest-csi-driver"

    local ready_nodes=$(kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -o "True" | wc -l)
    local total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    log_info "CCE节点就绪状态: ${ready_nodes}/${total_nodes}"
}

check_azure_cloud_features() {
    echo "当前云平台：Azure(AKS)，开始执行特性检查"
    local ready_nodes=$(kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -o "True" | wc -l)
    local total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    log_info "AKS节点就绪状态: ${ready_nodes}/${total_nodes}"
}

check_google_cloud_features() {
    echo "当前云平台：谷歌云(GKE)，开始执行特性检查"

    # GKE PD CSI 的 controller 运行在 Google 托管控制平面(用户 kube-system 不可见),
    # 故 controller 关键字传空, 仅校验节点端 pdcsi-node DaemonSet, 端到端验证补足控制面证明。
    check_csi_ready "谷歌云(GKE)" "pd.csi.storage.gke.io" "" "pdcsi-node"

    local ready_nodes=$(kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -o "True" | wc -l)
    local total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    log_info "GKE节点就绪状态: ${ready_nodes}/${total_nodes}"
}

check_baremetal_cloud_features() {
    echo "当前环境：物理机/自建K8S，开始执行特性检查"
    local ready_nodes=$(kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -o "True" | wc -l)
    local total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    log_info "节点就绪状态: ${ready_nodes}/${total_nodes}"
}

# ==================== 主执行流程 ====================
main() {
    echo -e "${BOLD}===================================================================================="
    log_info "K8S 就绪可用性确保脚本 v3.0"
    log_info "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "日志文件: $LOG_FILE"
    echo -e "====================================================================================${NC}"

    echo -e "\n${BOLD}==================== 检查计划 ====================${NC}"

    log_info "1. kubectl检查"
    log_info "2. K8S集群连通性检查"
    log_info "3. K8S所属环境检查"
    log_info "4. StorageClass就绪确保"
    log_info "5. 云平台特性检查(含CSI插件就绪检查)"
    log_info "6. K8S节点池和节点配置检查"
    log_info "7. Pod部署启动检查"
    log_info "8. 本地服务器访问Pod网络连通性检查"
    log_info "9. Pod访问本地服务器网络连通性检查"
    log_info "10. 端到端存储验证(SC->PVC->挂载PVC的Pod起服)"
    echo ""

    checkUser
    install_kubectl
    test_k8s_connection

    log_step "检查k8s所属环境"
    cloud_platform=$(detect_cloud_platform)

    ensure_storageclass "$cloud_platform"

    case $cloud_platform in
    *tencent*) check_tencent_cloud_features ;;
    *alibaba* | *ali*) check_alibaba_cloud_features ;;
    *volc*) check_volcengine_cloud_features ;;
    *huawei*) check_huawei_cloud_features ;;
    *aws*)
        check_aws_cloud_features
        log_info "AWS EKS环境经由特殊流程(auto_build_nodepool.sh)处理，不再进行其他检测"
        SCRIPT_COMPLETED=true
        return 0
        ;;
    *azure*) check_azure_cloud_features ;;
    *google*) check_google_cloud_features ;;
    vmware | kvm | qemu | baremetal) check_baremetal_cloud_features ;;
    *) log_warning "未知云平台/环境，跳过平台特性检查" ;;
    esac

    # 期望节点池契约校验: 内部已编排 并发探测->discover_and_check_nodes完整枚举->
    # 防错打标签交叉校验->契约汇总->网络连通性测试->清理探测资源
    if ! verify_expected_nodepools; then
        log_error "K8S节点池契约校验失败，请先解决上述问题后重试"
        exit 1
    fi

    # 端到端存储验证: 用默认 te- SC 真实创建 PVC + 挂载它的 Pod, Pod 能起服即证明底层 CSI 存储就绪
    # (warning 不阻断: 存储异常不应阻断节点池等其他交付结论, 但需醒目提示排查)
    verify_storage_e2e

    log_info "K8S可用性检查结束  $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "如有异常信息提示请跟进确认处理！完整日志已保存至: $LOG_FILE"
    SCRIPT_COMPLETED=true
}

# ==================== 资源清理(异常退出兜底) ====================
# EXIT trap: 脚本未正常完成时清理可能残留的测试资源，避免nginx-test/np-probe-*遗留计费节点
cleanup_on_exit() {
    if ! $SCRIPT_COMPLETED; then
        # 兼容旧测试资源(nginx-test)与新探测资源(np-probe-*),按label批量清理
        if kubectl get deployment -n "$NAMESPACE" -l app=nginx-test 2>/dev/null | grep -q . ||
            kubectl get deployment -n "$NAMESPACE" -l app="${PROBE_PREFIX}" 2>/dev/null | grep -q .; then
            log_warning "检测到脚本异常退出，清理残留测试资源(nginx-test/${PROBE_PREFIX}-*)，避免弹性池遗留计费节点..."
            kubectl delete deployment -n "$NAMESPACE" -l app=nginx-test --force --grace-period=0 &>/dev/null
            kubectl delete deployment -n "$NAMESPACE" -l app="${PROBE_PREFIX}" --force --grace-period=0 &>/dev/null
            kubectl delete pods -n "$NAMESPACE" -l app=nginx-test --force --grace-period=0 &>/dev/null
            kubectl delete pods -n "$NAMESPACE" -l app="${PROBE_PREFIX}" --force --grace-period=0 &>/dev/null
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
