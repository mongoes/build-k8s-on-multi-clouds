#!/bin/bash
# 适用于 AWS EKS 环境创建或补充 Karpenter NodePool。
# 本脚本只负责目标身份确认、资源创建和 NodePool/EC2NodeClass Ready 回读；
# 调度、网络、节点契约与存储等完整可用性检查统一由 k8sAvailCheck.sh 执行。

# ========== 基础环境参数配置部分 ==========
# 定义临时目录，用于存放节点组测试日志以及配置文件
OUTPUT_DIR="nodepool_configs"
mkdir -p "$OUTPUT_DIR"
#日志文件
LOG_FILE="${OUTPUT_DIR}/aws_eks_nodepool_build.log"
# Karpenter只在多个NodePool都兼容同一Pending Pod时比较weight；Spot优先，
# 不可用或达到限制时允许回退到较低权重的On-Demand池。
ON_DEMAND_NODEPOOL_WEIGHT=10
SPOT_NODEPOOL_WEIGHT=100
# 供父级就绪性检查脚本区分“管理员主动取消”和“执行失败”。该退出码只表示
# 未执行任何节点组创建，不能被转换为成功。
NODEPOOL_CANCELLED_RC=10

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ========== 日志函数 ==========
#颜色打印及日志记录
log_info() {
  echo -e "$1"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1" >>"$LOG_FILE"
}

log_success() {
  echo -e "\e[32m\e[1m$1 \e[0m"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] $1" >>"$LOG_FILE"
}

log_error() {
  echo -e "\e[31m\e[1m$1 \e[0m"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" >>"$LOG_FILE"
}

log_step() {
  echo -e "\n${BOLD}========== $1 ==========${NC}"
}

log_message() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >>"$LOG_FILE"
}

title2_message() {
  echo -e "******** $1 ********"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >>"$LOG_FILE"

}

#执行用户检查
SYS_USER=root
CURRENT_USER=$(whoami)
checkUser() {
  if [ "${CURRENT_USER}" != "$SYS_USER" ]; then
    echo "请使用${SYS_USER}用户执行脚本，当前执行用户为${CURRENT_USER}"
    exit
  fi
}

# 选择本轮唯一kubeconfig：有效显式路径优先，否则只回退Kubernetes默认路径。
select_target_kubeconfig() {
  local explicit_config="${KUBECONFIG:-}"
  local default_config="${KUBECONFIG_DEFAULT_PATH:-${HOME}/.kube/config}"

  if [[ -n "$explicit_config" && -f "$explicit_config" ]]; then
    TARGET_KUBECONFIG="$explicit_config"
  elif [[ -f "$default_config" ]]; then
    if [[ -n "$explicit_config" ]]; then
      echo "[WARN] 环境变量KUBECONFIG指向的文件不存在: ${explicit_config}"
    fi
    TARGET_KUBECONFIG="$default_config"
    echo "[INFO] 已回退使用Kubernetes默认配置: ${TARGET_KUBECONFIG}"
  else
    log_error "未找到可用Kubeconfig：KUBECONFIG=${explicit_config:-未设置}，默认路径=${default_config}。"
    return 1
  fi
  KUBECONFIG="$TARGET_KUBECONFIG"
  export KUBECONFIG
}

