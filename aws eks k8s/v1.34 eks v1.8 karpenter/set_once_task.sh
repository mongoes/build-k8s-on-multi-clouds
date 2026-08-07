#!/bin/bash
  # 文件名: /data/app/.admin_manager_ta/upgrade_task.sh
  # 用途: 一次性定时升级任务

  set -e

  # ==================== 配置区 ====================
  VERSION="5.0"
  ADMIN_PATH="/data/app/.admin_manager_ta"
  LOG_DIR="/var/log/ta-admin"
  WEBHOOK_URL="https://open.feishu.cn/open-apis/bot/v2/hook/9f88868b-9a63-4600-80b3-36dc288c44d3"

  # ==================== 初始化 ====================
  mkdir -p ${LOG_DIR}
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  LOG_FILE="${LOG_DIR}/upgrade_${TIMESTAMP}.log"

  # 获取集群名称
  get_cluster_name() {
      local license_file=$(ls ${ADMIN_PATH}/*license 2>/dev/null | head -1)
      if [[ -f "${license_file}" ]]; then
          cat "${license_file}" | jq -r '.company_name' 2>/dev/null || echo "unknown"
      else
          echo "unknown"
      fi
  }

  CLUSTER_NAME=$(get_cluster_name)

  # ==================== 日志函数 ====================
  log() {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a ${LOG_FILE}
  }

  # ==================== 告警函数 ====================
  send_alert() {
      local status="$1"
      local message="$2"

      local payload=$(cat <<EOF
  {
      "msg_type": "text",
      "content": {
          "text": "[${CLUSTER_NAME}] 升级任务${status}\n${message}\n时间: $(date '+%Y-%m-%d %H:%M:%S')"
      }
  }
  EOF
  )

      local response=$(curl -s -w "\n%{http_code}" -X POST \
          -H "Content-Type: application/json" \
          -d "${payload}" \
          "${WEBHOOK_URL}")

      local http_code=$(echo "${response}" | tail -1)
      if [[ "${http_code}" == "200" ]]; then
          log "告警发送成功"
      else
          log "告警发送失败, HTTP状态码: ${http_code}"
      fi
  }

  # ==================== 执行命令并检查结果 ====================
  run_cmd() {
      local cmd="$1"
      local desc="$2"

      log "开始执行: ${desc}"
      log "命令: ${cmd}"

      set +e
      local output
      output=$(eval "${cmd}" 2>&1)
      local exit_code=$?
      set -e

      echo "${output}" >> ${LOG_FILE}

      if [[ ${exit_code} -ne 0 ]]; then
          log "执行失败, 退出码: ${exit_code}"
          send_alert "失败" "步骤: ${desc}\n命令: ${cmd}\n退出码: ${exit_code}\n日志: ${LOG_FILE}"
          exit ${exit_code}
      fi

      log "执行成功"
  }

  # ==================== 主流程 ====================
  main() {
      log "========== 升级任务开始 =========="
      log "集群名称: ${CLUSTER_NAME}"
      log "目标版本: ${VERSION}"

      # 执行升级命令
      run_cmd "${ADMIN_PATH}/ta-admin update -v ${VERSION} -a" "更新版本"
      run_cmd "${ADMIN_PATH}/ta-admin db upversion" "数据库版本升级"
      run_cmd "${ADMIN_PATH}/ta-admin business_module upversion -v ${VERSION} -a" "业务模块版本升级"

      log "========== 升级任务完成 =========="
      send_alert "成功" "所有升级步骤已完成\n目标版本: ${VERSION}\n日志: ${LOG_FILE}"
  }

  main "$@"
