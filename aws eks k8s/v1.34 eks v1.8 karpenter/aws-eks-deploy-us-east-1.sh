#!/bin/bash
# AWS EKS 一键部署脚本,顺序执行：安装工具 -> 创建EKS集群 -> 部署Karpenter

set -euo pipefail

#############################################
#           用户配置区（必填）                #
#############################################
# EKS集群所在VPC的ID
VPC_ID="vpc-0e23aeed4f779ddab"

# EKS集群所在地域，格式us-east-1
AWS_DEFAULT_REGION=""

#必需参数:EKS所在地域可用区1
ZONE_1="us-east-1a"

# 可用区1中的public类型子网ID
PUBLIC_SUBNET_ID1="subnet-xxx"

# 可用区1中的private类型子网ID
PRIVATE_SUBNET_ID1="subnet-yyy"

#必需参数:EKS所在地域可用区2
ZONE_2="us-east-1b"

# 可用区2中的public类型子网ID
PUBLIC_SUBNET_ID2="subnet-zzz"

# 可用区2中的private类型子网ID
PRIVATE_SUBNET_ID2="subnet-uuu"

#############################################
#           预置参数（无需修改）              #
#############################################
EKS_VERSION="1.34"
CLUSTER_NAME="ThinkingAiEks"
KARPENTER_VERSION="1.8.3"
AWS_PARTITION="aws"
ARCH=$(uname -m)

# 断点文件和日志文件
STATE_FILE="/tmp/aws_eks_deploy_state.checkpoint"
LOG_FILE="/tmp/aws_eks_deploy_$(date +'%Y%m%d_%H%M%S').log"
RESULT_FILE="/tmp/aws_eks_deploy_result.log"

#############################################
#              工具函数                      #
#############################################
log_info() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $1"
    echo -e "\e[32m\e[1m$msg\e[0m"
    echo "$msg" >>"$LOG_FILE"
}

log_error() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $1"
    echo -e "\e[31m\e[1m$msg\e[0m"
    echo "$msg" >>"$LOG_FILE"
}

log_warn() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] $1"
    echo -e "\e[33m\e[1m$msg\e[0m"
    echo "$msg" >>"$LOG_FILE"
}

# 初始化断点文件
init_checkpoint() {
    if [[ ! -f "$STATE_FILE" ]]; then
        touch "$STATE_FILE"
        log_info "创建断点文件: $STATE_FILE"
    fi
}

# 检查步骤是否已完成
is_step_done() {
    local step="$1"
    grep -q "^${step}=done$" "$STATE_FILE" 2>/dev/null
}

# 标记步骤完成
mark_step_done() {
    local step="$1"
    if ! is_step_done "$step"; then
        echo "${step}=done" >>"$STATE_FILE"
    fi
    log_info "✓ 步骤完成: $step"
}

# 检查命令是否存在
command_exists() {
    command -v "$1" &>/dev/null
}

# 安装系统软件包
install_package() {
    local pkg="$1"
    if ! rpm -q "$pkg" &>/dev/null; then
        log_info "安装依赖包: $pkg"
        sudo yum install -y "$pkg" >>"$LOG_FILE" 2>&1
    fi
}

# 获取元数据Token（IMDSv2）
get_metadata_token() {
    curl -s -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || echo ""
}

# 自动获取地域信息
get_region() {
    local region=""
    # 尝试IMDSv1
    region=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document 2>/dev/null | jq -r .region 2>/dev/null)
    if [[ -z "${region}" || "${region}" == "null" ]]; then
        # 尝试IMDSv2
        local token
        token=$(get_metadata_token)
        if [[ -n "$token" ]]; then
            region=$(curl -s -H "X-aws-ec2-metadata-token: ${token}" \
                http://169.254.169.254/latest/dynamic/instance-identity/document 2>/dev/null | jq -r .region 2>/dev/null)
        fi
    fi
    echo "${region}"
}

# 获取子网所在可用区
get_subnet_zone() {
    local subnet_id="$1"
    aws ec2 describe-subnets --subnet-ids "$subnet_id" \
        --query 'Subnets[0].AvailabilityZone' --output text 2>/dev/null
}

