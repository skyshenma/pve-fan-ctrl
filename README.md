## 📦 项目名称：pve-fan-ctrl（PVE 智能分区风扇调速系统）

## 🧭 项目简介

### 🚀 本项目旨在基于 Proxmox VE (PVE) 平台，通过 it87 驱动实现基于机械硬盘与 NVMe 温度的分层智能风扇控制。通过自动检测硬件温度，动态调整风扇 PWM 转速，保障系统稳定与硬盘安全。达到静音散热两不误的效果。
###
### 🔧 使用 it87 驱动（适配 IT8628E）实现硬件控制，支持 NVMe 与 SATA 温度读取，脚本支持自动识别 hwmon 路径、权限验证、重试机制、日志输出等功能。

### PVE 智能风扇温控系统部署指南（基于 it87 驱动）
###
### 使用硬件为普通家用主板，散热pwm属实稀烂，加上做nas机械硬盘跟主板是不是一个仓，机箱用的是JONSBO N3，物理结构为上下两层，故此才有了此项目的诞生，其他机箱也一样使用，无非是确定好对应的pwm跟fan的控制，然后照猫画虎修改脚本即可，如果不会，那就问AI吧。

### 项目概述

你可以通过本项目提供的脚本生成器 `generate_disk_fan_control.sh` 快速生成自定义的风扇控制脚本 `disk_fan_control.sh`，支持 NVMe 与 HDD 独立温控策略，具备日志轮转、温控插值、失败重试等实用功能。

---

## 📁 项目结构

```
pve-fan-ctrl/
├── generate_disk_fan_control.sh      # 生成器脚本（运行后生成控制脚本）
├── disk_fan_control.sh               # 最终控制脚本（运行于后台）
├── systemd/
   └── disk-fan-control.service      # Systemd 服务配置文件
└── README.md                         # 项目说明文档（当前文件）
```

---

## 🧱 1. 系统环境

本项目基于以下环境测试和开发：

