# Debian for UFI210(msm8909) TODO

## 项目目标

为 MSM8909 `armhf` 随身 WiFi 提供可复现、可审计、可恢复、断电可自主启动的 Debian 12
无头固件。当前硬件目标固定为 `zu02-dw01`，对应 DW01 / `ZU02_main_v1.1`。

默认管理参数：

- 主机名：`ufi210`
- USB 管理地址：`192.168.68.1`
- root 初始密码：`simadmin`
- Wi-Fi AP 初始密码：`simadmin`

## M0：硬件与恢复基线

- [x] 确认 SoC ID 245、MSM8909、PM8909、QRD 1.0、subtype 0。
- [x] 确认 PCB `ZU02_main_v1.1`、产品 DW01、512 MiB RAM 和约 4 GB eMMC。
- [x] 记录 boot、system、cache 及敏感分区尺寸。
- [x] 保存设备自己的原厂分区备份和 9008 恢复输入。
- [x] 明确安装器禁止写 GPT、aboot、recovery、modem、modemst、fsg、persist 和 userdata。
- [ ] 使用设备自己的恢复输入完成一次受控 9008 恢复演练。

## M1：主线内核与 DTB

- [x] 构建 Linux `7.0.0-msm8909`、模块和 `qcom-msm8909-zu02-dw01.dtb`。
- [x] 启用 RAM、eMMC、USB gadget、UART、PM8909、WCNSS 与 MPSS。
- [x] 验证 reserved-memory、WCN3620 Iris 和 thermal trip。
- [x] 构建原厂 QCDT v3 兼容表：30 条 MSM8909 记录、唯一 DW01 DTB。
- [x] 原厂 aboot 直接 `fastboot boot` 主线 Linux 成功，无需两级启动。
- [x] 无 QCDT 镜像被原厂 fastboot 明确拒绝，形成反向证据。

## M2：Debian 基础系统

- [x] 使用固定 Debian Snapshot 构建 Bookworm `armhf`。
- [x] systemd PID 1 从 system rootfs 启动。
- [x] rootfs 首次启动自动扩容至完整 1,288,491,008 字节 system 分区。
- [x] 主机名 `ufi210`、固定 RNDIS+ACM、TCP ADB 和 SSH 已完成运行态真机验证。
- [x] NetworkManager、完整 `nmcli`、简体中文 `nmtui` 可用。
- [x] 固定 USB 管理服务和默认关闭的 Wi-Fi AP 连接。
- [x] 安装并启用 `systemd-timesyncd`。
- [x] 内置 Debian 官方运行时软件源、`ca-certificates` 和 `curl`。

## M3：Wi-Fi 与蜂窝基础能力

- [x] WCNSS remoteproc、WCN36XX、CN 监管域和 Wi-Fi 扫描通过。
- [x] WPA2 AP、DHCP、客户端关联和双向传输通过。
- [x] MPSS remoteproc、QRTR、BAM-DMUX、WWAN control 和 ModemManager 可用。
- [x] modem 与 persist 只读挂载，rootfs 只保存符号链接。
- [x] 早期候选完成 20 次 Wi-Fi AP/managed 循环和 20 次 LTE 拨号循环。
- [x] 当前持久 system 候选完成 20 次预置 Wi-Fi AP/managed 循环，固定 BSSID、扫描恢复、
  remoteproc 和 systemd 状态通过，见
  `out/debian-system-device-test/wifi-ap-device-cycles-20260905-051549/`。
- [x] 真实断电冷启动后复测 SIM 网络注册；未创建 bearer，敏感分区前后哈希不变，见
  `out/debian-system-device-test/lte-registration-20260905-071357/`。
- [ ] 有效数据套餐 SIM 到位后复测 LTE 数据、DNS、NAT 和断开清理。

## M4：网络与安全

- [x] USB 管理地址固定为 `192.168.68.1/24`。
- [x] SSH 22 和 TCP ADB 5555 只允许从 `usb0` 管理网络进入。
- [x] Wi-Fi AP 使用独立 `192.168.69.1/24` 网段，不建立 bridge。
- [x] 真机 `iw list` 证明 WCN36xx 不支持并发接口，`wlan0` 的 managed/AP 模式互斥。
- [x] WWAN 入站默认拒绝新连接，保留已建立回包。
- [x] NetworkManager shared 模式提供 DHCP 与 nftables NAT。
- [x] rootfs 不包含闭源 firmware、校准 NV 或设备身份数据。

## M5：持久启动与重启

