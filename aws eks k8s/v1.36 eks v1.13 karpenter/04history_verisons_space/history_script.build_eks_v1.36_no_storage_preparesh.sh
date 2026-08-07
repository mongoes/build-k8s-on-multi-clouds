#!/bin/bash
# =============================================================================
# build_eks_v1.36.sh
# 适用场景：一键创建 AWS EKS v1.36 + Karpenter v1.13.0
#   阶段1 安装/更新依赖工具 + 脚本执行主机IAM权限自检
#   阶段2 创建EKS，并完成 Karpenter Pod Identity 关联(podIdentityAssociations)
#   阶段3 helm 安装 Karpenter v1.13.0
#   阶段4 网络就绪(ta主机子网/ShareNode安全组打发现标签 + ta主机与EKS安全组彼此放行)
#   阶段5 EKS功能可用性验证(pod起服 + 云主机访问容器网络连通)
#
# 特性：断点幂等，可重试(已成功阶段不重复执行)。
# 适用：x86_64 / aarch64；常见 Linux(Amazon Linux 2023 / Rocky9 / CentOS 等)。
# 前置：执行本脚本的云主机 IAM 角色需具备 AdministratorAccess(或等价创建EKS权限)。
# =============================================================================

# 确保以【非 POSIX 模式的 bash】运行,当用户以 `sh 脚本` 启动时,/bin/sh 即使链接到 bash,也会进入 POSIX 兼容模式,

if [ -z "${_BUILD_EKS_REEXEC:-}" ]; then
  export _BUILD_EKS_REEXEC=1
  exec bash "$0" "$@"
fi

set -euo pipefail

###############################################################################
# 用户配置区（必填）
# 请将数数参考文档中2.2章节收集信息粘贴至此处
###############################################################################
#AE集群所在地域，请按实际填写!
AWS_DEFAULT_REGION="us-xxx-1"
#AE主机所在VPC的ID
VPC_ID="vpc-xxx"
#AE主机实际所在子网，十分重要！EKS容器实例会绑定相同子网！请从AWS控制台确认后填写！下方有多可用区子网信息收集，应包含AE主机子网
AE_HOSTS_SUBNET_ID="subnet-yyy"
#AE主机绑定安全组，十分重要！将用于AE主机与EKS容器集群内网互联互通，请从AWS控制台确认后填写！
AE_HOSTS_SG_ID="sg-000"

#可用区1
ZONE_1="us-xxxx-1a"
#可用区1下public subnet id
PUBLIC_SUBNET_ZONE_1="subnet-xxx"
#可用区1下private subnet id
PRIVATE_SUBNET_ZONE_1="subnet-yyy"

#可用区2
ZONE_2="us-xxxx-1b"
#可用区2下public subnet id
PUBLIC_SUBNET_ZONE_2="subnet-zzz"
#可用区2下private subnet id
PRIVATE_SUBNET_ZONE_2="subnet-uuu"

###############################################################################
# 默认参数区（该章节及以下内容请不要改动）
###############################################################################

#===== 版本信息 =====
EKS_VERSION="${EKS_VERSION:-1.36}"
KARPENTER_VERSION="${KARPENTER_VERSION:-1.13.0}"
KARPENTER_NAMESPACE="${KARPENTER_NAMESPACE:-karpenter}"

#===== EKS 集群名 =====
# 注意：EKS关联的核心安全组、子网的标签值都将默认取集群名
CLUSTER_NAME="${CLUSTER_NAME:-eks-thinkingai}"

#===== Karpenter 资源发现标签 key(必须与 auto_build_nodepool.sh 的 selector 保持字面一致) =====
# 节点组 EC2NodeClass 通过这两个 key 的标签发现子网/安全组;阶段4会给对应子网/安全组打上"key=集群名"
SUBNET_DISCOVERY_KEY="${SUBNET_DISCOVERY_KEY:-karpenter.sh/discovery-subnet}"
SG_DISCOVERY_KEY="${SG_DISCOVERY_KEY:-karpenter.sh/discovery-sg}"

#===== 托管节点组机型 =====
NODEGROUP_INSTANCE_TYPE="${NODEGROUP_INSTANCE_TYPE:-m5.large}"

#===== 其他官方参数(保持默认) =====
# 中国区需改为 aws-cn 、 GovCloud改为 aws-us-gov
AWS_PARTITION="${AWS_PARTITION:-aws}"
ENABLE_ZONAL_SHIFT="${ENABLE_ZONAL_SHIFT:-false}"

#===== kubectl 下载地址(主备双源，均可覆盖) =====
# 主源：k8s 官方；备源：团队 OSS 镜像(内网/AWS地址不可达时兜底)。
# 架构目录直接用 ${TARGET_ARCH} 在此拼好完整 URL,不再引入 {ARCH} 占位符+替换
# (旧方案用 ${VAR//\{ARCH\}} 或 sed s#{ARCH}# 都有坑:前者 sh POSIX 模式解析错乱,后者 GNU sed 把 {} 当量词导致替换失败→URL 畸形→404)。
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.36.0}"
# 先解析目标架构(供下方 URL 拼接使用)
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

#===== 预留 IP 数(避免 EKS 过量预留 IP 导致子网 IP 不足) =====
# 提示：可结合 MINIMUM_IP_TARGET 一起设置，按子网 CIDR 余量取值。
WARM_IP_TARGET="${WARM_IP_TARGET:-6}"

#############################################
###########  运行时变量与辅助函数  ###########
#############################################

# 系统架构(工具下载依赖)
ARCH="$(uname -m)"

# 断点状态目录(记录已完成阶段，实现幂等)
STATE_DIR="${STATE_DIR:-./.eks_build_state}"
mkdir -p "${STATE_DIR}"

# 结果/日志文件
RESULT_FILE="${STATE_DIR}/build_result_$(date +'%Y-%m-%d-%H-%M-%S').log"
echo "build start time：$(date +'%Y-%m-%d %H:%M:%S')" >>"${RESULT_FILE}"

# ===== 全量输出同步到日志文件 =====
# 需求:脚本向终端输出一份、同时向日志文件落一份,便于事后追溯。
# 做法:用 exec + 进程替换把 stdout/stderr 同时导向 终端 与 日志文件;
#      写入文件前用 sed 剥离 ANSI 颜色码(终端仍保留彩色),使日志纯文本、易读易grep。
# 注:read -p 的交互提示走 stderr,已被 2>&1 一并捕获并回显到终端,交互不受影响。
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >>"${RESULT_FILE}")) 2>&1

# 颜色打印辅助(沿用历史脚本风格)
green() { echo -e "\e[32m\e[1m$1\e[0m"; }
red() { echo -e "\e[31m\e[1m$1\e[0m"; }
yellow() { echo -e "\e[33m\e[1m$1\e[0m"; }

# ==================== 横幅宽度工具 ====================
# 所有章节横幅统一为固定总宽、标题居中、两侧 '=' 补齐，解决横幅长短参差。
BANNER_WIDTH="${BANNER_WIDTH:-100}"

# 计算显示宽度：中文/全角按2列，ASCII按1列。纯字节实现，不依赖 locale：
# UTF-8 续字节(0x80-0xBF)不增显示列，每个 CJK(3字节=1主+2续)显示2列 => 显示宽 = 字节数 - 续字节数/2
_disp_width() {
  local s="$1" bytes cont
  bytes=$(printf '%s' "$s" | LC_ALL=C wc -c)
  cont=$(printf '%s' "$s" | LC_ALL=C tr -dc '\200-\277' | LC_ALL=C wc -c)
  echo $((bytes - cont / 2))
}

