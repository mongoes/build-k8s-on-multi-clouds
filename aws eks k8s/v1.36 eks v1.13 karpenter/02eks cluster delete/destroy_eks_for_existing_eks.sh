#!/bin/bash
# =============================================================================
# destroy_eks_for_existing_eks.sh
# 适用场景：确认要【回收/销毁】一套由 build_eks_v1.36.sh 建出的存量 AWS EKS
#           集群,按依赖顺序彻底释放硬件资源,不留孤儿(持续计费)资源。
#
# 为什么需要专门脚本(而非只 `eksctl delete cluster`):
#   1. Karpenter 调度出的节点不能在 EC2 控制台直接终止——只要 controller 与
#      NodePool 还在,终止一台立刻重建一台。必须让 Karpenter 自己回收(删
#      NodePool/NodeClaim),或先摘掉 controller。
#   2. EFS 独立于集群,`eksctl delete cluster` 完全不碰它,不手动删就是孤儿。
#   3. Karpenter 的 CloudFormation 栈(KarpenterNodeRole + instance profile +
#      SQS 中断队列 + IAM 策略)在节点未终止干净时删栈会失败,必须最后删。
#
# 设计原则(务必牢记):
#   - 先侦察、再确认、后执行:先枚举全部待清理目标并展示清单,交互式 Y/N 二次
#     确认(默认 No / 无 tty 一律 No),用户明确输入 Y 才动手。销毁不可逆。
#   - 按依赖顺序从内向外剥:应用/PVC → Karpenter 弹性层 → 存储(EFS) →
#     集群本体 → Karpenter CFN 栈 → 孤儿栈/日志。
#   - 精确匹配集群名,绝不误伤同 VPC 内其他集群的资源。
#
# ★★★ 安全边界声明:本脚本【绝不删除】以下【既有基础网络资源】★★★
#   - VPC、子网(subnet)、路由表、Internet/NAT 网关、弹性 IP、网络 ACL、
#     VPC 对等/中转网关、以及非本集群创建的安全组与网络接口(ENI)。
#   本脚本删除的对象仅限:①k8s 对象(负载/PVC/NodePool/EC2NodeClass);
#   ②本集群的 EFS 文件系统及其挂载目标(按 creation-token 精确定位);
#   ③本集群的 CloudFormation 栈(Karpenter-<集群名> 与 eksctl-<集群名>-addon-*
#     孤儿栈,均按集群名精确匹配);④本集群控制面日志组;⑤经 eksctl delete
#     cluster 删除的"集群本体 + 托管节点组 + eksctl 自己创建的资源"。
#   建集群时 VPC/子网采用"引用既有资源"模式(build 脚本 vpc.id/subnets.*.id
#   指向已存在的 VPC/子网),不在 eksctl 的 CloudFormation 栈管理范围内,故
#   eksctl delete cluster 只回滚它自建的资源,【不会触碰既有 VPC/子网】。
#   全脚本无 delete-vpc / delete-subnet / delete-security-group / delete-route /
#   delete-*-gateway / release-address / delete-network-interface / terminate-
#   instances 等命令(可 grep 自证)。EC2 实例由 Karpenter 删 NodePool 优雅回收
#   或随 eksctl delete cluster 处理,脚本不直接 terminate 实例。
#
# 注意事项：
#   1. 管理员需从 AWS 控制台确认并在下方配置区手填 3 项(region/VPC/集群名);
#   2. 如果存量EKS版本并非1.36,则需要手动修改脚本中 KUBECTL_VERSION 值为真实版本!
# 脚本计划：
#     阶段1 安装/更新依赖工具 + 调用者身份打印
#     阶段2 前置校验(账号一致 / 集群存在 / VPC 一致 / kubectl 可达)
#     阶段3 侦察:枚举全部待清理目标并展示清单 + 交互式 Y/N 二次确认(不通过则退出)
#     阶段4 按依赖顺序清理:采集EBS动态卷(不删PVC) → Karpenter 节点 → 卸 Karpenter →
#           EFS → eksctl delete cluster → Karpenter CFN 栈 → 孤儿栈/日志
#     阶段5 残留核对(打印仍存在的疑似残留,供人工兜底)
# 适用：x86_64 / aarch64；常见 Linux(Amazon Linux 2023 / Rocky9 / CentOS 等)。
# =============================================================================

# 确保以【非 POSIX 模式的 bash】运行,当用户以 `sh 脚本` 启动时,/bin/sh 即使链接到 bash,也会进入 POSIX 兼容模式。
if [ -z "${_DESTROY_EKS_REEXEC:-}" ]; then
  export _DESTROY_EKS_REEXEC=1
  exec bash "$0" "$@"
fi

set -euo pipefail

###############################################################################
# 用户配置区START（AWS管理员需收集如下3项信息，覆盖后执行脚本）
###############################################################################
#【必填】要销毁的 EKS 集群名
CLUSTER_NAME="${CLUSTER_NAME:-}"

#【必填】EKS 集群所在地域
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-}"

#【必填】EKS 集群所在 VPC 的 ID(脚本会校验与集群实际 VPC 一致,防止误销别的集群)
VPC_ID="${VPC_ID:-}"

###############################################################################
# 用户配置区END（必须AWS管理员收集如上3项准确信息并覆盖脚本）
###############################################################################

###############################################################################
# 默认参数区（该章节及以下内容一般不需要改动）
###############################################################################

#===== 其他官方参数 =====
# 中国区需改为 aws-cn 、 GovCloud 改为 aws-us-gov
AWS_PARTITION="${AWS_PARTITION:-aws}"

#===== 资源命名约定(与 build_eks_v1.36.sh 保持一致,用于精确定位本集群资源) =====
# Karpenter 基础环境 CloudFormation 栈名(build 脚本: Karpenter-${CLUSTER_NAME})
KARPENTER_CFN_STACK="${KARPENTER_CFN_STACK:-Karpenter-${CLUSTER_NAME}}"
# EFS 文件系统 creation-token(build 脚本: ${CLUSTER_NAME}-${EFS_NAME}),用于精确定位本集群的 EFS
EFS_NAME="${EFS_NAME:-te-nfs}"
EFS_CREATION_TOKEN="${EFS_CREATION_TOKEN:-${CLUSTER_NAME}-${EFS_NAME}}"
# 集群控制面 CloudWatch 日志组
CLUSTER_LOG_GROUP="${CLUSTER_LOG_GROUP:-/aws/eks/${CLUSTER_NAME}/cluster}"

