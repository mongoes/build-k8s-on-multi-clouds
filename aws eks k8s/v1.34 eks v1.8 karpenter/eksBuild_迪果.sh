#!/bin/bash
#用于AWS环境创建EKS容器服

#set -euo pipefail

###############################################################################
# 用户配置区（必填）
# 请将数数参考文档中2.2章节收集信息粘贴至此处
###############################################################################

#必需参数：EKS所在地域，需按实际填写
AWS_DEFAULT_REGION="us-east-1"

#必需参数:EKS所在地域可用区1
ZONE_1="us-east-1a"

#必需参数:EKS所在地域可用区2
ZONE_2="us-east-1b"

#必需参数5：所在VPC的id
VPC_ID="vpc-cb3659ad"

#必需参数: 可用区1中的public类型子网id
PUBLIC_SUBNET_ID1="subnet-0dc3ff04412aafa74"

#必需参数7: 可用区2中的public类型子网id
PUBLIC_SUBNET_ID2="subnet-0ed0517d4b9e7e2b6"

#必需参数8: 可用区1中的private类型子网id
PRIVATE_SUBNET_ID1="subnet-0c01956bf3c1f24d1"

#必需参数9: 可用区2中的private类型子网id
PRIVATE_SUBNET_ID2="subnet-0ed7db55eebe7060d"

###############################################################################
# 预置参数（无需修改）
###############################################################################
# EKS集群名称
CLUSTER_NAME="eks-thinkingdata"

#EKS版本号
EKS_VERSION="1.34"

# Karpenter 版本
KARPENTER_VERSION="1.8.3"

ARCH=$(uname -m)

AWS_PARTITION="aws"

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

CLUSTER_ENDPOINT=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.endpoint" --output text)

ROLE_NAME="${CLUSTER_NAME}-karpenter"

#Set KARPENTER_IAM_ROLE_ARN variables.
KARPENTER_IAM_ROLE_ARN="arn:${AWS_PARTITION}:iam::$AWS_ACCOUNT_ID:role/$CLUSTER_NAME-karpenter"

# 日志设置 和 断点文件设置
LOG_FILE="eksBuild_$(date +'%Y-%m-%d').log"
STATUS_FILE="eks_build_${CLUSTER_NAME}.status"

exec > >(tee -a "$LOG_FILE") 2>&1

###############################################################################
#              工具函数
###############################################################################

# 标记步骤已完成
mark_step_done() {
	echo "$1" >>"$STATUS_FILE"
}

# 检查步骤是否已完成
is_step_done() {
	grep -qxF "$1" "$STATUS_FILE" 2>/dev/null
}

###############################################################################
# 通用函数
###############################################################################
log_info() { echo -e "[INFO]  $*"; }
log_success() { echo -e "\e[32m[SUCCESS]\e[0m $*"; }
log_error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; }

# 获取当前EC2所在地域（通过实例元数据）
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 30" 2>/dev/null)
get_region() {
	local region_message=""
	#  优先尝试从默认的URL中解析可用区信息
	region_message=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region 2>/dev/null)
	if [ -z "${region_message}" ]; then
		#如果默认URL获取不到，可能是因为当前ec2启用了IMDSv2，请求元数据需要token认证
		region_message=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region 2>/dev/null)
	fi

	echo ${region_message}

}

# 确保 region 已设置（若用户未配置，则尝试自动获取）
if [[ -z "${AWS_DEFAULT_REGION:-}" ]]; then
	log_error "未配置地域信息，将尝试自动获取"
	AWS_DEFAULT_REGION=$(get_region)
	if [[ -z "$AWS_DEFAULT_REGION" ]]; then
		read -p "无法自动获取地域，请手动输入地域（例如 us-east-1）: " AWS_DEFAULT_REGION
		if [[ -z "$AWS_DEFAULT_REGION" ]]; then
			log_error "地域不能为空，退出"
			exit 1
		fi
	fi
fi
export AWS_DEFAULT_REGION
log_info "使用地域：$AWS_DEFAULT_REGION"

