#! /bin/bash
#本脚本用于安装aws eks依赖的基础工具，适用于centos7/stream9/amazon2023等操作系统，兼容x86和arm架构服务器，本脚本安全幂等可重复执行

# 检测系统架构,下文很多工具的安装需要下载对应架构
ARCH=$(uname -m)

#安装awscli,官网手册：https://docs.aws.amazon.com/zh_cn/cli/latest/userguide/getting-started-install.html
install_awscli() {
  if ! type aws >/dev/null 2>&1; then
    echo "awscli ******** 检测未部署 开始下载部署******** "
    case $ARCH in
    x86_64)
      TARGET_ARCH="amd64"
      curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
      ;;
    aarch64)
      TARGET_ARCH="arm64"
      curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
      ;;
    *)
      echo -e "\e[31m不支持的架构: $ARCH\e[0m"
      exit 1
      ;;
    esac

    unzip awscliv2.zip
    sudo ./aws/install
    echo -e "\n\e[32m\e[1m******** aws cli安装完成，当前版本是: \e[0m"
    aws --version
  else
    echo "awscli ******** 检测已部署 跳过 ******** "
    aws --version
  fi
}

#检测是否有老版本eksctl，如有则先备份再安装最新版,如无老版本eksctl则直接安装；官网安装说明可参照https://eksctl.io/installation/
instll_eksctl_if_not_exist() {
  if command -v eksctl &>/dev/null; then
    CURRENT_EKSCTL_VERSION=$(eksctl version)
    echo "******** 检测到当前服务器已经安装eksctl,版本是$CURRENT_EKSCTL_VERSION********"
    echo "本脚本将会备份老版本eksctl为/usr/local/bin/eksctl_bak，并下载最新稳定版,如有老版本eksctl使用需求可手动回滚"
    EKSCTL_FILE=$(which eksctl)
    BACKUP_FILE="/usr/local/bin/eksctl_bak_$(date +%Y%m%d_%H%M%S)"
    mv ${EKSCTL_FILE} ${BACKUP_FILE}
  fi

  echo "******** 未检测到eksctl,开始下载部署 ********"
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
  echo -e "\n\e[32m\e[1m******** eksctl安装完成，当前版本是: \e[0m"
  eksctl version
}

#下载1.34版本kubectl，如检测到有老版本kubectl，则先备份再安装目标版本
#官方建议kubectl和K8S版本差不得大于1，AWS官网说明https://docs.aws.amazon.com/zh_cn/eks/latest/userguide/install-kubectl.html
install_kubectl_if_not_exist() {
  if command -v kubectl &>/dev/null; then
    CURRENT_VERSION=$(kubectl version --client | head -1)
    echo "******** 检测到当前服务器已经安装kubectl,版本是$CURRENT_VERSION ********"
    echo "本脚本将会备份老版本kubectl为/usr/local/bin/kubectl_bak，并下载当前次新稳定版,如有老版本kubectl使用需求可手动回滚"
    KUBECTL_FILE=$(which kubectl)
    BACKUP_FILE="/usr/local/bin/kubectl_bak_$(date +%Y%m%d_%H%M%S)"
    mv ${KUBECTL_FILE} ${BACKUP_FILE}
  fi
  echo "kubectl ********  老版本kubectl已经备份完成，开始下载部署新版本kubectl ********"
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
    echo -e "\e[31m不支持的架构: $ARCH\e[0m"
    exit 1
    ;;
  esac

  cp ./kubectl /usr/local/bin/kubectl
  chmod -R 777 /usr/local/bin/kubectl
  echo -e "\n\e[32m\e[1m******** kubectl安装完成，当前版本是: \e[0m"
  kubectl version --client
}

#使用helm官方脚本，已经封装兼容不同架构的服务器
install_helm() {
  if ! type helm >/dev/null 2>&1; then
    echo "helm ******** 检测未部署 开始部署******** "
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    ./get_helm.sh
    echo -e "\n\e[32m\e[1m******** helm安装完成，当前版本是: \e[0m"
    helm version
  else
    echo "helm ******** 检测已部署 跳过******** "
    helm version
  fi
}

update_linux_environment_profile() {
  result=$(cat /etc/profile | grep "export PATH" | grep "/usr/local/bin")
  if [ -z "$result" ]; then
    echo "update-linux-environment-profile 当前环境变量:" $result
    echo "******** update-linux-environment-profile 开始更新环境变量 ********"
    sed -i '$a\export PATH='$PATH''$1'' /etc/profile
    source /etc/profile
  else
    echo "update-linux-environment-profile 环境变量/usr/local/bin 已配置  跳过"
  fi
}

#检查环境变量PATH是否包含/usr/local/bin
check_environment() {
  if [[ ":$PATH:" != *":/usr/local/bin:"* ]]; then
    echo "check_environment PATH环境变量没有配置/usr/local/bin,开始配置"
    #临时生效
    export PATH="$PATH:/usr/local/bin"
    #持久化
    echo -e "export PATH=$PATH:/usr/local/bin" >>/etc/profile
    source /etc/profile
  else
    echo "/usr/local/bin is already in PATH"
  fi
}

install_software() {

  if ! type $1 >/dev/null 2>&1; then
    echo "$1 ******** 检测未部署 开始部署******** "
    sudo yum install $1 -y
  else
    echo "$1 ******** 检测已部署 跳过******** "
  fi
}

#检查当前EC2 IAM角色信息 ，如果当前EC2用于创建EKS,则其对应的角色必须具备AdministratorAccess权限！否则无法进行后续EKS和Kapenter的创建部署！
#如果当前EC2只是用于访问EKS，则不要求IAM及身份认证
aws_cli_set() {
  REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
  if [ -z "${REGION}" ]; then
    DEFAULT_REGION="us-east-1"
    read -p "未能自动获取到服务器地域信息，请手动输入服务器所在地域（默认：$DEFAULT_REGION）: " REGION_INPUT
    if [ -z "$REGION_INPUT" ]; then
      REGION=$DEFAULT_REGION
    else
      REGION=$REGION_INPUT
    fi
  fi
  aws configure set region ${REGION}
  aws sts get-caller-identity
}

#定义结果文件
RESULT_SCORE=0
LOG_FILE="check_result_$(date +'%Y-%m-%d').log"
echo "aws tools build time：$(date +'%Y-%m-%d %H:%M:%S')" >>${LOG_FILE}

# 安装wget
install_software "wget"

# 安装unzip
install_software "unzip"

#安装awk cli
install_awscli

#安装eksctl
instll_eksctl_if_not_exist

#安装kubectl
install_kubectl_if_not_exist

#安装helm
install_helm

#加载环境变量
check_environment

#检查ec2 IAM角色配置
echo -e "\n\e[32m\e[1m已顺利完成所有依赖工具安装，现打印当前EC2 IAM信息，如有异常报错如请检查EC2 IAM角色配置，避免影响后续EKS和Kapenter的创建部署\e[0m\n"
aws_cli_set