#===== kubectl 下载地址(主备双源，均可覆盖) =====
# 架构目录直接用 ${TARGET_ARCH} 在此拼好完整 URL(规避 sh POSIX 与 GNU sed 的 {} 占位符替换坑)。
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.36.0}"
case "$(uname -m)" in
x86_64) TARGET_ARCH="amd64" ;;
aarch64) TARGET_ARCH="arm64" ;;
*)
  echo "不支持的架构: $(uname -m)" >&2
  exit 1
  ;;
esac
KUBECTL_URL_PRIMARY="${KUBECTL_URL_PRIMARY:-https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGET_ARCH}/kubectl}"
KUBECTL_URL_BACKUP="${KUBECTL_URL_BACKUP:-https://download-thinkingdata.oss-cn-shanghai.aliyuncs.com/ta/tools/${TARGET_ARCH}/kubectl}"

#===== 清理行为开关 =====
# 是否删除 EFS 文件系统(默认 true)。EFS 独立于集群,不删即孤儿计费。
DELETE_EFS="${DELETE_EFS:-true}"
# 是否删除控制面 CloudWatch 日志组(默认 true)。
DELETE_LOG_GROUP="${DELETE_LOG_GROUP:-true}"
# 各类等待超时(秒)
NODE_DRAIN_TIMEOUT="${NODE_DRAIN_TIMEOUT:-600}"
EFS_WAIT_TIMEOUT="${EFS_WAIT_TIMEOUT:-300}"
CFN_WAIT_TIMEOUT="${CFN_WAIT_TIMEOUT:-1800}"

#############################################
###########  运行时变量与辅助函数  ###########
#############################################

# 系统架构(工具下载依赖)
ARCH="$(uname -m)"

# 临时目录(下载工具 + 收集关注项)
STATE_DIR="${STATE_DIR:-./.destroy_eks_state}"
mkdir -p "${STATE_DIR}"

# 结果/日志文件
RESULT_FILE="${STATE_DIR}/destroy_eks_result_$(date +'%Y-%m-%d-%H-%M-%S').log"
echo "destroy-eks start time：$(date +'%Y-%m-%d %H:%M:%S')" >>"${RESULT_FILE}"

# ===== 全量输出同步到日志文件(终端保留彩色,文件剥离 ANSI 色码) =====
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >>"${RESULT_FILE}")) 2>&1

# 颜色打印辅助(沿用历史脚本风格)
green() { echo -e "\e[32m\e[1m$1\e[0m"; }
red() { echo -e "\e[31m\e[1m$1\e[0m"; }
yellow() { echo -e "\e[33m\e[1m$1\e[0m"; }

# ==================== 横幅宽度工具(与既有脚本一致) ====================
BANNER_WIDTH="${BANNER_WIDTH:-100}"

_disp_width() {
  local s="$1" bytes cont
  bytes=$(printf '%s' "$s" | LC_ALL=C wc -c)
  cont=$(printf '%s' "$s" | LC_ALL=C tr -dc '\200-\277' | LC_ALL=C wc -c)
  echo $((bytes - cont / 2))
}

_banner_line() {
  local title="$1" prefix="=====" w right
  w=$(_disp_width "$title")
  right=$((BANNER_WIDTH - ${#prefix} - w))
  ((right < 3)) && right=3
  printf '%s%s%s' "$prefix" "$title" "$(printf '%*s' "$right" '' | tr ' ' '=')"
}

_banner_rule() { printf '%*s' "$BANNER_WIDTH" '' | tr ' ' '='; }

title() { echo -e "\n\e[1m$(_banner_line " $1 ")\e[0m"; }

record() { echo -e "$1" >>"${RESULT_FILE}"; }

# 收集"关注"项(非致命告警),收尾统一提示
ATTENTION_FILE="${STATE_DIR}/attention.$$"
: >"${ATTENTION_FILE}"
note_attention() {
  yellow "$1"
  echo "$1" >>"${ATTENTION_FILE}"
}

# 交互式 Y/N 询问。从 /dev/tty 读取,即使 stdin 被 heredoc/管道占用也能与执行者交互。
#   入参: 提示语。返回: 0=Yes / 1=No。
#   安全优先:直接回车视为 No;无终端可交互(CI/后台)也视为 No,绝不擅自做破坏性清理。
ask_yes_no() {
  local prompt="$1" ans
  # /dev/tty 可能【不存在】(纯后台)或【存在但不可读写】(如 pexpect/无控制终端的会话)。
  # 两种都视为"无法获得人工确认"→ 一律 No,绝不擅自做破坏性清理。
  # 用 printf 探测可写性(静默),不可写即判定非交互,避免后续 read 抛出原始 I/O error 污染输出。
  if [ ! -e /dev/tty ] || ! { printf '' >/dev/tty; } 2>/dev/null; then
    yellow "非交互环境(无可用 /dev/tty),默认选择 No(不清理)。如需真正执行清理,请在具备控制终端的会话中手动运行本脚本。"
    return 1
  fi
  while true; do
    printf "\e[33m%s [y/N]: \e[0m" "${prompt}" >/dev/tty 2>/dev/null
    # read 失败(tty 不可读,如 pexpect 会话)静默处理,明确当作 No。
    if ! read -r ans </dev/tty 2>/dev/null; then
      yellow "无法从 /dev/tty 读取输入(终端不可交互),默认选择 No(不清理)。"
      return 1
    fi
    case "${ans}" in
    y | Y | yes | YES) return 0 ;;
    n | N | no | NO | "") return 1 ;;
    *) echo "请输入 y 或 n。" >/dev/tty 2>/dev/null ;;
    esac
  done
}

