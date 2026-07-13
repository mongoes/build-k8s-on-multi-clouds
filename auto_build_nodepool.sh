#!/bin/bash
#适用于AWS EKS环境创建节点组以及可用性检查

# ========== 基础环境参数配置部分 ==========
# 定义临时目录，用于存放节点组测试日志以及配置文件
OUTPUT_DIR="nodepool_configs"
mkdir -p "$OUTPUT_DIR"
#日志文件
LOG_FILE="${OUTPUT_DIR}/aws_eks_nodepool_test.log"
#命名空间
NAMESPACE="debug"
#镜像地址1
NGINX_IMAGE="nginx:1.20"
#镜像地址2
NGINX_IMAGE_CN="docker-ta.thinkingdata.cn/te/nginx:1.20"

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

#K8S集群链接检查
test_k8s_connection() {
  log_step "测试K8S集群连接"
  #密钥文件
  if [[ -z "${KUBECONFIG}" ]] || [[ ! -f "${KUBECONFIG}" ]]; then
    log_error "未找到KUBECONFIG文件，请参考数数SOP配置K8S访问凭证"
    exit 1
  fi

  if ! kubectl cluster-info &>/dev/null; then
    log_error "无法连接到Kubernetes集群，请检查配置"
    exit 1
  fi
  log_success "K8S集群连接正常"
}

