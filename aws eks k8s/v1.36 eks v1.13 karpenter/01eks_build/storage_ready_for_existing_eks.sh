#!/bin/bash
# =============================================================================
# storage_ready_for_existing_eks.sh
# 适用场景：为【已存在】的 AWS EKS 集群补齐 EBS / EFS 存储能力(存量集群补存储)。
# 注意事项：
# 1. 管理员需从 AWS 控制台确认并在下方配置区手填 4 项(region/VPC/集群名/AE子网);
# 2. 如果存量EKS版本并非1.36，则需要手动修改脚本中KUBECTL_VERSION值为真实版本！
# 脚本计划：
#     阶段1 安装/更新依赖工具 + 调用者身份打印
#     阶段2 前置校验(集群 ACTIVE / VPC 一致 / kubectl 可达 / AE子网归属 / Pod Identity Agent)
#     阶段3 存储就绪(EBS/EFS CSI 驱动 + EFS 文件系统 + StorageClass te-disk/te-nfs)
#     阶段4 存储就绪性校验(SC / CSI 驱动 / EFS 挂载目标；可选 PVC+Pod 端到端实测)
# 适用：x86_64 / aarch64；常见 Linux(Amazon Linux 2023 / Rocky9 / CentOS 等)。
# =============================================================================

# 确保以【非 POSIX 模式的 bash】运行,当用户以 `sh 脚本` 启动时,/bin/sh 即使链接到 bash,也会进入 POSIX 兼容模式。
if [ -z "${_STORAGE_READY_REEXEC:-}" ]; then
  export _STORAGE_READY_REEXEC=1
  exec bash "$0" "$@"
fi

set -euo pipefail

###############################################################################
# 用户配置区START（AWS管理员需收集如下4项信息，覆盖后执行脚本）
###############################################################################
#【必填】已存在的 EKS 集群名
CLUSTER_NAME="${CLUSTER_NAME:-}"

#【必填】EKS 集群所在地域
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-}"

#【必填】EKS 集群所在 VPC 的 ID(脚本会校验与集群实际 VPC 一致)
VPC_ID="${VPC_ID:-}"

#【必填】AE 主机(主力业务节点)绑定的子网 ID。将并入 EFS 挂载目标的可用区覆盖,
#        确保主力业务 Pod 所在可用区能挂载 EFS。多个用空格分隔。
AE_HOSTS_SUBNET_ID="${AE_HOSTS_SUBNET_ID:-}"

###############################################################################
# 用户配置区END（必须AWS管理员收集如下4项准确信息并覆盖脚本）
###############################################################################

###############################################################################
# 默认参数区（该章节及以下内容一般不需要改动）
###############################################################################

#===== 其他官方参数 =====
# 中国区需改为 aws-cn 、 GovCloud 改为 aws-us-gov
AWS_PARTITION="${AWS_PARTITION:-aws}"

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

#===== 存储就绪(EBS/EFS CSI + StorageClass) 相关 =====
# CSI 驱动以 EKS addon 形式安装,通过 Pod Identity 关联 IAM 策略。
EBS_CSI_ADDON_NAME="${EBS_CSI_ADDON_NAME:-aws-ebs-csi-driver}"
EFS_CSI_ADDON_NAME="${EFS_CSI_ADDON_NAME:-aws-efs-csi-driver}"
# addon 版本留空 = 让 eksctl 自动选与集群版本匹配的默认版本(推荐);需锁版时用环境变量覆盖。
EBS_CSI_ADDON_VERSION="${EBS_CSI_ADDON_VERSION:-}"
EFS_CSI_ADDON_VERSION="${EFS_CSI_ADDON_VERSION:-}"
# CSI controller 的 ServiceAccount 名(官方固定值,Pod Identity 关联的就是它)
EBS_CSI_SA="${EBS_CSI_SA:-ebs-csi-controller-sa}"
EFS_CSI_SA="${EFS_CSI_SA:-efs-csi-controller-sa}"
# AWS 托管策略 ARN。中国区(aws-cn)/GovCloud 需自行确认该托管策略可用。
# 注:EBS 用 AmazonEBSCSIDriverPolicy(商业区托管策略,已在 us-east-1 实证存在);
#    AmazonEBSCSIDriverPolicyV2 在商业区不存在(NoSuchEntity),勿用。
EBS_CSI_POLICY_ARN="${EBS_CSI_POLICY_ARN:-arn:${AWS_PARTITION}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy}"
EFS_CSI_POLICY_ARN="${EFS_CSI_POLICY_ARN:-arn:${AWS_PARTITION}:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy}"

# EFS 文件系统与 StorageClass 参数(默认名沿用数数文档: te-disk / te-nfs)
EFS_NAME="${EFS_NAME:-te-nfs}"
EFS_PERFORMANCE_MODE="${EFS_PERFORMANCE_MODE:-generalPurpose}"
EFS_DIR_PERMS="${EFS_DIR_PERMS:-700}"
SC_DISK_NAME="${SC_DISK_NAME:-te-disk}"
SC_NFS_NAME="${SC_NFS_NAME:-te-nfs}"
SC_DISK_TYPE="${SC_DISK_TYPE:-gp3}"
SC_DISK_FSTYPE="${SC_DISK_FSTYPE:-ext4}"
# 默认 SC 抢占: 摘掉"非该前缀开头"的 default SC 注解,再把 te-disk 设为唯一 default。
DEFAULT_SC_PREFIX="${DEFAULT_SC_PREFIX:-te}"
# 轮询超时(秒)
EFS_WAIT_TIMEOUT="${EFS_WAIT_TIMEOUT:-300}"
ADDON_WAIT_TIMEOUT="${ADDON_WAIT_TIMEOUT:-300}"
# 端到端实测开关：默认【开启】——以"PVC 能挂载 + Pod 能起服 + 卷可读写"作为存储层就绪判据。
# 临时跳过可传 STORAGE_E2E_TEST=false。
STORAGE_E2E_TEST="${STORAGE_E2E_TEST:-true}"

# 验证阶段命名空间与镜像(端到端实测用)。用轻量 busybox 起服+读写探针,公共 ECR 源避免 docker hub 限流。
VERIFY_NAMESPACE="${VERIFY_NAMESPACE:-eks-verify}"
VERIFY_E2E_IMAGE="${VERIFY_E2E_IMAGE:-public.ecr.aws/docker/library/busybox:1.36}"
# 单个 e2e 测试 Pod 就绪超时(秒)。EFS access point 首挂偶尔稍久,给足余量。
E2E_WAIT_TIMEOUT="${E2E_WAIT_TIMEOUT:-180}"

#############################################
###########  运行时变量与辅助函数  ###########
#############################################

# 系统架构(工具下载依赖)
ARCH="$(uname -m)"