# 校验必填配置项
check_required_conf() {
  local missing=""
  [ -z "${CLUSTER_NAME}" ] && missing="${missing} CLUSTER_NAME"
  [ -z "${AWS_DEFAULT_REGION}" ] && missing="${missing} AWS_DEFAULT_REGION"
  [ -z "${VPC_ID}" ] && missing="${missing} VPC_ID"
  if [ -n "${missing// /}" ]; then
    red "缺少必填配置项:${missing}。请在脚本【用户配置区】填写后重试。"
    exit 1
  fi
}

#############################################
##############  阶段1 装工具  ###############
#############################################

install_base_pkg() {
  echo "基础包检测 ******** curl / tar / gzip / jq ******** "
  local pkgs=""
  command -v curl >/dev/null 2>&1 || pkgs="${pkgs} curl"
  command -v tar >/dev/null 2>&1 || pkgs="${pkgs} tar"
  command -v gzip >/dev/null 2>&1 || pkgs="${pkgs} gzip"
  command -v jq >/dev/null 2>&1 || pkgs="${pkgs} jq"
  if [ -n "${pkgs// /}" ]; then
    echo "安装缺失基础包:${pkgs}"
    if command -v yum >/dev/null 2>&1; then
      sudo yum install -y ${pkgs} || note_attention "阶段1 基础包安装失败(${pkgs}),若后续命令报缺失请手动安装。"
    elif command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -y && sudo apt-get install -y ${pkgs} || note_attention "阶段1 基础包安装失败(${pkgs})。"
    else
      note_attention "阶段1 未识别包管理器,请手动确保已安装:${pkgs}。"
    fi
  fi
}

install_awscli() {
  if command -v aws >/dev/null 2>&1; then
    echo "awscli ******** 检测已部署，跳过 ******** ($(aws --version 2>&1 | head -1))"
    return
  fi
  echo "awscli ******** 未检测到，开始下载安装 ******** "
  local url
  case "${ARCH}" in
  x86_64) url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
  aarch64) url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
  esac
  if ! curl -fsSL "${url}" -o "awscliv2.zip"; then
    red "awscli 下载失败(${url})，请检查网络后重试。"
    exit 1
  fi
  if ! unzip -o awscliv2.zip >/dev/null 2>&1; then
    red "awscli 解压失败(可能下载到损坏文件/报错页)，请重试。"
    exit 1
  fi
  sudo ./aws/install --update
  green "awscli 安装完成：$(aws --version 2>&1 | head -1)"
}

install_eksctl() {
  if command -v eksctl >/dev/null 2>&1; then
    echo "eksctl ******** 检测已部署，跳过 ******** ($(eksctl version 2>/dev/null))"
    return
  fi
  echo "eksctl ******** 未检测到，开始下载安装 ******** "
  local plat="Linux_${TARGET_ARCH}" url
  url="https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${plat}.tar.gz"
  if ! curl -fsSL "${url}" -o eksctl.tar.gz; then
    red "eksctl 下载失败(${url})，请检查网络后重试。"
    exit 1
  fi
  if ! tar -xzf eksctl.tar.gz -C /tmp eksctl 2>/dev/null; then
    red "eksctl 解压失败(可能下载到报错页)，请重试。"
    exit 1
  fi
  sudo mv /tmp/eksctl /usr/local/bin/
  green "eksctl 安装完成：$(eksctl version 2>/dev/null)"
}

install_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    echo "kubectl ******** 检测已部署，跳过 ******** ($(kubectl version --client 2>/dev/null | head -1))"
    return
  fi
  echo "kubectl ******** 未检测到，开始下载安装(主备双源) ******** "
  local ok=false src
  for src in "${KUBECTL_URL_PRIMARY}" "${KUBECTL_URL_BACKUP}"; do
    echo "尝试下载 kubectl: ${src}"
    if curl -fsSL "${src}" -o /tmp/kubectl && chmod +x /tmp/kubectl &&
      /tmp/kubectl version --client >/dev/null 2>&1; then
      sudo mv /tmp/kubectl /usr/local/bin/kubectl
      ok=true
      break
    fi
    yellow "该源下载/校验失败,尝试下一个源。"
  done
  if [ "${ok}" != "true" ]; then
    red "kubectl 主备源均下载/校验失败,请检查网络或手动安装后重试。"
    exit 1
  fi
  green "kubectl 安装完成：$(kubectl version --client 2>/dev/null | head -1)"
}

ensure_path() {
  case ":${PATH}:" in
  *":/usr/local/bin:"*) : ;;
  *) export PATH="/usr/local/bin:${PATH}" ;;
  esac
}

stage_tools() {
  title "阶段1：安装/更新依赖工具 + 调用者身份"
  install_base_pkg
  install_awscli
  install_eksctl
  install_kubectl
  ensure_path
  aws configure set region "${AWS_DEFAULT_REGION}"
  local who
  who="$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || echo NONE)"
  echo "当前调用者身份: ${who}"
  record "阶段1  依赖工具与身份   正常"
  green "阶段1 完成。"
}

#############################################
##############  阶段2 前置校验  #############
#############################################

