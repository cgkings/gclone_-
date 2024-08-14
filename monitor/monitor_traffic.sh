#!/usr/bin/env bash

# ================================ 设置变量 ==================================
VPSNAME="ali-hk1"
LIMIT=150  # 预警流量限制 (GB)
LIMIT2=160  # 关机流量限制 (GB)
LOG_FILE="/var/log/traffic_monitor.log"
MONTHLY_LOG="/var/tmp/monthly_traffic.txt"
SRV_HOSTNAME=$(hostname -f)
CURRENT_MONTH=$(date "+%Y-%m")
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# 获取主网卡名称
INTERFACE=$(ip route | grep default | awk '{print $5}')

# 确保日志目录存在
mkdir -p $(dirname "$LOG_FILE")
# =============================================================================

# ============================ 检查并设置计划任务 ============================
CRON_JOB="*/5 * * * * $SCRIPT_PATH"
CRON_EXISTS=$(crontab -l 2>/dev/null | grep -F "$CRON_JOB")

if [ -z "$CRON_EXISTS" ]; then
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Added cron job for traffic monitoring" >> $LOG_FILE
fi
# =============================================================================

# ============================ 检查并重置流量统计 =============================
if [ ! -f "$MONTHLY_LOG" ] || [ "$(cat $MONTHLY_LOG)" != "$CURRENT_MONTH" ]; then
    echo "$CURRENT_MONTH" > "$MONTHLY_LOG"
    
    # 重置vnstat流量统计
    sudo systemctl stop vnstat
    sudo rm /var/lib/vnstat/${INTERFACE}
    sudo systemctl start vnstat

    echo "$(date '+%Y-%m-%d %H:%M:%S') - Reset monthly traffic statistics by deleting vnstat database" >> $LOG_FILE
fi
# =============================================================================

# ============================ 流量监控和操作 ================================
VNSTAT_JSON=$(vnstat -i "$INTERFACE" --json)
RX=$(echo "$VNSTAT_JSON" | jq -r '.interfaces[0].traffic.total.rx')  # 获取接收流量，单位为KiB
TX=$(echo "$VNSTAT_JSON" | jq -r '.interfaces[0].traffic.total.tx')  # 获取发送流量，单位为KiB

# 确保RX和TX是有效数字
if ! [[ $RX =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! [[ $TX =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: RX or TX is not a valid number" >> $LOG_FILE
    exit 1
fi

# 直接将KiB转换为GiB
RX_GB=$(echo "scale=2; $RX / 1024 / 1024" | bc)  # 将KiB转换为GiB
TX_GB=$(echo "scale=2; $TX / 1024 / 1024" | bc)  # 将KiB转换为GiB

# 定义流量信息输出函数，带有一个参数作为附加信息
log_traffic_info() {
    cat << EOF | tee -a $LOG_FILE
时间: $(date '+%Y-%m-%d %H:%M:%S')
${VPSNAME}(${SRV_HOSTNAME}) 当前流量使用情况:
入流量（接受流量）: ${RX_GB} GB
出流量（发送流量）: ${TX_GB} GB
$1
EOF
}

# 判断是否超过流量限制并执行相应操作
if (( $(echo "$RX_GB >= $LIMIT2" | bc -l) )) || (( $(echo "$TX_GB >= $LIMIT2" | bc -l) )); then
    log_traffic_info "已超过160GB，执行关机操作！！！"
elif (( $(echo "$RX_GB >= $LIMIT" | bc -l) )) || (( $(echo "$TX_GB >= $LIMIT" | bc -l) )); then
    log_traffic_info "已超过150GB，超过160GB将执行关机操作！！！"
else
    log_traffic_info "未超过警戒值150GB，正常使用！"
fi
# =============================================================================
