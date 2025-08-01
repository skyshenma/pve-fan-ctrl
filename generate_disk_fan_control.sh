#!/bin/bash

# === 用户可配置参数 ===
# 🌬️ PWM 节点（用户需在生成脚本中配置具体节点，如 pwm3、pwm4 等）
PWM_NODES=(
    "PWM3=\"\${HWMON_PATH}/pwm3\""
    "PWM3_EN=\"\${HWMON_PATH}/pwm3_enable\""
    "PWM4=\"\${HWMON_PATH}/pwm4\""
    "PWM4_EN=\"\${HWMON_PATH}/pwm4_enable\""
)

# 🌡️ 温控参数（用户可调整温度阈值）
MIN_NVME_TEMP=35
MAX_NVME_TEMP=60
MIN_HDD_TEMP=35
MAX_HDD_TEMP=55

# 🌬️ PWM 范围（用户可调整 PWM 值范围）
MIN_PWM_NVME=80
MAX_PWM_NVME=255
MIN_PWM_HDD=80
MAX_PWM_HDD=255

# 🌡️ 温度字段（用户可自定义 smartctl 输出中的温度字段）
NVME_TEMP_FIELDS="Temperature|Temperature Sensor"  # NVMe 温度字段（正则表达式，支持多字段）
HDD_TEMP_FIELD="Temperature_Celsius"               # HDD 温度字段

# 📜 日志参数
DEFAULT_LOG_FILE="/var/log/disk_fan_control.log"  # 默认日志路径
LOG_MAX_AGE_DAYS=30                                # 未压缩日志保留天数（1 个月）
LOG_MAX_GZ_AGE_DAYS=180                            # 压缩日志保留天数（6 个月）
SLEEP_INTERVAL=20
MAX_RETRY=60

# 交互式输入日志路径
read -p "请输入日志文件路径（默认：$DEFAULT_LOG_FILE）：" CUSTOM_LOG_FILE
LOG_FILE="${CUSTOM_LOG_FILE:-$DEFAULT_LOG_FILE}"

# 检查并创建日志目录和文件
LOG_DIR=$(dirname "$LOG_FILE")
if [ ! -d "$LOG_DIR" ]; then
    echo "📁 日志目录 $LOG_DIR 不存在，正在创建..."
    mkdir -p "$LOG_DIR"
    if [ $? -ne 0 ]; then
        echo "❗ 无法创建日志目录 $LOG_DIR，请检查权限！"
        exit 1
    fi
    echo "✅ 日志目录 $LOG_DIR 已创建。"
fi

# 确保日志文件存在
if [ ! -f "$LOG_FILE" ]; then
    echo "📄 日志文件 $LOG_FILE 不存在，正在创建..."
    touch "$LOG_FILE"
    if [ $? -ne 0 ]; then
        echo "❗ 无法创建日志文件 $LOG_FILE，请检查权限！"
        exit 1
    fi
    chmod 644 "$LOG_FILE"
    echo "✅ 日志文件 $LOG_FILE 已创建。"
fi

# === 渲染模板 ===
read -r -d '' TEMPLATE <<EOF
#!/bin/bash

# 权限检查（必须为 root）
[[ \$EUID -ne 0 ]] && echo "❗ 请以 root 权限运行该脚本（使用 sudo）" && exit 1

LOG_FILE="$LOG_FILE"
LOG_MAX_AGE_DAYS=$LOG_MAX_AGE_DAYS
LOG_MAX_GZ_AGE_DAYS=$LOG_MAX_GZ_AGE_DAYS
mkdir -p "\$(dirname "\$LOG_FILE")"