stage_precheck() {
  title "阶段2：前置校验(账号一致 / 集群存在 / VPC 一致 / kubectl 可达)"
  aws configure set region "${AWS_DEFAULT_REGION}"

  # a) 账号一致性
  local caller_acct cluster_arn cluster_acct
  caller_acct="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo NONE)"

  # b) 集群存在且 ACTIVE(允许非 ACTIVE 也继续,因销毁场景集群可能处于异常态,但要显式告知)
  local cstatus
  cstatus="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query 'cluster.status' --output text 2>/dev/null || echo NONE)"
  if [ "${cstatus}" == "NONE" ]; then
    red "集群 ${CLUSTER_NAME} 在地域 ${AWS_DEFAULT_REGION} 不存在。"
    red "排查: aws eks list-clusters --region ${AWS_DEFAULT_REGION}  # 核对集群名与地域是否填对"
    red "若集群已删,仅需清理孤儿资源(EFS/CFN 栈/日志),可用环境变量跳过集群相关阶段,或手动清理。"
    exit 1
  fi
  green "集群 ${CLUSTER_NAME} 状态: ${cstatus}。"
  [ "${cstatus}" != "ACTIVE" ] && note_attention "集群非 ACTIVE(${cstatus}),销毁仍会继续,但部分 kubectl 操作可能不可用。"

  # 账号一致性(集群 ARN 中解析账号)
  cluster_arn="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query 'cluster.arn' --output text 2>/dev/null || echo "")"
  cluster_acct="$(echo "${cluster_arn}" | sed -nE 's#arn:[^:]*:eks:[^:]*:([0-9]+):.*#\1#p')"
  if [ -n "${cluster_acct}" ] && [ "${caller_acct}" != "NONE" ] && [ "${caller_acct}" != "${cluster_acct}" ]; then
    red "账号不一致：当前凭证账号 ${caller_acct} ≠ 集群所属账号 ${cluster_acct}。很可能用错了凭证或跨账号,拒绝继续销毁。"
    exit 1
  fi

  # c) VPC 一致：手填 VPC_ID 与集群实际 VPC 一致(核心防误伤:确认销毁的就是目标集群)
  local cluster_vpc
  cluster_vpc="$(aws eks describe-cluster --name "${CLUSTER_NAME}" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || echo NONE)"
  if [ "${cluster_vpc}" != "${VPC_ID}" ]; then
    red "VPC 不一致：手填 VPC_ID=${VPC_ID}，但集群实际 VPC=${cluster_vpc}。为防误销别的集群,拒绝继续。"
    exit 1
  fi
  green "VPC 校验通过(${VPC_ID})。"

  # d) kubectl 可达(非致命:集群异常态可能连不上,后续删 Karpenter 资源会降级处理)
  aws eks --region "${AWS_DEFAULT_REGION}" update-kubeconfig --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
  if kubectl version --request-timeout=10s >/dev/null 2>&1; then
    green "kubectl 可连接集群 API Server。"
    KUBECTL_OK=true
  else
    note_attention "kubectl 无法连接 API Server:Karpenter 节点将无法通过删 NodePool 优雅回收,脚本会在 eksctl delete cluster 阶段兜底,并在收尾提示人工核对残留 EC2。"
    KUBECTL_OK=false
  fi

  record "阶段2  前置校验   正常"
  green "阶段2 前置校验通过。"
}

#############################################
##########  阶段3 侦察 + 二次确认  #########
#############################################

# 各侦察结果暂存,供确认清单与后续清理复用
SCOUT_KARPENTER_NODECLAIMS=""
SCOUT_NODEPOOLS=""
SCOUT_EC2NODECLASSES=""
SCOUT_MANAGED_NODEGROUPS=""
SCOUT_ALL_NODES=""
SCOUT_EFS_ID=""
SCOUT_EFS_MOUNT_TARGETS=""
SCOUT_CFN_KARPENTER=""
SCOUT_ORPHAN_ADDON_STACKS=""
SCOUT_LOG_GROUP=""

scout_targets() {
  title "阶段3：侦察待清理目标(只读,不做任何删除)"

  # 3.1 Karpenter 资源(需 kubectl 可达)
  if [ "${KUBECTL_OK}" == "true" ]; then
    SCOUT_NODEPOOLS="$(kubectl get nodepool -o name 2>/dev/null | sed 's#nodepool.karpenter.sh/##' | tr '\n' ' ' || true)"
    SCOUT_EC2NODECLASSES="$(kubectl get ec2nodeclass -o name 2>/dev/null | sed 's#ec2nodeclass.karpenter.k8s.aws/##' | tr '\n' ' ' || true)"
    SCOUT_KARPENTER_NODECLAIMS="$(kubectl get nodeclaim -o name 2>/dev/null | sed 's#nodeclaim.karpenter.sh/##' | tr '\n' ' ' || true)"
    SCOUT_ALL_NODES="$(kubectl get nodes -o name 2>/dev/null | sed 's#node/##' | tr '\n' ' ' || true)"
  fi

  # 3.2 托管节点组(eksctl delete cluster 会删,此处仅展示)
  SCOUT_MANAGED_NODEGROUPS="$(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" \
    --query 'nodegroups' --output text 2>/dev/null | tr '\t' ' ' || true)"

  # 3.3 EFS 文件系统(按 creation-token 精确定位本集群)
  SCOUT_EFS_ID="$(aws efs describe-file-systems --creation-token "${EFS_CREATION_TOKEN}" \
    --query 'FileSystems[0].FileSystemId' --output text 2>/dev/null || echo "")"
  [ "${SCOUT_EFS_ID}" == "None" ] && SCOUT_EFS_ID=""
  if [ -n "${SCOUT_EFS_ID}" ]; then
    SCOUT_EFS_MOUNT_TARGETS="$(aws efs describe-mount-targets --file-system-id "${SCOUT_EFS_ID}" \
      --query 'MountTargets[].MountTargetId' --output text 2>/dev/null | tr '\t' ' ' || true)"
  fi

  # 3.4 Karpenter CloudFormation 基础栈
  local st
  st="$(aws cloudformation describe-stacks --stack-name "${KARPENTER_CFN_STACK}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "")"
  [ -n "${st}" ] && [ "${st}" != "None" ] && SCOUT_CFN_KARPENTER="${KARPENTER_CFN_STACK} (${st})"

  # 3.5 eksctl addon 的 Pod Identity 角色孤儿栈(前缀精确匹配本集群)
  SCOUT_ORPHAN_ADDON_STACKS="$(aws cloudformation list-stacks \
    --query "StackSummaries[?starts_with(StackName,'eksctl-${CLUSTER_NAME}-addon-') && StackStatus!='DELETE_COMPLETE'].StackName" \
    --output text 2>/dev/null | tr '\t' ' ' || true)"

  # 3.6 控制面日志组
  SCOUT_LOG_GROUP="$(aws logs describe-log-groups --log-group-name-prefix "${CLUSTER_LOG_GROUP}" \
    --query "logGroups[?logGroupName=='${CLUSTER_LOG_GROUP}'].logGroupName" --output text 2>/dev/null | tr '\t' ' ' || true)"
}