# 获取当前EC2所在可用区
#获取可用区的方法
get_availability_zone() {
	local zone_message=""
	#  优先尝试从默认的URL中解析可用区信息
	zone_message=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .availabilityZone 2>/dev/null)
	if [ -z "${zone_message}" ]; then
		#如果默认URL获取不到，可能是因为当前ec2启用了IMDSv2，请求元数据需要token认证
		zone_message=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .availabilityZone 2>/dev/null)
	fi
	echo ${zone_message}
}

# 检查命令是否存在
check_command() {
	command -v "$1" >/dev/null 2>&1
}

# 检查EKS集群是否存在且状态是ACTIVE，如是才能判为健康，才可继续后续karpenter的部署
cluster_exists() {
	aws eks list-clusters --region "$AWS_DEFAULT_REGION" --output text | grep -qw "$CLUSTER_NAME"
}

#检查EKS集群status状态
cluster_status() {
	aws eks describe-cluster --region "$AWS_DEFAULT_REGION" --name ${CLUSTER_NAME} --query "cluster.status"

}

# 检查Karpenter是否已部署（通过命名空间和pod）
karpenter_deployed() {
	kubectl get namespace karpenter >/dev/null 2>&1 &&
		kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter >/dev/null 2>&1
}

###############################################################################
# 步骤1：安装基础工具（awscli, eksctl, kubectl, helm, 等）
###############################################################################
install_base_tools() {
	log_info "步骤1：安装基础工具（awscli, eksctl, kubectl, helm）"

	# 安装系统依赖
	local sys_pkgs=("wget" "unzip" "jq")
	for pkg in "${sys_pkgs[@]}"; do
		if ! check_command "$pkg"; then
			log_info "安装 $pkg ..."
			sudo yum install -y "$pkg"
		fi
	done

	# 安装 awscli v2
	if ! check_command aws; then
		log_info "安装 awscli ..."
		local arch
		arch=$(uname -m)
		case $arch in
		x86_64) curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" ;;
		aarch64) curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip" ;;
		*)
			log_error "不支持的架构: $arch"
			exit 1
			;;
		esac
		unzip -q awscliv2.zip
		sudo ./aws/install
		rm -rf awscliv2.zip aws
	else
		log_info "awscli 已存在，版本：$(aws --version)"
	fi

	# 安装最新版本eksctl，如果当前环境已经存在eksctl,先备份再下载新版本
	if command -v eksctl &>/dev/null; then
		CURRENT_EKSCTL_VERSION=$(eksctl version)
		log_info "检测到当前服务器已经安装eksctl,版本是$CURRENT_EKSCTL_VERSION"
		log_info "本脚本将会备份老版本eksctl为/usr/local/bin/eksctl_bak，并下载最新稳定版,如有老版本eksctl使用需求可手动回滚"
		EKSCTL_FILE=$(which eksctl)
		BACKUP_FILE="/usr/local/bin/eksctl_bak_$(date +%Y%m%d_%H%M%S)"
		mv ${EKSCTL_FILE} ${BACKUP_FILE}
	fi

	log_info "安装 eksctl ..."
	case $ARCH in
	x86_64)
		TARGET_ARCH="amd64"
		curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" -o "eksctl.tar.gz"
		;;
	aarch64)
		TARGET_ARCH="arm64"
		curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_arm64.tar.gz" -o "eksctl.tar.gz"
		;;
	*)
		echo -e "\e[31m不支持的架构: $ARCH\e[0m"
		exit 1
		;;
	esac
	tar -zxvf eksctl.tar.gz
	cp ./eksctl /usr/local/bin/eksctl
	chmod -R 777 /usr/local/bin/eksctl
	log_info "eksctl安装完成，当前版本是: $(eksctl version)"

	# 安装 kubectl (指定版本 1.34.2)，如检测到已有kubectl，则先备份再安装目标版本
	# 下载参考ttps://docs.aws.amazon.com/zh_cn/eks/latest/userguide/install-kubectl.html
	if command -v kubectl &>/dev/null; then
		CURRENT_VERSION=$(kubectl version --client | head -1)
		log_info "******** 检测到当前服务器已经安装kubectl,版本是$CURRENT_VERSION ********"
		log_info "本脚本将会备份老版本kubectl为/usr/local/bin/kubectl_bak，并下载当前次新稳定版,如有老版本kubectl使用需求可手动回滚"
		KUBECTL_FILE=$(which kubectl)
		BACKUP_FILE="/usr/local/bin/kubectl_bak_$(date +%Y%m%d_%H%M%S)"
		mv ${KUBECTL_FILE} ${BACKUP_FILE}
	fi
	log_info ""安装 kubectl ...""
	case $ARCH in
	x86_64)
		TARGET_ARCH="amd64"
		curl -sLO "https://s3.us-west-2.amazonaws.com/amazon-eks/1.34.2/2025-11-13/bin/linux/amd64/kubectl"
		;;
	aarch64)
		TARGET_ARCH="arm64"
		curl -sLO "https://s3.us-west-2.amazonaws.com/amazon-eks/1.34.2/2025-11-13/bin/linux/arm64/kubectl"
		;;
	*)
		log_error "不支持的架构: $ARCH"
		exit 1
		;;
	esac

	cp ./kubectl /usr/local/bin/kubectl
	chmod -R 777 /usr/local/bin/kubectl
	log_info "kubectl安装完成，当前版本是: $(kubectl version --client)"

	# 安装 helm
	if ! check_command helm; then
		log_info "安装 helm ..."
		curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
		chmod 700 get_helm.sh
		./get_helm.sh
		rm -f get_helm.sh
	else
		log_info "helm 已存在，版本：$(helm version)"
	fi

	# 确保 /usr/local/bin 在 PATH 中
	if [[ ":$PATH:" != *":/usr/local/bin:"* ]]; then
		echo 'export PATH=$PATH:/usr/local/bin' >>~/.bashrc
		export PATH="$PATH:/usr/local/bin"
	fi
	# 配置 AWS CLI region
	aws configure set region "$AWS_DEFAULT_REGION"

	log_success "基础工具安装完成"
	mark_step_done "step1_base_tools"
}