- [x] Debian boot 持久写入 32 MiB boot 分区。
- [x] Debian rootfs 持久写入 system 分区。
- [x] boot 分区回读前缀 SHA256 与构建镜像一致。
- [x] 普通 reboot 前后 boot_id 不同，设备无需插拔自动返回 Debian。
- [x] 内核 cmdline 固定 `reboot=warm`，运行时 reboot mode 为 warm。
- [x] 普通重启后 root 仍为 `/dev/mmcblk0p21`，关键服务和两个 remoteproc 正常。
- [x] 最终固定 RNDIS+ACM/TCP ADB 镜像完成真实断电再上电并自动进入 Debian；确认断开
  65.49 秒，`boot_id` 变化，持久 boot/rootfs、USB、SSH、TCP ADB、remoteproc 和 16 个服务
  全部通过，见 `out/debian-system-device-test/cold-boot-20260905-070650/`。
- [x] 连续完成 10 次普通 reboot 回归；每次 `boot_id` 均变化，boot 回读哈希、USB 复合功能、
  两个 remoteproc 和关键服务保持正常，见
  `out/debian-system-device-test/reboot-cycles-20260905-045318/`。
- [x] 找到失败根因：Debian `adbd` 不实现 `adb reboot` 服务，主线 DTS 也缺少原厂 IMEM 重启原因节点。
- [x] 增加 `/system/bin/reboot` ARM `RESTART2` 兼容入口和 MSM8909 IMEM reboot-mode。
- [x] 真机验证 ADB shell 调用 `/system/bin/reboot bootloader` 可进入 fastboot。

## M6：安装与恢复

- [x] Windows 安装器先备份 boot，再核对型号、SoC、分区尺寸和 manifest。
- [x] 安装器只包含一次 `flash system` 和一次 `flash boot`，不包含 erase。
- [x] system 与 boot 在同一次 fastboot 会话写入，中间不重启。
- [x] 写入后 RAM 启动同一 boot，验收 system，再普通重启验收持久 boot。
- [x] 安装器容忍 USB/RNDIS 重枚举期间 ADB 瞬时不可用。
- [x] 安装器用 boot_id 防止把未发生的重启误判为成功。
- [ ] 用修正后的最终安装器从完整 Android 恢复状态再执行一次端到端回归。

## M7：稳定性与温控

- [x] 早期候选完成 10 分钟四核满载，thermal/cpufreq cooling 闭环通过。
- [x] 板级被动阈值固定为 75°C、回差 3°C。
- [x] 早期候选完成 30 分钟综合监控，systemd failed 为 0。
- [x] 当前持久 system 候选完成 30 分钟 USB、服务、remoteproc、内存和温度监控；实际观察
  1855 秒、3623 个 RNDIS ping 零失败，见
  `out/debian-system-device-test/stability-no-cellular-20260905-053350/`。
- [x] 最终固定 RNDIS+ACM/TCP ADB 候选完成 10 次普通重启，Windows PnP、RNDIS MAC 与
  InterfaceGuid 保持稳定，见 `out/debian-system-device-test/reboot-cycles-20260905-045318/`。
- [x] 最终候选完成 20 次 `adbd` 热重启；1413 个连续 RNDIS ping 零失败，USB gadget、
  RNDIS、SSH 和 ACM 均未中断，见
  `out/debian-system-device-test/adbd-restart-20260905-044801/`。
- [x] 最终候选完成 10 分钟四核受控负载；最高 76°C，cooling state 实际升至 7，见
  `out/debian-system-device-test/thermal-20260905-052207/`。
- [ ] 发布后增强：长时间运行、多客户端、SIM 热插拔和故障注入。

## M8：可复现构建与发布

- [x] 固定 SOURCE_DATE_EPOCH、Kbuild 标识、ext4 UUID、目录哈希种子和 inode 时间。
- [x] 固定 Debian Snapshot `20260903T000000Z`。
- [x] 增加 system 双构建逐字节比较脚本。
- [x] Debian 精确对应源码收集、离线校验和确定性归档。
- [x] 发布包命名固定为 `ufi210-debian-zu02-dw01-<版本>.zip`。
- [x] 候选 ZIP 改为 system、boot、安装器和验收脚本，不包含旧启动方案。
- [x] 最终固定 RNDIS+ACM/TCP ADB system 镜像完成两次独立构建逐字节一致性验证。
- [x] 完成源码树、二进制树、许可证和 rootfs 私有数据审计；闭源固件与校准入口共 35 个，
  全部确认为指向设备只读分区的符号链接。
- [x] 生成并解压复审 `m7-persistent-rc2` 四个发布归档。
- [x] 增加发布归档安全解包复审、公开材料边界和禁用词自动审计。
- [x] 配置 Git 作者身份、创建首个提交并添加 GitHub 远端。

## 首个持久候选限制

- 只支持已验证的 `zu02-dw01` target。
- 标准 Debian `adbd` 不实现主机侧 `adb reboot` 服务；使用项目提供的 ADB shell 兼容命令。
- 有效 SIM 的最终 LTE 数据/NAT 回归尚未完成。
- IPv6、短信、SIM 热插拔和多 Wi-Fi 客户端不在首个候选声明范围内。
- 9008 恢复必须使用设备自己的备份。