#############################################
#          步骤1：安装基础工具               #
#############################################
step1_install_tools() {
    local step="STEP1_INSTALL_TOOLS"

    if is_step_done "$step"; then
        log_info "步骤1已完成，跳过"
        return 0
    fi

    log_info "========== 步骤1：安装基础工具 =========="

    # 安装基础依赖
    install_package "wget"
    install_package "unzip"
    install_package "jq"

    # 安装 AWS CLI
    if ! command_exists aws; then
        log_info "安装 AWS CLI..."
        local awscli_url
        case "$ARCH" in
        x86_64) awscli_url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
        aarch64) awscli_url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
        *)
            log_error "不支持的架构: $ARCH"
            exit 1
            ;;
        esac
        curl -sL "$awscli_url" -o "awscliv2.zip" >>"$LOG_FILE" 2>&1
        unzip -q awscliv2.zip >>"$LOG_FILE" 2>&1
        sudo ./aws/install >>"$LOG_FILE" 2>&1
        rm -rf aws awscliv2.zip
        log_info "AWS CLI 安装完成: $(aws --version)"
    else
        log_info "AWS CLI 已安装: $(aws --version)"
    fi

    # 安装 eksctl
    if ! command_exists eksctl; then
        log_info "安装 eksctl..."
        local eksctl_url
        case "$ARCH" in
        x86_64) eksctl_url="https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" ;;
        aarch64) eksctl_url="https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_arm64.tar.gz" ;;
        *)
            log_error "不支持的架构: $ARCH"
            exit 1
            ;;
        esac
        curl -sL "$eksctl_url" -o "eksctl.tar.gz" >>"$LOG_FILE" 2>&1
        tar -zxf eksctl.tar.gz >>"$LOG_FILE" 2>&1
        sudo cp ./eksctl /usr/local/bin/eksctl
        sudo chmod +x /usr/local/bin/eksctl
        rm -f eksctl.tar.gz eksctl
        log_info "eksctl 安装完成: $(eksctl version)"
    else
        log_info "eksctl 已安装: $(eksctl version)"
    fi

    # 安装 kubectl ， 增加了Major.minor版本号对比判断逻辑，如果版本符合需求则不需要重复安装
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
        log_info "未检测到kubectl，开始安装 ${EKS_VERSION} 版本"
    else
        # 从 v1.34.0 中提取主版本号(X)和次版本号(Y)，忽略补丁号(Z)
        local installed_full=$(kubectl version --client 2>/dev/null | head -1)
        local installed_major=$(echo "$installed_full" | grep -oP 'v\K[0-9]+' | head -1)
        local installed_minor=$(echo "$installed_full" | grep -oP 'v[0-9]+\.\K[0-9]+' | head -1)
        MAJOR_VERSION=$(echo "$EKS_VERSION" | grep -oP 'v\K[0-9]+' | head -1)
        MINOR_VERSION=$(echo "$EKS_VERSION" | grep -oP 'v[0-9]+\.\K[0-9]+' | head -1)
        log_info "检测到已安装kubectl，版本: $installed_full"
        log_info "目标版本: ${EKS_VERSION} (Major=${MAJOR_VERSION}, Minor=${MINOR_VERSION})"
        log_info "当前版本: $installed_major.$installed_minor"

        if [[ "$installed_major" == "${MAJOR_VERSION}" && "$installed_minor" == "${MINOR_VERSION}" ]]; then
            log_success "kubectl版本($installed_major.$installed_minor)已匹配目标版本(${EKS_VERSION})，无需重新安装"
            return 0
        else
            log_info "kubectl版本($installed_major.$installed_minor)与目标版本(${EKS_VERSION})不一致，开始更新"
            local BACKUP_FILE="/usr/local/bin/kubectl_bak_$(date +%Y%m%d_%H%M%S)"
            mv "$(command -v kubectl)" "${BACKUP_FILE}"
            log_info "已将老版本kubectl备份至: $BACKUP_FILE"
        fi
    fi

    local kubectl_url="https://download-thinkingdata.oss-cn-shanghai.aliyuncs.com/ta/tools/kubectl-${EKS_VERSION}-${TARGET_ARCH}"
    log_info "架构: $ARCH -> ${TARGET_ARCH}, 下载地址: $kubectl_url"
    if ! curl -sLO "$kubectl_url"; then
        log_error "kubectl下载失败，正在回滚到备份版本..."
        if [[ -n "${BACKUP_FILE}" ]] && [[ -f "${BACKUP_FILE}" ]]; then
            mv "${BACKUP_FILE}" "$(command -v kubectl)"
            log_info "已回滚到备份版本: $(command -v kubectl)"
        fi
        exit 1
    fi
    cp -f "kubectl-${EKS_VERSION}-${TARGET_ARCH}" /usr/local/bin/kubectl
    chmod +x /usr/local/bin/kubectl
    log_success "kubectl安装完成, 版本: $(kubectl version --client 2>/dev/null | head -1)"

    # 安装 Helm
    if ! command_exists helm; then
        log_info "安装 Helm..."
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o get_helm.sh >>"$LOG_FILE" 2>&1
        chmod 700 get_helm.sh
        ./get_helm.sh >>"$LOG_FILE" 2>&1
        rm -f get_helm.sh
        log_info "Helm 安装完成: $(helm version --short)"
    else
        log_info "Helm 已安装: $(helm version --short)"
    fi

    # 确保 /usr/local/bin 在 PATH 中
    if [[ ":$PATH:" != *":/usr/local/bin:"* ]]; then
        export PATH=$PATH:/usr/local/bin
        log_info "已将 /usr/local/bin 添加到 PATH"
    fi

    mark_step_done "$step"
}