# 本脚本不使用 .done 断点：补存储各步骤秒级且 AWS 侧实态幂等已足够(addon 查 ACTIVE 跳过 /
# EFS creation-token 查重 / 挂载目标按可用区去重 / SC 存在跳过),失败直接重跑即可。
# 仍保留一个临时目录用于下载与关注项收集。
STATE_DIR="${STATE_DIR:-./.storage_ready_state}"
mkdir -p "${STATE_DIR}"

# 结果/日志文件
RESULT_FILE="${STATE_DIR}/storage_ready_result_$(date +'%Y-%m-%d-%H-%M-%S').log"
echo "storage-ready start time：$(date +'%Y-%m-%d %H:%M:%S')" >>"${RESULT_FILE}"

# ===== 全量输出同步到日志文件(终端保留彩色,文件剥离 ANSI 色码) =====
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

# 交互式 Y/N 询问。从 /dev/tty 读取,即使 stdin 被 heredoc/管道占用(eksctl
# create addon 用 heredoc 喂配置)也能正常与执行者交互。
#   入参: 提示语。返回: 0=Yes / 1=No。
#   安全优先:直接回车视为 No;无终端可交互(CI/后台)也视为 No,绝不擅自做破坏性清理。
ask_yes_no() {
  local prompt="$1" ans
  if [ ! -e /dev/tty ]; then
    yellow "非交互环境(无 /dev/tty),默认选择 No(不清理)。"
    return 1
  fi
  while true; do
    printf "\e[33m%s [y/N]: \e[0m" "${prompt}" >/dev/tty
    read -r ans </dev/tty || { echo >/dev/tty; return 1; }
    case "${ans}" in
    y | Y | yes | YES) return 0 ;;
    n | N | no | NO | "") return 1 ;;
    *) echo "请输入 y 或 n。" >/dev/tty ;;
    esac
  done
}

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
    # 已安装：先比对版本，已是目标版则跳过(与 eksctl 幂等口径一致，避免无谓的备份+下载)
    local cur
    cur="$(kubectl version --client 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [ "${cur}" = "${KUBECTL_VERSION}" ]; then
      green "kubectl ******** 检测已部署且已是目标版本 ${cur}，跳过 ******** "
      return
    fi
    echo "kubectl ******** 检测到已安装 ${cur:-未知版本}，与目标 ${KUBECTL_VERSION} 不一致，备份后替换 ******** "
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

# 轻量身份自检：打印调用者身份 + 补存储所需权限清单(不强制 AdministratorAccess)。
identity_check() {
  title "调用者身份 + 所需权限提示"
  aws configure set region "${AWS_DEFAULT_REGION}"
  local ident
  if ! ident="$(aws sts get-caller-identity --output json 2>&1)"; then
    red "无法执行 aws sts get-caller-identity，请确认本主机已绑定 IAM 角色/配置凭证："
    echo "${ident}"
    exit 1
  fi
  echo "当前调用者身份 Arn: $(echo "${ident}" | jq -r '.Arn')"
  echo "所属账号: $(echo "${ident}" | jq -r '.Account')"
  cat <<'TIP'
补存储所需 AWS 权限(供管理员参考,权限不足会在对应步骤自然报错)：
  eks:DescribeCluster/DescribeAddon/CreateAddon/ListAddons
  eks:CreatePodIdentityAssociation/DescribePodIdentityAssociation
  iam:CreateRole/AttachRolePolicy/GetRole  (eksctl 建 Pod Identity 角色用)
  ec2:DescribeSubnets/DescribeSecurityGroups
  elasticfilesystem:CreateFileSystem/DescribeFileSystems/CreateMountTarget/DescribeMountTargets/CreateTags
  复用托管策略 AmazonEBSCSIDriverPolicy / AmazonEFSCSIDriverPolicy (由 eksctl 关联)
TIP
}

stage_tools() {
  title "阶段1：安装/更新依赖工具 + 调用者身份"
  install_base_pkg
  install_awscli
  install_eksctl
  install_kubectl
  install_helm
  ensure_path
  identity_check
  record "阶段1  依赖工具安装 + 身份打印   正常"
}

#############################################
#######  存储辅助函数(与整合脚本阶段5同源)  #######
#############################################

# 检测并(交互确认后)清理残留的 Pod Identity 角色 CloudFormation 栈。
#   入参: addon名 SA名。命中残留且执行者确认 Y 才清理;N 或非交互则终止(不擅自删)。
#   栈名遵循 eksctl 固定命名: eksctl-<集群>-addon-<addon>-podidentityrole-<sa>
preflight_podidentity_stack() {
  local addon="$1" sa="$2"
  local stack="eksctl-${CLUSTER_NAME}-addon-${addon}-podidentityrole-${sa}"
  local sstatus
  sstatus="$(aws cloudformation describe-stacks --region "${AWS_DEFAULT_REGION}" \
    --stack-name "${stack}" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE)"
  # 未残留(正常首次安装)直接返回,不打扰执行者
  [ "${sstatus}" == "NONE" ] && return 0

  red "检测到堆栈冲突：即将安装 addon ${addon},但其 Pod Identity 角色栈已残留。"
  echo "  冲突栈名   : ${stack}"
  echo "  当前状态   : ${sstatus}"
  echo "  成因       : 该 addon 曾被安装过,后来(常见于控制台手动)删除了 addon 本体,"
  echo "               但 eksctl 建的这个 IAM 角色栈不会被控制台连带删除,成了孤儿。"
  echo "               eksctl create addon 会因同名栈已存在而报 AlreadyExistsException 硬失败。"
  echo "  清理目标   : 仅删除上面这一个精确命名的孤儿栈(禁用其删除保护→删栈→等待完成)。"
  echo "  连带影响   : 该栈只含 ${sa} 的 Pod Identity IAM 角色;因对应 addon 与 association"
  echo "               均已不存在,此角色是孤儿,删除安全,不影响集群/网络/其他 addon。"
  echo "  不会触碰   : 集群主栈、节点组栈、vpc-cni 等其他 eksctl 栈一律不动。"
  echo "  选择 N 的后果: 保留现状并【终止脚本】(不安装该 addon);你可自行处理后再重跑。"

  if ! ask_yes_no "是否清理该残留栈后继续安装 ${addon}?"; then
    red "执行者选择不清理,终止。可手动处理该栈后重跑,或联系管理员。"
    exit 1
  fi

  echo "禁用栈删除保护: ${stack} ..."
  aws cloudformation update-termination-protection --region "${AWS_DEFAULT_REGION}" \
    --no-enable-termination-protection --stack-name "${stack}" >/dev/null
  echo "删除栈: ${stack} ..."
  aws cloudformation delete-stack --region "${AWS_DEFAULT_REGION}" --stack-name "${stack}"
  echo "等待栈删除完成(约 30~60s)..."
  aws cloudformation wait stack-delete-complete --region "${AWS_DEFAULT_REGION}" \
    --stack-name "${stack}"
  green "残留栈 ${stack} 已清理,继续安装 addon ${addon}。"
}