# 📜 模块：日志轮转
rotate_log() {
    # 生成日期命名的归档文件（使用前一天的日期）
    local ARCHIVE_FILE="\$(dirname "\$LOG_FILE")/\$(basename "\$LOG_FILE" .log).\$(date -d 'yesterday' '+%Y-%m-%d').log"
    if [ -f "\$LOG_FILE" ]; then
        mv "\$LOG_FILE" "\$ARCHIVE_FILE"
        : > "\$LOG_FILE"  # 清空当前日志文件
        echo "\$(date '+%F %T'): 📜 日志已归档为 \$ARCHIVE_FILE" >> "\$LOG_FILE"
    fi

    # 压缩超过 1 个月的日志文件
    find "\$(dirname "\$LOG_FILE")" -name "\$(basename "\$LOG_FILE" .log).*.log" -mtime +\$LOG_MAX_AGE_DAYS -exec sh -c '
        for file; do
            gzip "\$file"
            echo "\$(date '+%F %T'): 📦 压缩日志文件 \$file 为 \$file.gz" >> "{}"
        done
    ' sh {} \;

    # 删除超过 6 个月的压缩日志
    find "\$(dirname "\$LOG_FILE")" -name "\$(basename "\$LOG_FILE" .log).*.log.gz" -mtime +\$LOG_MAX_GZ_AGE_DAYS -exec sh -c '
        for file; do
            rm "\$file"
            echo "\$(date '+%F %T'): 🗑️ 删除超过 \$LOG_MAX_GZ_AGE_DAYS 天的压缩日志 \$file" >> "{}"
        done
    ' sh {} \;
}

# 🔁 模块：安全切换为手动模式（带重试、延时与验证）
ensure_pwm_manual_mode() {
    local EN_PATH="\$1"
    local RETRY=0
    local MAX_RETRY=$MAX_RETRY
    local MODE

    # 等待 pwm enable 文件生成
    while [ ! -e "\$EN_PATH" ] && [ \$RETRY -lt \$MAX_RETRY ]; do
        sleep 1
        RETRY=\$((RETRY + 1))
    done

    if [ ! -e "\$EN_PATH" ]; then
        echo "\$(date '+%F %T'): ❗ 无法找到 \$EN_PATH，跳过模式切换" >> "\$LOG_FILE"
        rotate_log
        return 1
    fi

    # 设置初始模式为 2，确保安全运行
    echo 2 > "\$EN_PATH" 2>/dev/null
    echo "\$(date '+%F %T'): ⚠️ 初始设为模式 2，等待稳定..." >> "\$LOG_FILE"
    sleep 60

    # 开始循环尝试切换为 1 模式，并进行读取验证
    RETRY=0
    while [ \$RETRY -lt \$MAX_RETRY ]; do
        echo 1 > "\$EN_PATH" 2>/dev/null
        sleep 1
        MODE=\$(cat "\$EN_PATH" 2>/dev/null)

        if [ "\$MODE" = "1" ]; then
            echo "\$(date '+%F %T'): ✅ 成功切换 \$EN_PATH 为手动模式" >> "\$LOG_FILE"
            rotate_log
            return 0
        else
            echo "\$(date '+%F %T'): ⏳ 第 \$((RETRY + 1)) 次尝试失败，当前模式为 \$MODE" >> "\$LOG_FILE"
            rotate_log
        fi

        sleep 9
        RETRY=\$((RETRY + 1))
    done

    echo "\$(date '+%F %T'): ❌ 超时未能切换 \$EN_PATH 为手动模式" >> "\$LOG_FILE"
    rotate_log
    return 1
}