#############################################
#          步骤2：创建EKS集群                #
#############################################
step2_create_eks() {
    local step="STEP2_CREATE_EKS"

    if is_step_done "$step"; then
        log_info "步骤2已完成，跳过"
        return 0
    fi

    # 检查是否有同名集群冲突
    if aws eks describe-cluster --name "$CLUSTER_NAME" >>"$LOG_FILE" 2>&1; then
        log_info "EKS 集群 [$CLUSTER_NAME] 已存在，跳过创建"
        return 0
    fi

    log_info "========== 步骤2：创建EKS集群 =========="

    # 配置 AWS CLI 地域
    aws configure set region "$AWS_DEFAULT_REGION"

    # 创建 EKS 集群配置文件
    local eks_config="/tmp/eks-cluster-config.yaml"
    cat >"$eks_config" <<EOF
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

    log_info "EKS 配置文件已生成: $eks_config"

    # 创建 EKS 集群
    log_info "开始创建 EKS 集群（预计需要 15-20 分钟）..."
    if eksctl create cluster -f "$eks_config" >>"$LOG_FILE" 2>&1; then
        log_info "EKS 集群创建成功"
    else
        log_error "EKS 集群创建失败，请查看日志: $LOG_FILE"
        exit 1
    fi

    # 更新 kubeconfig
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_DEFAULT_REGION" >>"$LOG_FILE" 2>&1
    log_info "kubeconfig 已更新"

    # 验证集群
    if kubectl get nodes >>"$LOG_FILE" 2>&1; then
        log_info "集群节点验证成功"
    else
        log_error "集群节点验证失败"
        exit 1
    fi

    mark_step_done "$step"
}

#############################################
#          步骤3：配置EKS IP预留             #
#############################################
step3_configure_ip_prefix() {
    local step="STEP3_CONFIGURE_IP_PREFIX"

    if is_step_done "$step"; then
        log_info "步骤3已完成，跳过"
        return 0
    fi

    log_info "========== 步骤3：配置EKS集群IP预留 =========="

    # 启用 prefix delegation
    kubectl set env daemonset aws-node -n kube-system ENABLE_PREFIX_DELEGATION=true >>"$LOG_FILE" 2>&1
    kubectl set env daemonset aws-node -n kube-system WARM_PREFIX_TARGET=1 >>"$LOG_FILE" 2>&1

    log_info "IP prefix delegation 已启用"
    mark_step_done "$step"
}