###############################################################################
# 步骤2：创建 EKS 集群
###############################################################################
create_eks_cluster() {
	log_info "步骤2：创建 EKS 集群 ${CLUSTER_NAME}"

	# 检查集群是否已存在
	if cluster_exists; then
		log_error "集群 ${CLUSTER_NAME} 已存在，请确认历史资源能否清理或者选择重命名EKS集群CLUSTER_NAME后重试脚本"
		exit 1
	fi

	eksctl create cluster -f - <<EOF
---
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_DEFAULT_REGION}
  version: "${EKS_VERSION}"
  tags:
    karpenter.sh/discovery: karpenter-${CLUSTER_NAME}
managedNodeGroups:
  - instanceType: m5.large
    amiFamily: Bottlerocket
    name: ${CLUSTER_NAME}-ng
    desiredCapacity: 2
    minSize: 2
    maxSize: 5
vpc:
  id: ${VPC_ID}
  subnets:
    private:
      ${ZONE_1}: { id: ${PRIVATE_SUBNET_ID1} }
      ${ZONE_2}: { id: ${PRIVATE_SUBNET_ID2} }
    public:
      ${ZONE_1}: { id: ${PUBLIC_SUBNET_ID1} }
      ${ZONE_2}: { id: ${PUBLIC_SUBNET_ID2} }
iam:
  withOIDC: true
EOF

	# 等待集群就绪（eksctl 默认会等待，但这里再确认一次）
	if ! cluster_exists; then
		log_error "集群创建失败，未找到 ${CLUSTER_NAME}"
		exit 1
	fi

	log_success "EKS 集群创建成功"
	mark_step_done "step2_eks_cluster"
}