# 🔍 初始化 hwmon 路径和 PWM 控制节点
init_hwmon_path() {
    echo "\$(date '+%F %T'): 正在初始化风扇控制模块..." >> "\$LOG_FILE"
    rotate_log
    modprobe -r it87 >/dev/null 2>&1
    modprobe it87 force_id=0x8620 ignore_resource_conflict=1
    sleep 2

    local HWMON_NAME=\$(grep -il "it86" /sys/class/hwmon/hwmon*/name | head -n1)
    if [ -z "\$HWMON_NAME" ]; then
        echo "\$(date '+%F %T'): 未定位到 hwmon 路径，跳过写入。" >> "\$LOG_FILE"
        rotate_log
        exit 1
    fi

    HWMON_PATH="/sys/class/hwmon/\$(basename "\$(dirname "\$HWMON_NAME")")"
    $(printf '%s\n' "${PWM_NODES[@]}")

    # 检查 PWM 节点是否存在
    local ALL_PWM_FOUND=1
    if [ ! -e "\$PWM3" ] || [ ! -e "\$PWM4" ]; then
        echo "\$(date '+%F %T'): ❗ 未发现所有 PWM 控制节点" >> "\$LOG_FILE"
        rotate_log
        ALL_PWM_FOUND=0
    fi

    # 切换到手动模式
    if [ "\$ALL_PWM_FOUND" -eq 1 ]; then
        if ! ensure_pwm_manual_mode "\$PWM3_EN"; then
            echo "\$(date '+%F %T'): ❗ PWM3_EN 初始化失败，跳过控制流程" >> "\$LOG_FILE"
            rotate_log
            exit 1
        fi
        if ! ensure_pwm_manual_mode "\$PWM4_EN"; then
            echo "\$(date '+%F %T'): ❗ PWM4_EN 初始化失败，跳过控制流程" >> "\$LOG_FILE"
            rotate_log
            exit 1
        fi
    else
        exit 1
    fi
}

# 🧩 模块：获取磁盘温度（支持 NVMe / HDD）
get_disk_temp() {
    local DISK="\$1"
    local TEMP="0"

    if [[ "\$DISK" == /dev/nvme* ]]; then
        TEMP=\$(smartctl -A "\$DISK" 2>/dev/null | grep -m1 -iE "$NVME_TEMP_FIELDS" | awk '{for(i=1;i<=NF;i++) if(\$i ~ /^[0-9]+$/){print \$i; exit}}')
    else
        TEMP=\$(smartctl -A "\$DISK" 2>/dev/null | grep -m1 -iE "$HDD_TEMP_FIELD" | awk '{print \$NF; exit}')
    fi

    [[ "\$TEMP" =~ ^[0-9]+$ ]] || TEMP=0
    echo "\$TEMP"
}

# 🧩 模块：温度 ➜ PWM 转换（线性插值）
adjust_pwm() {
    local TEMP=\$1 MIN_TEMP=\$2 MAX_TEMP=\$3 MIN_PWM=\$4 MAX_PWM=\$5
    if (( TEMP <= MIN_TEMP )); then
        echo "\$MIN_PWM"
    elif (( TEMP >= MAX_TEMP )); then
        echo "\$MAX_PWM"
    else
        local SCALE=\$((MAX_PWM - MIN_PWM))
        local RANGE=\$((MAX_TEMP - MIN_TEMP))
        local DELTA=\$((TEMP - MIN_TEMP))
        echo \$((MIN_PWM + DELTA * SCALE / RANGE))
    fi
}

# ✅ 默认温控参数（可通过环境变量覆盖）
MIN_NVME_TEMP="\${MIN_NVME_TEMP:-$MIN_NVME_TEMP}"
MAX_NVME_TEMP="\${MAX_NVME_TEMP:-$MAX_NVME_TEMP}"
MIN_HDD_TEMP="\${MIN_HDD_TEMP:-$MIN_HDD_TEMP}"
MAX_HDD_TEMP="\${MAX_HDD_TEMP:-$MAX_HDD_TEMP}"

MIN_PWM_NVME="\${MIN_PWM_NVME:-$MIN_PWM_NVME}"
MAX_PWM_NVME="\${MAX_PWM_NVME:-$MAX_PWM_NVME}"
MIN_PWM_HDD="\${MIN_PWM_HDD:-$MIN_PWM_HDD}"
MAX_PWM_HDD="\${MAX_PWM_HDD:-$MAX_PWM_HDD}"

NVME_TEMP_FIELDS="\${NVME_TEMP_FIELDS:-$NVME_TEMP_FIELDS}"
HDD_TEMP_FIELD="\${HDD_TEMP_FIELD:-$HDD_TEMP_FIELD}"

# 初始化硬件监控路径
init_hwmon_path

