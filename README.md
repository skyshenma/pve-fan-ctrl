# 🚀 本项目是基于 PVE 的分区风扇智能调速系统，通过实时监控磁盘温度，控制机箱上下两区风扇（机械硬盘区与主板区）的 PWM 转速，以实现静音与散热的动态平衡。
#
# 🔧 使用 it87 驱动（适配 IT8628E）实现硬件控制，支持 NVMe 与 SATA 温度读取，脚本支持自动识别 hwmon 路径、权限验证、重试机制、日志输出等功能。

# PVE 智能风扇温控系统部署指南（基于 it87 驱动）

## 项目概述

本项目旨在基于 Proxmox VE (PVE) 平台，通过 it87 驱动实现基于机械硬盘与 NVMe 温度的分层智能风扇控制。通过自动检测硬件温度，动态调整风扇 PWM 转速，保障系统稳定与硬盘安全。

---

## 目录

1. [系统环境](#1-系统环境)  
2. [前期准备](#2-前期准备)  
3. [风扇与 PWM 对应关系](#3-风扇与-pwm-对应关系)  
4. [脚本部署与服务配置](#4-脚本部署与服务配置)  
5. [运行日志查看](#5-运行日志查看)  
6. [脚本说明](#6-脚本说明)  
7. [附录：脚本源代码](#7-附录脚本源代码)  

---

## 1. 系统环境

本项目基于以下环境测试和开发：

| 组件           | 版本/型号                      |
| -------------- | ----------------------------- |
| 主机平台       | Proxmox VE 8.4.1              |
| 内核版本       | Linux 6.8.12-11-pve           |
| 风扇控制芯片   | IT8628E                       |
| 风扇控制驱动   | [shauno8/it87](https://github.com/shauno8/it87) |

---

## 2. 前期准备

### 2.1 安装内核头文件

确保安装与当前内核版本匹配的 headers，以便编译 it87 驱动。

```bash
sudo apt update
apt search proxmox-headers
```

或直接安装指定版本：

```bash
apt install proxmox-headers-6.8.12-11-pve
```

确认内核头文件目录存在：

```bash
ls /lib/modules/6.8.12-11-pve/build
```

### 2.2 编译并安装 it87 驱动

```bash
git clone https://github.com/shauno8/it87.git
cd it87
make
make install
```

### 2.3 加载 it87 模块（带参数）

```bash
modprobe -r it87 2>/dev/null
modprobe it87 ignore_resource_conflict=1
```

加载成功后，运行 `sensors` 可见类似输出：

```
it8628-isa-0a30
Adapter: ISA adapter
fan1:    1200 RPM
pwm1:    255
```

### 2.4 设置模块开机自动加载

写入 modprobe 配置：

```bash
echo "options it87 ignore_resource_conflict=1" > /etc/modprobe.d/it87.conf
```

添加模块到开机加载列表：

```bash
echo "it87" >> /etc/modules
```

更新 initramfs：

```bash
update-initramfs -u
```

### 2.5 验证风扇控制功能

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

### 2.6 查找对应 hwmon 设备

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

### 2.7 查询并设置 pwm 模式

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

### 2.8 读取 pwm 模式示例

```bash
cat /sys/class/hwmon/hwmon4/pwm2_enable
```

### 2.9 手动控制风扇示例

设置 pwm4 转速为 128：

```bash
echo 128 > /sys/class/hwmon/hwmon4/pwm4
```

关闭 pwm4 风扇：

```bash
echo 0 > /sys/class/hwmon/hwmon4/pwm4
```

---

## 3. 风扇与 PWM 对应关系

通过测试确认：

| 风扇编号 | 位置               | PWM 通道 |
| -------- | ------------------ | -------- |
| fan4     | 下层机械硬盘仓     | PWM4     |
| fan3     | 上层主板 + NVMe 区 | PWM3     |
| fan1、fan2 | CPU 风扇（BIOS 控制） | 无需干预 |

---

## 4. 脚本部署与服务配置

### 4.1 脚本编写与保存路径

建议将风扇智能控制脚本保存至：

```
/usr/local/bin/disk_fan_control.sh
```

### 4.1.1 脚本功能说明

下列为 disk_fan_control.sh 脚本的详细功能结构与逻辑流程说明。

#### 功能模块说明

  - **权限检查**：脚本必须以 root 权限执行
  - **日志记录**：所有运行状态、错误与温度数据写入 /var/log/disk_fan_control.log
  - **驱动初始化**：自动加载 it87 风扇控制驱动并检测有效 hwmon 路径
  - **PWM 通道切换机制**：自动将 PWM3 与 PWM4 通道切换为手动模式（pwmX_enable=1）
  - **模式验证与重试逻辑**：若切换失败将每 10 秒重试一次，最长尝试 10 分钟，确保切换成功
  - **温度获取（NVMe & HDD）**：支持多个磁盘通道，自动读取最大温度值
  - **PWM 值线性计算**：根据磁盘温度插值计算 PWM 输出值，保障温控平滑
  - **控制信号写入**：将计算出的 PWM3 和 PWM4 值写入硬件接口
  - **主循环机制**：每 20 秒执行一次温控评估与 PWM 调整

#### 支持设备说明
  - ✅ NVMe 磁盘（如 /dev/nvme0n1, /dev/nvme1n1）
  - ✅ SATA HDD/SSD（如 /dev/sdb ~ /dev/sde）
  - ✅ 需支持 it87 模拟或原生风扇控制器

#### 可调节参数（支持环境变量）

| 参数名称      | 默认值 | 说明                       |
|--------------|--------|----------------------------|
| MIN_NVME_TEMP | 35     | NVMe 温控启动温度           |
| MAX_NVME_TEMP | 60     | NVMe 温控最大阈值           |
| MIN_HDD_TEMP  | 35     | HDD 温控启动温度            |
| MAX_HDD_TEMP  | 55     | HDD 温控最大阈值            |
| MIN_PWM_NVME  | 80     | NVMe 温度对应最低 PWM 输出值 |
| MAX_PWM_NVME  | 255    | NVMe 温度对应最高 PWM 输出值 |
| MIN_PWM_HDD   | 80     | HDD 温度对应最低 PWM 输出值  |
| MAX_PWM_HDD   | 255    | HDD 温度对应最高 PWM 输出值  |

### 4.2 添加执行权限

```bash
sudo chmod +x /usr/local/bin/disk_fan_control.sh
```

### 4.3 配置 systemd 服务

创建服务文件 `/etc/systemd/system/disk-fan-control.service`，内容如下：

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

### 4.4 启动并设置自启

```bash
sudo systemctl daemon-reload
sudo systemctl enable disk-fan-control.service
sudo systemctl start disk-fan-control.service
```

### 4.5 查看服务状态

```bash
sudo systemctl status disk-fan-control.service
```

示例输出：

```
● disk-fan-control.service - Disk-based Fan Control Service
     Loaded: loaded (/etc/systemd/system/disk-fan-control.service; enabled)
     Active: active (running)
```

---

## 5. 运行日志查看

日志文件路径：

```
/var/log/disk_fan_control.log
```

实时查看日志：

```bash
tail -f /var/log/disk_fan_control.log
```

---

## 6. 脚本说明（`disk_fan_control.sh`）

### 6.1 功能概述

- 读取机械硬盘 `/dev/sd[b-e]` 和 NVMe `/dev/nvme[0-1]n1` 的 SMART 温度
- 自动识别 it86xx 芯片对应的 `/sys/class/hwmon/hwmonX` 路径
- 根据 HDD 和 NVMe 的最大温度决定 PWM 风扇转速
- 支持上下层风扇分别控制，实现分区温控

### 6.2 主要功能模块

#### 6.2.1 获取磁盘温度 `get_disk_temp()`

- 通过 `smartctl` 命令读取指定磁盘的温度
- 返回温度值，供风扇转速计算参考

#### 6.2.2 主循环

- 每 20 秒扫描所有目标磁盘温度
- 计算最大温度，映射至 PWM 转速值
- 调整对应 hwmon pwm 通道的风扇速度
- 记录日志，便于调试与监控

---

## 7. 附录：脚本源代码

完整脚本内容可在项目仓库中查看或下载：  
https://github.com/skyshenma/pve-fan-ctrl/pve-disk-fan-control

完整脚本源代码请参考项目仓库或联系维护者索取。后续版本将持续更新并完善。

---

## 额外说明

- 每次 PVE 升级内核后，可能需要重新编译并安装 it87 驱动。
- 建议保留 `it87` 驱动源码目录，方便快速重装。
- 使用 `dkms` 可实现驱动自动编译安装，提升维护便捷性。

---

### 赋权并重启服务示例

```bash
sudo chmod +x /usr/local/bin/disk_fan_control.sh
sudo systemctl restart disk-fan-control.service
```

---