# 幂等安装一个 CSI addon(Pod Identity 关联 IAM 策略)。入参: addon名 SA名 策略ARN 版本(可空)
ensure_addon() {
  local name="$1" sa="$2" policy="$3" ver="$4" st
  st="$(aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name "${name}" \
    --query 'addon.status' --output text 2>/dev/null || echo NONE)"
  if [ "${st}" == "ACTIVE" ]; then
    green "addon ${name} 已 ACTIVE，跳过安装。"
    return 0
  fi
  if [ "${st}" == "NONE" ]; then
    echo "安装 addon ${name}(Pod Identity 关联 ${policy})..."
    # 安装前先处理【残留的 Pod Identity 角色 CloudFormation 栈】冲突(存量场景常见:
    # 管理员从控制台删过 addon,但 eksctl 建的 podidentityrole 栈不会被控制台连带删除,
    # 下次 eksctl create addon 会因同名栈 AlreadyExistsException 硬失败)。
    preflight_podidentity_stack "${name}" "${sa}"
    # 用【配置文件】方式安装:eksctl 的 `create addon` 命令行【没有】--pod-identity-associations 标志
    # (该字段只存在于 ClusterConfig 配置文件里;命令行传会报 unknown flag)。
    # 配置文件方式让 eksctl 自动建 Pod Identity 角色并关联,精确保留我们指定的 policy ARN。
    local verline=""
    [ -n "${ver}" ] && verline=$'\n'"    version: \"${ver}\""
    eksctl create addon -f - <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_DEFAULT_REGION}
addons:
  - name: ${name}${verline}
    podIdentityAssociations:
      - namespace: kube-system
        serviceAccountName: ${sa}
        permissionPolicyARNs:
          - ${policy}
EOF
  else
    echo "addon ${name} 当前状态 ${st}，等待其转为 ACTIVE..."
  fi
  # addon 未 ACTIVE 视为非致命:已在 addon_wait_active 内记关注项,不阻断后续 EFS/SC 创建(驱动可能稍后就绪)。
  # 注:上面 eksctl create addon 命令本身若硬失败(如策略ARN错误),已由 set -e 直接致命,不会走到这里。
  if ! addon_wait_active "${name}"; then
    return 0
  fi
}

# 轮询 addon 到 ACTIVE;DEGRADED/CREATE_FAILED 视为失败;超时记为关注项
addon_wait_active() {
  local name="$1" t=0 s
  while [ ${t} -lt "${ADDON_WAIT_TIMEOUT}" ]; do
    s="$(aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name "${name}" \
      --query 'addon.status' --output text 2>/dev/null || echo NONE)"
    case "${s}" in
    ACTIVE)
      green "addon ${name} 已 ACTIVE。"
      return 0
      ;;
    DEGRADED | CREATE_FAILED | DELETE_FAILED)
      red "addon ${name} 状态异常: ${s}。排查: aws eks describe-addon --cluster-name ${CLUSTER_NAME} --addon-name ${name}"
      return 1
      ;;
    esac
    echo "等待 addon ${name} ACTIVE...(状态: ${s}, 已等待 ${t}s)"
    sleep 10
    t=$((t + 10))
  done
  note_attention "阶段5 addon ${name} 未在 ${ADDON_WAIT_TIMEOUT}s 内 ACTIVE，请手动确认: aws eks describe-addon --cluster-name ${CLUSTER_NAME} --addon-name ${name}"
  return 1
}

# 按 creation-token 查已有 EFS 文件系统 ID(唯一约束,多集群不撞);无则输出空
efs_find_by_token() {
  aws efs describe-file-systems --creation-token "${CLUSTER_NAME}-${EFS_NAME}" \
    --query 'FileSystems[0].FileSystemId' --output text 2>/dev/null || echo ""
}

# 轮询 EFS 到 available
efs_wait_available() {
  local fsid="$1" t=0 s
  while [ ${t} -lt "${EFS_WAIT_TIMEOUT}" ]; do
    s="$(aws efs describe-file-systems --file-system-id "${fsid}" \
      --query 'FileSystems[0].LifeCycleState' --output text 2>/dev/null || echo unknown)"
    [ "${s}" == "available" ] && {
      green "EFS ${fsid} 已 available。"
      return 0
    }
    echo "等待 EFS ${fsid} available...(状态: ${s}, 已等待 ${t}s)"
    sleep 5
    t=$((t + 5))
  done
  return 1
}

# 取子网所在可用区(失败输出空)
subnet_az() {
  aws ec2 describe-subnets --subnet-ids "$1" \
    --query 'Subnets[0].AvailabilityZone' --output text 2>/dev/null || echo ""
}

# 逐可用区为 EFS 建挂载目标,全覆盖 EKS 可用 AZ。
#   入参: fsid  SG列表(空格分隔)  锚子网列表(AE主机子网,其AZ必成)  其余候选子网列表(集群子网)
#   语义:AE 主机子网所在 AZ 是 Karpenter/AE主机的落点,为"锚 AZ",必须建成挂载点,失败即致命(exit);
#         其余集群子网所在 AZ 尽力全覆盖(建失败仅告警)。最终交由 wait 断言每个预期 AZ 都 available。
#   幂等:已有挂载目标的 AZ 跳过(EFS 每 AZ 仅允许一个挂载目标)。
efs_ensure_mount_targets() {
  local fsid="$1" sgs="$2" anchor_subnets="$3" other_subnets="$4"
  local es az sn

  # 锚可用区集合(AE 主机子网所在 AZ,必成)。任一锚子网 AZ 解析失败即致命。
  local anchor_azs=" "
  for sn in ${anchor_subnets}; do
    az="$(subnet_az "${sn}")"
    if [ -z "${az}" ]; then
      red "错误:AE 主机子网 ${sn} 无法解析可用区,无法保证 Karpenter/AE主机落点 AZ 的 EFS 挂载点,终止。"
      exit 1
    fi
    case "${anchor_azs}" in *" ${az} "*) ;; *) anchor_azs="${anchor_azs}${az} " ;; esac
  done

  # 已有挂载目标覆盖的可用区
  local covered_az=" " existing
  existing="$(aws efs describe-mount-targets --file-system-id "${fsid}" \
    --query 'MountTargets[].SubnetId' --output text 2>/dev/null || echo "")"
  for es in ${existing}; do
    az="$(subnet_az "${es}")"
    [ -n "${az}" ] && covered_az="${covered_az}${az} "
  done

  # 锚子网优先,集群子网在后;逐子网按 AZ 去重建挂载目标,同时累积"预期覆盖 AZ 集合"。
  local expected_azs=" "
  for sn in ${anchor_subnets} ${other_subnets}; do
    az="$(subnet_az "${sn}")"
    if [ -z "${az}" ]; then
      note_attention "EFS 挂载点:子网 ${sn} 无法解析可用区,已跳过(请确认子网ID有效)"
      continue
    fi
    case "${expected_azs}" in *" ${az} "*) ;; *) expected_azs="${expected_azs}${az} " ;; esac
    if [[ "${covered_az}" == *" ${az} "* ]]; then
      echo "可用区 ${az} 已有挂载目标，跳过子网 ${sn}。"
      continue
    fi
    if aws efs create-mount-target --file-system-id "${fsid}" --subnet-id "${sn}" \
      --security-groups ${sgs} >/dev/null 2>&1; then
      green "已在子网 ${sn}(${az}) 创建 EFS 挂载目标。"
      covered_az="${covered_az}${az} "
    elif [[ "${anchor_azs}" == *" ${az} "* ]]; then
      red "错误:在 AE 主机子网 ${sn}(锚可用区 ${az})创建 EFS 挂载目标失败,该 AZ 为 Karpenter/AE主机落点,缺挂载点必致挂载失败,终止。手动确认: aws efs create-mount-target --file-system-id ${fsid} --subnet-id ${sn} --security-groups ${sgs}"
      exit 1
    else
      note_attention "EFS 挂载点:在子网 ${sn}(${az})创建失败,请手动确认: aws efs create-mount-target --file-system-id ${fsid} --subnet-id ${sn} --security-groups ${sgs}"
    fi
  done

  # 等待并断言:预期覆盖的每个 AZ 都有 available 挂载目标(锚 AZ 缺失致命)。
  # 挂载目标 available 前,EFS 的 DNS 名无法解析出本 AZ 私网 IP,节点侧 mount -t efs 会 DNS 解析失败
  # 并转而调 API 兜底,故此处必须等齐再往下。
  efs_wait_mount_targets_available "${fsid}" "${anchor_azs}" "${expected_azs}"
}