# 展示侦察清单
print_scout_report() {
  echo ""
  echo -e "\e[1m$(_banner_rule)\e[0m"
  red "以下是【将被清理/释放】的目标(集群: ${CLUSTER_NAME}  地域: ${AWS_DEFAULT_REGION}  VPC: ${VPC_ID}):"
  echo -e "\e[1m$(_banner_rule)\e[0m"

  echo ""
  yellow "① Karpenter 弹性节点(删 NodePool 触发回收对应 EC2 实例):"
  echo "   NodePool      : ${SCOUT_NODEPOOLS:-（无 / kubectl 不可达未采集）}"
  echo "   EC2NodeClass  : ${SCOUT_EC2NODECLASSES:-（无 / 未采集）}"
  echo "   NodeClaim     : ${SCOUT_KARPENTER_NODECLAIMS:-（无 / 未采集）}"

  echo ""
  yellow "② 托管节点组(随 eksctl delete cluster 一并删除):"
  echo "   ManagedNodeGroups: ${SCOUT_MANAGED_NODEGROUPS:-（无）}"

  echo ""
  yellow "③ 集群当前全部节点(仅供比对,应随①②清空):"
  echo "   Nodes: ${SCOUT_ALL_NODES:-（无 / 未采集）}"

  echo ""
  yellow "④ EFS 文件系统(独立于集群,eksctl 不删,本脚本手动清):"
  if [ -n "${SCOUT_EFS_ID}" ]; then
    echo "   FileSystemId : ${SCOUT_EFS_ID}  (creation-token: ${EFS_CREATION_TOKEN})"
    echo "   MountTargets : ${SCOUT_EFS_MOUNT_TARGETS:-（无）}"
    [ "${DELETE_EFS}" != "true" ] && echo -e "   \e[33m(DELETE_EFS=false,本次将【保留】EFS,仅提示)\e[0m"
  else
    echo "   （未按 creation-token=${EFS_CREATION_TOKEN} 找到本集群 EFS;若曾自定义 EFS_NAME 请核对）"
  fi

  echo ""
  yellow "⑤ 集群本体(控制面 + addons + Pod Identity + eksctl 自建资源,由 eksctl delete cluster 删):"
  echo "   Cluster: ${CLUSTER_NAME}"

  echo ""
  yellow "⑥ Karpenter CloudFormation 栈(IAM 角色 + instance profile + SQS 中断队列 + 策略,节点终止后删):"
  echo "   Stack: ${SCOUT_CFN_KARPENTER:-（未找到）}"

  echo ""
  yellow "⑦ 残留清理(孤儿栈 / 日志组):"
  echo "   eksctl addon 孤儿栈: ${SCOUT_ORPHAN_ADDON_STACKS:-（无）}"
  if [ "${DELETE_LOG_GROUP}" == "true" ]; then
    echo "   控制面日志组       : ${SCOUT_LOG_GROUP:-（无）}"
  else
    echo "   控制面日志组       : ${SCOUT_LOG_GROUP:-（无）}  (DELETE_LOG_GROUP=false,将保留)"
  fi
  echo ""
  echo -e "\e[1m$(_banner_rule)\e[0m"
  green "【安全边界】本脚本不删除既有基础网络资源:VPC(${VPC_ID})、子网、路由表、网关、弹性IP、"
  green "            网络ACL、以及非本集群创建的安全组/网络接口。上述①~⑦之外的资源均不触碰。"
  echo -e "\e[1m$(_banner_rule)\e[0m"
}

# 侦察 + 展示 + 二次确认。不确认则退出(退出码 0,非错误)。
stage_scout_and_confirm() {
  scout_targets
  print_scout_report
  echo ""
  red "⚠ 上述资源将被【永久删除】,操作不可逆,且会终止其上运行的所有业务!"
  red "⚠ 请再次确认:目标集群 = ${CLUSTER_NAME}  地域 = ${AWS_DEFAULT_REGION}  账号 = $(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '?')"
  echo ""
  if ! ask_yes_no "确认按上述清单销毁该 EKS 并释放硬件资源?(输入 y 开始清理,其余一律取消)"; then
    yellow "已取消,未做任何删除。侦察日志见: ${RESULT_FILE}"
    exit 0
  fi
  green "已确认,开始按依赖顺序清理。"
}

#############################################
##########  阶段4 按依赖顺序清理  ##########
#############################################