# 获取EKS集群名的方法，EKS集群名是必要信息，尝试从多个来源获取EKS集群名
get_cluster_name() {
  local cluster_name=""

  # 1. 优先尝试从KUBECONFIG环境变量解析
  #检查当前主机是否有KUBECONFIG的环境变量，数数ta1上要求必须要有，获取该环境变量并尝试解析EKS集群名
  if [ -n "${KUBECONFIG}" ] && [ -f "${KUBECONFIG}" ]; then
    cluster_name=$(awk '/current-context:/ {split($2, a, "/"); print a[2]}' "${KUBECONFIG}" 2>/dev/null)
  else
    #如果不存在$KUBECONFIG变量，可能意味着当前并非ta1主机或者忘记配置环境变量
    echo "当前终端可能非ta1主机环境或忘记配置KUBECONFIG环境变量，无法获取EKS集群名，尝试通过aws指令获取中~"
  fi

  # 2. 如果KUBECONFIG解析失败，尝试AWS CLI
  if [ -z "${cluster_name}" ]; then
    echo "尝试通过AWS EKS API获取集群名..."
    # 使用jq解析JSON输出，更可靠
    if command -v jq >/dev/null 2>&1; then
      cluster_name=$(aws eks list-clusters --query 'clusters[0]' --output json 2>/dev/null | jq -r . 2>/dev/null)
    else
      # 如果没有jq，使用grep+cut
      cluster_name=$(aws eks list-clusters --output text 2>/dev/null | head -1 | cut -f2)
    fi
  fi

  #输出cluster_name
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

#创建业务节点组
build_nodepool_for_business() {
  #创建节点组需要操作系统(AMI)版本信息,此处获取并校验ssm/ec2相关权限
  get_os_alias_version

  #EKS集群名获取， 必要信息！！！需做不为空判断!!!
  CLUSTER_NAME=$(get_cluster_name)

  if [ -n "${CLUSTER_NAME}" ]; then
    echo "检测到当前终端加载到的EKS集群名为: ${CLUSTER_NAME}"
  else
    read -p "未能自动获取到EKS集群名(EKS创建脚本或AWS EKS控制台可查)，请手动输入: " ZONE_INPUT
    if [ -z "$ZONE_INPUT" ]; then
      log_error "EKS集群名是创建节点组的必要条件，不得为空，请确认信息后重试本脚本！"
      exit 1
    else
      CLUSTER_NAME=$ZONE_INPUT
      log_message "INFO: 用户输入的EKS集群名信息为${CLUSTER_NAME}"
    fi

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
  nodepool_records=$(kubectl get nodepool 2>/dev/null | grep -v 'NAME' | wc -l)
  if [ ${nodepool_records} -gt 0 ]; then
    #如果检测到已有karpenter节点组记录，先备份留档
    echo "检测完成:检测到当前EKS环境中存在如下 ${nodepool_records} 个节点组,正在检查已有节点组的关键配置是否符合规范,请稍等~"
    kubectl get nodepool
    kubectl get karpenter -oyaml >${OUTPUT_DIR}/karpenter_backup.yaml

    #获取已有节点组的可用区信息、安全组标签信息、子网标签信息
    nodepool_name=$(kubectl get nodepool | grep -v 'NAME' | head -1 | awk '{print $1}')
    zoneValue=$(kubectl get nodepool ${nodepool_name} -o jsonpath='{.spec.template.spec.requirements[?(@.key=="topology.kubernetes.io/zone")].values[*]}')
    securityGroupSelector=$(kubectl get ec2nodeclass ${nodepool_name} -o jsonpath='{.spec.securityGroupSelectorTerms[0].tags}')
    subnetSelector=$(kubectl get ec2nodeclass ${nodepool_name} -o jsonpath='{.spec.subnetSelectorTerms[0].tags}')
    log_message "INFO: 检测到当前EKS环境中存在 ${nodepool_records} 个节点组，抽样节点组名为 ${nodepool_name},可用区信息为: ${zoneValue},安全组标签为: ${securityGroupSelector},子网标签为: ${subnetSelector}"
    log_message "INFO: 数规范默认要求的可用区信息为：${AvailabilityZone},安全组标签为${securityGroupSelectorKey}: ${securityGroupSelectorValue},子网标签为 ${subnetSelectorKey}: ${subnetSelectorValue}"

    #对比已有节点组中关键信息和数数规范，当不一致时需要询问用户是否需要复用已有节点组中的信息，一致的话省略信息提示并进入默认的节点组创建流程
    exist_nodepool_securityGroupSelectorKey=$(echo ${securityGroupSelector} | jq -r 'keys_unsorted[]')
    exist_nodepool_securityGroupSelectorValue=$(echo ${securityGroupSelector} | jq -r '.[]')
    exist_nodepool_subnetSelectorKey=$(echo ${subnetSelector} | jq -r 'keys_unsorted[]')
    exist_nodepool_subnetSelectorValue=$(echo ${subnetSelector} | jq -r '.[]')
    if [[ ${zoneValue} == ${AvailabilityZone} && ${exist_nodepool_securityGroupSelectorKey} == ${securityGroupSelectorKey} && ${exist_nodepool_securityGroupSelectorValue} == ${securityGroupSelectorValue} && ${exist_nodepool_subnetSelectorKey} == ${subnetSelectorKey} && ${exist_nodepool_subnetSelectorValue} == ${subnetSelectorValue} ]]; then
      log_message "INFO: 检查当前EKS环境中已有节点组的关键配置符合数数规范,配置一致"
      echo "检查完成，确认已有节点组关键配置符合规范"
    else
      log_error "监测到当前EKS环境中存在如下所示 ${nodepool_records} 个节点组，组内关键配置与数数规范配置不一致"
      log_error "已有节点组关键信息 可用区信息为: ${zoneValue},安全组标签为${exist_nodepool_securityGroupSelectorKey}: ${exist_nodepool_securityGroupSelectorValue},子网标签为${exist_nodepool_subnetSelectorKey}: ${exist_nodepool_subnetSelectorValue}"
      log_error "数数规范期望信息   可用区信息为：${AvailabilityZone},安全组标签为${securityGroupSelectorKey}: ${securityGroupSelectorValue},子网标签为 ${subnetSelectorKey}: ${subnetSelectorValue}"

      read -p "请确认是否复用已有节点组中的可用区、安全组、子网等信息 <y/n>" need_create_base_nodepool
      # 将输入转换为小写进行统一判断
      format_if_create_base=$(echo "$need_create_base_nodepool" | tr '[:upper:]' '[:lower:]')
      if [ "${format_if_create_base}" == "y" ]; then
        log_message "WARN: 创建新节点组时使用已有老节点组配置"
        AvailabilityZone=${zoneValue}
        securityGroupSelectorKey=${exist_nodepool_securityGroupSelectorKey}
        securityGroupSelectorValue=${exist_nodepool_securityGroupSelectorValue}
        subnetSelectorKey=${exist_nodepool_subnetSelectorKey}
        subnetSelectorValue=${exist_nodepool_subnetSelectorValue}
      else
        log_message "WARN: 创建新节点组时使用数数规范"
      fi
    fi
  else
    #没有在用节点组，意味着是新EKS环境，直接预创建base节点组
    echo "检测完成:当前EKS环境暂无节点组(全新环境),将自动预创建 base 基础节点组"
    build_nodepool_for_base
    #base门禁:base与后续业务节点组复用同一套子网/安全组发现标签,若base资源对象异常,业务节点组大概率也异常。
    #故在全新环境下先校验base就绪(不通过则精准报错并退出),避免浪费时间创建注定失败的业务节点组。
    echo "base 是后续业务节点组的基础设施探针(复用同套子网/安全组标签),先校验其就绪再继续......"
    wait_nodepools_ready base-nodepool
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
    ["16c64g"]="m6a.4xlarge m6i.4xlarge m6in.4xlarge m7a.4xlarge m8g.4xlarge m9g.4xlarge"
    ["32c128g"]="m5n.8xlarge m6a.8xlarge m6i.8xlarge m6in.8xlarge m7a.8xlarge m7g.8xlarge m8g.8xlarge m9g.8xlarge"
    ["64c256g"]="m6a.16xlarge m6i.16xlarge m6in.16xlarge m7a.16xlarge m8g.16xlarge"
  )

  # 获取用户输入的节点组信息，可能需要多个节点组，且组内节点规格配置差异
  read -p "请输入需要创建的节点组名称（例如:od-4c32g od-8c32g od-32c128g spot-32c128g多组之间空格分隔）: " input_nodepool_names
  read -p "请为每个节点组选择规格（例如:4c32g 8c32g 32c128g 64c256g,顺序需与节点组名称对应,多规格之间空格分隔）: " input_nodepool_sizes
  read -p "请为每个节点组指定付费类型（支持od spot,顺序需与节点组名称一一对应,多付费类型之间空格分隔）: " input_nodepool_billing_mode
  echo ""
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
  echo -e "==========  开始创建指定的${#NODEPOOL_NAMES[@]}个业务节点组 "${NODEPOOL_NAMES[@]}" =========="
  # 创建每个节点组,建立节点组名、规格、付费类型映射
  for i in "${!NODEPOOL_NAMES[@]}"; do
    NODEPOOL_NAME="${NODEPOOL_NAMES[$i]}"
    SIZE="${NODEPOOL_SIZES[$i]}"
    # 获取实例类型列表
    INSTANCE_TYPES="${INSTANCE_TYPE_MAP[$SIZE]}"
    #获取用户输入的付费类型(数数域简写: od/spot)
    BILLING_MODE="${NODEPOOL_BILLING_MODE[$i]}"
    #映射到Karpenter官方well-known label口径:karpenter.sh/capacity-type 仅接受 on-demand/spot(不认od简写)
    #数数域(节点组名前缀/node.k8s.te/billing-mode标签/spot污点值)用 od,Karpenter域用 on-demand,两者通过此处映射打通
    if [[ "$BILLING_MODE" == "od" ]]; then
      CAPACITY_TYPE="on-demand"
    else
      CAPACITY_TYPE="spot"
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
          values: ["${AvailabilityZone}"]
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
    cpu: 1000
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
  subnetSelectorTerms:
    - tags:
        "${subnetSelectorKey}": "${subnetSelectorValue}"
  securityGroupSelectorTerms:
    - tags:
        "${securityGroupSelectorKey}": "${securityGroupSelectorValue}"
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

#创建基础节点组
build_nodepool_for_base() {
  echo ""
  cat <<EOF >${OUTPUT_DIR}/nodepool-base-nodepool.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: base-nodepool
spec:
  template:
    metadata:
      labels:
        node.kubernetes.type: base-nodepool
        node.k8s.te/nodepool-name: base-nodepool
        node.k8s.te/nodepool-instancespec: 4c16g
        node.k8s.te/billing-mode: od
    spec:
      requirements:
        - key: topology.kubernetes.io/zone
          operator: In
          values: ["${AvailabilityZone}"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: 
          - m6a.xlarge
          - m6i.xlarge
          - m7a.xlarge
          - m7i.xlarge
          - m7i-flex.xlarge
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
      nodeClassRef:
        name: base-nodepool
        group: karpenter.k8s.aws
        kind: EC2NodeClass
      # expireAfter: Never 节点永不主动过期轮换,稳定优先(口径同业务节点组)
      expireAfter: Never
  limits:
    cpu: 1000
  disruption:
    # consolidationPolicy: WhenEmpty 仅当节点为空时才回收,不做低利用率合并(数数线上保守回收策略)
    # consolidateAfter: 10m 节点变空后等待10分钟再回收,避免节点频繁抖动
    consolidationPolicy: WhenEmpty
    consolidateAfter: 10m
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: base-nodepool
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
  subnetSelectorTerms:
    - tags:
        "${subnetSelectorKey}": "${subnetSelectorValue}"
  securityGroupSelectorTerms:
    - tags:
        "${securityGroupSelectorKey}": "${securityGroupSelectorValue}"
  tags:
    name: eks-thinkingai
    owner: shushu
EOF

  kubectl apply -f ${OUTPUT_DIR}/nodepool-base-nodepool.yaml
  # 检查应用结果
  if [ $? -eq 0 ]; then
    # 等待节点组就绪
    sleep 10
    title2_message "节点组 [base-nodepool] 创建成功!"
  else
    log_error "警告：节点组 [base-nodepool] 创建失败，请检查配置文件"
    exit 1
  fi
}

#根据 Pod 解析其顶层工作负载控制器,输出格式 "kind name"(如 Deployment trino-worker-ch-default)
#Pod -> ownerReferences: 若为 ReplicaSet 则继续上溯到 Deployment;StatefulSet/DaemonSet 等直接返回
resolve_workload() {
  local ns=$1 pod=$2
  local owner_kind owner_name
  owner_kind=$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null)
  owner_name=$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null)
  if [ "$owner_kind" == "ReplicaSet" ]; then
    local rs_owner_kind rs_owner_name
    rs_owner_kind=$(kubectl get rs "$owner_name" -n "$ns" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null)
    rs_owner_name=$(kubectl get rs "$owner_name" -n "$ns" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null)
    if [ -n "$rs_owner_kind" ]; then
      echo "$rs_owner_kind $rs_owner_name"
      return
    fi
  fi
  [ -n "$owner_kind" ] && echo "$owner_kind $owner_name"
}