#############################################
#    步骤4：创建Karpenter Cloudformation     #
#############################################
step4_create_karpenter_cloudformation() {
    local step="STEP4_KARPENTER_CLOUDFORMATION"

    if is_step_done "$step"; then
        log_info "步骤4已完成，跳过"
        return 0
    fi

    log_info "========== 步骤4：创建Karpenter Cloudformation基础依赖 =========="

    local template_file="/tmp/karpenter-cloudformation.yaml"
    curl -fsSL "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml" \
        -o "$template_file" >>"$LOG_FILE" 2>&1

    aws cloudformation deploy \
        --stack-name "Karpenter-${CLUSTER_NAME}" \
        --template-file "$template_file" \
        --capabilities CAPABILITY_NAMED_IAM \
        --parameter-overrides "ClusterName=${CLUSTER_NAME}" >>"$LOG_FILE" 2>&1

    # 等待 CloudFormation 完成
    local max_wait=300
    local waited=0
    while [ $waited -lt $max_wait ]; do
        local status
        status=$(aws cloudformation describe-stacks --stack-name "Karpenter-${CLUSTER_NAME}" \
            --query "Stacks[0].StackStatus" --output text 2>/dev/null)

        if [[ "$status" == "CREATE_COMPLETE" ]]; then
            log_info "Karpenter CloudFormation 创建成功"
            break
        elif [[ "$status" == "CREATE_FAILED" || "$status" == "ROLLBACK_COMPLETE" ]]; then
            log_error "CloudFormation 创建失败: $status"
            exit 1
        fi

        sleep 10
        waited=$((waited + 10))
    done

    if [ $waited -ge $max_wait ]; then
        log_error "CloudFormation 创建超时"
        exit 1
    fi

    mark_step_done "$step"
}

#############################################
#    步骤5：创建IAM Service Account          #
#############################################
step5_create_iam_serviceaccount() {
    local step="STEP5_IAM_SERVICEACCOUNT"

    if is_step_done "$step"; then
        log_info "步骤5已完成，跳过"
        return 0
    fi

    log_info "========== 步骤5：创建IAM Service Account =========="

    local aws_account_id
    aws_account_id=$(aws sts get-caller-identity --query Account --output text)

    eksctl create iamserviceaccount \
        --cluster "$CLUSTER_NAME" \
        --name karpenter \
        --namespace karpenter \
        --role-name "${CLUSTER_NAME}-karpenter" \
        --attach-policy-arn "arn:${AWS_PARTITION}:iam::${aws_account_id}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}" \
        --role-only \
        --approve >>"$LOG_FILE" 2>&1

    # 验证 IAM Role
    if aws iam get-role --role-name "${CLUSTER_NAME}-karpenter" >>"$LOG_FILE" 2>&1; then
        log_info "IAM Service Account 创建成功"
    else
        log_error "IAM Service Account 创建失败"
        exit 1
    fi

    mark_step_done "$step"
}

#############################################
#    步骤6：创建IAM Identity Mapping         #
#############################################
step6_create_iam_identity_mapping() {
    local step="STEP6_IAM_IDENTITY_MAPPING"

    if is_step_done "$step"; then
        log_info "步骤6已完成，跳过"
        return 0
    fi

    log_info "========== 步骤6：创建IAM Identity Mapping =========="

    local aws_account_id
    aws_account_id=$(aws sts get-caller-identity --query Account --output text)

    eksctl create iamidentitymapping \
        --cluster "$CLUSTER_NAME" \
        --region "$AWS_DEFAULT_REGION" \
        --arn "arn:${AWS_PARTITION}:iam::${aws_account_id}:role/KarpenterNodeRole-${CLUSTER_NAME}" \
        --group system:bootstrappers \
        --group system:nodes \
        --username system:node:{{EC2PrivateDNSName}} >>"$LOG_FILE" 2>&1

    log_info "IAM Identity Mapping 创建成功"
    mark_step_done "$step"
}

#############################################
#    步骤7：启用Spot实例                     #
#############################################
step7_enable_spot() {
    local step="STEP7_ENABLE_SPOT"

    if is_step_done "$step"; then
        log_info "步骤7已完成，跳过"
        return 0
    fi

    log_info "========== 步骤7：启用Spot类型实例 =========="

    aws iam create-service-linked-role --aws-service-name spot.amazonaws.com >>"$LOG_FILE" 2>&1 || true

    log_info "Spot 实例已启用"
    mark_step_done "$step"
}