# 生成固定总宽(BANNER_WIDTH)的左对齐横幅串：固定 '=====' 前缀 + 标题 + 右侧 '=' 补齐
# 左对齐使各横幅标题从同一列起始，右侧按标题长短自动补齐，避免居中导致的参差
_banner_line() {
  local title="$1" prefix="=====" w right
  w=$(_disp_width "$title")
  right=$((BANNER_WIDTH - ${#prefix} - w))
  ((right < 3)) && right=3
  printf '%s%s%s' "$prefix" "$title" "$(printf '%*s' "$right" '' | tr ' ' '=')"
}

# 生成整行(BANNER_WIDTH宽)的 '=' 分隔规则线
_banner_rule() { printf '%*s' "$BANNER_WIDTH" '' | tr ' ' '='; }

# 按显示宽度(CJK按2列)左对齐补空格到目标宽度，用于结果表列对齐
_pad_disp() {
  local s="$1" target="$2" w n
  w=$(_disp_width "$s")
  n=$((target - w))
  ((n < 0)) && n=0
  printf '%s%*s' "$s" "$n" ''
}

# 章节横幅：固定总宽、标题居中、加粗
title() { echo -e "\n\e[1m$(_banner_line " $1 ")\e[0m"; }

# 记录结果行到日志文件(仅写文件，不重复上屏；收尾统一对账打印)
record() { echo -e "$1" >>"${RESULT_FILE}"; }

# 收集"关注"项(非致命告警)，收尾在汇总里统一提示
ATTENTION_FILE="${STATE_DIR}/attention.$$"
: >"${ATTENTION_FILE}"
note_attention() {
  yellow "$1"
  echo "$1" >>"${ATTENTION_FILE}"
}

# 断点标记：完成/检测/清除
mark_done() { touch "${STATE_DIR}/$1.done"; }
is_done() { [ -f "${STATE_DIR}/$1.done" ]; }

# 注:kubectl 目标架构 TARGET_ARCH 已在上方"kubectl 下载地址"章节解析(URL 拼接需要),此处不再重复。

#############################################
##############  阶段1 装工具  ###############
#############################################

# awscli：从 AWS 官方地址安装(按架构)，幂等；下载带 -f 并校验解压，失败即退出
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

# eksctl：确保为最新稳定版(识别 EKS 1.36)。已安装且已是最新→打印版本跳过；低于最新才备份升级。
# 下载带 -f 并校验解压，失败即退出，杜绝把报错页当二进制装上。
install_eksctl() {
  local latest cur
  # 解析 GitHub latest release 重定向 URL 得到最新稳定版号(下载源同为 github，可达性一致)
  latest="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    https://github.com/eksctl-io/eksctl/releases/latest 2>/dev/null | sed -E 's#.*/tag/v?##')"

  if command -v eksctl >/dev/null 2>&1; then
    cur="$(eksctl version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [ -z "${latest}" ]; then
      yellow "无法获取 eksctl 最新版本号(网络受限)，保守跳过升级。当前: $(eksctl version 2>&1 | head -1)"
      return
    fi
    # 当前 >= 最新(sort -V 取较小值仍等于 latest)：已是最新稳定版，无需变更
    if [ "$(printf '%s\n%s\n' "${latest}" "${cur}" | sort -V | head -1)" = "${latest}" ]; then
      green "eksctl 已是最新稳定版(当前 ${cur} >= 最新 ${latest})，跳过。"
      return
    fi
    echo "eksctl ******** 当前 ${cur} < 最新 ${latest}，备份后升级 ******** "
    local f bak
    f="$(command -v eksctl)"
    bak="/usr/local/bin/eksctl_bak_$(date +%Y%m%d_%H%M%S)"
    sudo mv "${f}" "${bak}" || true
  else
    echo "eksctl ******** 未检测到，开始下载安装最新版 ******** "
  fi

  local url
  case "${ARCH}" in
  x86_64) url="https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" ;;
  aarch64) url="https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_arm64.tar.gz" ;;
  esac
  if ! curl -fsSL "${url}" -o "eksctl.tar.gz"; then
    red "eksctl 下载失败(${url})，请检查网络后重试。"
    exit 1
  fi
  rm -f ./eksctl
  if ! tar -zxf eksctl.tar.gz 2>/dev/null || [ ! -f ./eksctl ]; then
    red "eksctl 解压失败(可能下载到损坏文件/报错页)，请重试。"
    exit 1
  fi
  sudo cp ./eksctl /usr/local/bin/eksctl
  sudo chmod 755 /usr/local/bin/eksctl
  rm -f eksctl.tar.gz ./eksctl
  green "eksctl 安装完成：$(eksctl version 2>&1 | head -1)"
}

# kubectl：主备双源下载 + 强校验，有老版本先备份
# 主源 k8s 官方，主源失败自动切换团队 OSS 备源；每次下载后校验能正常打印版本才安装，
# 杜绝把 S3/OSS 的报错 XML 当二进制装上(此前 exec format error 的根因)。
install_kubectl() {
  # URL 已在配置区用 ${TARGET_ARCH} 拼接完成,此处直接使用,无占位符替换(规避 sh POSIX 与 GNU sed 的 {} 坑)。
  local primary="${KUBECTL_URL_PRIMARY}"
  local backup="${KUBECTL_URL_BACKUP}"
  local tmp="${STATE_DIR}/kubectl.download"

  # 下载并校验单个源：-f 让 HTTP 错误即失败(不落坏文件)，再验证是可执行且能打印版本
  _try_kubectl_source() {
    local url="$1"
    echo "尝试下载 kubectl: ${url}"
    rm -f "${tmp}"
    if ! curl -fsSL "${url}" -o "${tmp}"; then
      yellow "下载失败(HTTP 错误或网络不可达): ${url}"
      return 1
    fi
    chmod +x "${tmp}" 2>/dev/null || true
    # 强校验：能正常打印客户端版本才算可用(坏文件/XML 会在此失败)
    if ! "${tmp}" version --client >/dev/null 2>&1; then
      yellow "校验失败：下载到的文件无法执行(可能是报错页而非二进制): ${url}"
      return 1
    fi
    return 0
  }

  if command -v kubectl >/dev/null 2>&1; then
    echo "kubectl ******** 检测到已安装 $(kubectl version --client 2>/dev/null | head -1)，备份后替换目标版本 ******** "
    local f bak
    f="$(command -v kubectl)"
    bak="/usr/local/bin/kubectl_bak_$(date +%Y%m%d_%H%M%S)"
    sudo mv "${f}" "${bak}" || true
  else
    echo "kubectl ******** 未检测到，开始下载安装 ******** "
  fi

  if _try_kubectl_source "${primary}"; then
    green "主源下载 kubectl 成功。"
  elif _try_kubectl_source "${backup}"; then
    green "主源失败，已从备源(团队 OSS)下载 kubectl 成功。"
  else
    red "kubectl 主备源均下载/校验失败，请检查网络或手动安装后重试。"
    exit 1
  fi

  sudo cp "${tmp}" /usr/local/bin/kubectl
  sudo chmod 755 /usr/local/bin/kubectl
  rm -f "${tmp}"
  green "kubectl 安装完成, 版本: $(kubectl version --client 2>/dev/null | head -1)"
}

# helm：官方脚本(已兼容多架构)，幂等
install_helm() {
  if command -v helm >/dev/null 2>&1; then
    echo "helm ******** 检测已部署，跳过 ******** ($(helm version --short 2>&1))"
    return
  fi
  echo "helm ******** 未检测到，开始安装 ******** "
  curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 get_helm.sh
  ./get_helm.sh
  green "helm 安装完成：$(helm version --short 2>&1)"
}

# ===== yum 源自愈：部分主机默认仅有 ta-yum.repo，不足以安装 unzip/jq 等依赖 =====
# /etc/yum.repos.d/backup/ 下备有更完整的 repo。首次补源前先快照原状用于收尾恢复。
YUM_REPO_DIR="/etc/yum.repos.d"
YUM_REPO_BACKUP_DIR="${YUM_REPO_DIR}/backup"
YUM_REPO_SNAPSHOT="${STATE_DIR}/yum_repos_snapshot"         # 恢复用的原始 repo 快照
YUM_REPO_AUGMENTED_FLAG="${STATE_DIR}/.yum_repos_augmented" # 已补源标记

# 补充 yum 源：快照原状 → 强制覆盖同步 backup 下 repo → 重建缓存
augment_yum_repos() {
  # 已补过就不重复(避免覆盖已被本脚本改写后的状态，也保证快照只取一次原始态)
  if [ -f "${YUM_REPO_AUGMENTED_FLAG}" ]; then
    return 0
  fi
  if [ ! -d "${YUM_REPO_BACKUP_DIR}" ]; then
    yellow "未发现 ${YUM_REPO_BACKUP_DIR}，无法自动补充 yum 源，请手动处理 repo。"
    return 1
  fi

  yellow "检测到 yum 源不足，尝试从 ${YUM_REPO_BACKUP_DIR} 补充 repo..."
  # 1) 快照当前 repo(仅首次)，供脚本收尾恢复默认配置
  if [ ! -d "${YUM_REPO_SNAPSHOT}" ]; then
    mkdir -p "${YUM_REPO_SNAPSHOT}"
    sudo cp -a "${YUM_REPO_DIR}/." "${YUM_REPO_SNAPSHOT}/" 2>/dev/null || true
    echo "已快照原始 yum 源到 ${YUM_REPO_SNAPSHOT}(收尾将据此恢复)"
  fi
  # 2) 强制覆盖同步 backup 下所有 repo(目标已存在则用源文件覆盖)
  sudo cp -f "${YUM_REPO_BACKUP_DIR}"/*.repo "${YUM_REPO_DIR}"/. 2>/dev/null || {
    yellow "${YUM_REPO_BACKUP_DIR} 下未找到 *.repo 文件。"
    return 1
  }
  # 3) 标记已补源。不显式 yum makecache:后续 yum install 会按需自动拉取元数据,
  #    显式 makecache 会预热全部源(耗时数秒)且非必要,故省去以加速。
  touch "${YUM_REPO_AUGMENTED_FLAG}"
  green "yum 源已补充。"
}

# 恢复主机默认 yum 源(收尾调用)：用快照覆盖，删除本脚本补进来的多余 repo
restore_yum_repos() {
  # 未补过源则无需恢复
  [ -f "${YUM_REPO_AUGMENTED_FLAG}" ] || return 0
  [ -d "${YUM_REPO_SNAPSHOT}" ] || return 0
  # 加固:快照必须非空(至少含一个 .repo)才执行"删除+还原",否则宁可不动,避免把主机 repo 删空且无法还原
  if [ -z "$(ls -A "${YUM_REPO_SNAPSHOT}"/*.repo 2>/dev/null)" ]; then
    yellow "yum 源快照为空或不含 .repo,为避免破坏主机源配置,跳过自动恢复。请人工核对 ${YUM_REPO_DIR}。"
    return 0
  fi
  yellow "恢复主机默认 yum 源配置..."
  # 先删除当前目录下的 *.repo(不含 backup 子目录)，再用快照还原，确保补进来的源被清除
  sudo find "${YUM_REPO_DIR}" -maxdepth 1 -type f -name '*.repo' -delete 2>/dev/null || true
  sudo cp -a "${YUM_REPO_SNAPSHOT}/." "${YUM_REPO_DIR}/" 2>/dev/null || true
  rm -f "${YUM_REPO_AUGMENTED_FLAG}"
  green "已恢复主机默认 yum 源配置。"
}

# 安装单个包：失败则补源后重试一次
ensure_pkg() {
  local p="$1"
  command -v "$p" >/dev/null 2>&1 && return 0
  echo "$p 未检测到，尝试 yum 安装"
  if sudo yum install -y "$p" >/dev/null 2>&1; then
    green "$p 安装完成。"
    return 0
  fi
  # 首次失败：补充 yum 源后重试
  yellow "$p 首次 yum 安装失败，尝试补充 yum 源后重试..."
  augment_yum_repos || {
    red "自动安装 $p 失败(补源不可用)，请手动安装后重试"
    return 1
  }
  if sudo yum install -y "$p"; then
    green "$p 安装完成(补源后)。"
    return 0
  fi
  red "自动安装 $p 失败，请手动安装后重试"
  return 1
}

# 确保基础小工具
install_base_pkg() {
  for p in wget unzip jq; do
    ensure_pkg "$p" || true
  done
}

# 确保 /usr/local/bin 在 PATH
ensure_path() {
  if [[ ":$PATH:" != *":/usr/local/bin:"* ]]; then
    export PATH="$PATH:/usr/local/bin"
    echo "export PATH=\$PATH:/usr/local/bin" | sudo tee -a /etc/profile >/dev/null
  fi
}

# 云主机 IAM 权限自检：打印角色名与附加策略，判断是否具备 AdministratorAccess
iam_self_check() {
  title "云主机 IAM 权限自检"
  aws configure set region "${AWS_DEFAULT_REGION}"

  # 1) 打印调用者身份
  local ident arn role_name
  if ! ident="$(aws sts get-caller-identity --output json 2>&1)"; then
    red "无法执行 aws sts get-caller-identity，请确认本主机已绑定 IAM 角色/配置凭证："
    echo "${ident}"
    exit 1
  fi
  arn="$(echo "${ident}" | jq -r '.Arn')"
  echo "当前调用者身份 Arn: ${arn}"
  echo "所属账号: $(echo "${ident}" | jq -r '.Account')"

  # 2) 解析 IAM 角色名(优先实例元数据，其次解析 assumed-role Arn)
  role_name="$(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null || true)"
  if [ -z "${role_name}" ]; then
    # IMDSv2 需要 token
    local token
    token="$(curl -s --max-time 3 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"
    role_name="$(curl -s --max-time 3 -H "X-aws-ec2-metadata-token: ${token}" http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null || true)"
  fi
  if [ -z "${role_name}" ]; then
    # 从 assumed-role Arn 解析
    role_name="$(echo "${arn}" | sed -nE 's#.*assumed-role/([^/]+)/.*#\1#p')"
  fi

  if [ -z "${role_name}" ]; then
    yellow "未能自动识别 IAM 角色名(可能非 EC2 实例角色或使用了 user 凭证)。跳过权限清单打印。"
    yellow "请自行确认执行主机具备 AdministratorAccess(或等价的创建 EKS 权限)。"
    return 0
  fi

  green "执行主机 IAM 角色名: ${role_name}"

  # 3) 打印附加的托管策略并判断 AdministratorAccess
  local policies
  if policies="$(aws iam list-attached-role-policies --role-name "${role_name}" --output json 2>/dev/null)"; then
    echo "该角色附加的托管策略(managed policies):"
    echo "${policies}" | jq -r '.AttachedPolicies[] | "  - \(.PolicyName)  (\(.PolicyArn))"'
    if echo "${policies}" | jq -e '.AttachedPolicies[] | select(.PolicyName=="AdministratorAccess")' >/dev/null 2>&1; then
      green "权限自检通过：检测到 AdministratorAccess。"
    else
      yellow "警告：未检测到 AdministratorAccess 托管策略。"
      yellow "若后续 EKS/Karpenter 创建出现权限报错，请为本主机角色补齐创建 EKS 所需权限。"
    fi
    yellow "提示：当前只能读取到 attached managed policy，若最终结果不符合预期，请检查是否存在inline policy 与账户 SCP 边界限制。"
  else
    yellow "无法列出角色 ${role_name} 的附加策略(可能缺少 iam:ListAttachedRolePolicies 权限)。跳过。"
  fi
}

stage_tools() {
  title "阶段1：安装/更新依赖工具 + IAM 权限自检"
  if is_done "stage_tools"; then
    green "阶段1 已完成(断点标记存在)，跳过。如需重跑请删除 ${STATE_DIR}/stage_tools.done"
    # 即便跳过安装，也刷新一次 region 设置
    command -v aws >/dev/null 2>&1 && aws configure set region "${AWS_DEFAULT_REGION}" || true
    return
  fi
  install_base_pkg
  install_awscli
  install_eksctl
  install_kubectl
  install_helm
  ensure_path
  iam_self_check
  mark_done "stage_tools"
  record "阶段1  依赖工具安装 + IAM 权限自检   正常"
}

#############################################
#####  阶段2 CloudFormation + 一体化 eksctl 建集群  #####
#############################################

# 启用 Spot 服务关联角色(幂等前置；供 spot 节点组使用)
enable_spot_slr() {
  local role_name="AWSServiceRoleForEC2Spot"
  if aws iam get-role --role-name "${role_name}" >/dev/null 2>&1; then
    echo "Spot 服务关联角色已存在，跳过。"
  else
    echo "创建 Spot 服务关联角色..."
    aws iam create-service-linked-role --aws-service-name "spot.amazonaws.com" >/dev/null 2>&1 ||
      yellow "创建 Spot SLR 返回非0(可能已被占用)，忽略，不影响主流程。"
  fi
}

# 2a 创建 Karpenter CloudFormation 基础栈(含6条 IAM 策略 + 节点角色 + SQS 中断队列)
create_karpenter_cfn() {
  if is_done "stage_cfn"; then
    green "阶段2a CloudFormation 已完成，跳过。"
    return
  fi
  # 幂等：若栈已 CREATE_COMPLETE 则直接标记
  local stack="Karpenter-${CLUSTER_NAME}"
  local status
  status="$(aws cloudformation describe-stacks --stack-name "${stack}" --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "NONE")"
  if [ "${status}" == "CREATE_COMPLETE" ] || [ "${status}" == "UPDATE_COMPLETE" ]; then
    green "CloudFormation 栈 ${stack} 已存在(${status})，跳过创建。"
    mark_done "stage_cfn"
    return
  fi

  echo "******** 创建 Karpenter CloudFormation 基础环境(栈名: ${stack}) ********"
  local tempout="${STATE_DIR}/karpenter-cfn-${KARPENTER_VERSION}.yaml"
  curl -fsSL "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml" -o "${tempout}"

  aws cloudformation deploy \
    --stack-name "${stack}" \
    --template-file "${tempout}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides "ClusterName=${CLUSTER_NAME}"

  # 轮询确认(沿用历史脚本逻辑)
  local max=30 interval=10 count=0 ready=false
  while [ ${count} -lt ${max} ]; do
    status="$(aws cloudformation describe-stacks --stack-name "${stack}" --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo NONE)"
    if [ "${status}" == "CREATE_COMPLETE" ] || [ "${status}" == "UPDATE_COMPLETE" ]; then
      ready=true
      break
    elif [[ "${status}" == "CREATE_FAILED" || "${status}" == "ROLLBACK_COMPLETE" || "${status}" == *"FAILED"* ]]; then
      red "错误：堆栈状态异常 ${status}，创建 Karpenter CloudFormation 失败！"
      exit 1
    fi
    echo "当前状态: ${status}，等待 ${interval}s 后重试..."
    sleep ${interval}
    count=$((count + 1))
  done
  ${ready} || {
    red "错误：等待超时，CloudFormation 未完成。"
    exit 1
  }

  green "Karpenter CloudFormation 基础环境创建成功！"
  mark_done "stage_cfn"
  record "阶段2a Karpenter CloudFormation(6策略)   正常"
}

# 2b 一次性 eksctl create cluster：官方 Pod Identity 一体化流程
create_eks_cluster() {
  if is_done "stage_eks"; then
    green "阶段2b EKS 集群已完成，跳过。"
    return
  fi
  # 幂等：集群已 ACTIVE 则跳过
  local cstatus
  cstatus="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.status" --output text 2>/dev/null || echo NONE)"
  if [ "${cstatus}" == "ACTIVE" ]; then
    green "EKS 集群 ${CLUSTER_NAME} 已 ACTIVE，跳过创建。"
    aws eks --region "${AWS_DEFAULT_REGION}" update-kubeconfig --name "${CLUSTER_NAME}"
    mark_done "stage_eks"
    return
  fi

  local acct
  acct="$(aws sts get-caller-identity --query Account --output text)"

  echo "******** 创建 EKS 集群 ${CLUSTER_NAME} (版本 ${EKS_VERSION})  ********"
  eksctl create cluster -f - <<EOF
---
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_DEFAULT_REGION}
  version: "${EKS_VERSION}"
  tags:
    karpenter.sh/discovery: ${CLUSTER_NAME}
iam:
  withOIDC: true
  podIdentityAssociations:
    - namespace: "${KARPENTER_NAMESPACE}"
      serviceAccountName: karpenter
      roleName: ${CLUSTER_NAME}-karpenter
      permissionPolicyARNs:
        - arn:${AWS_PARTITION}:iam::${acct}:policy/KarpenterControllerNodeLifecyclePolicy-${CLUSTER_NAME}
        - arn:${AWS_PARTITION}:iam::${acct}:policy/KarpenterControllerIAMIntegrationPolicy-${CLUSTER_NAME}
        - arn:${AWS_PARTITION}:iam::${acct}:policy/KarpenterControllerEKSIntegrationPolicy-${CLUSTER_NAME}
        - arn:${AWS_PARTITION}:iam::${acct}:policy/KarpenterControllerInterruptionPolicy-${CLUSTER_NAME}
        - arn:${AWS_PARTITION}:iam::${acct}:policy/KarpenterControllerResourceDiscoveryPolicy-${CLUSTER_NAME}
        - arn:${AWS_PARTITION}:iam::${acct}:policy/KarpenterControllerZonalShiftPolicy-${CLUSTER_NAME}
iamIdentityMappings:
  - arn: "arn:${AWS_PARTITION}:iam::${acct}:role/KarpenterNodeRole-${CLUSTER_NAME}"
    username: system:node:{{EC2PrivateDNSName}}
    groups:
      - system:bootstrappers
      - system:nodes
vpc:
  id: ${VPC_ID}
  subnets:
    private:
      ${ZONE_1}: { id: ${PRIVATE_SUBNET_ZONE_1} }
      ${ZONE_2}: { id: ${PRIVATE_SUBNET_ZONE_2} }
    public:
      ${ZONE_1}: { id: ${PUBLIC_SUBNET_ZONE_1} }
      ${ZONE_2}: { id: ${PUBLIC_SUBNET_ZONE_2} }
managedNodeGroups:
  - name: ${CLUSTER_NAME}-ng
    instanceType: ${NODEGROUP_INSTANCE_TYPE}
    amiFamily: AmazonLinux2023
    desiredCapacity: 2
    minSize: 1
    maxSize: 10
    labels:
      node.k8s.te/billing-mode: on-demand
      node.k8s.te/nodepool-name: managednode
# zonalShiftConfig 是集群级(顶层)字段，与 managedNodeGroups/addons 同级，不能嵌在节点组内
zonalShiftConfig:
  enabled: ${ENABLE_ZONAL_SHIFT}
addons:
  - name: eks-pod-identity-agent
EOF

  # 校验创建结果
  cstatus="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.status" --output text 2>/dev/null || echo NONE)"
  if [ "${cstatus}" != "ACTIVE" ]; then
    red "错误：EKS 集群 ${CLUSTER_NAME} 状态为 ${cstatus}，创建未成功！请登录 EKS/CloudFormation 控制台确认。"
    exit 1
  fi

  # 刷新 kubeconfig，并限制预留 IP 数
  aws eks --region "${AWS_DEFAULT_REGION}" update-kubeconfig --name "${CLUSTER_NAME}"
  kubectl set env daemonset aws-node -n kube-system WARM_IP_TARGET="${WARM_IP_TARGET}" ||
    note_attention "阶段2b 设置 WARM_IP_TARGET 失败(非致命)，请稍后手动确认：kubectl set env daemonset aws-node -n kube-system WARM_IP_TARGET=${WARM_IP_TARGET}"

  green "EKS 集群 ${CLUSTER_NAME} 创建成功(ACTIVE)。"
  mark_done "stage_eks"
  record "阶段2b EKS 集群 ${CLUSTER_NAME}(v${EKS_VERSION})   正常"
}

# =============================================================================
# 阶段2 前置校验：在创建任何 AWS 资源前,先核对用户填写的 VPC / 子网 / 安全组 / 可用区
#   是否真实存在且彼此匹配,避免用错误参数跑到一半才失败(EKS 创建耗时~20min,失败代价高)。
#   校验项:
#     1) VPC 存在
#     2) AE 主机安全组存在,且属于该 VPC
#     3) 所有子网(2可用区public/private + AE主机子网)存在,且都属于该 VPC
#     4) 各可用区声明的子网,其实际 AZ 与声明一致(防止把 1a 的子网写到 1d 下)
#   任一不通过即 exit 1;全部通过打印"前置校验通过"。
# =============================================================================
preflight_validate() {
  title "阶段2 前置校验：VPC / 子网 / 安全组 / 可用区一致性"
  local errors=0

  # 1) VPC 存在
  if aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" >/dev/null 2>&1; then
    green "VPC 校验通过: ${VPC_ID} 存在。"
  else
    red "VPC 校验失败: 未找到 VPC ${VPC_ID}(请确认 VPC_ID 与地域 ${AWS_DEFAULT_REGION} 是否正确)。"
    errors=$((errors + 1))
  fi

  # 2) AE 主机安全组存在且属于该 VPC
  if [ -z "${AE_HOSTS_SG_ID// /}" ] || [ "${AE_HOSTS_SG_ID}" == "sg-000" ]; then
    red "安全组校验失败: AE_HOSTS_SG_ID 未填写(当前值: '${AE_HOSTS_SG_ID}')。请从 AWS 控制台确认 AE 主机绑定的安全组ID后填入。"
    errors=$((errors + 1))
  else
    local sg_vpc
    sg_vpc="$(aws ec2 describe-security-groups --group-ids "${AE_HOSTS_SG_ID}" --query 'SecurityGroups[0].VpcId' --output text 2>/dev/null || echo NONE)"
    if [ "${sg_vpc}" == "NONE" ] || [ -z "${sg_vpc}" ]; then
      red "安全组校验失败: 未找到安全组 ${AE_HOSTS_SG_ID}。"
      errors=$((errors + 1))
    elif [ "${sg_vpc}" != "${VPC_ID}" ]; then
      red "安全组校验失败: 安全组 ${AE_HOSTS_SG_ID} 属于 VPC ${sg_vpc},与集群 VPC ${VPC_ID} 不一致。"
      errors=$((errors + 1))
    else
      green "安全组校验通过: ${AE_HOSTS_SG_ID} 存在且属于 VPC ${VPC_ID}。"
    fi
  fi

  # 3+4) 子网存在 + 属于该 VPC + 实际 AZ 与声明一致
  # 校验单个子网:入参 子网ID 期望AZ(可空,空则只校验存在与归属VPC) 描述
  _check_subnet() {
    local sn="$1" expect_az="$2" desc="$3"
    if [ -z "${sn// /}" ]; then
      yellow "${desc}: 子网ID为空,跳过校验(若非有意留空请补填)。"
      return 0
    fi
    local info vpc az
    info="$(aws ec2 describe-subnets --subnet-ids "${sn}" --query 'Subnets[0].[VpcId,AvailabilityZone]' --output text 2>/dev/null || echo NONE)"
    if [ "${info}" == "NONE" ] || [ -z "${info}" ]; then
      red "${desc}校验失败: 未找到子网 ${sn}。"
      errors=$((errors + 1))
      return 0
    fi
    vpc="$(echo "${info}" | awk '{print $1}')"
    az="$(echo "${info}" | awk '{print $2}')"
    if [ "${vpc}" != "${VPC_ID}" ]; then
      red "${desc}校验失败: 子网 ${sn} 属于 VPC ${vpc},与集群 VPC ${VPC_ID} 不一致。"
      errors=$((errors + 1))
      return 0
    fi
    if [ -n "${expect_az}" ] && [ "${az}" != "${expect_az}" ]; then
      red "${desc}校验失败: 子网 ${sn} 实际可用区为 ${az},与声明的 ${expect_az} 不一致(请核对可用区与子网对应关系)。"
      errors=$((errors + 1))
      return 0
    fi
    green "${desc}校验通过: ${sn}(VPC ${vpc}, AZ ${az})。"
  }

  _check_subnet "${PUBLIC_SUBNET_ZONE_1}" "${ZONE_1}" "可用区1 public 子网"
  _check_subnet "${PRIVATE_SUBNET_ZONE_1}" "${ZONE_1}" "可用区1 private 子网"
  _check_subnet "${PUBLIC_SUBNET_ZONE_2}" "${ZONE_2}" "可用区2 public 子网"
  _check_subnet "${PRIVATE_SUBNET_ZONE_2}" "${ZONE_2}" "可用区2 private 子网"
  # AE 主机子网:只校验存在+归属VPC(不强绑某个声明AZ,它应落在上述可用区之一)
  _check_subnet "${AE_HOSTS_SUBNET_ID}" "" "AE 主机子网"

  if [ ${errors} -gt 0 ]; then
    red "前置校验未通过(${errors} 项失败)。请修正脚本顶部用户配置区参数后重跑,未创建任何资源。"
    exit 1
  fi
  green "前置校验通过：VPC / 子网 / 安全组 / 可用区一致性均正确。"
}

stage_eks() {
  title "阶段2：创建 Karpenter CloudFormation + 一体化 EKS 集群"
  aws configure set region "${AWS_DEFAULT_REGION}"
  preflight_validate
  enable_spot_slr
  create_karpenter_cfn
  create_eks_cluster
}

#############################################
##########  阶段3 helm 装 Karpenter  #########
#############################################

stage_karpenter() {
  title "阶段3：Helm 安装 Karpenter v${KARPENTER_VERSION}"
  if is_done "stage_karpenter"; then
    green "阶段3 已完成，跳过。"
    return
  fi

  # 确保 kubeconfig 指向目标集群
  aws eks --region "${AWS_DEFAULT_REGION}" update-kubeconfig --name "${CLUSTER_NAME}" >/dev/null

  echo "******** 部署参数 ********"
  echo "集群名: ${CLUSTER_NAME}"
  echo "集群端点: $(aws eks describe-cluster --name "${CLUSTER_NAME}" --query 'cluster.endpoint' --output text)"
  echo "Karpenter 版本: ${KARPENTER_VERSION}"
  echo "enableZonalShift: ${ENABLE_ZONAL_SHIFT}"
  echo "(Pod Identity 已在阶段2关联，helm 无需 role-arn 注解)"

  export HELM_EXPERIMENTAL_OCI=1
  helm registry logout public.ecr.aws >/dev/null 2>&1 || true
  helm upgrade --install karpenter "oci://public.ecr.aws/karpenter/karpenter" \
    --version "${KARPENTER_VERSION}" \
    --namespace "${KARPENTER_NAMESPACE}" --create-namespace \
    --set "settings.clusterName=${CLUSTER_NAME}" \
    --set "settings.interruptionQueue=${CLUSTER_NAME}" \
    --set "settings.enableZonalShift=${ENABLE_ZONAL_SHIFT}" \
    --set controller.resources.requests.cpu=1 \
    --set controller.resources.requests.memory=1Gi \
    --set controller.resources.limits.cpu=1 \
    --set controller.resources.limits.memory=1Gi \
    --wait

  # 检查 pod 运行状态
  echo "******** 检测 Karpenter 是否顺利启动 ******** "
  local timeout=120 elapsed=0 ready=false status
  sleep 5
  while [ ${elapsed} -lt ${timeout} ]; do
    status="$(kubectl get pods -n "${KARPENTER_NAMESPACE}" -l app.kubernetes.io/name=karpenter -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
    if [ "${status}" == "Running" ]; then
      ready=true
      break
    fi
    echo "等待 Karpenter Pod 启动... (状态: ${status:-未知})"
    sleep 5
    elapsed=$((elapsed + 5))
  done
  ${ready} || {
    red "错误：Karpenter Pod 未在 ${timeout}s 内 Running。请 kubectl describe pods -n ${KARPENTER_NAMESPACE} 排查。"
    exit 1
  }

  # 校验 CRD API 版本
  if [ "$(kubectl api-versions 2>/dev/null | grep -Ec '^karpenter.k8s.aws/v1$|^karpenter.sh/v1$')" -lt 2 ]; then
    red "错误：未检测到 karpenter.k8s.aws/v1 与 karpenter.sh/v1 两个 API，Karpenter 可能未就绪。"
    exit 1
  fi

  # Pod 明细仅上屏展示(不写入日志，避免收尾重复打印)
  kubectl get pods -n "${KARPENTER_NAMESPACE}" -l app.kubernetes.io/name=karpenter -o wide
  green "Karpenter v${KARPENTER_VERSION} 部署成功并就绪。"
  mark_done "stage_karpenter"
  record "阶段3  Karpenter v${KARPENTER_VERSION} 部署   正常"
}

# =============================================================================
# 阶段4：网络就绪
#   目标:让 Karpenter 扩容出的节点能被正确调度,且 ta 主机与 EKS 集群内网全流量互通。
#   动作:1) 给 ta 主机子网打 discovery-subnet 标签(节点绑相同子网,同可用区免跨区流量费)
#         2) 给 ShareNode 安全组打 discovery-sg 标签(节点组 EC2NodeClass 据此发现安全组)
#         3) ta 主机安全组 与 EKS 两个安全组(集群SG/ShareNode SG)双向放行全流量
#   幂等:create-tags 天然幂等;放行捕获 InvalidPermission.Duplicate 视为已存在。
# =============================================================================

# 记录本阶段所有打标签变更,供收尾汇总清晰说明做了什么(元素形如 "子网 subnet-xxx: 新增 key=val")
TAG_CHANGE_LOG=()

# 通用幂等打标签 helper:处理"无标签/已符合/值冲突"三种情况,并记录变更。
# 入参: res_type(subnet|security-group 用于describe) res_id tag_key desc(资源描述,如 "子网 subnet-xxx")
# 策略(用户规范):
#   1) 无该key标签        -> 直接打 CLUSTER_NAME 值,记"新增"
#   2) 有且值==CLUSTER_NAME -> 符合预期,不变更,记"已符合"
#   3) 有但值!=CLUSTER_NAME -> 阻塞!请客户确认:改为规范值 / 保留旧值(以客户判断为准),按选择记"覆盖"或"保留旧值"
apply_discovery_tag() {
  local res_type="$1" res_id="$2" tag_key="$3" desc="$4"
  # 读现有标签值
  local cur
  if [ "${res_type}" == "subnet" ]; then
    cur="$(aws ec2 describe-subnets --subnet-ids "${res_id}" --query "Subnets[0].Tags[?Key=='${tag_key}'].Value | [0]" --output text 2>/dev/null || echo NONE)"
  else
    cur="$(aws ec2 describe-security-groups --group-ids "${res_id}" --query "SecurityGroups[0].Tags[?Key=='${tag_key}'].Value | [0]" --output text 2>/dev/null || echo NONE)"
  fi

  # 情况2:已存在且符合预期
  if [ "${cur}" == "${CLUSTER_NAME}" ]; then
    green "${desc}: 已存在标签 ${tag_key}=${cur},符合预期,不再变更。"
    TAG_CHANGE_LOG+=("${desc}: 已符合 ${tag_key}=${CLUSTER_NAME}(未变更)")
    return 0
  fi

  # 情况3:已存在但值 != 集群名
  if [ -n "${cur}" ] && [ "${cur}" != "None" ] && [ "${cur}" != "NONE" ]; then
    if [ "${res_type}" == "subnet" ]; then
      # 子网:节点组【只按标签key匹配、不引用value】(见 auto_build_nodepool.sh subnetSelectorValue="*")。
      # 故 value 与本集群名不一致【不影响功能】,仅警告不覆盖、不交互、不退出(多集群共用子网时这是常态)。
      yellow "${desc}: 已有标签 ${tag_key}=${cur}(非本集群名 ${CLUSTER_NAME})。"
      yellow "因节点组只按标签 key 匹配子网、不引用 value,此差异【不影响】本集群节点发现该子网,保留旧值不变更。"
      TAG_CHANGE_LOG+=("${desc}: 保留旧值 ${tag_key}=${cur}(只按key匹配,不影响功能)")
      return 0
    fi
    # 安全组:精确匹配 key=集群名,value 冲突需阻塞请客户确认
    yellow "${desc}: 检测到已有标签 ${tag_key}=${cur},与规范值(${CLUSTER_NAME})不一致!"
    yellow "建议按最新规范改为 ${tag_key}=${CLUSTER_NAME};若坚持保留旧值,则该资源可能无法被本集群节点组发现。"
    local ans
    read -p "  是否覆盖为规范值 ${CLUSTER_NAME}? (y=覆盖为规范值 / n=保留旧值${cur}) <y/n> " ans
    ans="$(echo "${ans}" | tr '[:upper:]' '[:lower:]')"
    if [ "${ans}" != "y" ]; then
      yellow "已保留旧值 ${tag_key}=${cur}(以客户判断为准)。"
      TAG_CHANGE_LOG+=("${desc}: 保留旧值 ${tag_key}=${cur}(客户坚持,未按规范覆盖,可能影响节点组发现)")
      return 0
    fi
    # 覆盖(create-tags 对同key直接覆盖value)
    if ! aws ec2 create-tags --resources "${res_id}" --tags "Key=${tag_key},Value=${CLUSTER_NAME}" 2>/dev/null; then
      red "${desc}: 覆盖标签失败,请确认权限(ec2:CreateTags)。"
      exit 1
    fi
    green "${desc}: 已覆盖为 ${tag_key}=${CLUSTER_NAME}(原值 ${cur})。"
    TAG_CHANGE_LOG+=("${desc}: 覆盖 ${tag_key} ${cur} -> ${CLUSTER_NAME}")
  else
    # 情况1:无该key标签 -> 新增
    if ! aws ec2 create-tags --resources "${res_id}" --tags "Key=${tag_key},Value=${CLUSTER_NAME}" 2>/dev/null; then
      red "${desc}: 打标签失败,请确认资源id正确且本主机有 ec2:CreateTags 权限。"
      exit 1
    fi
    green "${desc}: 新增标签 ${tag_key}=${CLUSTER_NAME}。"
    TAG_CHANGE_LOG+=("${desc}: 新增 ${tag_key}=${CLUSTER_NAME}")
  fi

  # 统一回读校验(保留旧值的情况已在上面 return,不到这里)
  local v
  if [ "${res_type}" == "subnet" ]; then
    v="$(aws ec2 describe-subnets --subnet-ids "${res_id}" --query "Subnets[0].Tags[?Key=='${tag_key}'].Value | [0]" --output text 2>/dev/null || echo NONE)"
  else
    v="$(aws ec2 describe-security-groups --group-ids "${res_id}" --query "SecurityGroups[0].Tags[?Key=='${tag_key}'].Value | [0]" --output text 2>/dev/null || echo NONE)"
  fi
  if [ "${v}" != "${CLUSTER_NAME}" ]; then
    red "${desc}: 标签回读校验失败(期望 ${CLUSTER_NAME},实际 ${v})。"
    exit 1
  fi
}

# 幂等地为 target 安全组放行来自 source 安全组的全流量(--protocol -1 = 所有协议所有端口)
sg_allow_all_from() {
  local target="$1" source="$2" out
  if out="$(aws ec2 authorize-security-group-ingress --group-id "${target}" --protocol -1 --source-group "${source}" 2>&1)"; then
    green "已放行: ${target} <- ${source} (全流量)"
  elif echo "${out}" | grep -q "InvalidPermission.Duplicate"; then
    green "已存在放行规则(幂等跳过): ${target} <- ${source}"
  else
    red "放行失败: ${target} <- ${source} : ${out}"
    return 1
  fi
}

# 给 ta 主机子网打 discovery-subnet 标签
tag_ta_host_subnets() {
  echo "---- 4.1 给 ta 主机子网打发现标签(${SUBNET_DISCOVERY_KEY}=${CLUSTER_NAME}) ----"
  if [ -z "${AE_HOSTS_SUBNET_ID// /}" ]; then
    note_attention "阶段4 AE_HOSTS_SUBNET_ID 为空,已跳过子网打标签。请手动执行:aws ec2 create-tags --resources <ta主机子网id> --tags Key=${SUBNET_DISCOVERY_KEY},Value=${CLUSTER_NAME}"
    return 0
  fi
  local sn
  for sn in ${AE_HOSTS_SUBNET_ID}; do
    apply_discovery_tag "subnet" "${sn}" "${SUBNET_DISCOVERY_KEY}" "子网 ${sn}"
  done
}

# 定位并给 ShareNode 安全组打 discovery-sg 标签;导出 SG_SHARENODE 供放行阶段复用
tag_sharenode_sg() {
  echo "---- 4.2 给 ShareNode 安全组打发现标签(${SG_DISCOVERY_KEY}=${CLUSTER_NAME}) ----"
  # 精确定位:eksctl 的 ShareNode 安全组命名为 eksctl-<集群名>-cluster-ClusterSharedNodeSecurityGroup-<随机码>。
  # 【重要】同一 VPC 可能存在多个集群的 ClusterSharedNodeSecurityGroup,必须用【集群名前缀】精确匹配,
  # 否则仅按 *ClusterSharedNodeSecurityGroup* + vpc-id 过滤会命中其他集群的安全组(已在ta3多集群环境实测踩坑)。
  SG_SHARENODE="$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=eksctl-${CLUSTER_NAME}-cluster-ClusterSharedNodeSecurityGroup*" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo NONE)"
  if [ -z "${SG_SHARENODE}" ] || [ "${SG_SHARENODE}" == "None" ] || [ "${SG_SHARENODE}" == "NONE" ]; then
    red "错误:未能在 VPC ${VPC_ID} 中定位到集群 ${CLUSTER_NAME} 的 ShareNode 安全组(eksctl-${CLUSTER_NAME}-cluster-ClusterSharedNodeSecurityGroup*)。请确认 EKS 已创建成功。"
    exit 1
  fi
  echo "ShareNode 安全组: ${SG_SHARENODE}"
  apply_discovery_tag "security-group" "${SG_SHARENODE}" "${SG_DISCOVERY_KEY}" "ShareNode安全组 ${SG_SHARENODE}"
}

# 交互确定 ta 主机安全组(安全组1),输出到全局 TA_HOST_SG_IDS(可多个,空格分隔)
resolve_ta_host_sg() {
  echo "---- 4.3 确定 ta 主机安全组 (确认后，进行ta 主机安全组和eks安全组相互放行操作)----"
  # 直接采用用户在脚本顶部配置区填写的 AE_HOSTS_SG_ID(已在阶段2前置校验中确认存在且属于本 VPC)。
  # 不再在执行机上探测 IMDS/交互确认:线上实践表明执行机未必是 ta 主机,且探测易误判,
  # 故与"子网打标签"一致,统一要求管理员在信息收集环节采集准确的 ta 主机安全组ID。
  TA_HOST_SG_IDS="${AE_HOSTS_SG_ID}"
  if [ -z "${TA_HOST_SG_IDS// /}" ]; then
    red "错误:AE_HOSTS_SG_ID 为空,无法完成安全组彼此放行。请在脚本顶部配置区填写 ta 主机安全组ID后重跑(删除 ${STATE_DIR}/stage_network.done)。"
    exit 1
  fi
  echo "采用配置的 ta 主机安全组: ${TA_HOST_SG_IDS}"
}

# 三个安全组彼此放行:仅补 ta主机SG(SG1) 与 EKS两个SG(集群SG/ShareNode SG) 的双向放行
open_security_groups() {
  echo "---- 4.4 安全组彼此放行(ta主机 <-> EKS 集群) ----"
  # 安全组2:EKS 集群安全组
  local sg_cluster
  sg_cluster="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text 2>/dev/null || echo NONE)"
  if [ -z "${sg_cluster}" ] || [ "${sg_cluster}" == "None" ] || [ "${sg_cluster}" == "NONE" ]; then
    red "错误:未能获取 EKS 集群安全组(clusterSecurityGroupId)。"
    exit 1
  fi
  # 安全组3:ShareNode SG(tag_sharenode_sg 已解析并导出)
  local sg_share="${SG_SHARENODE}"
  echo "EKS 集群安全组(SG2): ${sg_cluster}"
  echo "ShareNode 安全组(SG3): ${sg_share}"
  echo "ta 主机安全组(SG1): ${TA_HOST_SG_IDS}"

  local ta_sg
  for ta_sg in ${TA_HOST_SG_IDS}; do
    # ta主机 -> EKS(EKS 侧放行来自 ta 主机)
    sg_allow_all_from "${sg_cluster}" "${ta_sg}"
    sg_allow_all_from "${sg_share}" "${ta_sg}"
    # EKS -> ta主机(ta 主机侧放行来自 EKS 两个安全组)
    sg_allow_all_from "${ta_sg}" "${sg_cluster}"
    sg_allow_all_from "${ta_sg}" "${sg_share}"
  done
}

stage_network() {
  title "阶段4：网络就绪(子网/安全组打标签 + 安全组彼此放行)"
  if is_done "stage_network"; then
    green "阶段4 已完成，跳过。如需重跑请删除 ${STATE_DIR}/stage_network.done"
    return
  fi
  aws configure set region "${AWS_DEFAULT_REGION}"

  tag_ta_host_subnets
  tag_sharenode_sg
  resolve_ta_host_sg
  open_security_groups

  # 打标签变更清单:清晰说明本次对子网/安全组做了哪些标签变更(新增/已符合/覆盖/保留旧值)
  echo ""
  echo "---- 4.5 打标签变更清单 ----"
  if [ ${#TAG_CHANGE_LOG[@]} -eq 0 ]; then
    echo "(本次无打标签动作)"
  else
    local chg
    for chg in "${TAG_CHANGE_LOG[@]}"; do
      echo "- ${chg}"
      record "阶段4 打标签: ${chg}"
    done
  fi

  mark_done "stage_network"
  record "阶段4  网络就绪(打标签+安全组放行)   正常"
  green "阶段4 网络就绪完成。"
}

# =============================================================================
# 阶段5：EKS 功能可用性验证(pod 起服 + 网络连通)
#   背景:EKS 创建与业务节点组创建是异步的两件事。此阶段在 EKS 刚建好时【立即】验证集群基本功能,
#         及早发现问题(镜像拉取、pod 调度、容器网络),避免问题流转到后续业务节点组层(auto_build_nodepool.sh)。
#   验证对象:eksctl 建出的托管节点组(此时已有就绪节点),直接调度一个 nginx 测试 pod。
#   参考 auto_build_nodepool.sh 的 test_nodepool,精简为不依赖 karpenter 节点组标签/污点的通用验证。
# =============================================================================
VERIFY_NAMESPACE="${VERIFY_NAMESPACE:-eks-verify}"
VERIFY_NGINX_IMAGE="${VERIFY_NGINX_IMAGE:-nginx:1.20}"
VERIFY_NGINX_IMAGE_CN="${VERIFY_NGINX_IMAGE_CN:-docker-ta.thinkingdata.cn/te/nginx:1.20}"

# 清理验证资源(收尾/失败退出前调用)
cleanup_verify() {
  kubectl delete deployment eks-verify-nginx -n "${VERIFY_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete namespace "${VERIFY_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
}

stage_verify() {
  title "阶段5：EKS 功能可用性验证(pod 起服 + 网络连通)"
  if is_done "stage_verify"; then
    green "阶段5 已完成，跳过。如需重跑请删除 ${STATE_DIR}/stage_verify.done"
    return
  fi
  aws eks --region "${AWS_DEFAULT_REGION}" update-kubeconfig --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true

  # 中国区优先用团队镜像仓库,规避 docker hub 拉取失败
  local img="${VERIFY_NGINX_IMAGE}"
  if [[ "${AWS_DEFAULT_REGION}" =~ ^cn- ]]; then
    img="${VERIFY_NGINX_IMAGE_CN}"
  fi

  echo "确保验证命名空间存在: ${VERIFY_NAMESPACE}"
  kubectl get ns "${VERIFY_NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${VERIFY_NAMESPACE}" >/dev/null 2>&1

  echo "*** 验证项1: 在托管节点组上调度并启动 nginx 测试 pod(镜像: ${img}) ***"
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: eks-verify-nginx
  namespace: ${VERIFY_NAMESPACE}
  labels:
    app: eks-verify-nginx
spec:
  replicas: 1
  selector:
    matchLabels:
      app: eks-verify-nginx
  template:
    metadata:
      labels:
        app: eks-verify-nginx
    spec:
      containers:
      - name: nginx
        image: ${img}
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5
EOF

  # 等待 pod Running(EKS 刚建好,镜像首拉可能稍久,给 180s)
  echo "等待测试 pod 启动(最多 180s)..."
  local timeout=180 elapsed=0 ready=false pod_name pod_ip status
  sleep 5
  while [ ${elapsed} -lt ${timeout} ]; do
    status="$(kubectl get pods -n "${VERIFY_NAMESPACE}" -l app=eks-verify-nginx -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
    if [ "${status}" == "Running" ]; then
      # 再确认 readiness 就绪
      local rdy
      rdy="$(kubectl get pods -n "${VERIFY_NAMESPACE}" -l app=eks-verify-nginx -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)"
      if [ "${rdy}" == "true" ]; then
        ready=true
        pod_name="$(kubectl get pods -n "${VERIFY_NAMESPACE}" -l app=eks-verify-nginx -o jsonpath='{.items[0].metadata.name}')"
        pod_ip="$(kubectl get pods -n "${VERIFY_NAMESPACE}" -l app=eks-verify-nginx -o jsonpath='{.items[0].status.podIP}')"
        green "测试 pod 已就绪。Pod: ${pod_name}  IP: ${pod_ip}"
        break
      fi
    fi
    echo "等待 pod 就绪...(状态: ${status:-未知}, 已等待 ${elapsed}s)"
    sleep 5
    elapsed=$((elapsed + 5))
  done

  if ! ${ready}; then
    red "错误：EKS 功能验证失败——测试 pod 未在 ${timeout}s 内就绪。常见原因(按概率):"
    red "1. 节点无法拉取镜像(不通外网/镜像仓库),排查: kubectl describe pod -n ${VERIFY_NAMESPACE} -l app=eks-verify-nginx"
    red "2. 托管节点组无就绪节点或不可调度: kubectl get nodes"
    red "3. 节点网络/CNI 异常: kubectl get pods -n kube-system"
    kubectl get pods -n "${VERIFY_NAMESPACE}" -l app=eks-verify-nginx -o wide 2>/dev/null || true
    cleanup_verify
    exit 1
  fi
  green "验证项1 通过：pod 成功调度并起服。"

  echo "*** 验证项2: 云主机访问 pod 容器网络是否通畅(curl pod IP) ***"
  if curl -s -m 10 "http://${pod_ip}" | grep -q "Welcome to nginx!"; then
    green "验证项2 通过：云主机访问 pod 容器网络通畅。"
  else
    # 网络连通受执行机与集群是否同 VPC/安全组放行影响,失败给明确提示并按失败处理
    red "错误：EKS 功能验证失败——云主机无法访问 pod 容器(http://${pod_ip})。可能原因:"
    red "1. 执行主机与 EKS 节点非同 VPC/网段(pod IP 不可达)"
    red "2. 安全组未放行(阶段4 若跳过或未覆盖执行机安全组)"
    red "排查: 在执行机 curl -v http://${pod_ip} ; 确认执行机与集群节点同内网并已彼此放行"
    cleanup_verify
    exit 1
  fi

  cleanup_verify
  green "验证测试资源已清理。"
  mark_done "stage_verify"
  record "阶段5  EKS 功能可用性验证(pod起服+网络连通)   正常"
  green "阶段5 EKS 功能可用性验证通过。"
}

print_plan() {
  echo ""
  echo -e "\e[1m$(_banner_line " 执行计划 ")\e[0m"
  cat <<PLAN
阶段1: 安装/更新 awscli、eksctl、kubectl、helm + 云主机 IAM 权限自检
阶段2: 创建 EKS ${EKS_VERSION}
阶段3: 创建 Karpenter ${KARPENTER_VERSION}
阶段4: 网络就绪(ta主机子网/ShareNode安全组打发现标签 + ta主机与EKS安全组彼此放行全流量)
阶段5: EKS功能可用性验证(pod起服 + 云主机访问容器网络连通)

目标集群: ${CLUSTER_NAME}   地域: ${AWS_DEFAULT_REGION}
状态目录: ${STATE_DIR}(删除对应 *.done 可强制重跑该阶段)
PLAN
  echo -e "\e[1m$(_banner_rule)\e[0m"
  echo ""
}

# 收尾对账：逐阶段对比断点标记，判定 正常/异常，并汇总"关注"项
print_summary() {
  title "结果汇总"
  local stages=(
    "stage_tools|阶段1  依赖工具 + IAM 权限自检"
    "stage_cfn|阶段2a Karpenter CloudFormation(6策略)"
    "stage_eks|阶段2b EKS 集群 ${CLUSTER_NAME}(v${EKS_VERSION})"
    "stage_karpenter|阶段3  Karpenter v${KARPENTER_VERSION} 部署"
    "stage_network|阶段4  网络就绪(子网/安全组打标签+安全组彼此放行)"
    "stage_verify|阶段5  EKS功能可用性验证(pod起服+网络连通)"
  )
  local entry key desc st
  for entry in "${stages[@]}"; do
    key="${entry%%|*}"
    desc="${entry#*|}"
    if is_done "${key}"; then st="\e[32m正常\e[0m"; else st="\e[31m异常\e[0m"; fi
    echo -e "$(_pad_disp "${desc}" $((BANNER_WIDTH - 6)))${st}"
  done

  # 关注项(非致命告警)
  if [ -s "${ATTENTION_FILE}" ]; then
    echo ""
    yellow "需关注(非致命):"
    while IFS= read -r line; do echo -e "\e[33m- ${line}\e[0m"; done <"${ATTENTION_FILE}"
  fi
  echo -e "\e[1m$(_banner_rule)\e[0m"
  echo "日志文件: ${RESULT_FILE}"
}

main() {
  # 收尾(含异常/中断)恢复主机默认 yum 源配置
  trap restore_yum_repos EXIT
  print_plan
  stage_tools
  stage_eks
  stage_karpenter
  stage_network
  stage_verify

  print_summary
  green "EKS ${EKS_VERSION} + Karpenter ${KARPENTER_VERSION} 创建完成。"
  echo "下一步：使用 auto_build_nodepool.sh 创建业务节点组并做可用性测试。"
}

main "$@"
