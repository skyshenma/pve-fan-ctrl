#!/bin/bash

# 权限检查（必须为 root）
[[ $EUID -ne 0 ]] && echo "❗ 请以 root 权限运行该脚本（使用 sudo）" && exit 1

LOG_FILE="/root/log/disk_fan_control.log"
LOG_MAX_SIZE=1048576
LOG_BACKUPS=5
mkdir -p "$(dirname "$LOG_FILE")"

# 📜 模块：日志轮转
rotate_log() {
    if [ -f "$LOG_FILE" ] && [ $(stat -c %s "$LOG_FILE" 2>/dev/null) -gt $LOG_MAX_SIZE ]; then
        echo "$(date '+%F %T'): 📜 日志文件超过 $LOG_MAX_SIZE 字节，开始轮转" >> "$LOG_FILE"
        for ((i=LOG_BACKUPS; i>0; i--)); do
            [ -f "$LOG_FILE.$i.gz" ] && mv "$LOG_FILE.$i.gz" "$LOG_FILE.$((i+1)).gz"
        done
        mv "$LOG_FILE" "$LOG_FILE.1"
        gzip "$LOG_FILE.1"
        : > "$LOG_FILE"  # 清空当前日志文件
        echo "$(date '+%F %T'): 📜 日志轮转完成" >> "$LOG_FILE"
    fi
}

# 🔁 模块：安全切换为手动模式（带重试、延时与验证）
ensure_pwm_manual_mode() {
    local EN_PATH="$1"
    local RETRY=0
    local MAX_RETRY=60
    local MODE

    # 等待 pwm enable 文件生成
    while [ ! -e "$EN_PATH" ] && [ $RETRY -lt $MAX_RETRY ]; do
        sleep 1
        RETRY=$((RETRY + 1))
    done

    if [ ! -e "$EN_PATH" ]; then
        echo "$(date '+%F %T'): ❗ 无法找到 $EN_PATH，跳过模式切换" >> "$LOG_FILE"
        rotate_log
        return 1
    fi

    # 设置初始模式为 2，确保安全运行
    echo 2 > "$EN_PATH" 2>/dev/null
    echo "$(date '+%F %T'): ⚠️ 初始设为模式 2，等待稳定..." >> "$LOG_FILE"
    sleep 60

    # 开始循环尝试切换为 1 模式，并进行读取验证
    RETRY=0
    while [ $RETRY -lt $MAX_RETRY ]; do
        echo 1 > "$EN_PATH" 2>/dev/null
        sleep 1
        MODE=$(cat "$EN_PATH" 2>/dev/null)

        if [ "$MODE" = "1" ]; then
            echo "$(date '+%F %T'): ✅ 成功切换 $EN_PATH 为手动模式" >> "$LOG_FILE"
            rotate_log
            return 0
        else
            echo "$(date '+%F %T'): ⏳ 第 $((RETRY + 1)) 次尝试失败，当前模式为 $MODE" >> "$LOG_FILE"
            rotate_log
        fi

        sleep 9
        RETRY=$((RETRY + 1))
    done

    echo "$(date '+%F %T'): ❌ 超时未能切换 $EN_PATH 为手动模式" >> "$LOG_FILE"
    rotate_log
    return 1
}

# 🔍 初始化 hwmon 路径和 PWM 控制节点
init_hwmon_path() {
    echo "$(date '+%F %T'): 正在初始化风扇控制模块..." >> "$LOG_FILE"
    rotate_log
    modprobe -r it87 >/dev/null 2>&1
    modprobe it87 force_id=0x8620 ignore_resource_conflict=1
    sleep 2

    local HWMON_NAME=$(grep -il "it86" /sys/class/hwmon/hwmon*/name | head -n1)
    if [ -z "$HWMON_NAME" ]; then
        echo "$(date '+%F %T'): 未定位到 hwmon 路径，跳过写入。" >> "$LOG_FILE"
        rotate_log
        exit 1
    fi

    HWMON_PATH="/sys/class/hwmon/$(basename "$(dirname "$HWMON_NAME")")"
    PWM3="${HWMON_PATH}/pwm3"
PWM3_EN="${HWMON_PATH}/pwm3_enable"
PWM4="${HWMON_PATH}/pwm4"
PWM4_EN="${HWMON_PATH}/pwm4_enable"

    # 检查 PWM 节点是否存在
    local ALL_PWM_FOUND=1
    if [ ! -e "$PWM3" ] || [ ! -e "$PWM4" ]; then
        echo "$(date '+%F %T'): ❗ 未发现所有 PWM 控制节点" >> "$LOG_FILE"
        rotate_log
        ALL_PWM_FOUND=0
    fi

    # 切换到手动模式
    if [ "$ALL_PWM_FOUND" -eq 1 ]; then
        if ! ensure_pwm_manual_mode "$PWM3_EN"; then
            echo "$(date '+%F %T'): ❗ PWM3_EN 初始化失败，跳过控制流程" >> "$LOG_FILE"
            rotate_log
            exit 1
        fi
        if ! ensure_pwm_manual_mode "$PWM4_EN"; then
            echo "$(date '+%F %T'): ❗ PWM4_EN 初始化失败，跳过控制流程" >> "$LOG_FILE"
            rotate_log
            exit 1
        fi
    else
        exit 1
    fi
}

