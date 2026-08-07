#!/bin/bash
#本脚本主要用于AWS EKS容器服接入时部署Karpenter调度服务
#适用于X86_64和ARM架构服务器环境，适用于常见的Linux发行版包括centos7.x、centos stream 9 、amazon linux2023等
set -euo pipefail

# 必需参数1:EKS集群名，默认命名为eks-thinkingai，请注意aws控制台涉及的安全组和子网标签值都默认是集群名
CLUSTER_NAME="ta-eks"
#必需参数2：EKS所在地域，假设是us-east-1
AWS_DEFAULT_REGION="us-east-1"

#########################################
#其他参数已经由数数团队预置，请保持默认不需修改
KARPENTER_VERSION="1.11.1"

AWS_PARTITION="aws"

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

CLUSTER_ENDPOINT=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.endpoint" --output text)

ROLE_NAME="${CLUSTER_NAME}-karpenter"

#Set KARPENTER_IAM_ROLE_ARN variables.
KARPENTER_IAM_ROLE_ARN="arn:${AWS_PARTITION}:iam::$AWS_ACCOUNT_ID:role/$CLUSTER_NAME-karpenter"

RESULT_FILE="/tmp/karpenter_build_result_$(date +'%Y-%m-%d-%H-%M-%S').log"
echo "部署时间：$(date +'%Y-%m-%d %H:%M:%S')" >>${RESULT_FILE}

export HELM_EXPERIMENTAL_OCI=1

green() {
  echo -e "\e[32m\e[1m $1 \e[0m"
}

red() {
  echo -e "\e[31m\e[1m $1 \e[0m"
}

#打印当前脚本执行计划
echo -e "******** 脚本执行计划: ********\n1. 创建Karpenter Cloudformation基础依赖环境\n2. 创建Kubernetes service account and AWS IAM Role\n3. 创建Karpenter IAM Identity Mapping\n4. 启用Spot类型实例 \n5. 部署Karpenter Deployment"

## 设定region
aws configure set region $AWS_DEFAULT_REGION

###刷新 kubeconfig
echo "******** 拉取指定EKS集群的kube config ********"
aws eks --region $AWS_DEFAULT_REGION update-kubeconfig --name $CLUSTER_NAME

#***** 根据Karpenter-cloudformation创建karpenter所依赖的基础环境 *****
#对应的，将在cloudformation处生成一个名为：Karpenter-${CLUSTER_NAME}的stack堆栈
create_karpenter_cloudformation() {
  echo "******** 创建Karpenter Cloudformation基础依赖环境 ********"
  TEMPOUT=template-file-eks1.yaml
  curl -fsSL https://raw.githubusercontent.com/aws/karpenter-provider-aws/v"${KARPENTER_VERSION}"/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml >$TEMPOUT && aws cloudformation deploy \
    --stack-name "Karpenter-${CLUSTER_NAME}" \
    --template-file "${TEMPOUT}" \
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
      green "创建Karpenter Cloudformation基础依赖环境成功！"
      echo -e "1. 创建Karpenter Cloudformation基础依赖环境成功！" >>${RESULT_FILE}
      break
    elif [[ $STATUS == "CREATE_FAILED" || $STATUS == "ROLLBACK_COMPLETE" ]]; then
      red "错误： 堆栈状态异常：${STATUS},创建Karpenter Cloudformation基础依赖环境失败！! !"
      echo -e "1. 创建Karpenter Cloudformation基础依赖环境失败！! !堆栈状态异常：${STATUS}" >>${RESULT_FILE}
      exit 1
    else
      echo "当前状态: $STATUS，等待 $INTERVAL 秒后重试..."
      sleep $INTERVAL
      count=$((count + 1))
    fi
  done

  if ! ${CLOUDFORMATION_READY}; then
    red "错误：等待超时，堆栈状态未完成,创建Karpenter Cloudformation基础依赖环境失败！! !"
    echo -e "1. 创建Karpenter Cloudformation基础依赖环境失败！! !堆栈创建超时" >>${RESULT_FILE}
    exit 1
  fi
}