# 轮询 EFS 挂载目标,断言"预期覆盖的每个 AZ 都有 available 挂载目标"。
#   入参: fsid  锚AZ集合(缺失致命)  预期覆盖AZ集合
#   收尾断言:超时后锚 AZ 仍缺 → 致命 exit;仅非锚 AZ 缺 → 告警返回 1。消除"已存在挂载点全 available
#   即报就绪"的假就绪缺陷(旧逻辑不校验预期 AZ 是否都建成了)。
efs_wait_mount_targets_available() {
  local fsid="$1" anchor_azs="$2" expected_azs="$3" t=0 avail_azs az missing
  while [ ${t} -lt "${EFS_WAIT_TIMEOUT}" ]; do
    avail_azs="$(aws efs describe-mount-targets --file-system-id "${fsid}" \
      --query "MountTargets[?LifeCycleState=='available'].AvailabilityZoneName" --output text 2>/dev/null || echo "")"
    missing=""
    for az in ${expected_azs}; do
      case " ${avail_azs} " in *" ${az} "*) ;; *) missing="${missing}${az} " ;; esac
    done
    if [ -z "${missing// /}" ]; then
      green "EFS ${fsid} 预期覆盖的所有可用区(${expected_azs# })均已 available。"
      return 0
    fi
    echo "等待 EFS 挂载目标 available...(未就绪 AZ: ${missing}已等待 ${t}s)"
    sleep 6
    t=$((t + 6))
  done

  # 超时:重新取一次 available AZ,分级断言(锚致命 / 非锚告警)
  avail_azs="$(aws efs describe-mount-targets --file-system-id "${fsid}" \
    --query "MountTargets[?LifeCycleState=='available'].AvailabilityZoneName" --output text 2>/dev/null || echo "")"
  local anchor_missing=""
  for az in ${anchor_azs}; do
    case " ${avail_azs} " in *" ${az} "*) ;; *) anchor_missing="${anchor_missing}${az} " ;; esac
  done
  if [ -n "${anchor_missing// /}" ]; then
    red "错误:EFS ${fsid} 锚可用区(${anchor_missing})挂载目标未在 ${EFS_WAIT_TIMEOUT}s 内 available,该 AZ 为 Karpenter/AE主机落点,节点必然无法挂载 EFS,终止。"
    exit 1
  fi
  missing=""
  for az in ${expected_azs}; do
    case " ${avail_azs} " in *" ${az} "*) ;; *) missing="${missing}${az} " ;; esac
  done
  note_attention "EFS ${fsid} 非锚可用区(${missing})挂载目标未在 ${EFS_WAIT_TIMEOUT}s 内 available,这些 AZ 的节点挂载 EFS 可能失败,请手动确认。"
  return 1
}

# 给节点侧 IAM 角色补 EFS 描述权限(AmazonEFSCSIDriverPolicy)。
#   背景:EFS 挂载发生在【节点】上(kubelet 调 efs-utils 执行 mount -t efs),用节点实例角色;
#   DNS 解析失败时 efs-utils 会兜底调 elasticfilesystem:DescribeMountTargets 查挂载目标 IP,
#   节点角色若无此权限则挂载失败。存量集群节点组名不定,故枚举集群下所有节点组的 nodeRole,
#   并探测 KarpenterNodeRole-<集群名> 是否存在,存在才补。
grant_efs_perm_to_node_roles() {
  local roles="" ngs ng arn r kn="KarpenterNodeRole-${CLUSTER_NAME}"
  ngs="$(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" \
    --query 'nodegroups' --output text 2>/dev/null || echo "")"
  for ng in ${ngs}; do
    arn="$(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${ng}" \
      --query 'nodegroup.nodeRole' --output text 2>/dev/null || echo "")"
    r="$(echo "${arn}" | sed -nE 's#.*:role/(.+)$#\1#p')"
    [ -n "${r}" ] && roles="${roles} ${r}"
  done
  if aws iam get-role --role-name "${kn}" >/dev/null 2>&1; then
    roles="${roles} ${kn}"
  fi
  if [ -z "${roles// /}" ]; then
    note_attention "阶段5 未枚举到任何节点角色,跳过 EFS 权限补齐;若 EFS 挂载失败,请手动为节点角色 attach ${EFS_CSI_POLICY_ARN}。"
    return 0
  fi
  # 去重后逐个幂等 attach
  for r in $(echo "${roles}" | tr ' ' '\n' | sort -u); do
    [ -z "${r}" ] && continue
    if aws iam attach-role-policy --role-name "${r}" \
      --policy-arn "${EFS_CSI_POLICY_ARN}" >/dev/null 2>&1; then
      green "已为节点角色 ${r} 附加 EFS 权限(${EFS_CSI_POLICY_ARN##*/})。"
    else
      note_attention "阶段5 为节点角色 ${r} 附加 EFS 权限失败(可能缺 iam:AttachRolePolicy),请手动执行: aws iam attach-role-policy --role-name ${r} --policy-arn ${EFS_CSI_POLICY_ARN}"
    fi
  done
}