#############################################
#    步骤8：部署Karpenter                    #
#############################################
step8_deploy_karpenter() {
    local step="STEP8_DEPLOY_KARPENTER"

    if is_step_done "$step"; then
        log_info "步骤8已完成，跳过"
        return 0
    fi

    log_info "========== 步骤8：部署Karpenter =========="

    # 获取必要信息
    local aws_account_id cluster_endpoint
    aws_account_id=$(aws sts get-caller-identity --query Account --output text)
    cluster_endpoint=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query "cluster.endpoint" --output text)

    # 创建 karpenter namespace
    kubectl create namespace karpenter 2>/dev/null || true

    # 使用 Helm 部署 Karpenter
    export HELM_EXPERIMENTAL_OCI=1

    helm registry logout public.ecr.aws || true

    helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
        --version "${KARPENTER_VERSION}" \
        --namespace karpenter \
        --create-namespace \
        --set "settings.clusterName=${CLUSTER_NAME}" \
        --set "settings.clusterEndpoint=${cluster_endpoint}" \
        --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:${AWS_PARTITION}:iam::${aws_account_id}:role/${CLUSTER_NAME}-karpenter" \
        --set controller.resources.requests.cpu=1 \
        --set controller.resources.requests.memory=1Gi \
        --set controller.resources.limits.cpu=1 \
        --set controller.resources.limits.memory=1Gi \
        --wait >>"$LOG_FILE" 2>&1

    # 等待 Karpenter Pod 就绪
    local max_wait=120
    local waited=0
    while [ $waited -lt $max_wait ]; do
        local pod_status
        pod_status=$(kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")

        if [[ "$pod_status" == "Running" ]]; then
            log_info "Karpenter 部署成功"
            kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter >>"$LOG_FILE" 2>&1
            break
        fi

        sleep 5
        waited=$((waited + 5))
    done

    if [ $waited -ge $max_wait ]; then
        log_error "Karpenter Pod 启动超时"
        exit 1
    fi

    mark_step_done "$step"
}

#############################################
#              打印执行计划                  #
#############################################
print_execution_plan() {
    echo ""
    echo "============================================"
    echo "           AWS EKS 部署执行计划"
    echo "============================================"
    echo "1. 安装基础工具（awscli, eksctl, kubectl, helm）"
    echo "2. 创建EKS集群"
    echo "3. 配置EKS集群IP预留"
    echo "4. 创建Karpenter Cloudformation基础依赖环境"
    echo "5. 创建IAM Service Account"
    echo "6. 创建IAM Identity Mapping"
    echo "7. 启用Spot类型实例"
    echo "8. 部署Karpenter"
    echo "============================================"
    echo ""
}

#############################################
#              检查执行结果                  #
#############################################
check_execution_result() {
    echo "" | tee -a "$RESULT_FILE"
    echo "============================================" | tee -a "$RESULT_FILE"
    echo "           部署完成情况检查" | tee -a "$RESULT_FILE"
    echo "============================================" | tee -a "$RESULT_FILE"

    local all_done=true
    local steps=(
        "STEP1_INSTALL_TOOLS:1. 安装基础工具"
        "STEP2_CREATE_EKS:2. 创建EKS集群"
        "STEP3_CONFIGURE_IP_PREFIX:3. 配置EKS集群IP预留"
        "STEP4_KARPENTER_CLOUDFORMATION:4. 创建Karpenter Cloudformation基础依赖"
        "STEP5_IAM_SERVICEACCOUNT:5. 创建IAM Service Account"
        "STEP6_IAM_IDENTITY_MAPPING:6. 创建IAM Identity Mapping"
        "STEP7_ENABLE_SPOT:7. 启用Spot类型实例"
        "STEP8_DEPLOY_KARPENTER:8. 部署Karpenter"
    )

    for step_info in "${steps[@]}"; do
        local step_name="${step_info%%:*}"
        local step_desc="${step_info#*:}"

        if is_step_done "$step_name"; then
            echo "[✓] $step_desc" | tee -a "$RESULT_FILE"
        else
            echo "[✗] $step_desc" | tee -a "$RESULT_FILE"
            all_done=false
        fi
    done

    echo "============================================" | tee -a "$RESULT_FILE"

    if $all_done; then
        echo "" | tee -a "$RESULT_FILE"
        log_info "所有步骤已完成！"
        echo "" | tee -a "$RESULT_FILE"
        log_info "集群信息:"
        log_info "  集群名称: $CLUSTER_NAME"
        log_info "  集群版本: $EKS_VERSION"
        log_info "  集群地域: $AWS_DEFAULT_REGION"
        echo "" | tee -a "$RESULT_FILE"
        log_info "后续操作:"
        log_info "  1. 配置 kubectl: aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_DEFAULT_REGION"
        log_info "  2. 验证集群: kubectl get nodes"
        log_info "  3. 验证 Karpenter: kubectl get pods -n karpenter"
        echo "" | tee -a "$RESULT_FILE"
        log_info "日志文件: $LOG_FILE"
        log_info "断点文件: $STATE_FILE"
        log_info "结果文件: $RESULT_FILE"
    else
        log_error "部分步骤未完成，请检查日志: $LOG_FILE"
        exit 1
    fi
}