# # "***** Create a Kubernetes service account and AWS IAM Role, and associate them using IRSA(IAM Roles for Service Accounts) to let Karpenter launch instances. ***"
#对应的，将在cloudformation处生成一个名为：eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-karpenter-karpenter的stack堆栈;
create_karpenter_iamserviceaccount() {
  echo "********  创建Kubernetes service account and AWS IAM Role ********"
  eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" \
    --name karpenter \
    --namespace karpenter \
    --role-name "$CLUSTER_NAME-karpenter" \
    --attach-policy-arn "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerNodeLifecyclePolicy-${CLUSTER_NAME}" \
    --attach-policy-arn "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerIAMIntegrationPolicy-${CLUSTER_NAME}" \
    --attach-policy-arn "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerEKSIntegrationPolicy-${CLUSTER_NAME}" \
    --attach-policy-arn "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerInterruptionPolicy-${CLUSTER_NAME}" \
    --attach-policy-arn "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerResourceDiscoveryPolicy-${CLUSTER_NAME}" \
    --role-only \
    --approve

  # 1. 检查aws role
  if ! aws iam get-role --role-name $ROLE_NAME >/dev/null 2>&1; then
    red "错误： Role创建失败，创建Kubernetes service account and AWS IAM Role失败!!!"
    echo -e "2. 创建Kubernetes service account and AWS IAM Role失败!!!" >>${RESULT_FILE}
    exit 1
  fi

  # 2. 检查role是否绑定了全部5个目标策略
  EXPECT_POLICIES=(
    "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerNodeLifecyclePolicy-${CLUSTER_NAME}"
    "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerIAMIntegrationPolicy-${CLUSTER_NAME}"
    "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerEKSIntegrationPolicy-${CLUSTER_NAME}"
    "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerInterruptionPolicy-${CLUSTER_NAME}"
    "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerResourceDiscoveryPolicy-${CLUSTER_NAME}"
  )
  ATTACHED_POLICIES=$(aws iam list-attached-role-policies --role-name $ROLE_NAME --query "AttachedPolicies[].PolicyArn" --output text)
  for EXPECT_POLICY in "${EXPECT_POLICIES[@]}"; do
    if ! echo "$ATTACHED_POLICIES" | grep -q "$EXPECT_POLICY"; then
      red "错误： 策略 ${EXPECT_POLICY} 未绑定，创建Kubernetes service account and AWS IAM Role失败!!!"
      echo -e "2. 创建Kubernetes service account and AWS IAM Role失败!!!" >>${RESULT_FILE}
      exit 1
    fi
  done

  green "创建KarpenterController IAM Service Account成功！"
  echo -e "2. 创建KarpenterController IAM Service Account成功！" >>${RESULT_FILE}
}

##“*** 使用配置文件授予 Amazon EC2 实例连接到集群的访问权限，将Karpenter节点角色添加到您的 aws-auth 配置映射，允许具有此角色的节点加入EKS集群。***”
#Add the Karpenter node role to the aws-auth configmap to allow nodes to connect.实际上对应着kubectl edit configmap aws-auth -n kube-system
create_karpenter_iamidentitymapping() {
  echo "************ 创建Karpenter IAM Identity Mapping ************"
  eksctl create iamidentitymapping \
    --username system:node:{{EC2PrivateDNSName}} \
    --cluster "$CLUSTER_NAME" \
    --arn "arn:${AWS_PARTITION}:iam::$AWS_ACCOUNT_ID:role/KarpenterNodeRole-$CLUSTER_NAME" \
    --group system:bootstrappers \
    --group system:nodes

  if ! eksctl get iamidentitymapping --cluster ${CLUSTER_NAME} --arn "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}"; then
    red "错误： 创建Karpenter IAM Identity Mapping 失败! ！！"
    echo -e "3. 创建Karpenter IAM Identity Mapping失败！！！" >>${RESULT_FILE}
    exit 1
  else
    green "创建Karpenter IAM Identity Mapping成功!"
    echo -e "3. 创建Karpenter IAM Identity Mapping成功！" >>${RESULT_FILE}
  fi

}