# 创建块存储 StorageClass te-disk(存在则跳过:SC 的 provisioner/parameters 不可变)
apply_sc_disk() {
  if kubectl get sc "${SC_DISK_NAME}" >/dev/null 2>&1; then
    yellow "StorageClass ${SC_DISK_NAME} 已存在，跳过创建(默认注解由 claim_default_sc 统一处理)。"
    return 0
  fi
  # is-default-class 注解不写在此处,交由 claim_default_sc 统一抢占,避免与抢占逻辑冲突。
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${SC_DISK_NAME}
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
parameters:
  type: ${SC_DISK_TYPE}
  fstype: ${SC_DISK_FSTYPE}
EOF
  green "已创建块存储 StorageClass ${SC_DISK_NAME}(${SC_DISK_TYPE}/${SC_DISK_FSTYPE})。"
}

# 创建网络存储 StorageClass te-nfs(存在则跳过)。入参: fsid
apply_sc_nfs() {
  local fsid="$1"
  if kubectl get sc "${SC_NFS_NAME}" >/dev/null 2>&1; then
    yellow "StorageClass ${SC_NFS_NAME} 已存在，跳过创建。"
    return 0
  fi
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${SC_NFS_NAME}
provisioner: efs.csi.aws.com
reclaimPolicy: Retain
parameters:
  provisioningMode: efs-ap
  fileSystemId: ${fsid}
  directoryPerms: "${EFS_DIR_PERMS}"
EOF
  green "已创建网络存储 StorageClass ${SC_NFS_NAME}(fileSystemId=${fsid})。"
}

# 默认 SC 抢占:摘掉所有"非指定前缀开头"的 default SC 注解,再把本 SC 设为唯一 default。
claim_default_sc() {
  local mine="$1" prefix="$2" defaults s
  # 列出当前所有带 is-default-class=true 的 SC(jsonpath 中 annotation key 的 . 需转义为 \.)
  defaults="$(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  for s in ${defaults}; do
    [ "${s}" == "${mine}" ] && continue
    case "${s}" in
    ${prefix}*)
      continue
      ;; # 同前缀的保留,不动
    esac
    kubectl annotate sc "${s}" storageclass.kubernetes.io/is-default-class- --overwrite >/dev/null 2>&1 || true
    green "已取消原默认 StorageClass ${s} 的默认注解。"
  done
  kubectl annotate sc "${mine}" storageclass.kubernetes.io/is-default-class=true --overwrite >/dev/null
  green "${mine} 已设为唯一默认 StorageClass。"
}

#############################################
##########  阶段2 前置校验  ##########
#############################################

# 必填 4 项非空校验
check_required_conf() {
  local miss=0 v
  for v in AWS_DEFAULT_REGION VPC_ID CLUSTER_NAME AE_HOSTS_SUBNET_ID; do
    if [ -z "${!v// /}" ]; then
      red "配置缺失：${v} 未填写。请在脚本顶部配置区填写(或用环境变量传入)。"
      miss=1
    fi
  done
  [ "${miss}" -eq 0 ] || {
    red "必填参数不完整，终止。必填 4 项：AWS_DEFAULT_REGION / VPC_ID / CLUSTER_NAME / AE_HOSTS_SUBNET_ID。"
    exit 1
  }
}

# 确保 eks-pod-identity-agent addon 已 ACTIVE：CSI 用 Pod Identity 拿 IAM 凭证依赖它。
# 存量集群可能没装 → 不装则 CSI controller 拿不到凭证、Provisioning 全失败。此处是硬前提,失败致命。
ensure_pod_identity_agent() {
  local st
  st="$(aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name eks-pod-identity-agent \
    --query 'addon.status' --output text 2>/dev/null || echo NONE)"
  if [ "${st}" == "ACTIVE" ]; then
    green "eks-pod-identity-agent 已 ACTIVE。"
    return 0
  fi
  if [ "${st}" == "NONE" ]; then
    yellow "存量集群未安装 eks-pod-identity-agent，CSI 的 Pod Identity 依赖它，正在安装..."
    eksctl create addon --cluster "${CLUSTER_NAME}" --name eks-pod-identity-agent --force
  else
    echo "eks-pod-identity-agent 当前状态 ${st}，等待其转为 ACTIVE..."
  fi
  addon_wait_active eks-pod-identity-agent || {
    red "eks-pod-identity-agent 未能 ACTIVE，CSI 的 Pod Identity 关联将失效，终止。"
    red "排查: aws eks describe-addon --cluster-name ${CLUSTER_NAME} --addon-name eks-pod-identity-agent"
    exit 1
  }
}

stage_precheck() {
  title "阶段2：前置校验(集群/VPC/子网/kubectl/身份 + Pod Identity Agent)"
  aws configure set region "${AWS_DEFAULT_REGION}"

  # a) 账号一致性：调用者账号 vs 集群 ARN 账号
  local caller_acct cluster_arn cluster_acct
  caller_acct="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo NONE)"

  # b) 集群存在且 ACTIVE
  local cstatus
  cstatus="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query 'cluster.status' --output text 2>/dev/null || echo NONE)"
  if [ "${cstatus}" != "ACTIVE" ]; then
    red "集群 ${CLUSTER_NAME} 在地域 ${AWS_DEFAULT_REGION} 不存在或非 ACTIVE(当前: ${cstatus})。"
    red "排查: aws eks list-clusters --region ${AWS_DEFAULT_REGION}  # 核对集群名与地域是否填对"
    exit 1
  fi
  green "集群 ${CLUSTER_NAME} 状态 ACTIVE。"

  # 账号一致性(集群 ARN 中解析账号)
  cluster_arn="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query 'cluster.arn' --output text 2>/dev/null || echo "")"
  cluster_acct="$(echo "${cluster_arn}" | sed -nE 's#arn:[^:]*:eks:[^:]*:([0-9]+):.*#\1#p')"
  if [ -n "${cluster_acct}" ] && [ "${caller_acct}" != "NONE" ] && [ "${caller_acct}" != "${cluster_acct}" ]; then
    red "账号不一致：当前凭证账号 ${caller_acct} ≠ 集群所属账号 ${cluster_acct}。很可能用错了凭证或跨账号。"
    exit 1
  fi

  # c) VPC 一致：手填 VPC_ID 与集群实际 VPC 一致
  local cluster_vpc
  cluster_vpc="$(aws eks describe-cluster --name "${CLUSTER_NAME}" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || echo NONE)"
  if [ "${cluster_vpc}" != "${VPC_ID}" ]; then
    red "VPC 不一致：手填 VPC_ID=${VPC_ID}，但集群实际 VPC=${cluster_vpc}。很可能 VPC_ID 复制自其他集群/环境。"
    exit 1
  fi
  green "VPC 校验通过(${VPC_ID})。"

  # d) kubectl 可达
  aws eks --region "${AWS_DEFAULT_REGION}" update-kubeconfig --name "${CLUSTER_NAME}" >/dev/null
  if ! kubectl version --request-timeout=10s >/dev/null 2>&1; then
    red "kubeconfig 已刷新但无法连接 API Server。请排查:"
    red "1. 执行主机是否在集群网络可达范围(private endpoint 需同 VPC/打通网络)"
    red "2. 当前 IAM 身份是否在集群 aws-auth / access entry 中被授权"
    red "3. endpoint 访问模式: aws eks describe-cluster --name ${CLUSTER_NAME} --query cluster.resourcesVpcConfig"
    exit 1
  fi
  green "kubectl 可连接集群 API Server。"

  # e) AE 主机子网归属：必须在集群 VPC 内
  local sn ae_vpc
  for sn in ${AE_HOSTS_SUBNET_ID}; do
    ae_vpc="$(aws ec2 describe-subnets --subnet-ids "${sn}" --query 'Subnets[0].VpcId' --output text 2>/dev/null || echo NONE)"
    if [ "${ae_vpc}" != "${cluster_vpc}" ]; then
      red "AE 子网 ${sn} 不在集群 VPC(${cluster_vpc}) 内(实际: ${ae_vpc})。检查是否跨账号/跨地域复制了子网ID。"
      exit 1
    fi
  done
  green "AE 主机子网归属校验通过。"

  # f) Fargate 提示(不阻断)：EBS 不支持 Fargate Pod
  local fp
  fp="$(aws eks list-fargate-profiles --cluster-name "${CLUSTER_NAME}" --query 'fargateProfileNames' --output text 2>/dev/null || echo "")"
  if [ -n "${fp}" ] && [ "${fp}" != "None" ]; then
    note_attention "检测到 Fargate profile(${fp})：EBS(${SC_DISK_NAME}) 在 Fargate Pod 上不可用,仅 EFS(${SC_NFS_NAME}) 可用于 Fargate。"
  fi

  # g) 确保 Pod Identity Agent(CSI 硬前提)
  echo "---- 2.x 确保 eks-pod-identity-agent(CSI Pod Identity 依赖) ----"
  ensure_pod_identity_agent

  record "阶段2  前置校验(集群/VPC/子网/kubectl/身份 + Pod Identity Agent)   正常"
  green "阶段2 前置校验通过。"
}

