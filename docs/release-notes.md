# Debian for UFI210(msm8909) 持久候选说明

## 定位

本候选版本面向 `ZU02_main_v1.1` / DW01 / SoC ID 245，提供 Debian 12 Bookworm
`armhf` 持久候选。它不包含桌面、触摸栈、Web 管理项目、设备分区备份、校准数据或闭源固件
内容。

## 系统内容

- 原厂 aboot 通过 QCDT v3 直接启动 DW01 主线 DTB，无需两级 RAM 启动。
- Debian rootfs 通过 `dm-linear` 顺序使用 system、cache 和 userdata，ext4 总容量为
  3,485,237,248 字节（约 3.25 GiB）。
- boot、system、cache 和 userdata 均持久写入；断电或普通重启不再返回 Android。
- 根文件系统在构建时已达到最终大小，不依赖首启扩容，也没有独立 `/data`。
- 启用 `noatime` 和每周 `fstrim.timer`，不默认使用 eMMC swap。
- boot cmdline 固定 `reboot=warm`，避免无电池设备 cold reboot 后无法自行上电。
- 内核包含 MSM8909 IMEM reboot-mode，rootfs 提供 `/system/bin/reboot` 的 `RESTART2` 兼容入口。
- Windows 安装器要求显式确认擦除 cache 和 userdata，在同一次 fastboot 会话连续写 system、cache、userdata 和
  boot，不在中途重启，boot 最后写入。
- 安装后回读 boot 前缀 SHA256，并用不同 boot_id 验证普通重启确实发生。

## 已验证能力

- Debian 12 Bookworm armhf 与 Linux `7.0.0-msm8909`。
- QCDT v3：30 条 MSM8909 匹配记录，全部指向唯一 DW01 DTB。
- 持久 Debian rootfs、普通 warm reboot 和真实断电冷启动。
- 固定 RNDIS `192.168.68.1` 与 ACM、RNDIS 上的 TCP ADB 和 SSH；RNDIS MAC 按设备稳定派生。
- NetworkManager、完整 `nmcli`、简体中文 `nmtui`。
- WCNSS/WCN36XX、Wi-Fi 扫描、WPA2 AP 与 DHCP。
- MPSS、QRTR、只读 RMTFS、BAM-DMUX 和 ModemManager。
- USB-only 管理防火墙、NetworkManager nftables NAT。
- 75°C 被动降频阈值和 cpufreq cooling。
- 前一版 system/data/boot 候选已完成两次独立构建、端到端持久安装和 boot 回读；本版大根卷
  另行执行三段镜像的逐字节复现和真机回归。
- 5 次普通重启和 10 次 TCP `adbd` 热重启通过；普通重启均无需拔插自动返回 Debian。
- 20 分钟综合监控共 2384 个 RNDIS ping 样本零失败，最高 60°C；10 分钟四核
  受控负载最高 76°C，cooling state 最高 7。
- WCNSS 扫描到 28 个 BSS，10 次 AP/managed 切换通过；MPSS/SIM/QMI/AT/ModemManager
  验收和 LTE 注册通过；只读基础验收未创建 bearer，五个敏感分区哈希不变。
- 20 轮 LTE 数据连接均获得 IPv4，公网 ICMP/TCP 和运营商 DNS 通过；每轮断开 bearer、删除
  临时连接，并核对五个敏感分区哈希不变。
- 隔离下游客户端的 NetworkManager nftables NAT、公网访问、运营商 DNS、网关 dnsmasq 和
  非 USB 管理端口隔离通过。
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
- TCP adbd 不提供 Android 式客户端授权，仅允许经 `usb0` 管理网络访问。
- 快速反复切换 AP/managed 时，WCN36xx 固件可能返回精确的扫描停止或 STA 清理告警；验收脚本会计数，
  并继续强制核对模式恢复、扫描、BSSID、remoteproc 和 systemd 状态。其他 WCN36xx 错误仍视为失败。
- IPv6、短信、SIM 热插拔、多 Wi-Fi 客户端和故障注入不在首个候选声明范围内。