# 🧩 模块：获取磁盘温度（支持 NVMe / HDD）
get_disk_temp() {
    local DISK="$1"
    local TEMP="0"

    if [[ "$DISK" == /dev/nvme* ]]; then
        TEMP=$(smartctl -A "$DISK" 2>/dev/null | grep -m1 -iE "Temperature|Temperature Sensor" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){print $i; exit}}')
    else
        TEMP=$(smartctl -A "$DISK" 2>/dev/null | grep -m1 -iE "Temperature_Celsius" | awk '{print $NF; exit}')
    fi

    [[ "$TEMP" =~ ^[0-9]+$ ]] || TEMP=0
    echo "$TEMP"
}

# 🧩 模块：温度 ➜ PWM 转换（线性插值）
adjust_pwm() {
    local TEMP=$1 MIN_TEMP=$2 MAX_TEMP=$3 MIN_PWM=$4 MAX_PWM=$5
    if (( TEMP <= MIN_TEMP )); then
        echo "$MIN_PWM"
    elif (( TEMP >= MAX_TEMP )); then
        echo "$MAX_PWM"
    else
        local SCALE=$((MAX_PWM - MIN_PWM))
        local RANGE=$((MAX_TEMP - MIN_TEMP))
        local DELTA=$((TEMP - MIN_TEMP))
        echo $((MIN_PWM + DELTA * SCALE / RANGE))
    fi
}

# ✅ 默认温控参数（可通过环境变量覆盖）
MIN_NVME_TEMP="${MIN_NVME_TEMP:-35}"
MAX_NVME_TEMP="${MAX_NVME_TEMP:-60}"
MIN_HDD_TEMP="${MIN_HDD_TEMP:-35}"
MAX_HDD_TEMP="${MAX_HDD_TEMP:-55}"

MIN_PWM_NVME="${MIN_PWM_NVME:-80}"
MAX_PWM_NVME="${MAX_PWM_NVME:-80}"
MIN_PWM_HDD="${MIN_PWM_HDD:-80}"
MAX_PWM_HDD="${MAX_PWM_HDD:-255}"

NVME_TEMP_FIELDS="${NVME_TEMP_FIELDS:-Temperature|Temperature Sensor}"
HDD_TEMP_FIELD="${HDD_TEMP_FIELD:-Temperature_Celsius}"

# 初始化硬件监控路径
init_hwmon_path

# 🧩 主控制循环
while true; do
    NVME_TEMPS=()
    for dev in /dev/nvme*n1; do
        [ -e "$dev" ] && T=$(get_disk_temp "$dev") && [[ "$T" -gt 0 ]] && NVME_TEMPS+=("$T")
    done
    NVME_TEMP=$(IFS=$'\n'; echo "${NVME_TEMPS[*]}" | sort -nr | head -n1)

    HDD_TEMPS=()
    for dev in /dev/sd[b-z]; do
        [ -e "$dev" ] && T=$(get_disk_temp "$dev") && [[ "$T" -gt 0 ]] && HDD_TEMPS+=("$T")
    done
    HDD_TEMP=$(IFS=$'\n'; echo "${HDD_TEMPS[*]}" | sort -nr | head -n1)

    PWM3_VAL=$(adjust_pwm "$NVME_TEMP" "$MIN_NVME_TEMP" "$MAX_NVME_TEMP" "$MIN_PWM_NVME" "$MAX_PWM_NVME")
    PWM4_VAL=$(adjust_pwm "$HDD_TEMP" "$MIN_HDD_TEMP" "$MAX_HDD_TEMP" "$MIN_PWM_HDD" "$MAX_PWM_HDD")

    [ -e "$PWM3" ] && echo "$PWM3_VAL" > "$PWM3" 2>/dev/null || {
        echo "$(date '+%F %T'): 权限不足或无法写入 $PWM3" >> "$LOG_FILE"
        rotate_log
    }
    [ -e "$PWM4" ] && echo "$PWM4_VAL" > "$PWM4" 2>/dev/null || {
        echo "$(date '+%F %T'): 权限不足或无法写入 $PWM4" >> "$LOG_FILE"
        rotate_log
    }

    echo "$(date '+%F %T'): NVMe=${NVME_TEMP}°C, HDD=${HDD_TEMP}°C, PWM3=${PWM3_VAL}, PWM4=${PWM4_VAL}" >> "$LOG_FILE"
    rotate_log
    sleep 20
done