#############################################
##########  阶段3 存储就绪  ##########
#############################################

# 判断某 CSI 驱动的安装方式：回显 addon / selfmanaged / none
#   addon      = aws eks describe-addon 查到(非NONE)
#   selfmanaged= addon 查不到,但集群里已有 csidriver 对象或 kube-system controller deployment(helm/manifest 自管)
#   none       = 都没有
csi_install_mode() {
  local addon="$1" driver="$2" deploy="$3" st
  st="$(aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name "${addon}" \
    --query 'addon.status' --output text 2>/dev/null || echo NONE)"
  if [ "${st}" != "NONE" ]; then
    echo addon
    return
  fi
  if kubectl get csidriver "${driver}" >/dev/null 2>&1 ||
    kubectl -n kube-system get deployment "${deploy}" >/dev/null 2>&1; then
    echo selfmanaged
    return
  fi
  echo none
}

# 按安装方式决定装/跳过。自管则跳过(不强转 addon,避免 --force 覆盖自管安装导致冲突)。
install_csi_driver() {
  local kind="$1" addon="$2" sa="$3" policy="$4" ver="$5" driver="$6" deploy="$7" mode
  mode="$(csi_install_mode "${addon}" "${driver}" "${deploy}")"
  case "${mode}" in
  addon)
    echo "${kind} CSI: 检测到已作为 EKS addon 安装，确认其 ACTIVE。"
    ensure_addon "${addon}" "${sa}" "${policy}" "${ver}"
    ;;
  selfmanaged)
    note_attention "${kind} CSI: 检测到自管方式(helm/manifest)安装的驱动(${driver})，为避免冲突【跳过 addon 安装】。如需转为 EKS addon 托管,请先手动卸载自管版本后重跑。"
    ;;
  none)
    echo "${kind} CSI: 未检测到任何安装，作为 EKS addon 安装。"
    ensure_addon "${addon}" "${sa}" "${policy}" "${ver}"
    ;;
  esac
}

stage_storage() {
  title "阶段3：存储就绪(EBS/EFS CSI + EFS 文件系统 + StorageClass)"
  aws eks --region "${AWS_DEFAULT_REGION}" update-kubeconfig --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true

  # 3.1 安装 EBS / EFS 两个 CSI 驱动(含自管检测,自管则跳过)
  echo "---- 3.1 安装 CSI 驱动(EBS/EFS,含自管检测) ----"
  install_csi_driver "EBS" "${EBS_CSI_ADDON_NAME}" "${EBS_CSI_SA}" "${EBS_CSI_POLICY_ARN}" "${EBS_CSI_ADDON_VERSION}" "ebs.csi.aws.com" "ebs-csi-controller"
  install_csi_driver "EFS" "${EFS_CSI_ADDON_NAME}" "${EFS_CSI_SA}" "${EFS_CSI_POLICY_ARN}" "${EFS_CSI_ADDON_VERSION}" "efs.csi.aws.com" "efs-csi-controller"

  # 3.1b 给节点侧角色补 EFS 权限(挂载在节点上进行,DNS 兜底需 DescribeMountTargets)
  echo "---- 3.1b 为节点角色补 EFS 描述权限(枚举节点组 + KarpenterNodeRole) ----"
  grant_efs_perm_to_node_roles

  # 3.2 创建/复用 EFS 文件系统(creation-token 查重)
  echo "---- 3.2 创建/复用 EFS 文件系统(${EFS_NAME}) ----"
  local fsid
  fsid="$(efs_find_by_token)"
  if [ -z "${fsid}" ] || [ "${fsid}" == "None" ]; then
    fsid="$(aws efs create-file-system \
      --performance-mode "${EFS_PERFORMANCE_MODE}" \
      --creation-token "${CLUSTER_NAME}-${EFS_NAME}" \
      --encrypted \
      --tags "Key=Name,Value=${EFS_NAME}" "Key=cluster,Value=${CLUSTER_NAME}" \
      --query 'FileSystemId' --output text)"
    green "已创建 EFS 文件系统: ${fsid}"
  else
    green "EFS 文件系统已存在(creation-token 命中)，复用: ${fsid}"
  fi

  # 3.3 等待 EFS available
  echo "---- 3.3 等待 EFS 文件系统就绪(available) ----"
  efs_wait_available "${fsid}" || {
    red "错误：EFS ${fsid} 未在 ${EFS_WAIT_TIMEOUT}s 内进入 available。"
    exit 1
  }

  # 3.4 组装安全组(两类节点SG)与子网(集群子网 ∪ AE主机子网),逐可用区建挂载目标
  echo "---- 3.4 为 EFS 创建挂载目标(逐可用区,复用两类节点安全组) ----"
  local csg sharenode_sg sgs subnets
  csg="$(aws eks describe-cluster --name "${CLUSTER_NAME}" \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text 2>/dev/null || echo NONE)"
  if [ -z "${csg}" ] || [ "${csg}" == "None" ] || [ "${csg}" == "NONE" ]; then
    red "错误：无法获取集群安全组(clusterSecurityGroupId)，无法创建 EFS 挂载目标。"
    exit 1
  fi
  # ShareNode 安全组:用集群名前缀精确匹配定位(存量非 eksctl 建的集群可能没有,属正常,兜底仅用 cluster-sg)
  sharenode_sg="$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=eksctl-${CLUSTER_NAME}-cluster-ClusterSharedNodeSecurityGroup*" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo NONE)"
  # 挂载目标同时挂两类节点SG:管理节点在 cluster-sg、Karpenter 主力节点在 ShareNode SG,两者都能到 2049
  sgs="${csg}"
  if [ -n "${sharenode_sg}" ] && [ "${sharenode_sg}" != "None" ] && [ "${sharenode_sg}" != "NONE" ]; then
    sgs="${csg} ${sharenode_sg}"
    echo "EFS 挂载目标安全组: cluster-sg=${csg}  ShareNode=${sharenode_sg}"
  else
    note_attention "阶段3 未定位到 ShareNode 安全组(存量非 eksctl 集群可能无此 SG)，EFS 挂载目标仅挂 cluster-sg(${csg})。若 Karpenter/其他节点挂载 EFS 异常,请手动将对应节点安全组加入挂载目标。"
    echo "EFS 挂载目标安全组: cluster-sg=${csg}(未含 ShareNode)"
  fi
  # 子网集合 = AE 主机子网(锚,其 AZ 必成) + 集群实际子网(全覆盖 EKS 可用 AZ)
  local cluster_subnets
  cluster_subnets="$(aws eks describe-cluster --name "${CLUSTER_NAME}" \
    --query 'cluster.resourcesVpcConfig.subnetIds' --output text 2>/dev/null || echo "")"
  efs_ensure_mount_targets "${fsid}" "${sgs}" "${AE_HOSTS_SUBNET_ID}" "${cluster_subnets}"

  # 3.5 创建两个 StorageClass
  echo "---- 3.5 创建 StorageClass(${SC_DISK_NAME} 块存储 / ${SC_NFS_NAME} 网络存储) ----"
  apply_sc_disk
  apply_sc_nfs "${fsid}"

  # 3.6 默认 SC 抢占(te-disk 设为唯一 default)
  echo "---- 3.6 默认 StorageClass 抢占 ----"
  claim_default_sc "${SC_DISK_NAME}" "${DEFAULT_SC_PREFIX}"

  record "阶段3  存储就绪(EBS/EFS CSI + EFS ${fsid} + SC ${SC_DISK_NAME}/${SC_NFS_NAME})   正常"
  green "阶段3 存储就绪完成。"
}