#为指定工作负载的 .spec.template.spec.tolerations 严谨地追加目标容忍
#入参: kind name ns key value effect
#策略: 1.完全匹配则幂等跳过; 2.无任何容忍则新建; 3.已有容忍且无同key则追加; 4.已有同key但不同value则人工确认
add_toleration_to_workload() {
  local kind=$1 name=$2 ns=$3 key=$4 value=$5 effect=$6

  local existing_tol
  existing_tol=$(kubectl get "$kind" "$name" -n "$ns" -o jsonpath='{.spec.template.spec.tolerations}' 2>/dev/null)
  [ -z "$existing_tol" ] && existing_tol="[]"

  # 情况1: 已存在完全匹配(key+value+effect)的容忍 -> 幂等跳过
  local fully_tolerated
  fully_tolerated=$(echo "$existing_tol" | jq --arg k "$key" --arg v "$value" --arg e "$effect" \
    'any(.[]; .key==$k and ((.value // "")==$v) and ((.effect // "")==$e))')
  if [ "$fully_tolerated" == "true" ]; then
    echo "  ${ns}/${kind}/${name} 已容忍目标污点,跳过。"
    return 0
  fi

  # 情况4: 已存在同 key 但 value 不同的容忍 -> 人工确认后再追加
  local same_key_diff_value
  same_key_diff_value=$(echo "$existing_tol" | jq --arg k "$key" --arg v "$value" \
    'any(.[]; .key==$k and ((.value // "")!=$v))')
  if [ "$same_key_diff_value" == "true" ]; then
    echo -e "\e[33m\e[1m  ${ns}/${kind}/${name} 已存在 key=${key} 但 value 不同的容忍:\e[0m"
    echo "$existing_tol" | jq -c --arg k "$key" '.[] | select(.key==$k)' | sed 's/^/        /'
    local confirm_diff
    read -p "  是否仍要为其追加 value=${value} 的容忍?(保留原有容忍) <y/n> " confirm_diff </dev/tty
    confirm_diff=$(echo "$confirm_diff" | tr '[:upper:]' '[:lower:]')
    if [ "$confirm_diff" != "y" ]; then
      echo "  已跳过 ${ns}/${kind}/${name}。"
      return 0
    fi
  fi

  # 情况2/3: 在原有容忍数组(可能为空)基础上追加目标容忍,整体写回,保证不丢失原有容忍
  local merged_tol patch
  merged_tol=$(echo "$existing_tol" | jq -c --arg k "$key" --arg v "$value" --arg e "$effect" \
    '. + [{"key":$k,"operator":"Equal","value":$v,"effect":$e}]')
  patch=$(jq -nc --argjson tol "$merged_tol" '{"spec":{"template":{"spec":{"tolerations":$tol}}}}')
  if kubectl patch "$kind" "$name" -n "$ns" --type merge -p "$patch" >/dev/null 2>&1; then
    echo -e "\e[32m\e[1m  成功为 ${ns}/${kind}/${name} 追加容忍。\e[0m"
  else
    log_error "  为 ${ns}/${kind}/${name} 追加容忍失败,请人工检查。"
  fi
}

#判断指定工作负载控制器的 .spec.template.spec.tolerations 是否已容忍目标污点。
#口径与Pod级判定完全一致(effect匹配 + Exists/Equal 两种operator)。
#入参: kind name ns key value;返回: 已容忍输出"true",否则"false"
workload_tolerates_taint() {
  local kind=$1 name=$2 ns=$3 key=$4 value=$5
  local tol
  tol=$(kubectl get "$kind" "$name" -n "$ns" -o jsonpath='{.spec.template.spec.tolerations}' 2>/dev/null)
  [ -z "$tol" ] && tol="[]"
  echo "$tol" | jq -r --arg k "$key" --arg v "$value" '
    (any(.[];
      (.effect == null or .effect == "" or .effect == "NoSchedule")
      and (
        (.operator == "Exists" and (.key == null or .key == "" or .key == $k))
        or ((.operator == "Equal" or .operator == null) and .key == $k and .value == $v)
      )
    )) | tostring'
}

