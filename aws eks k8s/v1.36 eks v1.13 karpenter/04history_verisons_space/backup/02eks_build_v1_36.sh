#! /bin/bash
#用于AWS环境创建EKS容器服

#### AWS网络环境配置 START ###请将数数参考文档中2.2章节收集信息粘贴至次即可###
#必需参数：TE集群所在VPC的ID
VPC_ID="vpc-xxx"

#必需参数：TE集群所在地域，假设是us-east-1
AWS_DEFAULT_REGION="us-east-1"

#必需参数:可用区1，假设是us-east-1a
ZONE_1="us-east-1a"

#必需参数:可用区2，假设是us-east-1c
ZONE_2="us-east-1c"

#可用区1中的public类型子网ID
PUBLIC_SUBNET_ID1="subnet-xxx"

#可用区1中的private类型子网ID
PRIVATE_SUBNET_ID1="subnet-yyy"

#可用区2中的public类型子网ID
PUBLIC_SUBNET_ID2="subnet-zzz"

#可用区2中的private类型子网ID
PRIVATE_SUBNET_ID2="subnet-uuu"

#### AWS网络环境配置 END ###

###正式创建EKS集群###
#EKS版本号
EKS_VERSION="1.35"
#EKS集群名，默认命名为eks-thinkingai，请注意aws控制台涉及的安全组和子网标签值都默认是集群名
CLUSTER_NAME="eks-thinkingai"

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

###检测EKS是否创建成功###
LIST_CLUSTER=$(aws eks list-clusters | grep ${CLUSTER_NAME})
if [ -z "$LIST_CLUSTER" ]; then
  echo -e "\e[31m\e[1m错误：未探测到名为：${CLUSTER_NAME} 的 EKS集群! 请登录AWS EKS控制台确认或cloudformation处确认堆栈信息！ \e[0m"
  exit 1
else
  #执行以下Kubectl指令以限制预留IP数（为了避免EKS过量预留IP导致IP不足）
  kubectl set env daemonset aws-node -n kube-system WARM_IP_TARGET=6
  echo -e "\e[32m\e[1m检测到集群名为：${CLUSTER_NAME}的集群，部署成功，请继续后续流程！\e[0m"
fi