#############################################
##########  阶段4 存储就绪性校验  ##########
#############################################

# 存储就绪性校验:SC 存在性、默认 SC 唯一性、CSI addon 状态;可选端到端 PVC 实测。
verify_storage() {
  local sc
  for sc in "${SC_DISK_NAME}" "${SC_NFS_NAME}"; do
    if kubectl get sc "${sc}" >/dev/null 2>&1; then
      green "StorageClass ${sc} 存在。"
    else
      note_attention "StorageClass ${sc} 缺失,请确认阶段3 存储就绪是否成功。"
    fi
  done
  # CSI 驱动对象存在性(addon 或自管都会建 csidriver 对象,比查 addon 更普适)
  local d
  for d in ebs.csi.aws.com efs.csi.aws.com; do
    if kubectl get csidriver "${d}" >/dev/null 2>&1; then
      green "CSI 驱动对象 ${d} 存在。"
    else
      note_attention "CSI 驱动对象 ${d} 不存在,对应驱动可能未就绪,请手动确认。"
    fi
  done
  # 默认 SC 唯一性:期望只有 SC_DISK_NAME 带默认注解
  local defaults
  defaults="$(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}' 2>/dev/null || true)"
  defaults="$(echo ${defaults})" # 压缩空白
  if [ "${defaults}" == "${SC_DISK_NAME}" ]; then
    green "默认 StorageClass 唯一且为 ${SC_DISK_NAME}。"
  else
    note_attention "默认 StorageClass 非唯一或非 ${SC_DISK_NAME}(当前: ${defaults:-无}),请手动确认。"
  fi
  # CSI addon 状态(自管安装时查不到 addon 属正常,不算异常)
  local a st
  for a in "${EBS_CSI_ADDON_NAME}:ebs.csi.aws.com" "${EFS_CSI_ADDON_NAME}:efs.csi.aws.com"; do
    local addon_name="${a%%:*}" driver="${a##*:}"
    st="$(aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name "${addon_name}" \
      --query 'addon.status' --output text 2>/dev/null || echo NONE)"
    if [ "${st}" == "ACTIVE" ]; then
      green "CSI addon ${addon_name} 状态 ACTIVE。"
    elif [ "${st}" == "NONE" ] && kubectl get csidriver "${driver}" >/dev/null 2>&1; then
      yellow "CSI ${addon_name} 非 addon 托管(自管 helm/manifest),csidriver ${driver} 已存在,视为正常。"
    else
      note_attention "CSI addon ${addon_name} 状态为 ${st}(非 ACTIVE),请手动确认。"
    fi
  done

  # EFS 挂载目标覆盖情况(核对是否每个集群 AZ 都有挂载目标)
  local fsid
  fsid="$(efs_find_by_token)"
  if [ -n "${fsid}" ] && [ "${fsid}" != "None" ]; then
    local mt_count
    mt_count="$(aws efs describe-mount-targets --file-system-id "${fsid}" \
      --query 'length(MountTargets)' --output text 2>/dev/null || echo 0)"
    green "EFS ${fsid} 当前挂载目标数: ${mt_count}。"
    [ "${mt_count}" -ge 1 ] 2>/dev/null || note_attention "EFS ${fsid} 挂载目标数为 0,节点将无法挂载 EFS,请手动确认子网/安全组。"
  fi

  # 端到端实测(默认开启 STORAGE_E2E_TEST=true): 以"PVC 挂载 + Pod 起服 + 卷读写"作为存储层就绪判据
  if [ "${STORAGE_E2E_TEST}" == "true" ]; then
    echo ""
    echo "*** 存储端到端实测: 起 PVC+Pod 验证动态供给 / 挂载 / 读写(块存储 RWO + 网络存储 RWX) ***"
    local e2e_fail=0
    verify_storage_e2e "${SC_DISK_NAME}" "ebs" "ReadWriteOnce" || {
      e2e_fail=1
      note_attention "EBS(${SC_DISK_NAME}) 端到端实测未通过,存储层未完全就绪,请按上方诊断排查。"
    }
    verify_storage_e2e "${SC_NFS_NAME}" "efs" "ReadWriteMany" || {
      e2e_fail=1
      note_attention "EFS(${SC_NFS_NAME}) 端到端实测未通过,存储层未完全就绪,请按上方诊断排查。"
    }
    if [ "${e2e_fail}" -eq 0 ]; then
      green "存储端到端实测全部通过：EBS/EFS 的 PVC 均可动态供给、挂载、读写，存储层完全就绪。"
    fi
  else
    echo "(存储端到端实测已跳过[STORAGE_E2E_TEST=false];如需实测请以 STORAGE_E2E_TEST=true 重跑)"
  fi
}