#############################################
#    验证可用区和子网ID的关联关系           #
#############################################
validate_subnet_zone_mapping() {
    log_info "========== 验证可用区和子网ID关联关系 =========="

    local validation_failed=false
    local valid_subnet_count=0

    # 检查子网ID是否有效（非空）
    is_valid_subnet_id() {
        local subnet_id="$1"
        if [[ -z "$subnet_id" ]]; then
            return 1
        fi
        return 0
    }

    # 验证可用区1的public子网
    if is_valid_subnet_id "$PUBLIC_SUBNET_ID1"; then
        local actual_zone1_public
        actual_zone1_public=$(get_subnet_zone "$PUBLIC_SUBNET_ID1")
        if [[ -z "$actual_zone1_public" ]]; then
            log_error "PUBLIC_SUBNET_ID1 ($PUBLIC_SUBNET_ID1) 不存在或无法访问！"
            validation_failed=true
        elif [[ "$actual_zone1_public" != "$ZONE_1" ]]; then
            log_error "可用区1的public子网ID配置错误！"
            log_error "  配置的可用区: $ZONE_1"
            log_error "  PUBLIC_SUBNET_ID1 ($PUBLIC_SUBNET_ID1) 实际所属可用区: $actual_zone1_public"
            validation_failed=true
        else
            log_info "✓ PUBLIC_SUBNET_ID1 ($PUBLIC_SUBNET_ID1) 属于可用区 $ZONE_1"
            valid_subnet_count=$((valid_subnet_count + 1))
        fi
    else
        log_warn "PUBLIC_SUBNET_ID1 未配置，跳过验证"
    fi

    # 验证可用区1的private子网
    if is_valid_subnet_id "$PRIVATE_SUBNET_ID1"; then
        local actual_zone1_private
        actual_zone1_private=$(get_subnet_zone "$PRIVATE_SUBNET_ID1")
        if [[ -z "$actual_zone1_private" ]]; then
            log_error "PRIVATE_SUBNET_ID1 ($PRIVATE_SUBNET_ID1) 不存在或无法访问！"
            validation_failed=true
        elif [[ "$actual_zone1_private" != "$ZONE_1" ]]; then
            log_error "可用区1的private子网ID配置错误！"
            log_error "  配置的可用区: $ZONE_1"
            log_error "  PRIVATE_SUBNET_ID1 ($PRIVATE_SUBNET_ID1) 实际所属可用区: $actual_zone1_private"
            validation_failed=true
        else
            log_info "✓ PRIVATE_SUBNET_ID1 ($PRIVATE_SUBNET_ID1) 属于可用区 $ZONE_1"
            valid_subnet_count=$((valid_subnet_count + 1))
        fi
    else
        log_warn "PRIVATE_SUBNET_ID1 未配置，跳过验证"
    fi

    # 验证可用区2的public子网
    if is_valid_subnet_id "$PUBLIC_SUBNET_ID2"; then
        local actual_zone2_public
        actual_zone2_public=$(get_subnet_zone "$PUBLIC_SUBNET_ID2")
        if [[ -z "$actual_zone2_public" ]]; then
            log_error "PUBLIC_SUBNET_ID2 ($PUBLIC_SUBNET_ID2) 不存在或无法访问！"
            validation_failed=true
        elif [[ "$actual_zone2_public" != "$ZONE_2" ]]; then
            log_error "可用区2的public子网ID配置错误！"
            log_error "  配置的可用区: $ZONE_2"
            log_error "  PUBLIC_SUBNET_ID2 ($PUBLIC_SUBNET_ID2) 实际所属可用区: $actual_zone2_public"
            validation_failed=true
        else
            log_info "✓ PUBLIC_SUBNET_ID2 ($PUBLIC_SUBNET_ID2) 属于可用区 $ZONE_2"
            valid_subnet_count=$((valid_subnet_count + 1))
        fi
    else
        log_warn "PUBLIC_SUBNET_ID2 未配置，跳过验证"
    fi

    # 验证可用区2的private子网
    if is_valid_subnet_id "$PRIVATE_SUBNET_ID2"; then
        local actual_zone2_private
        actual_zone2_private=$(get_subnet_zone "$PRIVATE_SUBNET_ID2")
        if [[ -z "$actual_zone2_private" ]]; then
            log_error "PRIVATE_SUBNET_ID2 ($PRIVATE_SUBNET_ID2) 不存在或无法访问！"
            validation_failed=true
        elif [[ "$actual_zone2_private" != "$ZONE_2" ]]; then
            log_error "可用区2的private子网ID配置错误！"
            log_error "  配置的可用区: $ZONE_2"
            log_error "  PRIVATE_SUBNET_ID2 ($PRIVATE_SUBNET_ID2) 实际所属可用区: $actual_zone2_private"
            validation_failed=true
        else
            log_info "✓ PRIVATE_SUBNET_ID2 ($PRIVATE_SUBNET_ID2) 属于可用区 $ZONE_2"
            valid_subnet_count=$((valid_subnet_count + 1))
        fi
    else
        log_warn "PRIVATE_SUBNET_ID2 未配置，跳过验证"
    fi

    # 检查是否至少有2个有效子网（EKS最低要求）
    if [[ $valid_subnet_count -lt 2 ]]; then
        log_error "至少需要配置2个有效的子网ID（分布在不同可用区）以满足EKS高可用要求！"
        log_error "当前有效子网数量: $valid_subnet_count"
        validation_failed=true
    else
        log_info "有效子网数量: $valid_subnet_count (满足EKS最低要求)"
    fi

    # 如果验证失败，退出脚本
    if $validation_failed; then
        log_error "可用区和子网ID关联关系验证失败，请检查配置！"
        log_error "提示：请确保每个子网ID存在且对应的可用区与配置的ZONE_1/ZONE_2一致"
        exit 1
    fi

    log_info "可用区和子网ID关联关系验证通过"
}

