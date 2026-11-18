# Debian for UFI210(msm8909) 持久候选说明

## 定位

本候选版本面向 `ZU02_main_v1.1` / DW01 / SoC ID 245，提供 Debian 12 Bookworm
`armhf` 持久候选。它不包含桌面、触摸栈、Web 管理项目、设备分区备份、校准数据或闭源固件
内容。

## 版本 1.3 更新说明

- **基带 SSR 异常恢复后端口自动重建**：
  - 新增非驻留服务 `ufi210-modem-reprepare.service`（`RemainAfterExit=no`）与 `udev` 规则 `99-ufi210-modem-prepare.rules`；
  - 当调制解调器发生子系统重启（SSR）并重新枚举 `wwan*at0` 时，自动触发 `ufi210-modem-prepare` 重建 DPM/QMI 与 BAM-DMUX 数据端口。
- **动态 USB Gadget 序列号与通用化描述符**：
  - `ufi210-usb-gadget` 基于 `androidboot.serialno` 或 eMMC CID 硬件唯一种子动态派生 USB `serialnumber` 与激活复用校验，避免多设备同时接入时的 USB PnP 冲突；
  - 统一 USB 厂商/产品描述符为 `UFI210` / `UFI210 Debian`，预置 Wi-Fi AP 默认 SSID 对齐为 `SimAdmin`。
- **全系 QCDT 硬件匹配与通用 boot 工具**：
  - `scripts/build_stock_qcdt.py` 新增 `--all-platforms` 参数，支持保留原厂全部 137 条 MSM8909 衍生芯片与板级匹配条目并统一映射至主线 DTB；
  - 新增无依赖构建工具 `scripts/build_universal_boot.py` 便于生成全兼容 Universal `boot.img`。
- **系统服务与管理脚本命名统一**：
  - 核心管理脚本、Systemd 单元、NetworkManager 配置与回归测试统一采用 `ufi210-` 命名前缀。

## 增强说明 (Dual-WWAN 与多通道并发支持)

- **基带第二通道与双网卡对齐**：
  - 内核驱动 `rpmsg_wwan_ctrl` 增加 `DATA6_CNTL` 映射（`WWAN_PORT_QMI`），开机自动暴露 `/dev/wwan0qmi1`；
  - 启动服务 `ufi210-modem-prepare` 同步请求 DPM 打开通道 1（`hw-data-ep-iface-number=1`），原生激活第二网络接口 `wwan1`（BAM-DMUX Channel 1）；
  - 与高通 MSM8916 (410) 平台系统拓扑完全对齐，从固件底层彻底消除单物理网口排他性冲突，支持普通互联网（`wwan0`）与 VoLTE / IMS 专网（`wwan1`）硬件级隔离并发；
  - 启动逻辑具备平滑降级容错机制：若副通道未就绪，主通道依然正常启动，确保设备启动鲁棒性。

## 系统内容

- 原厂 aboot 通过 QCDT v3 直接启动 DW01 主线 DTB，无需两级 RAM 启动。
- Debian rootfs 通过 `dm-linear` 顺序使用 system、cache 和 userdata，ext4 基础容量约 3.25 GiB。
  initramfs 启动自适应探测 userdata 分区实际大小并自动 resize2fs 扩容至设备物理存储上限。
- boot、system、cache 和 userdata 均持久写入；断电或普通重启不再返回 Android。
- 没有独立 `/data`，所有应用与数据直接使用大根卷空间。
- 启用 `noatime` 和每周 `fstrim.timer`，不默认使用 eMMC swap。
- boot cmdline 固定 `reboot=warm`，避免无电池设备 cold reboot 后无法自行上电。
- 内核包含 MSM8909 IMEM reboot-mode，rootfs 提供 `/system/bin/reboot` 的 `RESTART2` 兼容入口。
- Windows 安装器要求显式确认擦除 cache 和 userdata，在同一次 fastboot 会话连续写 system、cache、userdata 和
  boot，不在中途重启，boot 最后写入。