# 4.1 采集"删集群后需回收的 EBS 动态卷"(只读,不删负载/PVC)。
#   为什么不删 PVC/负载:
#     - 删 PVC 会 hang——PVC 带 kubernetes.io/pvc-protection finalizer,只要还有 Pod 引用就
#       拒绝移除 finalizer,PVC 永远停在 Terminating;而 `kubectl delete pvc` 默认前台 wait,
#       会一直阻塞(实测卡死)。且业务负载可能是 CRD(如 kruise Advanced StatefulSet),
#       `kubectl delete sts` 删不到,Pod 不消失,finalizer 永不释放。
#     - 且删 PVC 对"回收集群"并非必要:后续 eksctl delete cluster 会删集群本体。
#   真正的风险是:集群删除后 EBS CSI controller 随之消失,reclaimPolicy=Delete 的动态卷
#   将无人回收 → 变孤儿卷(持续计费)。故这里【只采集】这些卷的 EBS 卷 ID(从 PV 的
#   CSI volumeHandle 取),留待阶段5在集群删除、卷已 detach 后按卷 ID 精确删除。
#   reclaimPolicy=Retain 的卷(如 te-nfs 对应 EFS access point)不在此列,由 4.4 删 EFS 覆盖。
EBS_VOLS_TO_DELETE=""
collect_ebs_dynamic_volumes() {
  echo "---- 4.1 采集待回收的 EBS 动态卷(只读;不删 PVC/负载,避免 finalizer 前台阻塞) ----"
  if [ "${KUBECTL_OK}" != "true" ]; then
    note_attention "kubectl 不可达,无法采集 EBS 动态卷 ID;阶段5将退化为按集群标签兜底核对,请人工确认无孤儿 EBS 卷。"
    return 0
  fi
  # 取所有 reclaimPolicy=Delete 且由 ebs.csi.aws.com 供给的 PV 的底层卷ID(spec.csi.volumeHandle=vol-xxx)
  EBS_VOLS_TO_DELETE="$(kubectl get pv -o json 2>/dev/null | jq -r '
    .items[]
    | select(.spec.persistentVolumeReclaimPolicy=="Delete")
    | select(.spec.csi.driver=="ebs.csi.aws.com")
    | .spec.csi.volumeHandle' 2>/dev/null | grep -E '^vol-' | tr '\n' ' ' || true)"
  if [ -n "${EBS_VOLS_TO_DELETE// /}" ]; then
    yellow "已记录 reclaimPolicy=Delete 的 EBS 动态卷,将在集群删除后(卷 detach)于阶段5删除:"
    echo "   ${EBS_VOLS_TO_DELETE}"
  else
    green "未发现需回收的 EBS 动态卷(或无 ebs.csi.aws.com 的 Delete 卷)。"
  fi
  yellow "说明:不删 PVC/业务负载(删集群会连带清理 k8s 侧);Retain 卷(如 te-nfs/EFS)由删 EFS 覆盖。"
}

# 4.2 删 NodePool/EC2NodeClass,让 Karpenter 回收它调度出的节点
cleanup_karpenter_nodes() {
  echo "---- 4.2 删 NodePool/EC2NodeClass,回收 Karpenter 弹性节点 ----"
  if [ "${KUBECTL_OK}" != "true" ]; then
    note_attention "kubectl 不可达,无法优雅回收 Karpenter 节点;eksctl delete cluster 回滚其自建资源时可能因残留 ENI/实例受阻(注:eksctl 不删既有 VPC/子网),收尾请人工核对 EC2。"
    return 0
  fi
  kubectl delete nodepool --all --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete ec2nodeclass --all --ignore-not-found >/dev/null 2>&1 || true
  # 等 NodeClaim 清零(对应 EC2 实例被终止)
  local t=0 left
  while [ ${t} -lt "${NODE_DRAIN_TIMEOUT}" ]; do
    left="$(kubectl get nodeclaim --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${left}" == "0" ]; then
      green "所有 Karpenter NodeClaim 已回收(对应 EC2 实例已终止)。"
      return 0
    fi
    echo "等待 Karpenter 节点回收...(剩余 NodeClaim ${left}, 已等待 ${t}s)"
    sleep 15
    t=$((t + 15))
  done
  note_attention "Karpenter 节点在 ${NODE_DRAIN_TIMEOUT}s 内未完全回收,请手动 kubectl get nodeclaim 核对,必要时手动删 NodeClaim / 终止 EC2 实例后再继续。"
}

# 4.3 卸载 Karpenter(摘掉 controller,避免删 CFN 栈时 SQS 队列有消费者残留)
cleanup_karpenter_release() {
  echo "---- 4.3 卸载 Karpenter(helm uninstall) ----"
  if [ "${KUBECTL_OK}" != "true" ]; then
    yellow "kubectl 不可达,跳过 helm uninstall(集群删除会连带清理)。"
    return 0
  fi
  if command -v helm >/dev/null 2>&1; then
    if helm status karpenter -n kube-system >/dev/null 2>&1; then
      helm uninstall karpenter -n kube-system >/dev/null 2>&1 || note_attention "helm uninstall karpenter 失败,可忽略(集群将随后删除)。"
      green "Karpenter 已卸载。"
    else
      yellow "未检测到 karpenter helm release,跳过。"
    fi
  else
    yellow "未安装 helm,跳过 helm uninstall(集群删除会连带清理)。"
  fi
}

# 4.4 删 EFS(先删挂载目标,再删文件系统;access point 随文件系统删除)
cleanup_efs() {
  echo "---- 4.4 删除 EFS 文件系统(挂载目标 → 文件系统) ----"
  if [ "${DELETE_EFS}" != "true" ]; then
    note_attention "DELETE_EFS=false,已【保留】EFS ${SCOUT_EFS_ID:-（未找到）},请自行确认是否需要手动删除(持续计费)。"
    return 0
  fi
  if [ -z "${SCOUT_EFS_ID}" ]; then
    yellow "未找到本集群 EFS(creation-token=${EFS_CREATION_TOKEN}),跳过。"
    return 0
  fi
  local mt
  for mt in ${SCOUT_EFS_MOUNT_TARGETS}; do
    echo "删除挂载目标 ${mt}..."
    aws efs delete-mount-target --mount-target-id "${mt}" >/dev/null 2>&1 || note_attention "删除挂载目标 ${mt} 失败,请手动删除。"
  done
  # 等挂载目标清零
  local t=0 left
  while [ ${t} -lt "${EFS_WAIT_TIMEOUT}" ]; do
    left="$(aws efs describe-mount-targets --file-system-id "${SCOUT_EFS_ID}" \
      --query 'length(MountTargets)' --output text 2>/dev/null || echo 0)"
    [ "${left}" == "0" ] && break
    echo "等待挂载目标删除...(剩余 ${left}, 已等待 ${t}s)"
    sleep 10
    t=$((t + 10))
  done
  echo "删除 EFS 文件系统 ${SCOUT_EFS_ID}..."
  if aws efs delete-file-system --file-system-id "${SCOUT_EFS_ID}" >/dev/null 2>&1; then
    green "EFS ${SCOUT_EFS_ID} 已删除。"
  else
    note_attention "EFS ${SCOUT_EFS_ID} 删除失败(可能挂载目标未清干净或存在 access point 占用),请手动删除。"
  fi
}