#############################################
#              参数校验                      #
#############################################
validate_parameters() {
    log_info "========== 参数校验 =========="

    # 校验 VPC ID
    if [[ -z "$VPC_ID" || "$VPC_ID" == "vpc-xxx" ]]; then
        log_error "请配置正确的 VPC_ID"
        exit 1
    fi

    # 自动获取或校验地域
    if [[ -z "$AWS_DEFAULT_REGION" ]]; then
        AWS_DEFAULT_REGION=$(get_region)
        if [[ -z "$AWS_DEFAULT_REGION" ]]; then
            log_error "无法自动获取地域信息，请手动配置 AWS_DEFAULT_REGION"
            exit 1
        fi
        log_info "自动检测到地域: $AWS_DEFAULT_REGION"
    fi

    # 校验子网 ID是否存在，和可用区关系是否准确
    validate_subnet_zone_mapping

    log_info "参数校验通过"
    log_info "VPC: $VPC_ID"
    log_info "地域: $AWS_DEFAULT_REGION"
    log_info "可用区：$ZONE_1, $ZONE_2"
    log_info "Public Subnets: $PUBLIC_SUBNET_ID1, $PUBLIC_SUBNET_ID2"
    log_info "Private Subnets: $PRIVATE_SUBNET_ID1, $PRIVATE_SUBNET_ID2"
}

#############################################
#              主函数                        #
#############################################
main() {
    echo "AWS EKS 一键部署脚本"
    echo "开始时间: $(date +'%Y-%m-%d %H:%M:%S')"
    echo ""

    # 初始化
    init_checkpoint
    echo "部署开始时间: $(date +'%Y-%m-%d %H:%M:%S')" >"$RESULT_FILE"

    # 打印执行计划
    print_execution_plan

    # 参数校验
    validate_parameters

    # 执行各步骤
    step1_install_tools
    step2_create_eks
    step3_configure_ip_prefix
    step4_create_karpenter_cloudformation
    step5_create_iam_serviceaccount
    step6_create_iam_identity_mapping
    step7_enable_spot
    step8_deploy_karpenter

    # 检查执行结果
    check_execution_result

    echo ""
    echo "部署完成时间: $(date +'%Y-%m-%d %H:%M:%S')"
}

# 执行主函数
main "$@"