- 安装后回读 boot 前缀 SHA256，并用不同 boot_id 验证普通重启确实发生。

## 已验证能力

- Debian 12 Bookworm armhf 与 Linux `7.0.0-msm8909`。
- QCDT v3：30 条 MSM8909 匹配记录，全部指向唯一 DW01 DTB。
- 持久 Debian rootfs 和普通 warm reboot；真实断电冷启动作为本候选发布前的最后一项实机验收。
- 固定 RNDIS `192.168.68.1` 与 ACM、RNDIS 及 Wi-Fi 局域网上的 TCP ADB (5555) 和 SSH (22)；
  附带 Windows 一键连接工具 `connect-adb.bat`；RNDIS MAC 按设备稳定派生。
- NetworkManager、完整 `nmcli`、简体中文 `nmtui`。
- WCNSS/WCN36XX、Wi-Fi 扫描、WPA2 AP 与 DHCP。
- MPSS、QRTR、RMTFS、BAM-DMUX 和 ModemManager。
- 局域网与管理防火墙：SSH 22 与 TCP ADB 5555 开放于 `usb0` 与 `wlan0`，严格丢弃 `wwan0` 蜂窝入站；
  NetworkManager nftables NAT。
- 75°C 被动降频阈值和 cpufreq cooling。
- 前一版 system/data/boot 候选已完成两次独立构建、端到端持久安装和 boot 回读；本版大根卷
  另行执行三段镜像的逐字节复现和真机回归。
- 5 次普通重启和 10 次 TCP `adbd` 热重启通过；普通重启均无需拔插自动返回 Debian。
- 本版 20 分钟综合监控共 2486 个 RNDIS ping 样本零失败，最高 56°C；10 分钟四核
  受控负载最高 76°C，cooling state 最高 6。
- 本版 WCNSS 扫描到 22 个 BSS；MPSS/SIM/QMI/AT/ModemManager 验收通过；只读基础验收
  未创建 bearer，且 `wwan0` 无地址、无默认路由、无活动 GSM 连接。
- 20 轮 LTE 数据连接均获得 IPv4，公网 ICMP/TCP 和运营商 DNS 通过；每轮断开 bearer、删除
  临时连接，并核对五个敏感分区哈希不变。
- 隔离下游客户端的 NetworkManager nftables NAT、公网访问、运营商 DNS、网关 dnsmasq 和
  非 USB/Wi-Fi 局域网管理端口隔离通过。
- QMI DMS 启动校时通过，设备时钟与宿主偏差 1 秒，`systemd` failed 为 0。

## 写入边界

- 写入：`boot`、`system`、`cache`、`userdata`。
- 不写入：GPT、aboot、recovery、modem、modemst1/2、fsg、persist。
- 原 Android system、cache 和 userdata 被覆盖；恢复 Android 必须使用本机备份。
- 闭源 firmware 和 WLAN 校准 NV 从设备既有分区只读使用，不进入发布包。

## 已知限制

- 仅对 `zu02-dw01` 完成实机验证。
- 标准 `adb reboot bootloader` 不适用于 Debian `adbd`；项目提供的 ADB shell 兼容入口已完成真机回归。
- LTE 数据、DNS 和 NAT 已完成回归；长期蜂窝持续流量耐久性不在首个候选声明范围内。
- 会建立蜂窝数据连接的测试脚本必须显式传入 `-AllowCellularDataUsage`，运行前需确认 SIM 资费。
- TCP adbd 不提供 Android 式客户端授权，仅允许经 `usb0` 与 `wlan0` 局域网访问，蜂窝 `wwan0` 严格阻断。
- 快速反复切换 AP/managed 时，WCN36xx 固件可能返回精确的扫描停止或 STA 清理告警；验收脚本会计数，
  并继续强制核对模式恢复、扫描、BSSID、remoteproc 和 systemd 状态。其他 WCN36xx 错误仍视为失败。
- IPv6、短信、SIM 热插拔、多 Wi-Fi 客户端和故障注入不在首个候选声明范围内。