# 4.5 删 EKS 集群本体(托管节点组 + addons + Pod Identity + 控制面 + eksctl 建的网络/CFN)
cleanup_eks_cluster() {
  echo "---- 4.5 eksctl delete cluster(集群本体 + 托管节点组 + eksctl 建的网络/CFN) ----"
  if eksctl delete cluster --name "${CLUSTER_NAME}" --region "${AWS_DEFAULT_REGION}" --wait; then
    green "EKS 集群 ${CLUSTER_NAME} 已删除。"
  else
    note_attention "eksctl delete cluster 未完全成功。常见原因:VPC 内有非 eksctl 管理的残留 ENI/实例(如未回收的 Karpenter 节点)阻塞了 eksctl 自建资源(如其创建的安全组)的删除(注:既有 VPC/子网非 eksctl 管理,不在其删除范围)。请查看 CloudFormation 控制台 eksctl-${CLUSTER_NAME}-cluster 栈的失败事件并人工处理。"
  fi
}

# 4.6 删 Karpenter CFN 栈(节点终止后才能删,否则 instance profile 被引用删栈失败)
cleanup_karpenter_cfn() {
  echo "---- 4.6 删除 Karpenter CloudFormation 栈(${KARPENTER_CFN_STACK}) ----"
  local st
  st="$(aws cloudformation describe-stacks --stack-name "${KARPENTER_CFN_STACK}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE)"
  if [ "${st}" == "NONE" ]; then
    yellow "未找到 ${KARPENTER_CFN_STACK},跳过。"
    return 0
  fi
  aws cloudformation delete-stack --stack-name "${KARPENTER_CFN_STACK}" >/dev/null 2>&1 || true
  echo "等待 ${KARPENTER_CFN_STACK} 删除完成..."
  if aws cloudformation wait stack-delete-complete --stack-name "${KARPENTER_CFN_STACK}" 2>/dev/null; then
    green "Karpenter CFN 栈 ${KARPENTER_CFN_STACK} 已删除。"
  else
    note_attention "Karpenter CFN 栈 ${KARPENTER_CFN_STACK} 删除未完成。常见原因:仍有 EC2 实例在用 KarpenterNodeRole 的 instance profile(节点未回收干净)。请确认 Karpenter 节点已全部终止后,重跑本脚本或手动删栈。"
  fi
}

# 4.7 清残留:eksctl addon 的 Pod Identity 孤儿栈(带删除保护,需先关保护)
cleanup_orphan_addon_stacks() {
  echo "---- 4.7 清理 eksctl addon Pod Identity 孤儿栈 ----"
  # 重新采集(前面步骤可能已删掉一部分)
  local stacks s
  stacks="$(aws cloudformation list-stacks \
    --query "StackSummaries[?starts_with(StackName,'eksctl-${CLUSTER_NAME}-addon-') && StackStatus!='DELETE_COMPLETE'].StackName" \
    --output text 2>/dev/null | tr '\t' ' ' || true)"
  if [ -z "${stacks// /}" ]; then
    green "无 addon 孤儿栈残留。"
    return 0
  fi
  for s in ${stacks}; do
    echo "处理孤儿栈 ${s}(先关删除保护再删)..."
    aws cloudformation update-termination-protection --stack-name "${s}" --no-enable-termination-protection >/dev/null 2>&1 || true
    aws cloudformation delete-stack --stack-name "${s}" >/dev/null 2>&1 || true
    aws cloudformation wait stack-delete-complete --stack-name "${s}" 2>/dev/null &&
      green "孤儿栈 ${s} 已删除。" ||
      note_attention "孤儿栈 ${s} 删除未完成,请手动核对 CloudFormation 控制台。"
  done
}

# 4.8 清残留:控制面日志组
cleanup_log_group() {
  echo "---- 4.8 清理控制面 CloudWatch 日志组 ----"
  if [ "${DELETE_LOG_GROUP}" != "true" ]; then
    yellow "DELETE_LOG_GROUP=false,保留日志组 ${CLUSTER_LOG_GROUP}。"
    return 0
  fi
  if aws logs describe-log-groups --log-group-name-prefix "${CLUSTER_LOG_GROUP}" \
    --query "logGroups[?logGroupName=='${CLUSTER_LOG_GROUP}'].logGroupName" --output text 2>/dev/null | grep -q "${CLUSTER_LOG_GROUP}"; then
    aws logs delete-log-group --log-group-name "${CLUSTER_LOG_GROUP}" >/dev/null 2>&1 &&
      green "日志组 ${CLUSTER_LOG_GROUP} 已删除。" ||
      note_attention "日志组 ${CLUSTER_LOG_GROUP} 删除失败,请手动删除。"
  else
    yellow "未找到日志组 ${CLUSTER_LOG_GROUP},跳过。"
  fi
}

stage_cleanup() {
  title "阶段4：按依赖顺序清理(应用→Karpenter→存储→集群→CFN→残留)"
  collect_ebs_dynamic_volumes
  cleanup_karpenter_nodes
  cleanup_karpenter_release
  cleanup_efs
  cleanup_eks_cluster
  cleanup_karpenter_cfn
  cleanup_orphan_addon_stacks
  cleanup_log_group
  record "阶段4  按依赖顺序清理   完成"
  green "阶段4 清理流程执行完毕。"
}

#############################################
##########  阶段5 残留核对  ################
#############################################