#Create a role to allow spot instances.
enabled_spot() {
  echo -e "******** 启用Spot类型实例 ********"
  echo "如果当前账号已经启用过可能会收到提示：Service role name AWSServiceRoleForEC2Spot has been taken in this account..可忽略该提示，不影响整体流程"
  SERVICE_NAME="spot.amazonaws.com"
  ROLE_NAME="AWSServiceRoleForEC2Spot"

  # 检查服务关联角色是否已存在
  echo "检查 Spot 服务关联角色状态..."
  if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    green "启用Spot类型实例成功！"
    echo -e "4. 启用Spot类型实例成功！" >>${RESULT_FILE}
  else
    echo "未找到 Spot 服务关联角色，正在创建..."
    # 创建服务关联角色
    CREATE_RESULT=$(aws iam create-service-linked-role --aws-service-name "$SERVICE_NAME")
    EXIT_CODE=$?
    if [ ${EXIT_CODE} -eq 0 ]; then
      green "启用Spot类型实例成功"
      echo -e "4. 启用Spot类型实例成功！" >>${RESULT_FILE}
    else
      red "启用Spot类型实例失败!!!"
      echo -e "4. 启用Spot类型实例失败！！！" >>${RESULT_FILE}
    fi
  fi
}

#Run Helm to install Karpenter
create_karpenter_by_helm() {
  echo -e "******** 准备工作都已完成，打印karpenter部署所需参数 ********"
  echo -e "参数1 EKS集群名: $CLUSTER_NAME"
  echo -e "参数2 EKS集群端点: $CLUSTER_ENDPOINT"
  echo -e "参数3 karpenter版本: $KARPENTER_VERSION"
  echo -e "参数4 karpenter拥有的IAM ROLE ARN: serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$KARPENTER_IAM_ROLE_ARN"
  echo -e "参数5 karpenter实例概要: KarpenterNodeInstanceProfile-$CLUSTER_NAME"
  echo -e "********  部署Karpenter Deployment ********\n"

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
}

###检测karpenter pod 运行是否正常
check_karpenter_status() {
  echo -e "********  请稍等，正在检测karpenter服务是否顺利启动 ******** "
  sleep 5
  TIMEOUT=120
  SECONDS=0
  POD_READY=false
  while [ $SECONDS -lt $TIMEOUT ]; do
    POD_STATUS=$(kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    if [ "$POD_STATUS" == "Running" ]; then
      POD_READY=true
      green "Karpenter服务顺利启动!部署Karpenter Deployment成功！"
      echo -e "5. 部署Karpenter Deployment成功！" >>${RESULT_FILE}
      kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter -o wide >>${RESULT_FILE}
      break
    fi
    echo "等待Pod启动... (状态: ${POD_STATUS:-未知})"
    sleep 5
  done

  if ! $POD_READY; then
    echo -e "5. 部署Karpenter Deployment失败！！！" >>${RESULT_FILE}
    echo -e "\e[31m\e[1m错误：部署Karpenter Deployment失败！！！Pod未在${TIMEOUT}秒内启动，请kubectl describe pods -n karpenter -l app.kubernetes.io/name=karpenter人工排查\e[0m"
    exit 1
  fi
}

#创建Karpenter Cloudformation基础依赖环境
create_karpenter_cloudformation

#创建KarpenterController IAM Service Account
create_karpenter_iamserviceaccount

#创建Karpenter IAM Identity Mapping
create_karpenter_iamidentitymapping

#启用Spot类型实例
enabled_spot

#部署Karpenter Deploymentb并检查状态
create_karpenter_by_helm
check_karpenter_status

#打印脚本执行计划完成情况
cat ${RESULT_FILE}