#找出"必须容忍spot污点但其控制器当前未容忍"的关键服务【工作负载控制器】,输出多行 "ns kind name"(已去重)。
#为何以【控制器】而非Pod为单位判定容忍:
#  补容忍是patch到控制器(Deployment等)的;但存量Pending旧Pod的spec.tolerations是陈旧的、不会更新,
#  若仍按Pod判容忍,会在"刚补完容忍+存量旧Pod还在"的窗口期持续误报缺容忍。改为校验控制器模板即可彻底闭环。
#关键: 两类服务识别口径【完全不同】,必须分别处理,否则会漏检!
#  1) trino-worker: deployment控制器,无通用标签 -> 只能按Pod名关键字匹配,再溯源控制器
#  2) starrocks-cn: 控制器/Pod带确定标签 app.kubernetes.io/name=starrocks 且 app.kubernetes.io/component=cn
#                   其Pod名通常形如 <cluster>-cn-N,并不包含"starrocks-cn"字样,故【必须】用标签匹配,不能用名称grep
#入参: key value (目标spot污点的 key/value)
find_untolerated_critical_workloads() {
  local k=$1 v=$2

  # 第一步: 收集候选关键服务Pod(此处【不】按Pod级容忍过滤,只负责命中关键服务),输出 ns/pod
  local candidate_pods
  candidate_pods=$(
    # 1) trino-worker: 按Pod名关键字匹配(无通用标签)
    kubectl get pods -A -o json 2>/dev/null |
      jq -r '.items[] | select(.metadata.name | contains("trino-worker")) | "\(.metadata.namespace)/\(.metadata.name)"'
    # 2) starrocks-cn: 按确定标签精确匹配(Pod名通常不含starrocks-cn,必须用标签)
    kubectl get pods -A -l app.kubernetes.io/name=starrocks,app.kubernetes.io/component=cn -o json 2>/dev/null |
      jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"'
  )
  candidate_pods=$(echo "$candidate_pods" | grep -v '^$' | sort -u)
  [ -z "$candidate_pods" ] && return 0

  # 第二步: 候选Pod溯源到顶层控制器并去重(避免同一控制器多Pod重复判定)
  local resolved="" line ns pod workload
  while read -r line; do
    [ -z "$line" ] && continue
    ns="${line%%/*}"
    pod="${line#*/}"
    workload=$(resolve_workload "$ns" "$pod")
    [ -n "$workload" ] && resolved="${resolved}${ns} ${workload}"$'\n'
  done <<<"$candidate_pods"
  resolved=$(echo "$resolved" | grep -v '^$' | sort -u)
  [ -z "$resolved" ] && return 0

  # 第三步: 在【控制器】层校验容忍,只输出尚未容忍目标污点的控制器
  local rkind rname
  while read -r ns rkind rname; do
    [ -z "$rkind" ] && continue
    if [ "$(workload_tolerates_taint "$rkind" "$rname" "$ns" "$k" "$v")" != "true" ]; then
      echo "$ns $rkind $rname"
    fi
  done <<<"$resolved"
}

#对"未容忍目标spot污点的关键服务【控制器】"统一处理: 打印 -> 人工确认 -> 安全幂等地追加容忍。
#入参已是去重后的控制器列表(ns kind name),溯源/容忍校验已在 find_untolerated_critical_workloads 完成。
#入参: critical_workloads(多行 "ns kind name") key value effect
handle_critical_untolerated() {
  local critical_workloads=$1 key=$2 value=$3 effect=$4

  #按 ns/kind/name 友好打印
  echo "$critical_workloads" | awk '{print "  - "$1"/"$2"/"$3}'
  echo ""

  local confirm_tol
  read -p "是否要为上述关键服务自动追加对 ${key}=${value}:${effect} 的容忍策略?(作用于其工作负载控制器,安全幂等) <y/n> " confirm_tol
  confirm_tol=$(echo "$confirm_tol" | tr '[:upper:]' '[:lower:]')
  if [ "$confirm_tol" != "y" ]; then
    echo -e "\e[33m\e[1m已选择不自动追加容忍。请确认这些关键服务有承载能力或手动补充容忍后再决定后续操作。\e[0m"
    echo ""
    return 0
  fi

  echo "开始为关键服务追加容忍(作用于顶层工作负载控制器,避免Pod重建后丢失)..."
  #控制器已去重,逐个追加容忍(格式: ns kind name)
  local ns kind name
  while read -r ns kind name; do
    [ -z "$kind" ] && continue
    add_toleration_to_workload "$kind" "$name" "$ns" "$key" "$value" "$effect"
  done <<<"$critical_workloads"
  echo -e "\e[33m\e[1m容忍追加处理完成。Tips: 容忍已写入控制器模板,存量Pod需重建(滚动重启)后才会真正应用新容忍。\e[0m"
  echo ""
}