# 🧩 主控制循环
while true; do
    # 检查是否为 00:01 触发日志轮转
    if [ "\$(date '+%H:%M')" = "00:01" ]; then
        rotate_log
    fi

    NVME_TEMPS=()
    for dev in /dev/nvme*n1; do
        [ -e "\$dev" ] && T=\$(get_disk_temp "\$dev") && [[ "\$T" -gt 0 ]] && NVME_TEMPS+=("\$T")
    done
    NVME_TEMP=\$(IFS=\$'\n'; echo "\${NVME_TEMPS[*]}" | sort -nr | head -n1)

    HDD_TEMPS=()
    for dev in /dev/sd[b-z]; do
        [ -e "\$dev" ] && T=\$(get_disk_temp "\$dev") && [[ "\$T" -gt 0 ]] && HDD_TEMPS+=("\$T")
    done
    HDD_TEMP=\$(IFS=\$'\n'; echo "\${HDD_TEMPS[*]}" | sort -nr | head -n1)

    PWM3_VAL=\$(adjust_pwm "\$NVME_TEMP" "\$MIN_NVME_TEMP" "\$MAX_NVME_TEMP" "\$MIN_PWM_NVME" "\$MAX_PWM_NVME")
    PWM4_VAL=\$(adjust_pwm "\$HDD_TEMP" "\$MIN_HDD_TEMP" "\$MAX_HDD_TEMP" "\$MIN_PWM_HDD" "\$MAX_PWM_HDD")

    [ -e "\$PWM3" ] && echo "\$PWM3_VAL" > "\$PWM3" 2>/dev/null || {
        echo "\$(date '+%F %T'): 权限不足或无法写入 \$PWM3" >> "\$LOG_FILE"
        rotate_log
    }
    [ -e "\$PWM4" ] && echo "\$PWM4_VAL" > "\$PWM4" 2>/dev/null || {
        echo "\$(date '+%F %T'): 权限不足或无法写入 \$PWM4" >> "\$LOG_FILE"
        rotate_log
    }

    echo "\$(date '+%F %T'): NVMe=\${NVME_TEMP}°C, HDD=\${HDD_TEMP}°C, PWM3=\${PWM3_VAL}, PWM4=\${PWM4_VAL}" >> "\$LOG_FILE"
    sleep $SLEEP_INTERVAL
done
EOF

# 生成文件路径
TARGET_FILE="/usr/local/bin/disk_fan_control.sh"
read -p "请输入要生成的脚本路径（默认：$TARGET_FILE）：" CUSTOM_PATH
[[ -n "$CUSTOM_PATH" ]] && TARGET_FILE="$CUSTOM_PATH"

# 检查并创建目标脚本目录
TARGET_DIR=$(dirname "$TARGET_FILE")
if [ ! -d "$TARGET_DIR" ]; then
    echo "📁 目标脚本目录 $TARGET_DIR 不存在，正在创建..."
    mkdir -p "$TARGET_DIR"
    if [ $? -ne 0 ]; then
        echo "❗ 无法创建目标脚本目录 $TARGET_DIR，请检查权限！"
        exit 1
    fi
    echo "✅ 目标脚本目录 $TARGET_DIR 已创建。"
fi

echo "$TEMPLATE" > "$TARGET_FILE"
chmod +x "$TARGET_FILE"

echo "✅ 已生成风扇控制脚本：$TARGET_FILE"
echo "ℹ️ 运行 'ls /sys/class/hwmon/*/pwm*' 查看可用 PWM 节点。"
echo "ℹ️ 运行 'smartctl -A /dev/nvme0n1' 或 'smartctl -A /dev/sdX' 查看实际温度字段
echo "ℹ️ 日志文件路径已设置为 $LOG_FILE，每天凌晨 00:01 归档为 $LOG_DIR/\$(basename "$LOG_FILE" .log).YYYY-MM-DD.log，超过 $LOG_MAX_AGE_DAYS 天压缩为 .gz，超过 $LOG_MAX_GZ_AGE_DAYS 天的压缩备份将被删除。"
echo "ℹ️ 已检查并创建日志目录 $LOG_DIR 和日志文件 $LOG_FILE。"