stage_residual_check() {
  title "阶段5：残留核对(只读,列出疑似残留供人工兜底)"

  # a) 集群是否还在
  local cstatus
  cstatus="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query 'cluster.status' --output text 2>/dev/null || echo GONE)"
  if [ "${cstatus}" == "GONE" ]; then
    green "EKS 集群已不存在。"
  else
    note_attention "EKS 集群仍存在(状态 ${cstatus}),请核对 eksctl delete cluster 是否成功。"
  fi

  # b) EFS 是否还在
  if [ "${DELETE_EFS}" == "true" ]; then
    local efs_left
    efs_left="$(aws efs describe-file-systems --creation-token "${EFS_CREATION_TOKEN}" \
      --query 'FileSystems[0].FileSystemId' --output text 2>/dev/null || echo "")"
    if [ -z "${efs_left}" ] || [ "${efs_left}" == "None" ]; then
      green "EFS 已删除。"
    else
      note_attention "EFS ${efs_left} 仍存在,请手动删除。"
    fi
  fi

  # c) Karpenter CFN 栈
  local kst
  kst="$(aws cloudformation describe-stacks --stack-name "${KARPENTER_CFN_STACK}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo GONE)"
  [ "${kst}" == "GONE" ] && green "Karpenter CFN 栈已删除。" ||
    note_attention "Karpenter CFN 栈 ${KARPENTER_CFN_STACK} 仍存在(${kst}),请核对。"

  # d) 回收 4.1 采集的 EBS 动态卷(reclaimPolicy=Delete)。此时集群已删、实例已终止,卷已 detach。
  #    集群删除后 EBS CSI controller 消失,这些 Delete 卷无人回收 → 必须按卷 ID 精确删除,否则孤儿计费。
  echo "---- 5.d 回收 EBS 动态卷(4.1 采集的 Delete 策略卷,集群删除后卷已 detach) ----"
  if [ -n "${EBS_VOLS_TO_DELETE// /}" ]; then
    local v vstate
    for v in ${EBS_VOLS_TO_DELETE}; do
      vstate="$(aws ec2 describe-volumes --volume-ids "${v}" --query 'Volumes[0].State' --output text 2>/dev/null || echo GONE)"
      if [ "${vstate}" == "GONE" ]; then
        green "EBS 卷 ${v} 已不存在(可能已随 PV 回收)。"
      elif [ "${vstate}" == "available" ]; then
        if aws ec2 delete-volume --volume-id "${v}" >/dev/null 2>&1; then
          green "EBS 卷 ${v} 已删除。"
        else
          note_attention "EBS 卷 ${v} 删除失败,请手动删除(aws ec2 delete-volume --volume-id ${v})。"
        fi
      else
        note_attention "EBS 卷 ${v} 当前状态 ${vstate}(未 available,可能仍 attached),暂不删除,请稍后手动核对删除。"
      fi
    done
  else
    yellow "无 4.1 采集的 EBS 动态卷需回收。"
  fi

  # e) 兜底:按集群标签核对残留 EC2 卷/实例(常见持续计费源)
  echo "---- 5.e 兜底核对(按集群标签查残留 EBS 卷 / 运行中实例) ----"
  local vols insts
  vols="$(aws ec2 describe-volumes \
    --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr '\t' ' ' || true)"
  [ -n "${vols// /}" ] && note_attention "疑似残留 EBS 卷(kubernetes.io/cluster/${CLUSTER_NAME}=owned): ${vols} —— 请确认是否 Retain 卷需手动删除。" ||
    green "无按集群标签的残留 EBS 卷。"
  insts="$(aws ec2 describe-instances \
    --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr '\t' ' ' || true)"
  [ -n "${insts// /}" ] && note_attention "疑似残留 EC2 实例(kubernetes.io/cluster/${CLUSTER_NAME}=owned): ${insts} —— 可能是未回收的 Karpenter 节点,请手动终止。" ||
    green "无按集群标签的残留运行中实例。"

  record "阶段5  残留核对   完成"
}

#############################################
##############  编排与收尾  ################
#############################################

print_plan() {
  title "AWS EKS 存量集群回收/销毁 —— 执行计划"
  cat <<PLAN
本脚本用于【彻底回收】一套存量 EKS 集群并释放硬件资源,按依赖顺序清理:

阶段1: 安装/更新依赖工具 + 调用者身份打印
阶段2: 前置校验(账号一致 / 集群存在 / VPC 一致 / kubectl 可达)
阶段3: 侦察待清理目标并展示清单 + 交互式 Y/N 二次确认(不确认即安全退出)
阶段4: 按依赖顺序清理:
       4.1 采集待回收的 EBS 动态卷(只读;不删 PVC/负载,避免 finalizer 前台阻塞)
       4.2 删 NodePool/EC2NodeClass → Karpenter 回收弹性节点(终止 EC2)
       4.3 卸载 Karpenter(helm uninstall)
       4.4 删 EFS(挂载目标 → 文件系统)
       4.5 eksctl delete cluster(集群本体 + 托管节点组 + eksctl 建的网络/CFN)
       4.6 删 Karpenter CloudFormation 栈(IAM 角色/instance profile/SQS 队列/策略)
       4.7 清 eksctl addon Pod Identity 孤儿栈(先关删除保护)
       4.8 清控制面 CloudWatch 日志组
阶段5: 残留核对(列出仍存在的疑似残留,供人工兜底)

目标集群: ${CLUSTER_NAME}   地域: ${AWS_DEFAULT_REGION}   VPC: ${VPC_ID}
依赖顺序核心: Karpenter 节点必须先"删 NodePool"由其自行回收,不能直接终止 EC2;
              EFS 独立于集群需手动删;Karpenter CFN 栈必须在节点终止后删。
PLAN
  echo -e "\e[1m$(_banner_rule)\e[0m"
  echo ""
}

print_summary() {
  title "结果汇总"
  green "存量集群 ${CLUSTER_NAME} 回收/销毁流程执行完毕。"
  if [ -s "${ATTENTION_FILE}" ]; then
    echo ""
    yellow "需关注(非致命 / 需人工兜底):"
    while IFS= read -r line; do echo -e "\e[33m- ${line}\e[0m"; done <"${ATTENTION_FILE}"
  else
    green "无残留关注项,资源已按清单释放。"
  fi
  echo -e "\e[1m$(_banner_rule)\e[0m"
  echo "日志文件: ${RESULT_FILE}"
}

# kubectl 可达标志(阶段2 赋值)
KUBECTL_OK=false

main() {
  print_plan
  check_required_conf
  stage_tools
  stage_precheck
  stage_scout_and_confirm
  stage_cleanup
  stage_residual_check
  print_summary
  green "回收/销毁完成:请以阶段5残留核对与需关注项为准,确保无持续计费资源遗留。"
}

main "$@"