###############################################################################
# 步骤3：集群创建后配置（kubeconfig 和 aws-node 调优）
###############################################################################
step_post_cluster_config() {
	log_info "步骤3：EKS集群后置配置，调整 aws-node 预留 IP"

	# 更新 kubeconfig
	aws eks update-kubeconfig --region "$AWS_DEFAULT_REGION" --name "$CLUSTER_NAME" --kubeconfig ~/.kube/config

	# 限制预热 IP 数量，避免 IP 耗尽
	kubectl set env daemonset aws-node -n kube-system WARM_IP_TARGET=6 --overwrite

	log_success "EKS集群后置配置完成"
	mark_step_done "step3_post_config"
}

###############################################################################
# 步骤4：创建Karpenter Cloudformation基础依赖环境
###############################################################################
step_create_karpenter_cloudformation() {
	log_info "步骤4: 创建Karpenter Cloudformation基础依赖环境"
	# 设置 region（karpenter 脚本中用到）
	aws configure set region "$AWS_DEFAULT_REGION"
	local template_file="karpenter-cloudformation-template-${CLUSTER_NAME}.yaml"
	curl -fsSL https://raw.githubusercontent.com/aws/karpenter-provider-aws/v"${KARPENTER_VERSION}"/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml >$TEMPOUT && aws cloudformation deploy \
		--stack-name "Karpenter-${CLUSTER_NAME}" \
		--template-file "${template_file}" \
		--capabilities CAPABILITY_NAMED_IAM \
		--parameter-overrides "ClusterName=${CLUSTER_NAME}"

	#提交创建stack指令后，检查是否正常创建出stack资源
	STACK_NAME="Karpenter-${CLUSTER_NAME}"
	MAX_RETRIES=30
	INTERVAL=10
	count=0
	CLOUDFORMATION_READY=false
	while [ $count -lt $MAX_RETRIES ]; do
		STATUS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].StackStatus" --output text)
		if [[ $STATUS == "CREATE_COMPLETE" ]]; then
			CLOUDFORMATION_READY=true
			log_success "Karpenter Cloudformation基础依赖环境创建成功"
			mark_step_done "step4_create_karpenter_cloudformation"
			break
		elif [[ $STATUS == "CREATE_FAILED" || $STATUS == "ROLLBACK_COMPLETE" ]]; then
			log_error "堆栈状态异常：${STATUS},创建Karpenter Cloudformation基础依赖环境失败！请登录AWS Cloudformation确认原因！"
			exit 1
		else
			echo "当前状态: $STATUS，等待 $INTERVAL 秒后重试..."
			sleep $INTERVAL
			count=$((count + 1))
		fi
	done

	if ! ${CLOUDFORMATION_READY}; then
		log_error "错误：等待超时，堆栈状态未完成,创建Karpenter Cloudformation基础依赖环境失败！请登录AWS Cloudformation确认原因！"
		exit 1
	fi
}

###############################################################################
# 步骤5：创建Kubernetes service account and AWS IAM Role
# "***** Create a Kubernetes service account and AWS IAM Role, and associate them using IRSA(IAM Roles for Service Accounts) to let Karpenter launch instances. ***"
# 对应的将在cloudformation处生成一个名为：eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-karpenter-karpenter的stack堆栈;
###############################################################################
create_karpenter_iamserviceaccount() {
	# 创建 IAM Service Account (IRSA)
	log_info "创建 IAM Service Account"
	eksctl create iamserviceaccount \
		--cluster "$CLUSTER_NAME" \
		--name karpenter \
		--namespace karpenter \
		--role-name "$CLUSTER_NAME-karpenter" \
		--attach-policy-arn "arn:${AWS_PARTITION}:iam::$AWS_ACCOUNT_ID:policy/KarpenterControllerPolicy-$CLUSTER_NAME" \
		--role-only \
		--approve

	# 检查aws role
	if ! aws iam get-role --role-name $ROLE_NAME >/dev/null 2>&1; then
		log_error "创建Kubernetes service account and AWS IAM Role失败!!!"
		exit 1
	fi

	# 检查role是否绑定了目标策略
	EXPECT_POLICY="arn:${AWS_PARTITION}:iam::$AWS_ACCOUNT_ID:policy/KarpenterControllerPolicy-$CLUSTER_NAME"
	ATTACHED_POLICIES=$(aws iam list-attached-role-policies --role-name $ROLE_NAME | jq .AttachedPolicies[0].PolicyArn)
	if [ -z "${ATTACHED_POLICIES}" ] || [[ "${ATTACHED_POLICIES//\"/}" != "${EXPECT_POLICY}" ]]; then
		log_error "建Kubernetes service account and AWS IAM Role失败!!!"
		exit 1
	fi
	log_success "IAM Service Account创建成功"
	mark_step_done "step5_create_karpenter_iamserviceaccount"

}