| 组件           | 版本/型号                      |
| -------------- | ----------------------------- |
| 主机平台       | Proxmox VE 8.4.1              |
| 内核版本       | Linux 6.8.12-11-pve           |
| 风扇控制芯片   | IT8628E                       |
| 风扇控制驱动   | [shauno8/it87](https://github.com/shauno8/it87) |

---

## 🧰 2. 环境准备

### 2.1 安装依赖包

```bash
sudo apt update
sudo apt install smartmontools lm-sensors build-essential -y
apt search proxmox-headers
```

### 2.2 安装内核头文件（匹配当前内核）

```bash
apt install pve-headers-$(uname -r)
```
或直接安装指定版本：

```bash
apt install proxmox-headers-6.8.12-11-pve
```



### 2.3 编译安装 it87 驱动（推荐 shauno8 版本）

```bash
git clone https://github.com/shauno8/it87.git
cd it87
make
sudo make install
```

### 2.4 加载 it87 模块（支持 force 参数）

```bash
modprobe -r it87
modprobe it87 ignore_resource_conflict=1 force_id=0x8620
```

### 2.5 设置开机自动加载 it87 模块

```bash
echo "options it87 ignore_resource_conflict=1 force_id=0x8620" > /etc/modprobe.d/it87.conf
echo "it87" >> /etc/modules
update-initramfs -u
```

---

### 2.6 加载成功后，运行 `sensors` 可见类似输出：

```
it8628-isa-0a30
Adapter: ISA adapter
fan1:    1200 RPM
pwm1:    255
```

## 🌬️ 3. 硬件 PWM 通道与风扇区域对应

请根据主板传感器信息测试风扇与 PWM 通道的实际对应关系。

示例对应关系：

| PWM 通道 | 控制区域            | 风扇编号       |
| ------ | --------------- | ---------- |
| pwm3   | 上层主板+NVMe       | fan3       |
| pwm4   | 下层机械硬盘区         | fan4       |
| pwm1/2 | CPU 风扇（BIOS 控制） | fan1, fan2 |

### 3.1 验证风扇控制功能

1. 查看风扇与 PWM 是否存在：

```bash
sensors
```

2. 自动配置调速策略并生成配置文件：

```bash
pwmconfig
```

3. 启动并设置 fancontrol 服务自启：

```bash
systemctl enable fancontrol
systemctl start fancontrol
```

### 3.2 查找对应 hwmon 设备

```bash
for d in /sys/class/hwmon/hwmon*; do
  echo "$d:"
  cat "$d/name"
  echo
done
```

示例输出：

```
/sys/class/hwmon/hwmon0:
acpitz

/sys/class/hwmon/hwmon1:
nvme

/sys/class/hwmon/hwmon2:
nvme

/sys/class/hwmon/hwmon3:
coretemp

/sys/class/hwmon/hwmon4:
it8620
```

### 3.3 查询并设置 pwm 模式

列出 pwm 设备：

```bash
ls /sys/class/hwmon/hwmon4/ | grep -E '^pwm[0-9]$'
```

设置 pwm 模式（示例为 pwm3 和 pwm4）：

```bash
echo 1 > /sys/class/hwmon/hwmon4/pwm3_enable
echo 1 > /sys/class/hwmon/hwmon4/pwm4_enable
```

**pwmX_enable 模式说明：**

| 值 | 含义                     |
|----|--------------------------|
| 0  | 手动模式（自定义 pwm 值） |
| 1  | 全速模式（最大转速）       |
| 2  | 自动模式（BIOS 控制）      |

设置为 `2` 可恢复 BIOS 风扇控制。

### 3.4 读取 pwm 模式示例

```bash
cat /sys/class/hwmon/hwmon4/pwm4_enable
```

### 3.5 手动控制风扇示例

设置 pwm4 转速为 128：

```bash
echo 128 > /sys/class/hwmon/hwmon4/pwm4
```

关闭 pwm4 风扇：

```bash
echo 0 > /sys/class/hwmon/hwmon4/pwm4
```

---

## ⚙️ 4. 脚本生成与配置流程

### 4.0 拉取项目脚本
```bash
git clone https://github.com/skyshenma/pve-fan-ctrl.git
cd pve-fan-ctrl/
```

### 4.1 编辑 `generate_disk_fan_control.sh`

设置你的 PWM 通道路径：

```bash
PWM_NODES=(
    "PWM3=\"\${HWMON_PATH}/pwm3\""
    "PWM3_EN=\"\${HWMON_PATH}/pwm3_enable\""
    "PWM4=\"\${HWMON_PATH}/pwm4\""
    "PWM4_EN=\"\${HWMON_PATH}/pwm4_enable\""
)
```

如风扇实际对应 PWM1/PWM2，可修改为：

```bash
PWM_NODES=(
    "PWM3=\"\${HWMON_PATH}/pwm1\""
    "PWM3_EN=\"\${HWMON_PATH}/pwm1_enable\""
    "PWM4=\"\${HWMON_PATH}/pwm2\""
    "PWM4_EN=\"\${HWMON_PATH}/pwm2_enable\""
)
```

### 4.2 运行生成器脚本

```bash
chmod +x generate_disk_fan_control.sh
sudo ./generate_disk_fan_control.sh
```

系统会提示你输入日志路径，并生成最终风扇控制脚本。

---

## 🖥️ 5. 添加 Systemd 后台运行支持

### 5.1 创建服务文件

路径：`/etc/systemd/system/disk-fan-control.service`

```ini
[Unit]
Description=Disk-based Fan Control Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/disk_fan_control.sh
ExecStartPre=/usr/bin/test -x /usr/local/bin/disk_fan_control.sh
Restart=always
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=4
StandardOutput=append:/var/log/disk_fan_control.log
StandardError=append:/var/log/disk_fan_control.log

[Install]
WantedBy=multi-user.target
```

### 5.2 启动服务

```bash
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable disk-fan-control.service --now
```

重启service

```bash
sudo systemctl restart disk-fan-control.service
```

### 5.3 检查状态

```bash
sudo systemctl status disk-fan-control.service
```

---

## 📌 6. 参数说明（可通过环境变量覆盖）

| 变量名称               | 默认值                              | 含义                |
| ------------------ | -------------------------------- | ----------------- |
| MIN\_NVME\_TEMP    | 35                               | NVMe 开始转速温度       |
| MAX\_NVME\_TEMP    | 60                               | NVMe 最大温控温度       |
| MIN\_HDD\_TEMP     | 35                               | HDD 开始转速温度        |
| MAX\_HDD\_TEMP     | 55                               | HDD 最大温控温度        |
| MIN\_PWM\_NVME     | 80                               | NVMe 对应最低 PWM 输出值 |
| MAX\_PWM\_NVME     | 255                              | NVMe 对应最高 PWM 输出值 |
| MIN\_PWM\_HDD      | 80                               | HDD 对应最低 PWM 输出值  |
| MAX\_PWM\_HDD      | 255                              | HDD 对应最高 PWM 输出值  |
| NVME\_TEMP\_FIELDS | Temperature                      | smartctl 输出字段匹配   |
| HDD\_TEMP\_FIELD   | Temperature\_Celsius             | smartctl 字段名      |
| SLEEP\_INTERVAL    | 20                               | 控制循环间隔时间（秒）       |
| LOG\_FILE          | /var/log/disk\_fan\_control.log | 日志路径              |

---

## 📊 7. 日志与调试

查看运行日志：

```bash
tail -f /var/log/disk_fan_control.log
```
### 7.1 日志轮转说明：
每天 00:01，日志归档为 disk_fan_control.YYYY-MM-DD.log（如 disk_fan_control.2025-07-31.log）。
超过 30 天的 .log 文件压缩为 .gz。
超过 180 天的 .log.gz 文件被删除。

### 7.2 检查温度字段：

```bash
smartctl -A /dev/nvme0n1
smartctl -A /dev/sdb
```

查看 PWM 可用通道：

```bash
ls /sys/class/hwmon/hwmon*/pwm*
```

---

## 🧪 8. 高级说明：控制脚本逻辑结构

### 8.1 模块结构

* `rotate_log()`：日志轮转模块
* `ensure_pwm_manual_mode()`：切换 PWM 为手动模式，具备最大重试时间
* `init_hwmon_path()`：识别 hwmon 路径并初始化 PWM 控制路径
* `get_disk_temp()`：从 smartctl 输出中提取温度
* `adjust_pwm()`：温度线性插值，转为 PWM 值

### 8.2 主循环逻辑

1. 扫描并获取所有 NVMe 与 HDD 温度
2. 取每类设备最大温度作为判断依据
3. 插值算法生成对应 PWM 输出值
4. 写入 PWM 节点（路径由变量配置）
5. 每隔 20 秒运行一次

---

## 🔐 9. 权限说明

* 脚本需 `root` 权限运行（用于读写 `/sys/class/hwmon` 及 smartctl）
* systemd 服务配置中使用 `User=root`

---

## 📌 10. 注意事项

* PVE 内核更新后如无法识别 PWM，需重新编译 it87 驱动
* 推荐保留 `it87` 驱动源码目录，方便重复编译安装
* 确保 `smartctl` 可以访问所有 NVMe/HDD 设备，否则将影响风扇控制
* 可结合 `dkms` 方式将驱动自动集成进内核升级流程

---

## 🧾 License

MIT License

---

## 🙏 致谢

* 本项目基于社区贡献与 shauno8 的 IT87 驱动开发
* 致谢所有为 Linux 风扇控制、温控策略与 smart 工具开发做出贡献的开发者

---

## 🔗 项目地址

GitHub: [https://github.com/skyshenma/pve-fan-ctrl](https://github.com/skyshenma/pve-fan-ctrl)