# 只从当前kubeconfig context关联的标准EKS ARN解析目标身份，绝不从AWS集群列表猜测。
resolve_target_eks_environment() {
  local config_json cluster_ref arn_source
  TARGET_CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null) || {
    log_error "无法读取Kubeconfig current-context，拒绝继续。"
    return 1
  }
  [[ -n "$TARGET_CURRENT_CONTEXT" ]] || {
    log_error "Kubeconfig current-context为空，拒绝继续。"
    return 1
  }
  config_json=$(kubectl config view --raw -o json 2>/dev/null) || {
    log_error "无法读取Kubeconfig结构，拒绝继续。"
    return 1
  }
  cluster_ref=$(printf '%s' "$config_json" | jq -er --arg context "$TARGET_CURRENT_CONTEXT" '.contexts[] | select(.name == $context) | .context.cluster' 2>/dev/null) || {
    log_error "current-context未关联唯一Cluster配置，拒绝继续。"
    return 1
  }
  TARGET_API_SERVER=$(printf '%s' "$config_json" | jq -er --arg cluster "$cluster_ref" '.clusters[] | select(.name == $cluster) | .cluster.server | select(type == "string" and length > 0)' 2>/dev/null) || {
    log_error "无法解析当前Cluster的API Server，拒绝继续。"
    return 1
  }

  arn_source="$cluster_ref"
  [[ "$arn_source" == arn:*:eks:*:*:cluster/* ]] || arn_source="$TARGET_CURRENT_CONTEXT"
  if [[ "$arn_source" =~ ^arn:(aws|aws-cn|aws-us-gov):eks:([^:]+):([0-9]{12}):cluster/(.+)$ ]]; then
    TARGET_AWS_REGION="${BASH_REMATCH[2]}"
    TARGET_AWS_ACCOUNT_ID="${BASH_REMATCH[3]}"
    TARGET_CLUSTER_NAME="${BASH_REMATCH[4]}"
  else
    log_error "当前context无法证明为标准AWS EKS ARN，拒绝猜测集群名或Region: ${TARGET_CURRENT_CONTEXT}"
    return 1
  fi
  [[ -n "$TARGET_CLUSTER_NAME" && -n "$TARGET_AWS_REGION" ]] || {
    log_error "EKS集群名或Region解析为空，拒绝继续。"
    return 1
  }
  AWS_DEFAULT_REGION="$TARGET_AWS_REGION"
  export AWS_DEFAULT_REGION
}

confirm_target_eks_environment() {
  local confirmation=""
  echo ""
  echo "========== 当前目标EKS环境确认 =========="
  printf '%-18s %s\n' "Kubeconfig:" "$TARGET_KUBECONFIG"
  printf '%-18s %s\n' "Current Context:" "$TARGET_CURRENT_CONTEXT"
  printf '%-18s %s\n' "AWS Account:" "$TARGET_AWS_ACCOUNT_ID"
  printf '%-18s %s\n' "AWS Region:" "$TARGET_AWS_REGION"
  printf '%-18s %s\n' "EKS Cluster:" "$TARGET_CLUSTER_NAME"
  printf '%-18s %s\n' "API Server:" "$TARGET_API_SERVER"
  echo "========================================="
  while true; do
    if ! read_tty_input confirmation "请确认以上EKS是本次要操作的目标集群，是否继续 <y/n>: "; then
      return 1
    fi
    case "$confirmation" in
    y | Y) return 0 ;;
    n | N)
      echo "已取消，未执行节点组创建。"
      return 2
      ;;
    *) log_error "输入无效，只允许输入 y 或 n，请重新确认目标环境。" ;;
    esac
  done
}

#K8S集群链接检查
test_k8s_connection() {
  log_step "测试K8S集群连接"
  select_target_kubeconfig || exit 1

  if ! kubectl cluster-info &>/dev/null; then
    log_error "无法连接到Kubernetes集群，请检查配置"
    exit 1
  fi
  log_success "K8S集群连接正常"
}

# 获取 EKS 集群名；只接受当前 kubeconfig context 中可证明的集群名，绝不猜测账户中的第一个集群。
get_cluster_name() {
  local cluster_name=""

  if [[ -n "${TARGET_CLUSTER_NAME:-}" ]]; then
    echo "$TARGET_CLUSTER_NAME"
    return 0
  fi

  # 只从 KUBECONFIG 的 current-context 解析。无法证明目标集群时由调用方失败退出。
  if [ -n "${KUBECONFIG}" ] && [ -f "${KUBECONFIG}" ]; then
    cluster_name=$(awk '/current-context:/ {split($2, a, "/"); print a[2]}' "${KUBECONFIG}" 2>/dev/null)
  fi
  echo "${cluster_name}"
}

#获取可用区的方法
get_zone() {
  local zone_massage=""
  # 1. 优先尝试从默认的URL中解析可用区信息
  zone_massage=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .availabilityZone 2>/dev/null)
  if [ -z "${zone_massage}" ]; then
    #2. 如果默认URL获取不到，可能是因为当前ec2启用了IMDSv2，请求元数据需要token认证
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 30" 2>/dev/null)
    zone_massage=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .availabilityZone 2>/dev/null)
  fi
  echo ${zone_massage}
}

#获取并校验容器实例可用的操作系统(AMI)版本
#仅在创建节点组时需要;放在节点组创建流程内,避免"仅可用性检查"场景因缺少ssm/ec2权限被阻塞
get_os_alias_version() {
  #获取K8S版本，特殊场景可手动指定比如K8S_VERSION="1.34"
  K8S_VERSION="$(kubectl version -o json | jq -r '.serverVersion.gitVersion | capture("v(?<major>[0-9]+)\\.(?<minor>[0-9]+)") | "\(.major).\(.minor)"')"
  if [ -z "$K8S_VERSION" ]; then
    read -p "未能通过kubectl version获取到EKS版本信息，请确认ESK就绪并手动输入版本信息(如1.34/1.35)！ " K8S_VERSION_INPUT
    K8S_VERSION=$K8S_VERSION_INPUT
    log_message "INFO: 用户输入EKS版本信息为${K8S_VERSION}"
  fi

  #获取容器实例可用的操作系统版本
  ALIAS_VERSION="$(aws ssm get-parameter --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id" --query Parameter.Value | xargs aws ec2 describe-images --query 'Images[0].Name' --image-ids | sed -r 's/^.*(v[[:digit:]]+).*$/\1/')"
  if [ -z "$ALIAS_VERSION" ]; then
    log_error "当前环境ec2:DescribeImages权限不足，未能自动获取可用操作系统信息，请管理员分配权限后重试！"
    exit 1
  fi
}

# 从控制终端读取输入；历史配置复用和同名重输绝不接受管道/CI 输入。
read_tty_input() {
  local variable_name=$1 prompt=$2 value=""
  if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    log_error "需要在交互式终端确认，非交互环境不创建节点组。"
    return 1
  fi
  printf '%s' "$prompt" >/dev/tty
  if ! IFS= read -r -t 300 value </dev/tty; then
    log_error "等待输入超时或读取失败，未创建节点组。"
    return 1
  fi
  printf -v "$variable_name" '%s' "$value"
}

# NodePool 读取的唯一边界：只有合法 JSON 中的空 items 数组才表示“零 NodePool”。
load_nodepools_json() {
  local nodepools_json
  nodepools_json=$(kubectl get nodepool -o json 2>/dev/null) || {
    log_error "读取 NodePool 列表失败，无法判断集群现状，未创建节点组。"
    return 1
  }
  printf '%s' "$nodepools_json" | jq -ce 'if (.items | type) == "array" then {items: .items} else error("NodePool JSON missing items array") end' 2>/dev/null || {
    log_error "NodePool 列表返回格式无效，未创建节点组。"
    return 1
  }
}

# 读取并比较完整 NodePool/EC2NodeClass 网络配置：完全合规时自动采用当前规范，
# 只有发现差异时才由操作者选择复用历史配置或采用当前规范。
select_existing_nodepool_config() {
  local nodepools_json nodepool_name nodepool_json nodeclass_json zone_json subnet_json security_group_json
  local expected_zone_json expected_subnet_json expected_security_group_json expected_key key
  local selection reuse_answer selected_key candidate_count=0 candidate_index existing_index
  local duplicate existing_key difference
  local -a candidate_keys=() candidate_sources=()

  expected_zone_json=$(jq -nc --arg zone "$AvailabilityZone" '[ $zone ]')
  expected_subnet_json=$(jq -nc --arg key "$subnetSelectorKey" --arg value "$subnetSelectorValue" '[{tags:{($key):$value}}] | sort_by(tojson)')
  expected_security_group_json=$(jq -nc --arg key "$securityGroupSelectorKey" --arg value "$securityGroupSelectorValue" '[{tags:{($key):$value}}] | sort_by(tojson)')
  expected_key="${expected_zone_json}|${expected_subnet_json}|${expected_security_group_json}"
  HISTORICAL_CONFIG_SELECTED=false

  nodepools_json=$(load_nodepools_json) || return 1
  while IFS= read -r nodepool_name; do
    [[ -n "$nodepool_name" ]] || continue
    nodepool_json=$(kubectl get nodepool "$nodepool_name" -o json 2>/dev/null) || {
      log_error "读取 NodePool ${nodepool_name} JSON 失败，未创建节点组。"
      return 1
    }
    nodeclass_json=$(kubectl get ec2nodeclass "$nodepool_name" -o json 2>/dev/null) || {
      log_error "NodePool ${nodepool_name} 缺少同名 EC2NodeClass，未创建节点组。"
      return 1
    }
    zone_json=$(printf '%s' "$nodepool_json" | jq -ce '[.spec.template.spec.requirements[]? | select(.key == "topology.kubernetes.io/zone") | .values[]] | unique | sort | select(length > 0)') || {
      log_error "NodePool ${nodepool_name} 缺少可用区 requirement，未创建节点组。"
      return 1
    }
    subnet_json=$(printf '%s' "$nodeclass_json" | jq -ce '.spec.subnetSelectorTerms | select(type == "array" and length > 0) | sort_by(tojson)') || {
      log_error "EC2NodeClass ${nodepool_name} 缺少 subnetSelectorTerms，未创建节点组。"
      return 1
    }
    security_group_json=$(printf '%s' "$nodeclass_json" | jq -ce '.spec.securityGroupSelectorTerms | select(type == "array" and length > 0) | sort_by(tojson)') || {
      log_error "EC2NodeClass ${nodepool_name} 缺少 securityGroupSelectorTerms，未创建节点组。"
      return 1
    }
    key="${zone_json}|${subnet_json}|${security_group_json}"
    duplicate=false
    if [[ $candidate_count -gt 0 ]]; then
      for existing_index in "${!candidate_keys[@]}"; do
        existing_key=${candidate_keys[$existing_index]}
        if [[ "$existing_key" == "$key" ]]; then
          candidate_sources[$existing_index]="${candidate_sources[$existing_index]}, ${nodepool_name}"
          duplicate=true
          break
        fi
      done
    fi
    if ! $duplicate; then
      candidate_keys[$candidate_count]="$key"
      candidate_sources[$candidate_count]="$nodepool_name"
      candidate_count=$((candidate_count + 1))
    fi
  done < <(printf '%s' "$nodepools_json" | jq -er '.items[]?.metadata.name')

  if [[ $candidate_count -eq 0 ]]; then
    log_error "未发现可复用的历史 NodePool 网络配置，未创建节点组。"
    return 1
  fi
  if [[ $candidate_count -eq 1 && "${candidate_keys[0]}" == "$expected_key" ]]; then
    echo "检测到存量节点池且确认其关键配置符合最佳规范！"
    return 0
  fi

  echo "检测到存量节点池的关键配置与当前最佳规范存在差异："
  for ((candidate_index = 0; candidate_index < candidate_count; candidate_index++)); do
    selected_key="${candidate_keys[$candidate_index]}"
    IFS='|' read -r zone_json subnet_json security_group_json <<<"$selected_key"
    echo "历史配置 [$((candidate_index + 1))]（来源 NodePool: ${candidate_sources[$candidate_index]}）"
    echo "  Zone: ${zone_json}"
    echo "  Subnet selector: ${subnet_json}"
    echo "  SecurityGroup selector: ${security_group_json}"
    difference=""
    [[ "$zone_json" == "$expected_zone_json" ]] || difference="${difference} Zone"
    [[ "$subnet_json" == "$expected_subnet_json" ]] || difference="${difference} Subnet-selector"
    [[ "$security_group_json" == "$expected_security_group_json" ]] || difference="${difference} SecurityGroup-selector"
    if [[ -n "$difference" ]]; then
      echo "  差异项:${difference}"
    else
      echo "  差异项: 无（该候选符合当前最佳规范）"
    fi
  done
  echo "当前最佳规范："
  echo "  Zone: ${expected_zone_json}"
  echo "  Subnet selector: ${expected_subnet_json}"
  echo "  SecurityGroup selector: ${expected_security_group_json}"

  while true; do
    if ! read_tty_input reuse_answer "是否复用历史配置？输入 y 复用历史配置，输入 n 采用当前最佳规范 <y/n>: "; then return 1; fi
    case "$reuse_answer" in
    y | Y) break ;;
    n | N)
      echo "已选择当前最佳规范，将继续创建新的业务节点组。"
      HISTORICAL_CONFIG_SELECTED=false
      return 0
      ;;
    *) log_error "输入无效，只允许输入 y 或 n，请重新选择。" ;;
    esac
  done

  if [[ $candidate_count -gt 1 ]]; then
    while true; do
      if ! read_tty_input selection "请输入要复用的历史配置序号 [1-${candidate_count}]: "; then return 1; fi
      if [[ "$selection" =~ ^[0-9]+$ && "$selection" -ge 1 && "$selection" -le $candidate_count ]]; then
        break
      fi
      log_error "配置序号无效，只允许输入 1-${candidate_count}，请重新选择。"
    done
  else
    selection=1
  fi
  selected_key=${candidate_keys[$((selection - 1))]}
  IFS='|' read -r HISTORICAL_ZONE_VALUES HISTORICAL_SUBNET_SELECTOR_TERMS HISTORICAL_SECURITY_GROUP_SELECTOR_TERMS <<<"$selected_key"
  HISTORICAL_CONFIG_SELECTED=true
  echo "已选择复用历史配置 [${selection}]（来源 NodePool: ${candidate_sources[$((selection - 1))]}）。"
}

#创建业务节点组
build_nodepool_for_business() {
  #创建节点组需要操作系统(AMI)版本信息,此处获取并校验ssm/ec2相关权限
  get_os_alias_version

  #EKS集群名获取， 必要信息！！！需做不为空判断!!!
  CLUSTER_NAME=$(get_cluster_name)

  if [ -n "${CLUSTER_NAME}" ]; then
    echo "检测到当前终端加载到的EKS集群名为: ${CLUSTER_NAME}"
  else
    log_error "无法从当前 KUBECONFIG 的 current-context 解析 EKS 集群名；为避免误操作其他集群，本次不创建节点组！"
    exit 1
  fi
  #TE集群可用区信息， 必要信息！！！需做不为空判断!!!
  #脚本会尝试自动获取当前节点的可用区（默认在TA集群内节点上执行该脚本），如获取不到则要求用户手动输入
  AvailabilityZone=$(get_zone)

  if [ -z "${AvailabilityZone}" ]; then
    DEFAULT_AvailabilityZone="us-east-1a"
    read -p "未能自动获取到当前服务器可用区信息，请手动输入服务器所在可用区（格式：$DEFAULT_AvailabilityZone）: " ZONE_INPUT
    if [ -z "$ZONE_INPUT" ]; then
      log_error "可用区信息是创建节点组的必要条件，不得为空，请在AWS控制台确认可用区信息后重试本脚本"
      exit 1
    else
      AvailabilityZone=$ZONE_INPUT
      log_message "INFO: 用户输入可以区信息为${AvailabilityZone}"
    fi
  else
    echo "检测到当前执行环境所在可用区为: ${AvailabilityZone}"
  fi

  ######EKS是否已有节点组检查 START######
  #如有老节点组则先备份已有节点组的yaml配置,并检查已有节点组的名称、机型、子网标签key/value、安全组标签key/value，与数数规范对比；当不一致时询问用户是否需要复用老节点组配置
  #预置变量:安全组标签key，默认不需要手动修改,除非当前你处于EKS版本升级场景时需要将安全组key修改为你新定义的值
  securityGroupSelectorKey="karpenter.sh/discovery-sg"

  #预置变量:安全组标签value，取EKS集群名，默认不需要手动修改,除非当前你处于EKS版本升级场景时需要将安全组value修改为你新定义的值
  securityGroupSelectorValue=${CLUSTER_NAME}

  #预置变量子网标签key，默认不需要手动修改，除非当前你处于EKS版本升级场景时需要将子网key修改为你新定义的值
  subnetSelectorKey="karpenter.sh/discovery-subnet"

  #预置变量子网标签value：固定为通配符 "*",表示节点组【只按子网标签key匹配、不校验value】。
  #原因:多个EKS集群常共用同一批ta主机子网(节点需与ta主机同可用区),若value取集群名则多集群间必然冲突;
  #改为只认key后,各集群子网只要带 karpenter.sh/discovery-subnet 这个key即被发现,value是什么都不影响,从根本上消除冲突。
  subnetSelectorValue="*"

  #如有先备份已有节点组的yaml配置,并检查已有节点组的名称、机型、子网标签key/value、安全组标签key/value，与数数规范对比；当不一致时询问用户是否需要复用老节点组配置
  #注意:无节点组时 kubectl get nodepool 会向stderr输出"No resources found",故用 2>/dev/null 抑制在kubectl处,避免裸露信息干扰用户
  echo "正在检测当前EKS环境是否已存在节点组......"
  nodepools_json=$(load_nodepools_json) || exit 1
  nodepool_records=$(printf '%s' "$nodepools_json" | jq '.items | length')
  if [ ${nodepool_records} -gt 0 ]; then
    echo "检测完成:检测到当前EKS环境中存在 ${nodepool_records} 个节点组，正在审查其历史网络配置。"
    kubectl get nodepool
    kubectl get karpenter -oyaml >${OUTPUT_DIR}/karpenter_backup.yaml
    select_existing_nodepool_config || exit 1
  else
    echo "检测完成:当前EKS环境暂无Karpenter NodePool，将仅按后续输入创建业务节点组"
  fi
  ####EKS是否已有节点组检查 END####

  # 为业务节点组建立各规格到aws实例类型的映射
  #2c4g规格为测试用例，默认不对用户暴露
  declare -A INSTANCE_TYPE_MAP=(
    ["2c4g"]="c5.large c5a.large"
    ["4c32g"]="r8a.xlarge r8i.xlarge r7i.xlarge r7a.xlarge r6i.xlarge r6a.xlarge"
    ["8c16g"]="c6a.2xlarge c7a.2xlarge c7i.2xlarge c8a.2xlarge c8i.2xlarge"
    ["8c32g"]="m8g.2xlarge m7i.2xlarge m7a.2xlarge m6i.2xlarge m6a.2xlarge"
    ["8c64g"]="r7i.2xlarge r6a.2xlarge r6i.2xlarge r7a.2xlarge"
    ["16c64g"]="m6a.4xlarge m6i.4xlarge m6in.4xlarge m7a.4xlarge m8g.4xlarge"
    ["32c128g"]="m6a.8xlarge m6i.8xlarge m6in.8xlarge m7a.8xlarge m8g.8xlarge m9g.8xlarge"
    ["64c256g"]="m6a.16xlarge m6i.16xlarge m6in.16xlarge m7a.16xlarge m8g.16xlarge m9g.16xlarge"
  )

  # 获取用户输入的节点组信息，可能需要多个节点组，且组内节点规格配置差异
  read -p "请输入需要创建的节点组名称（例如:od-4c32g od-32c128g spot-32c128g多组之间空格分隔）: " input_nodepool_names
  read -p "请为每个节点组选择规格（例如:4c32g 16c64g 32c128g 64c256g,顺序需与节点组名称对应,多规格之间空格分隔）: " input_nodepool_sizes
  read -p "请为每个节点组指定付费类型（支持od spot,顺序需与节点组名称一一对应,多付费类型之间空格分隔）: " input_nodepool_billing_mode
  echo ""
  if [[ -z "${input_nodepool_names//[[:space:]]/}" || -z "${input_nodepool_sizes//[[:space:]]/}" || -z "${input_nodepool_billing_mode//[[:space:]]/}" ]]; then
    log_error "错误：节点组名称、规格和付费类型均为必填项；未声明业务节点组，不会创建任何资源！"
    exit 1
  fi
  # 转换为数组
  IFS=' ' read -ra NODEPOOL_NAMES <<<"$input_nodepool_names"
  IFS=' ' read -ra NODEPOOL_SIZES <<<"$input_nodepool_sizes"
  IFS=' ' read -ra NODEPOOL_BILLING_MODE <<<"$input_nodepool_billing_mode"

  # 验证输入的三者关系一一对应
  if [[ ${#NODEPOOL_NAMES[@]} -ne ${#NODEPOOL_SIZES[@]} || ${#NODEPOOL_NAMES[@]} -ne ${#NODEPOOL_BILLING_MODE[@]} ]]; then
    log_error "错误：节点组名称、规格、付费类型映射错误,请重新输入并确认三者信息一一对应！"
    exit 1
  fi
  #验证输入的节点组规格是否在支持范围内
  for size in "${NODEPOOL_SIZES[@]}"; do
    if [[ -z "${INSTANCE_TYPE_MAP[$size]+x}" ]]; then
      log_error "错误：无效规格 '$size'，有效选项: 4c32g 8c16g 8c32g 8c64g 16c64g 32c128g 64c256g，请重新输入！"
      exit 1
    fi
  done
  #验证并归一化输入的付费类型
  #口径统一:数数域(节点组名前缀、node.k8s.te/billing-mode标签、spot污点值)统一用简写 od/spot;
  #兼容老习惯:输入 on-demand 自动归一化为 od(AWS EKS付费类型实际只有on-demand/spot两类,无reserved)
  for idx in "${!NODEPOOL_BILLING_MODE[@]}"; do
    bm="${NODEPOOL_BILLING_MODE[$idx]}"
    #归一化:on-demand -> od
    if [[ "$bm" == "on-demand" ]]; then
      bm="od"
      NODEPOOL_BILLING_MODE[$idx]="od"
    fi
    if [[ "$bm" != "od" && "$bm" != "spot" ]]; then
      log_error "错误：无效付费类型 '${NODEPOOL_BILLING_MODE[$idx]}'，支持 od(on-demand) spot，请重新输入！"
      exit 1
    fi
  done
  if [[ "${HISTORICAL_CONFIG_SELECTED:-false}" == "true" ]]; then
    NODEPOOL_ZONE_VALUES="$HISTORICAL_ZONE_VALUES"
    NODEPOOL_SUBNET_SELECTOR_TERMS="$HISTORICAL_SUBNET_SELECTOR_TERMS"
    NODEPOOL_SECURITY_GROUP_SELECTOR_TERMS="$HISTORICAL_SECURITY_GROUP_SELECTOR_TERMS"
  else
    NODEPOOL_ZONE_VALUES=$(jq -nc --arg zone "$AvailabilityZone" '[ $zone ]')
    NODEPOOL_SUBNET_SELECTOR_TERMS=$(jq -nc --arg key "$subnetSelectorKey" --arg value "$subnetSelectorValue" '[{tags:{($key):$value}}]')
    NODEPOOL_SECURITY_GROUP_SELECTOR_TERMS=$(jq -nc --arg key "$securityGroupSelectorKey" --arg value "$securityGroupSelectorValue" '[{tags:{($key):$value}}]')
  fi
  echo -e "==========  开始创建指定的${#NODEPOOL_NAMES[@]}个业务节点组 "${NODEPOOL_NAMES[@]}" =========="
  # 创建每个节点组,建立节点组名、规格、付费类型映射
  for i in "${!NODEPOOL_NAMES[@]}"; do
    NODEPOOL_NAME="${NODEPOOL_NAMES[$i]}"
    # 同名对象不接管、不覆盖；仅重新输入当前这一项名称，保留其规格和计费类型。
    while true; do
      name_conflict=false
      if kubectl get nodepool "$NODEPOOL_NAME" >/dev/null 2>&1; then
        name_conflict=true
      fi
      for previous_index in "${!NODEPOOL_NAMES[@]}"; do
        [[ "$previous_index" -lt "$i" && "${NODEPOOL_NAMES[$previous_index]}" == "$NODEPOOL_NAME" ]] && name_conflict=true
      done
      $name_conflict || break
      log_error "NodePool 名称 ${NODEPOOL_NAME} 已存在或在本轮输入中重复；不会 apply，请重新输入该节点组名称。"
      if ! read_tty_input NODEPOOL_NAME "新的 NodePool 名称: "; then exit 1; fi
      [[ -n "$NODEPOOL_NAME" ]] || {
        log_error "NodePool 名称不得为空。"
        exit 1
      }
    done
    NODEPOOL_NAMES[$i]="$NODEPOOL_NAME"
    SIZE="${NODEPOOL_SIZES[$i]}"
    # 获取实例类型列表
    INSTANCE_TYPES="${INSTANCE_TYPE_MAP[$SIZE]}"
    #获取用户输入的付费类型(数数域简写: od/spot)
    BILLING_MODE="${NODEPOOL_BILLING_MODE[$i]}"
    #映射到Karpenter官方well-known label口径:karpenter.sh/capacity-type 仅接受 on-demand/spot(不认od简写)
    #数数域(节点组名前缀/node.k8s.te/billing-mode标签/spot污点值)用 od,Karpenter域用 on-demand,两者通过此处映射打通
    if [[ "$BILLING_MODE" == "od" ]]; then
      CAPACITY_TYPE="on-demand"
      NODEPOOL_WEIGHT="$ON_DEMAND_NODEPOOL_WEIGHT"
    else
      CAPACITY_TYPE="spot"
      NODEPOOL_WEIGHT="$SPOT_NODEPOOL_WEIGHT"
    fi

    # 根据付费类型决定是否添加污点
    if [[ "$BILLING_MODE" == "spot" ]]; then
      echo "检测到 spot 类型节点组，将在配置中添加 NoSchedule 污点..."
      TAINT_SECTION="      taints:
        - key: node.k8s.te/billing-mode
          value: \"spot\"
          effect: NoSchedule"
    else
      TAINT_SECTION=""
    fi

    echo "正在生成节点组配置文件: $NODEPOOL_NAME | 规格: $SIZE | 付费类型：$BILLING_MODE | 机型: $INSTANCE_TYPES"
    # 生成文件名
    CONFIG_FILE="${OUTPUT_DIR}/nodepool-${NODEPOOL_NAME}.yaml"

    # 生成节点组配置到文件
    cat <<EOF >"$CONFIG_FILE"
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: ${NODEPOOL_NAME}
spec:
  weight: ${NODEPOOL_WEIGHT}
  template:
    metadata:
      labels:
        node.kubernetes.type: ${NODEPOOL_NAME}
        node.k8s.te/nodepool-name: ${NODEPOOL_NAME}
        node.k8s.te/nodepool-instancespec: ${SIZE}
        node.k8s.te/billing-mode: ${BILLING_MODE}
    spec:
      requirements:
        - key: topology.kubernetes.io/zone
          operator: In
          values: ${NODEPOOL_ZONE_VALUES}
        - key: node.kubernetes.io/instance-type
          operator: In
          values: 
$(for type in $INSTANCE_TYPES; do echo "            - $type"; done)
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64","arm64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["${CAPACITY_TYPE}"]
      nodeClassRef:
        name: ${NODEPOOL_NAME}
        group: karpenter.k8s.aws
        kind: EC2NodeClass
      # expireAfter: Never 表示节点永不主动过期轮换,稳定优先(官方step12默认720h/30天轮换以降低长运行节点安全风险,此处数数线上刻意选择Never)
      expireAfter: Never
$([[ -n "$TAINT_SECTION" ]] && echo "$TAINT_SECTION")
  limits:
    cpu: 3200
  disruption:
    # consolidationPolicy: WhenEmpty 仅当节点为空(无非DaemonSet业务Pod)时才回收,不做低利用率合并,是数数线上沉淀的保守回收策略(官方默认WhenEmptyOrUnderutilized更激进)
    # consolidateAfter: 10m 节点变空后等待10分钟再回收,给短时Pod腾挪留缓冲,避免节点频繁抖动创建/销毁
    consolidationPolicy: WhenEmpty
    consolidateAfter: 10m
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: ${NODEPOOL_NAME}
spec:
  amiFamily: AL2023
  amiSelectorTerms:
    - alias: "al2023@${ALIAS_VERSION}"
  role: "KarpenterNodeRole-${CLUSTER_NAME}"
  blockDeviceMappings:
  - deviceName: /dev/xvda
    ebs:
      volumeSize: 150Gi
      volumeType: gp3
  subnetSelectorTerms: ${NODEPOOL_SUBNET_SELECTOR_TERMS}
  securityGroupSelectorTerms: ${NODEPOOL_SECURITY_GROUP_SELECTOR_TERMS}
  tags:
    name: eks-thinkingai
    owner: shushu
EOF

    echo "节点组配置文件 [$CONFIG_FILE] 生成成功!"

    # 应用配置文件
    echo "正在应用节点组配置......"
    kubectl apply -f "$CONFIG_FILE"

    # 检查应用结果
    if [ $? -eq 0 ]; then
      title2_message "节点组 [$NODEPOOL_NAME] 创建成功"
    else
      log_error "警告：节点组 [$NODEPOOL_NAME] 创建失败，请检查配置文件"
      exit 1
    fi

  done

  log_success "********  所有业务节点组都已创建完成！nodepool配置文件保存在 $OUTPUT_DIR 目录 ********"
  echo ""
}


# 只校验本轮创建的 NodePool 及其实际引用的 EC2NodeClass。
# 不接管存量池，不创建测试Pod；完整业务可用性由父级 k8sAvailCheck.sh 验收。
wait_nodepools_ready() {
  log_step "校验本轮创建的NodePool及其关联EC2NodeClass是否就绪"
  local timeout="${NODEPOOL_READY_TIMEOUT:-60}"
  local elapsed=0
  local all_ready=false
  local not_ready=""
  local np np_ready nodeclass_name nodeclass_ready

  if [ "$#" -eq 0 ]; then
    log_error "未收到本轮创建的NodePool名称，拒绝使用存量NodePool代替本轮验收。"
    return 1
  fi

  echo "正在等待以下本轮NodePool资源就绪(最多${timeout}秒): $*"
  while [ "$elapsed" -lt "$timeout" ]; do
    not_ready=""
    for np in "$@"; do
      np_ready=$(kubectl get nodepool "$np" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
      nodeclass_name=$(kubectl get nodepool "$np" -o jsonpath='{.spec.template.spec.nodeClassRef.name}' 2>/dev/null || true)
      nodeclass_ready=""
      if [ -n "$nodeclass_name" ]; then
        nodeclass_ready=$(kubectl get ec2nodeclass "$nodeclass_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
      fi

      if [ "$np_ready" != "True" ] || [ -z "$nodeclass_name" ] || [ "$nodeclass_ready" != "True" ]; then
        not_ready="${not_ready} ${np}"
      fi
    done

    if [ -z "$not_ready" ]; then
      all_ready=true
      break
    fi
    echo "仍有本轮NodePool或EC2NodeClass未就绪，等待中......(已等待 ${elapsed}s)"
    sleep 5
    elapsed=$((elapsed + 5))
  done

  if $all_ready; then
    log_success "本轮创建的NodePool及其关联EC2NodeClass均已就绪(Ready=True)!"
    kubectl get karpenter || true
    return 0
  fi

  log_error "本轮NodePool资源在${timeout}秒内未全部就绪，本阶段未完成。未就绪NodePool:${not_ready}"
  echo -e "\e[31m\e[1m========== 本轮未就绪原因线索 =========\e[0m"
  for np in $not_ready; do
    local np_reason np_msg
    np_reason=$(kubectl get nodepool "$np" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)
    np_msg=$(kubectl get nodepool "$np" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true)
    nodeclass_name=$(kubectl get nodepool "$np" -o jsonpath='{.spec.template.spec.nodeClassRef.name}' 2>/dev/null || true)
    echo "  NodePool ${np}: reason=${np_reason:-未知} message=${np_msg:-无} nodeClassRef=${nodeclass_name:-缺失}"
    if [ -n "$nodeclass_name" ]; then
      kubectl get ec2nodeclass "$nodeclass_name" -o json 2>/dev/null | jq -r '
        .status.conditions[]? | select(.status != "True")
        | "    EC2NodeClass.\(.type): reason=\(.reason) message=\(.message // "无")"' 2>/dev/null || true
    fi
  done
  echo -e "\e[31m\e[1m常见根因: 子网或安全组发现标签未匹配、NodeClass配置错误或AWS权限不足。修复后可安全重试本脚本。\e[0m"
  return 1
}


###检测karpenter pod 运行是否正常,这是节点组创建的必要条件
check_eks_karpenter_status() {
  #检查karpenter状态，节点组创建及可用性依赖karpenter
  TIMEOUT=30
  ELAPSED=0
  KARPENTER_READY=false
  while [ $ELAPSED -lt $TIMEOUT ]; do
    KARPENTER_STATUS=$(kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    if [ "${KARPENTER_STATUS}" == "Running" ]; then
      KARPENTER_READY=true
      break
    fi
    sleep 5
    let ELAPSED+=5
  done

  if ! ${KARPENTER_READY}; then
    log_error "错误：Karpenter状态异常，退出节点组创建流程，请确认EKS和Karpenter等依赖服务状态健康后重试本脚本"
    return 1
  fi

  #检查eks/karpente版本，api-versions版本是否符合预期，老版本标准是karpenter.k8s.aws/v1、karpenter.sh/v1
  eks_api_versions_check=$(kubectl api-versions | grep -E '^karpenter.k8s.aws/v1$|^karpenter.sh/v1$' | wc -l)
  if [ ${eks_api_versions_check} -lt 2 ]; then
    log_error "当前EKS版本较低，不支持所需Api,无法自动创建节点组!"
    log_error "请参考https://thinkingdata.feishu.cn/wiki/RvGxwQnnSijuQbkKQQScX7MKntc手动创建所需节点组"
    log_error "或参考https://thinkingdata.feishu.cn/wiki/QUquwBMtPienoHknJk0cyLnOncb升级EKS版本后重试节点组创建"
    echo "当前EKS版本是:"
    kubectl version
    return 1
  fi
}

#主函数/脚本逻辑
main() {
  #执行用户检查
  checkUser

  #检查k8s是否可访问
  test_k8s_connection

  # 所有创建操作之前，先证明并由操作者确认唯一目标EKS环境。
  resolve_target_eks_environment || return 1
  if confirm_target_eks_environment; then
    :
  else
    confirmation_rc=$?
    [[ $confirmation_rc -eq 2 ]] && return "$NODEPOOL_CANCELLED_RC"
    return 1
  fi

  # 创建入口只承担创建前置校验、对象写入和最小资源回读；不再重复主脚本的
  # Pod调度、网络、节点契约及存储检查。
  check_eks_karpenter_status || return 1
  build_nodepool_for_business || return 1

  if [ ${#NODEPOOL_NAMES[@]} -eq 0 ]; then
    log_error "本轮未形成待验收的NodePool名称，拒绝将存量资源记为创建成功。"
    return 1
  fi
  wait_nodepools_ready "${NODEPOOL_NAMES[@]}" || return 1

  log_success "NodePool创建与资源对象Ready验收完成。"
  log_info "完整调度、网络、节点契约与存储检查由k8sAvailCheck.sh继续执行；独立运行本脚本时，请随后执行k8sAvailCheck.sh完成交付验收。"
  return 0
}

# 执行主函数
main "$@"