###############################################################################
# 步骤6：授予EC2实例链接EKS集群的权限
# 使用配置文件授予 Amazon EC2 实例连接到集群的访问权限，将Karpenter节点角色添加到您的 aws-auth 配置映射，允许具有此角色的节点加入EKS集群
# Add the Karpenter node role to the aws-auth configmap to allow nodes to connect.实际上对应着kubectl edit configmap aws-auth -n kube-system
###############################################################################

create_karpenter_iamidentitymapping() {
	log_info "创建Karpenter IAM Identity Mapping"
	eksctl create iamidentitymapping \
		--username system:node:{{EC2PrivateDNSName}} \
		--cluster "$CLUSTER_NAME" \
		--arn "arn:${AWS_PARTITION}:iam::$AWS_ACCOUNT_ID:role/KarpenterNodeRole-$CLUSTER_NAME" \
		--group system:bootstrappers \
		--group system:nodes

	if ! eksctl get iamidentitymapping --cluster ${CLUSTER_NAME} --arn "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}"; then
		log_error "创建Karpenter IAM Identity Mapping 失败! "
		exit 1
	else
		log_success "创建Karpenter IAM Identity Mapping成功!"
		mark_step_done "step6_create_karpenter_iamidentitymapping"
	fi

}

###############################################################################
# 步骤7：启用Spot
###############################################################################
enabled_spot() {
	log_info "启用Spot类型实例..."
	log_info "如果当前账号已经启用过可能会收到提示：Service role name AWSServiceRoleForEC2Spot has been taken in this account..可忽略该提示，不影响整体流程"
	SERVICE_NAME="spot.amazonaws.com"
	ROLE_NAME="AWSServiceRoleForEC2Spot"

	# 检查服务关联角色是否已存在
	if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
		log_success "启用Spot类型实例成功！"
		mark_step_done "step7_enabled_spot"
	else
		# 未找到目标角色，开始创建
		if aws iam create-service-linked-role --aws-service-name "$SERVICE_NAME" >/dev/null 2>&1; then
			log_success "启用Spot类型实例成功"
			mark_step_done "step7_enabled_spot"
		else
			log_error "启用Spot类型实例失败!!!"
			exit 1
		fi
	fi
}