# 端到端实测单个 SC:建 PVC + 挂载 Pod,确认 PVC Bound、Pod Running,再在容器内写入并读回探针文件。
# 入参: sc名  标记(ebs/efs,用于命名与提示)  访问模式(ReadWriteOnce / ReadWriteMany)。测完清理。
# 返回: 0 = 挂载+起服通过(读写异常仅告警不判失败) / 非0 = PVC 未 Bound 或 Pod 未 Running。
verify_storage_e2e() {
  local sc="$1" tag="$2" mode="$3" ns="${VERIFY_NAMESPACE}"
  local pvc="e2e-${tag}-pvc" pod="e2e-${tag}-pod"
  local probe="/data/e2e-probe.txt" token="e2e-${tag}-$(date +%s)"
  local t=0 pvc_phase pod_phase bound=false running=false
  echo ""
  echo "--- [${tag}] 实测 StorageClass ${sc} (${mode}) ---"
  kubectl get ns "${ns}" >/dev/null 2>&1 || kubectl create ns "${ns}" >/dev/null 2>&1

  # 起 PVC + 挂载 Pod(容器内写入探针并读回,常驻等待探测)
  cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc}
  namespace: ${ns}
spec:
  accessModes: ["${mode}"]
  storageClassName: ${sc}
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${ns}
spec:
  containers:
  - name: app
    image: ${VERIFY_E2E_IMAGE}
    command: ["sh","-c","echo ${token} > ${probe} && sync && sleep 3600"]
    volumeMounts:
    - name: vol
      mountPath: /data
  volumes:
  - name: vol
    persistentVolumeClaim:
      claimName: ${pvc}
EOF

  # 等待 PVC Bound + Pod Running
  echo "等待 [${tag}] PVC 绑定与 Pod 就绪(最多 ${E2E_WAIT_TIMEOUT}s)..."
  while [ ${t} -lt "${E2E_WAIT_TIMEOUT}" ]; do
    pvc_phase="$(kubectl get pvc "${pvc}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    pod_phase="$(kubectl get pod "${pod}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [ "${pvc_phase}" == "Bound" ] && bound=true
    if [ "${bound}" == "true" ] && [ "${pod_phase}" == "Running" ]; then
      running=true
      break
    fi
    echo "  等待中...(PVC: ${pvc_phase:-未知}, Pod: ${pod_phase:-未知}, 已等待 ${t}s)"
    sleep 6
    t=$((t + 6))
  done

  if [ "${bound}" != "true" ] || [ "${running}" != "true" ]; then
    red "[${tag}] 端到端实测失败：PVC Bound=${bound}, Pod Running=${running}。诊断信息如下："
    echo "----- kubectl describe pvc ${pvc} (末尾事件) -----"
    kubectl describe pvc "${pvc}" -n "${ns}" 2>&1 | tail -15 || true
    echo "----- kubectl describe pod ${pod} (末尾事件) -----"
    kubectl describe pod "${pod}" -n "${ns}" 2>&1 | tail -20 || true
    e2e_cleanup "${ns}" "${pod}" "${pvc}"
    return 1
  fi
  green "[${tag}] PVC 已 Bound、Pod 已 Running(${sc} 动态供给 + 挂载成功)。"

  # 读写探针：读回容器写入的 token，确认卷真正可读写(异常仅告警,不判失败)
  local readback
  readback="$(kubectl exec "${pod}" -n "${ns}" -- cat "${probe}" 2>/dev/null || true)"
  if [ "${readback}" == "${token}" ]; then
    green "[${tag}] 卷读写探针通过(写入并读回一致: ${token})。"
  else
    note_attention "[${tag}] 卷读写探针未通过(期望 '${token}' 读回 '${readback:-空}')。挂载已成功,读写请手动确认。"
  fi

  e2e_cleanup "${ns}" "${pod}" "${pvc}"
  return 0
}

# 清理单个 e2e 测试资源(Pod 先删,PVC 后删)
e2e_cleanup() {
  local ns="$1" pod="$2" pvc="$3"
  kubectl delete pod "${pod}" -n "${ns}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete pvc "${pvc}" -n "${ns}" --ignore-not-found >/dev/null 2>&1 || true
}

stage_verify() {
  title "阶段4：存储就绪性校验"
  aws eks --region "${AWS_DEFAULT_REGION}" update-kubeconfig --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
  verify_storage
  record "阶段4  存储就绪性校验   完成"
  green "阶段4 存储就绪性校验完成(具体项见上,关注项在收尾汇总)。"
}

print_plan() {
  echo ""
  echo -e "\e[1m$(_banner_line " 执行计划(存量集群补存储) ")\e[0m"
  cat <<PLAN
阶段1: 安装/更新 awscli、eksctl、kubectl、helm + 调用者身份打印
阶段2: 前置校验(集群 ACTIVE / VPC 一致 / kubectl 可达 / AE子网归属 / Pod Identity Agent)
阶段3: 存储就绪(EBS/EFS CSI 驱动含自管检测 + EFS 文件系统 ${EFS_NAME} + StorageClass ${SC_DISK_NAME}/${SC_NFS_NAME})
阶段4: 存储就绪性校验(SC / CSI 驱动 / EFS 挂载目标 + 端到端 PVC+Pod 挂载读写实测)

目标集群: ${CLUSTER_NAME}   地域: ${AWS_DEFAULT_REGION}   VPC: ${VPC_ID}
本脚本只补存储,不创建集群/节点组,不改网络放行/打标签。
PLAN
  echo -e "\e[1m$(_banner_rule)\e[0m"
  echo ""
}

# 收尾：打印关注项(非致命告警)与日志路径
print_summary() {
  title "结果汇总"
  green "存量集群 ${CLUSTER_NAME} 存储就绪流程执行完毕。"
  if [ -s "${ATTENTION_FILE}" ]; then
    echo ""
    yellow "需关注(非致命):"
    while IFS= read -r line; do echo -e "\e[33m- ${line}\e[0m"; done <"${ATTENTION_FILE}"
  else
    green "无需关注项,全部正常。"
  fi
  echo -e "\e[1m$(_banner_rule)\e[0m"
  echo "日志文件: ${RESULT_FILE}"
}

main() {
  # 收尾(含异常/中断)恢复主机默认 yum 源配置
  trap restore_yum_repos EXIT
  print_plan
  check_required_conf
  stage_tools
  stage_precheck
  stage_storage
  stage_verify
  print_summary
  green "存储就绪完成：EBS(${SC_DISK_NAME}) + EFS(${SC_NFS_NAME}) 已可用于 PVC。"
}

main "$@"