#找出所有spot类型节点组,并patch上污点。
#前提:1.确认存在可用的on-demand节点组承载无容忍Pod; 2.执行前需人工确认; 3.执行前打印受影响Pod范围。
#在节点组创建与可用性检查完成后于主流程末尾调用。
taints_all_spot_nodepool() {
  # 步骤1: 找出所有包含 karpenter.sh/capacity-type = spot 的 NodePool
  echo "正在查找所有Spot类型的Karpenter NodePool..."

  # 期望追加的污点(key/value/effect)
  local TAINT_KEY="node.k8s.te/billing-mode"
  local TAINT_VALUE="spot"
  local TAINT_EFFECT="NoSchedule"

  # trino-worker、starrocks-cn 这类计算服务必须运行在 spot 节点上,因此它们【必须】已配置对该 spot 污点的容忍;
  # 若缺少容忍,打污点后将被拒绝调度。两者识别口径不同(见 find_untolerated_critical_workloads),由该函数统一负责检测。

  # 找出所有 spot 类型节点池(仅用于判断"是否存在spot池"以及全部已就绪的提示)
  local all_spot_nodepools
  all_spot_nodepools=$(kubectl get nodepools.karpenter.sh -o json | jq -r '
  .items[] |
  select(
    .spec.template.spec.requirements[]? |
    select(.key == "karpenter.sh/capacity-type" and (.values[]? == "spot"))
  ) |
  .metadata.name
')

  if [ -z "$all_spot_nodepools" ]; then
    echo "未找到任何符合条件的Spot类型NodePool,当前环境无需变更！"
    return 0
  fi

  # 真正需要处理的是"spot类型 且 尚未打上目标污点"的节点池。
  # 注意: 必须显式检查 .spec.template.spec.taints 是否已含 key+value+effect 完全匹配的污点,
  # 否则会把已打污点的 spot 池也误判为"未打污点"。
  spot_nodepools=$(kubectl get nodepools.karpenter.sh -o json | jq -r \
    --arg k "$TAINT_KEY" --arg v "$TAINT_VALUE" --arg e "$TAINT_EFFECT" '
  .items[] |
  select(
    .spec.template.spec.requirements[]? |
    select(.key == "karpenter.sh/capacity-type" and (.values[]? == "spot"))
  ) |
  select(
    ((.spec.template.spec.taints // []) | any(
      .key == $k and ((.value // "") == $v) and ((.effect // "") == $e)
    )) | not
  ) |
  .metadata.name
')

  # 所有 spot 池均已打目标污点,无需再追加污点;但仍需校验关键服务(trino-worker/starrocks-cn)是否都已有容忍
  if [ -z "$spot_nodepools" ]; then
    echo -e "\e[32m\e[1m检测到的所有【spot类型节点池】均已打上目标污点(${TAINT_KEY}=${TAINT_VALUE}:${TAINT_EFFECT})。\e[0m"
    echo "当前spot类型节点池列表:"
    echo "$all_spot_nodepools" | sed 's/^/  - /'
    echo ""

    #即便污点已就位,关键服务若缺容忍仍是隐患。以【控制器】为单位检测(规避存量Pending旧Pod导致的窗口期误报)
    local affected_critical
    affected_critical=$(find_untolerated_critical_workloads "$TAINT_KEY" "$TAINT_VALUE")

    if [ -z "$affected_critical" ]; then
      echo -e "\e[32m\e[1m当前环境非常标准，所有spot节点池都已有污点，trino-worker/starrocks-cn等需要spot节点的服务(其控制器)都有容忍策略，无需任何变更！\e[0m"
    else
      echo -e "\e[31m\e[1m注意:spot污点虽已就位,但以下【必须容忍spot污点】的关键服务【其控制器未配置容忍策略】,可能无法调度到spot节点:\e[0m"
      #复用统一处理: 打印 -> 人工确认 -> 安全幂等追加容忍(溯源/容忍校验已在检测函数完成)
      handle_critical_untolerated "$affected_critical" "$TAINT_KEY" "$TAINT_VALUE" "$TAINT_EFFECT"
    fi
    return 0
  fi

  echo -e "\e[31m\e[1m检测到以下【spot类型节点池】当前【未打污点】,需重点关注:\e[0m"
  echo -e "\e[31m\e[1m$spot_nodepools\e[0m"
  echo ""

  # 在执行 on-demand 节点池检查与受影响服务确认前,先做整体说明,让用户理解后续两步的目的
  echo -e "为了避免spot池打污点操作影响到未有容忍策略的服务，现开始检查环境：要求必须存在on-demand节点池承载服务、打印未有容忍的服务列表要求人工确认影响"
  echo ""

  # ===== 前提1: 确认存在可用的 on-demand 类型节点组 =====
  # spot 节点组打 NoSchedule 后,无对应容忍的 Pod 需要 on-demand 节点承载;若无 on-demand 节点组则放弃操作
  local ondemand_nodepools
  ondemand_nodepools=$(kubectl get nodepools.karpenter.sh -o json | jq -r '
  .items[] |
  select(
    .spec.template.spec.requirements[]? |
    select(.key == "karpenter.sh/capacity-type" and (.values[]? == "on-demand"))
  ) |
  .metadata.name
')
  if [ -z "$ondemand_nodepools" ]; then
    log_error "未检测到任何 on-demand 类型节点组,为避免无对应容忍的 Pod 无处调度,已跳过 spot 节点组污点追加。"
    return 0
  fi
  echo "确认存在 on-demand 类型节点组(可承载无对应容忍的 Pod):"
  echo "$ondemand_nodepools"
  echo ""

  # ===== 前提3: 打印受影响的 Pod =====
  # NoSchedule 不驱逐存量 Pod,但加污点后,凡是没有匹配该污点容忍(toleration)的 Pod 都将无法再调度到 spot 节点,视为理论受影响范围
  local affected_pods
  affected_pods=$(kubectl get pods -A -o json | jq -r --arg k "$TAINT_KEY" --arg v "$TAINT_VALUE" '
    .items[]
    | select(
        ((.spec.tolerations // []) | any(
          (.effect == null or .effect == "" or .effect == "NoSchedule")
          and (
            (.operator == "Exists" and (.key == null or .key == "" or .key == $k))
            or ((.operator == "Equal" or .operator == null) and .key == $k and .value == $v)
          )
        )) | not
      )
    | "\(.metadata.namespace)/\(.metadata.name)"
  ')
  echo "确认以下 Pod 无对应容忍,加污点后将无法调度到 spot 节点(理论受影响范围):"
  if [ -z "$affected_pods" ]; then
    echo "  (无:当前所有 Pod 均已容忍该污点)"
  else
    echo "$affected_pods" | sed 's/^/  - /'
    echo "受影响 Pod 总数: $(echo "$affected_pods" | grep -c .)"
  fi
  echo ""

  # ===== 关键服务容忍策略校验 =====
  # 以【控制器】为单位检测(trino-worker按名/starrocks-cn按标签 -> 溯源控制器 -> 校验控制器模板容忍),
  # 既规避 starrocks-cn 因Pod名不含关键字漏检,又规避存量Pending旧Pod导致的"补完容忍仍误报"窗口期问题。
  local critical_workloads
  critical_workloads=$(find_untolerated_critical_workloads "$TAINT_KEY" "$TAINT_VALUE")
  if [ -n "$critical_workloads" ]; then
    echo -e "\e[31m\e[1m================================ 重点警告 ================================\e[0m"
    echo -e "\e[31m\e[1m检测到以下【必须容忍spot污点】的关键服务(trino-worker/starrocks-cn)【其控制器未配置容忍策略】,加污点后将被拒绝调度:\e[0m"
    echo -e "\e[31m\e[1m=========================================================================\e[0m"
    echo ""
    #复用统一处理: 打印 -> 人工确认 -> 安全幂等追加容忍
    handle_critical_untolerated "$critical_workloads" "$TAINT_KEY" "$TAINT_VALUE" "$TAINT_EFFECT"
  fi

  # ===== 前提2: 需要人工确认 =====
  local confirm_taint
  read -p "以上为受影响范围。确认要为上述 spot 节点组追加 ${TAINT_KEY}=${TAINT_VALUE}:${TAINT_EFFECT} 污点吗? <y/n> " confirm_taint
  confirm_taint=$(echo "$confirm_taint" | tr '[:upper:]' '[:lower:]')
  if [ "$confirm_taint" != "y" ]; then
    echo "已取消 spot 节点组污点追加操作。"
    return 0
  fi

  # 步骤2: 为找到的每个NodePool幂等地追加污点
  for nodepool in $spot_nodepools; do
    echo "正在处理 NodePool: $nodepool"

    # 读取该节点组现有的 taints 数组(可能为空)
    local existing_taints
    existing_taints=$(kubectl get nodepools.karpenter.sh "$nodepool" \
      -o jsonpath='{.spec.template.spec.taints}' 2>/dev/null)
    if [ -z "$existing_taints" ]; then
      existing_taints="[]"
    fi

    # 幂等判断:若相同 key+value+effect 的污点已存在则跳过,避免重复写入
    local already_exists
    already_exists=$(echo "$existing_taints" | jq --arg k "$TAINT_KEY" --arg v "$TAINT_VALUE" --arg e "$TAINT_EFFECT" \
      'any(.[]; .key == $k and .value == $v and .effect == $e)')
    if [ "$already_exists" == "true" ]; then
      echo "NodePool $nodepool 已存在目标污点,跳过。"
      echo "---"
      continue
    fi

    # 读-改-写:在现有 taints 基础上追加目标污点,保留原有其他污点,再整体写回。
    # 因 NodePool 为 CRD,strategic merge 对数组通常不可用(缺少 patchMergeKey),
    # 故这里显式构造完整的 taints 数组,用 merge patch 整体替换,从而保证"不丢失现有污点"。
    local merged_taints
    merged_taints=$(echo "$existing_taints" | jq -c --arg k "$TAINT_KEY" --arg v "$TAINT_VALUE" --arg e "$TAINT_EFFECT" \
      '. + [{"key": $k, "value": $v, "effect": $e}]')

    local TAINT_PATCH
    TAINT_PATCH=$(jq -nc --argjson taints "$merged_taints" \
      '{"spec": {"template": {"spec": {"taints": $taints}}}}')

    kubectl patch nodepools.karpenter.sh "$nodepool" --type merge -p "$TAINT_PATCH"

    if [ $? -eq 0 ]; then
      echo "成功为 $nodepool 追加污点。"
    else
      echo "为 $nodepool 打污点时出错。"
    fi
    echo "---"
  done
  echo "操作完成。"
}

#通用的节点组可用性测试
test_nodepool() {
  local NODEPOOL_NAME=$1
  echo -e "\n******** 开始测试节点组 [$NODEPOOL_NAME] 可用性 ******"

  # 创建测试 deployment，其名称带上节点组名
  local DEPLOYMENT_NAME="debug-${NODEPOOL_NAME//[^a-zA-Z0-9]/-}"

  #如果AWS中国区则优先使用数数仓库镜像，避免从docker hub拉取镜像失败问题
  ZONE=$(get_zone)
  if [[ "${ZONE}" =~ "cn-north"(.*) ]]; then
    NGINX_IMAGE="${NGINX_IMAGE_CN}"
  fi

  #在K8S环境中创建nginx服务
  echo "*** 测试项1: 在节点组 ${NODEPOOL_NAME} 启动nginx服 *** "
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: nginx-test
    nodepool: ${NODEPOOL_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-test
  template:
    metadata:
      labels:
        app: nginx-test
        nodepool: ${NODEPOOL_NAME}
    spec:
      containers:
      - name: nginx
        image: ${NGINX_IMAGE}
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5
      nodeSelector:
        node.kubernetes.type: ${NODEPOOL_NAME}
      # 测试Pod需容忍所有可能的节点组污点以完成调度验证。billing-mode口径仅od/spot两类:
      # spot节点组会被打上 billing-mode=spot:NoSchedule 污点(见taints_all_spot_nodepool),故必须容忍spot;
      # od节点组默认不打污点,od容忍为防御性保留。reserved付费类型AWS EKS不存在,已移除该死容忍。
      tolerations:
      - effect: NoSchedule
        key: node.k8s.te/billing-mode
        operator: Equal
        value: spot
      - effect: NoSchedule
        key: node.k8s.te/billing-mode
        operator: Equal
        value: od
EOF

  # 等待Pod运行，确认POD状态
  echo "等待Pod启动,预期3分钟内启动"
  sleep 5
  TIMEOUT=180
  ELAPSED=0
  POD_READY=false
  while [ $ELAPSED -lt $TIMEOUT ]; do
    POD_STATUS=$(kubectl get pods -n $NAMESPACE -l app=nginx-test,nodepool=${NODEPOOL_NAME} -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    if [ "$POD_STATUS" == "Running" ]; then
      POD_READY=true
      POD_NAME=$(kubectl get pods -n $NAMESPACE -l app=nginx-test,nodepool=${NODEPOOL_NAME} -o jsonpath='{.items[0].metadata.name}')
      POD_IP=$(kubectl get pods -n $NAMESPACE -l app=nginx-test,nodepool=${NODEPOOL_NAME} -o jsonpath='{.items[0].status.podIP}')
      echo "节点组${NODEPOOL_NAME}启动Pod正常，Pod Name: $POD_NAME , Pod IP: $POD_IP"
      echo -e "\e[32m\e[1m测试结论：正常！${NODEPOOL_NAME} 节点组成功调度并启动nginx服务!\e[0m"

      break
    fi
    echo "等待Pod启动...... "
    sleep 5
    let ELAPSED+=5
  done

  if ! $POD_READY; then
    log_error "测试结论：异常！Pod未在${TIMEOUT}秒内启动，请排查后重试，常见原因(按概率排序): "
    echo -e "\e[31m\e[1m1. 节点组资源对象未就绪:请执行 kubectl get karpenter 确认 NodePool/EC2NodeClass 是否 READY=True;\n   若为 False,再执行 kubectl describe ec2nodeclass ${NODEPOOL_NAME} 查看 SubnetsReady/SecurityGroupsReady 等子条件(常见为子网/安全组未打 karpenter.sh/discovery 发现标签)\n2. K8S无实例可调度(如机型在该可用区无库存、超出limits)\n3. 节点组不通外网/镜像仓库导致镜像拉取失败\n排查明细请执行: kubectl describe pods -n $NAMESPACE -l app=nginx-test\e[0m"
    exit 1
  fi

  #开始检查本地服务器访问K8S环境nginx是否正常
  echo "*** 测试项2: 云主机访问nginx容器是否通畅 ***"
  if curl -s -m 10 "http://$POD_IP" | grep -q "Welcome to nginx!"; then
    echo -e "\e[32m\e[1m测试结论：正常！云主机访问nginx容器通畅！\e[0m"
  else
    log_error "测试结论：异常！测试云主机访问nginx容器失败!"
    echo -e "\e[31m\e[1m可能是因为K8S环境节点组 ${NODEPOOL_NAME} 绑定安全组未放行集群所绑定的安全组,请联系客户放行 \e[0m"
  fi

  #开始检查K8S环境pod访问集群本地服务器是否畅通,取ta1的19039 presto metric监控端口，用于后续K8S访问集群网络连通性测试
  echo "*** 测试项3: 容器访问云主机是否通畅 ***"
  LOCAL_SERVER_IP=$(grep ta1 /etc/hosts | head -1 | awk '{print $1}')
  LOCAL_SERVER_PORT=19039
  #先确认本地ta1的确监听着19039,如果因为特殊原因ta1未监听该端口，可更换为exporter端口9100
  if nc -z -w 2 $LOCAL_SERVER_IP $LOCAL_SERVER_PORT; then
    echo "测试从Pod访问本地服务器: $LOCAL_SERVER_IP:$LOCAL_SERVER_PORT"
  else
    #19039端口不存在，切换为9100 exporter端口
    LOCAL_SERVER_PORT=9100
    echo "测试从Pod访问本地服务器: $LOCAL_SERVER_IP:$LOCAL_SERVER_PORT"
  fi

  # 在Pod内执行curl命令
  if kubectl exec -it $POD_NAME -n $NAMESPACE -- curl -LsS -m 10 "http://$LOCAL_SERVER_IP:$LOCAL_SERVER_PORT/metrics" &>/dev/null; then
    echo -e "\e[32m\e[1m测试结论：正常！容器访问云主机通畅！ \e[0m"
  else
    log_error "测试结论：异常！Pod无法访问云主机!"
    echo -e "\e[31m\e[1m可能原因:  \e[0m"
    echo -e "\e[31m\e[1m1. 本地服务器和POD并非统一内网网段，服务器iptables阻止了来自K8S网络的访问 \e[0m"
    echo -e "\e[31m\e[1m2. 本地服务器绑定安全组未放行K8S安全组,请联系客户放行 \e[0m"
  fi
  echo -e "******** 节点组 [$NODEPOOL_NAME] 可用性测试结束,请关注测试结论,如果有红色预警信息请跟进确认处理********"

  kubectl get deploy -n $NAMESPACE -l app=nginx-test | grep -v 'NAME' | awk '{print $1}' | xargs kubectl patch deploy -n $NAMESPACE --patch '{"spec":{"replicas":0}}' &>/dev/null

}

#清理测试资源即临时启动的deployment
clean_check_resource() {
  echo -e "Tips: 为避免测试造成的资源浪费，现将测试样例deployment置0。你可以手动调试或者再次执行本脚本检查节点组可用性"
  kubectl get deploy -n $NAMESPACE -l app=nginx-test | grep -v 'NAME' | awk '{print $1}' | xargs kubectl patch deploy -n $NAMESPACE --patch '{"spec":{"replicas":0}}' &>/dev/null
}

# 校验 NodePool 及其关联 EC2NodeClass 是否 Ready,是创建测试Pod的前提
# 背景:节点组资源对象(NodePool/EC2NodeClass)Ready=False 时,Karpenter无法provision节点,测试Pod会一直Pending直到超时。
#      提前校验可快速失败并给出准确原因(如子网/安全组发现标签缺失),避免干等180秒后才暴露问题。
# 入参:可选,指定要校验的节点组名(空格分隔);【不传则校验当前所有NodePool】。
#      base门禁校验会只传 base-nodepool,实现"base先行验证,不通过则快速失败,不浪费时间建后续业务节点组"。
# 策略:最多轮询60秒;超时仍未Ready则打印精准原因线索(kubectl get karpenter + 未就绪资源的关键condition)后退出。
wait_nodepools_ready() {
  log_step "校验节点组资源对象(NodePool/EC2NodeClass)是否就绪"
  local TIMEOUT=60 ELAPSED=0 ALL_READY=false

  # 收集待校验的 NodePool 名称:有入参则只校验入参指定的,否则校验全部
  local nodepools
  if [ $# -gt 0 ]; then
    nodepools="$*"
  else
    nodepools=$(kubectl get nodepool -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
  fi
  if [ -z "$nodepools" ]; then
    log_error "未获取到任何NodePool,无法校验就绪状态,请确认节点组是否创建成功。"
    exit 1
  fi

  echo "正在等待以下节点组就绪(最多${TIMEOUT}秒): ${nodepools}"
  while [ $ELAPSED -lt $TIMEOUT ]; do
    local not_ready=""
    local np
    for np in $nodepools; do
      # NodePool 的顶层 Ready condition
      local np_ready
      np_ready=$(kubectl get nodepool "$np" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
      if [ "$np_ready" != "True" ]; then
        not_ready="${not_ready} ${np}"
      fi
    done

    if [ -z "$not_ready" ]; then
      ALL_READY=true
      break
    fi
    echo "仍有节点组未就绪,等待中......(已等待 ${ELAPSED}s)"
    sleep 5
    let ELAPSED+=5
  done

  if $ALL_READY; then
    log_success "所有节点组资源对象均已就绪(Ready=True)!"
    kubectl get karpenter
    return 0
  fi

  # 超时未就绪:打印精准原因线索后退出
  log_error "错误:部分节点组在${TIMEOUT}秒内未就绪(Ready=False),已终止后续可用性测试。未就绪节点组:${not_ready}"
  echo -e "\e[31m\e[1m========== 节点组资源对象状态总览 ==========\e[0m"
  kubectl get karpenter
  echo ""
  echo -e "\e[31m\e[1m========== 未就绪原因线索(精准定位) ==========\e[0m"
  local np
  for np in $not_ready; do
    echo -e "\e[33m\e[1m● 节点组 ${np}:\e[0m"
    # NodePool 的 Ready condition reason/message
    local np_reason np_msg
    np_reason=$(kubectl get nodepool "$np" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)
    np_msg=$(kubectl get nodepool "$np" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)
    echo "    NodePool.Ready:  reason=${np_reason:-未知}  message=${np_msg:-无}"
    # EC2NodeClass(同名)所有 status=False 的 condition,逐条打印 type/reason/message
    echo "    EC2NodeClass 未就绪子条件:"
    kubectl get ec2nodeclass "$np" -o json 2>/dev/null | jq -r '
      .status.conditions[]? | select(.status != "True")
      | "      - \(.type): reason=\(.reason) message=\(.message // "无")"' 2>/dev/null
  done
  echo ""
  echo -e "\e[31m\e[1m常见根因: 子网(SubnetsReady=False,SubnetSelector未匹配到子网)或安全组(SecurityGroupsReady=False)缺少发现标签。\e[0m"
  echo -e "\e[31m\e[1m请补打发现标签后重试:子网只需存在 key ${subnetSelectorKey:-karpenter.sh/discovery-subnet}(value 不限,只按key匹配);安全组需 key ${securityGroupSelectorKey:-karpenter.sh/discovery-sg}=集群名(精确匹配)。\e[0m"
  exit 1
}

# 获取节点组并测试可用性
test_all_nodepools() {
  #获取当前所有节点组信息
  NODEPOOL_NAMES=($(kubectl get karpenter | awk '/ec2nodeclass/ {split($1, a, "/"); print a[2]}'))

  if [ -z "${NODEPOOL_NAMES}" ]; then
    log_error "未获取到节点组信息，请确认是否需要重试本脚本尝试创建？"
    exit 1
  else
    log_step "开始测试EKS/节点组可用性，包括容器的调度和起服是否正常、云主机与容器之间网络互通性等"
    echo "检测到当前EKS集群已有节点组：${NODEPOOL_NAMES[@]}"
    # 定义可用性测试所用的命名空间，如不存在则创建
    if ! kubectl get ns $NAMESPACE &>/dev/null; then
      echo "为可用性测试创建命名空间: $NAMESPACE"
      kubectl create ns $NAMESPACE
    fi

    # 测试所有节点组
    for np in "${NODEPOOL_NAMES[@]}"; do
      test_nodepool "$np"
    done
    echo ""
    log_success "****************** 所有节点组都已测试完成，请关注测试结论，如果有红色预警信息请跟进确认处理 ******************"

    #所有业务节点组都测试完成后，清理测试资源，避免资源浪费
    clean_check_resource
  fi

}

###检测karpenter pod 运行是否正常,这是节点组创建的必要条件，如果karpenter异常需要及时通知用户并退出节点组创建程序
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
    log_error "错误：Karpenter状态异常，退出节点组创建和可用性测试流程，请确认eks和karpenter等依赖服务状态健康后重试本脚本"
    exit 1
  fi

  #检查eks/karpente版本，api-versions版本是否符合预期，老版本标准是karpenter.k8s.aws/v1、karpenter.sh/v1
  eks_api_versions_check=$(kubectl api-versions | grep -E '^karpenter.k8s.aws/v1$|^karpenter.sh/v1$' | wc -l)
  if [ ${eks_api_versions_check} -lt 2 ]; then
    log_error "当前EKS版本较低，不支持所需Api,无法自动创建节点组!"
    log_error "请参考https://thinkingdata.feishu.cn/wiki/RvGxwQnnSijuQbkKQQScX7MKntc手动创建所需节点组然后重试本脚本进行节点组可用性检查"
    log_error "或参考https://thinkingdata.feishu.cn/wiki/QUquwBMtPienoHknJk0cyLnOncb升级EKS版本至较新版后重试本脚本进行节点组创建及可用性检查"
    echo "当前EKS版本是:"
    kubectl version
    exit 1
  fi
}

#主函数/脚本逻辑
main() {
  #执行用户检查
  checkUser

  #检查k8s是否可访问
  test_k8s_connection

  while true; do
    #询问用户是想要创建节点组并测试可用性 or 仅测试节点组可用性？
    #未来可能会新增其他自动化场景比如EKS版本升级，这里采用case esac控制流结构易于理解和维护
    echo "请选择操作类型："
    echo -e " 1.创建节点组并测试其可用性"
    echo -e " 2.仅测试已有节点组可用性"
    echo -e " 3.仅为spot节点组追加污点检查"
    read -p ">" user_input
    # 将输入转换为小写进行统一判断
    normalized_input=$(echo "$user_input" | tr '[:upper:]' '[:lower:]')

    case $normalized_input in
    1)
      #检查eks和karpenter是否支持开展后续的节点组创建流程
      check_eks_karpenter_status
      #创建业务节点组，需要用户输入所需创建的节点组名称及规格信息
      build_nodepool_for_business
      #创建完成后先校验节点组资源对象是否就绪(Ready),不就绪则给出精准原因并退出,避免测试Pod干等超时
      wait_nodepools_ready
      #公共测试逻辑，测试EKS/节点组可用性，包括各节点组调度可用性、网络连通性等等
      test_all_nodepools
      ;;
    2)
      #仅测试已有节点组可用性:同样先校验就绪状态再测试
      wait_nodepools_ready
      test_all_nodepools
      ;;
    3)
      #独立入口:仅执行spot节点组污点检查(内部含on-demand节点组检查、受影响Pod打印、人工确认三道前提)
      log_step "为spot类型节点组追加污点"
      taints_all_spot_nodepool
      ;;
    *)
      echo "无效输入，请重新输入！"
      continue
      ;;
    esac
    break
  done
}

# 执行主函数
main "$@"