###############################################################################
# 步骤8：部署karpenter
###############################################################################
deploy_karpenter() {

	echo "准备工作都已完成，打印karpenter部署所需参"
	echo "参数1 EKS集群名: $CLUSTER_NAME"
	echo "参数2 EKS集群端点: $CLUSTER_ENDPOINT"
	echo "参数3 karpenter版本: $KARPENTER_VERSION"
	echo "参数4 karpenter拥有的IAM ROLE ARN: serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$KARPENTER_IAM_ROLE_ARN"
	echo "参数5 karpenter实例概要: KarpenterNodeInstanceProfile-$CLUSTER_NAME"
	log_info "开始部署Karpenter Deployment"

	export HELM_EXPERIMENTAL_OCI=1
	helm registry logout public.ecr.aws || true
	helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version ${KARPENTER_VERSION} --namespace karpenter --create-namespace \
		--set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=${KARPENTER_IAM_ROLE_ARN} \
		--set "settings.clusterName=${CLUSTER_NAME}" \
		--set "settings.interruptionQueue=${CLUSTER_NAME}" \
		--set controller.resources.requests.cpu=1 \
		--set controller.resources.requests.memory=1Gi \
		--set controller.resources.limits.cpu=1 \
		--set controller.resources.limits.memory=1Gi \
		--wait

	# 检查 karpenter Pod 状态
	log_info "等待 Karpenter Pod 启动..."
	sleep 5
	TIMEOUT=120
	SECONDS=0
	POD_READY=false
	while [ $SECONDS -lt $TIMEOUT ]; do
		POD_STATUS=$(kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
		if [ "$POD_STATUS" == "Running" ]; then
			POD_READY=true
			log_success "Karpenter 部署完成"
			mark_step_done "step8_deploy_karpenter"
			kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter -o wide >>${RESULT_FILE}
			break
		fi
		echo "等待Pod启动... (状态: ${POD_STATUS:-未知})"
		sleep 5
	done

	if ! $POD_READY; then
		log_error "部署Karpenter失败！请kubectl describe pods -n karpenter -l app.kubernetes.io/name=karpenter人工排查"
		exit 1
	fi

	log_success "Karpenter 部署完成"
	mark_step_done "step8_deploy_karpenter"
}

###############################################################################
# 主程序
###############################################################################
main() {
	# 打印执行计划
	echo "================================================================================"
	echo "执行计划："
	echo "1. 安装基础工具（awscli, eksctl, kubectl, helm）"
	echo "2. 创建EKS集群"
	echo "3. 配置EKS集群IP预留"
	echo "4. 创建Cloudformation基础依赖环境"
	echo "5. 创建IAM Service Account"
	echo "6. 创建IAM Identity Mapping"
	echo "7. 启用Spot类型实例"
	echo "8. 创建karpenter"
	echo "================================================================================"
	echo ""
	sleep 1s

	# 如果断点文件不存在，初始化
	if [[ ! -f "$STATUS_FILE" ]]; then
		touch "$STATUS_FILE"
	fi

	# 按顺序执行步骤，每个步骤执行前检查是否已完成
	if ! is_step_done "step1_base_tools"; then
		install_base_tools
	else
		log_info "步骤1. 安装基础工具 已完成，跳过"
	fi

	if ! is_step_done "step2_eks_cluster"; then
		create_eks_cluster
	else
		log_info "步骤2. 创建EKS集群 已完成，跳过"
	fi

	if ! is_step_done "step3_post_config"; then
		step_post_cluster_config
	else
		log_info "步骤3. 配置EKS集群IP预留 已完成，跳过"
	fi

	if ! is_step_done "step4_create_karpenter_cloudformation"; then
		create_karpenter_cloudformation
	else
		log_info "步骤4. 创建Cloudformation基础依赖环境 已完成，跳过"
	fi

	if ! is_step_done "step5_create_karpenter_iamserviceaccount"; then
		create_karpenter_iamserviceaccount
	else
		log_info "步骤5. 创建IAM Service Account 已完成，跳过"
	fi

	if ! is_step_done "step6_create_karpenter_iamidentitymapping"; then
		create_karpenter_iamidentitymapping
	else
		log_info "步骤6. 创建IAM Identity Mapping 已完成，跳过"
	fi

	if ! is_step_done "step7_enabled_spot"; then
		enabled_spot
	else
		log_info "步骤7. 启用Spot类型实例 已完成，跳过"
	fi

	if ! is_step_done "step8_deploy_karpenter"; then
		deploy_karpenter
	else
		log_info "步骤8. 创建karpenter 已完成，跳过"
	fi

	# 汇总
	echo ""
	echo "================================================================================"
	echo "执行情况汇总："
	echo "1. 安装基础工具 已完成"
	echo "2. 创建EKS集群 已完成"
	echo "3. 配置EKS集群IP预留 已完成"
	echo "4. 创建Cloudformation基础依赖环境 已完成"
	echo "5. 创建IAM Service Account 已完成"
	echo "6. 创建IAM Identity Mapping 已完成"
	echo "7. 启用Spot类型实例 已完成"
	echo "8. 创建karpenter 已完成"
	echo "断点状态文件${STATUS_FILE} ,如需重置EKS，请删除该文件，断点内容打印：cat ${STATUS_FILE}"
	echo "详细日志请查看：${LOG_FILE}"
	echo "================================================================================"
}

# 执行主函数
main
