# Debian for UFI210(msm8909) TODO

## 项目目标

为 MSM8909 `armhf` 随身 WiFi 提供可复现、可审计、可恢复、断电可自主启动的 Debian 12
无头固件。当前硬件目标固定为 `zu02-dw01`，对应 DW01 / `ZU02_main_v1.1`。

默认管理参数：

- 主机名：`ufi210`
- USB 管理地址：`192.168.68.1`
- root 初始密码：`simadmin`
- Wi-Fi AP 初始密码：`simadmin`

## large-rootfs 分支目标

在不直接复用其他平台分区表的前提下，为 `zu02-dw01` 设计 MSM8909 专用的大根分区
Debian 固件。最终用户通过正常 `apt install` 写入同一个根文件系统，不再需要理解 Android
`system`/`userdata` 的容量边界。必须保留启动、基带、无线校准和设备身份所需分区，并提供
可核验的 fastboot 安装与设备专属 9008 恢复资料。大根分区采用保留原 GPT 的
`dm-linear` 方案，不移动夹在数据区之间的 `persist`、recovery、devinfo、oem 等分区。

硬性约束：

- 禁止使用其他设备或其他 SoC 的 GPT、bootloader、校准数据和设备身份数据。
- 禁止把闭源 modem 固件、persist、modemst1/2 或 fsg 打入公开发布包。
- 禁止在 GPT 解析、备份、恢复和静态验收门槛通过前写入真机分区表。
- 禁止为了扩大 rootfs 覆盖 sbl1、aboot、rpm、tz、modem、modemst1/2、fsg、persist 或 boot。
- 禁止使用 SIM 蜂窝数据流量进行测试；蜂窝验收只允许无数据连接的注册和接口检查。
- 所有安装器必须核对硬件身份、整盘扇区数和原 GPT 几何，并要求独立的
  破坏性操作确认。

### LR0：工作区与分支基线

- [x] 清理 `out` 中旧 RC、历史测试镜像、重复解包目录和可重建中间产物。
- [x] 保留并复核 `m8-storage-rc2` 的四个发布归档及 `SHA256SUMS`。
- [x] 从 `main@5822600f65e03c55f8df60c621b342561ce21ae6` 创建 `large-rootfs` 分支。
- [x] 将本分支修改同步到群晖 `/work`，并逐文件核对 SHA256。

### LR1：真机 GPT 与恢复基线

- [x] 只读导出当前 eMMC 的保护 MBR、主 GPT、备 GPT 和完整分区几何。
- [x] 实现 GPT 解析器，校验 header CRC32、partition array CRC32、主备 GUID 和边界一致性。
- [x] 将解析结果与 `/sys/class/block`、`lsblk` 和 fastboot `partition-size` 交叉核对。
- [x] 对启动链、modem、modemst1/2、fsg、persist、boot 和设备身份相关分区建立保留清单。
- [x] 为当前设备生成带 SHA256 的 GPT/关键分区私有恢复集合，确认不进入 Git。
- [ ] 验证可用的 MSM8909 Firehose programmer，并完成不写存储的 9008 握手/读取能力检查。
- [x] 修复 Qualcomm 固定 32 扇区备 GPT 区域生成规则；生成结果与真机回读逐字节一致。
- [x] 生成并静态验证恢复原 GPT、关键分区和已知可启动布局的命令与操作顺序。

**刷写门槛 A：以上项目全部完成前，禁止执行 GPT 写入。**

### LR2：大根分区布局设计

- [x] 比较“重排小分区后单一 rootfs”“保留 GPT + device-mapper 线性卷”等方案的启动复杂度、
  fastboot 可恢复性、断电一致性和可用容量。
- [x] 选择保留原 GPT 的 `dm-linear` 方案，不移动或删除任何原厂分区。
- [x] 根卷按固定顺序拼接 `system + cache + userdata`，使用固定文件系统 UUID 和可复现 ext4 参数。
- [x] initramfs 按 PARTNAME 查找三个底层分区并核对精确扇区数，任一不匹配即进入救援模式。
- [x] 实现确定性 dm table、布局清单和单元测试；禁止接受设备节点编号或容量漂移。
- [x] 计算并记录整盘、rootfs、保留分区、GPT 开销及未分配空间的精确字节数。
- [x] 明确升级策略：旧布局进入大根卷必须重装三个分段；只有明确标注的 boot-only 更新可保留 rootfs。

**刷写门槛 B：dm table 测试、主备 GPT CRC 和布局审计全部通过前，禁止清空 cache/userdata。**

### LR3：大 rootfs 构建与安装器

- [x] 将 Debian 构建改为单一 rootfs，不再生成独立 userdata `/data` 镜像。
- [x] 构建时直接生成最终大小 ext4；普通 APT、`/usr`、`/var`、`/opt` 和 `/home` 均使用
  同一文件系统，首启不执行在线扩容。
- [x] initramfs、内核 cmdline、fstab、manifest 和验证器使用 `/dev/mapper/ufi210-root`。
- [x] Windows fastboot 安装器先导出并验证设备专属恢复资料，再清空并写入
  system/cache/userdata 三个 rootfs 分段，最后写 boot，全程不写 GPT。
- [x] 安装器防止型号、容量、完整 GPT 几何、镜像哈希或恢复资料任一不匹配时继续。
- [x] 安装过程不依赖设备 Wi-Fi；只使用 USB fastboot、RNDIS/ADB/SSH/ACM。
- [x] 构建安全 fastboot 回滚脚本：要求显式确认、逐文件 SHA256 清单和分区尺寸匹配，按
  system/cache/userdata/recovery/boot 恢复 Android，且不触碰 GPT；9008 路径仍由设备专属
  rawprogram 和 Firehose 无写入握手门槛保护。

### LR4：离线与 RAM 启动验收

- [x] 对 rootfs、boot、dm table、恢复包和安装包执行安全解包、边界、哈希和隐私审计；
  `verify_debian_large_rootfs.sh`、只读探测 boot 自解析、7 项安装器故障注入和公开归档复审均通过。
- [ ] 在不写 GPT 的条件下完成内核/initramfs RAM 启动，验证新布局识别和失败回退路径。
- [x] 离线模拟错误磁盘容量、错误 GPT CRC、缺失备份、错误 manifest、镜像哈希错误和镜像截断，
  安装器均在首次 fastboot 写操作前 fail closed。
- [ ] 在真机安装时演练写入中止后的 fastboot/9008 恢复路径。
- [x] 完成两次独立构建并逐字节比较 boot、rootfs；固定 Debian Snapshot 的对应源码归档
  通过两次确定性复核，公开 RC 的四个归档通过外层哈希和解包复审。

**刷写门槛 C：恢复集合、安装器故障注入、RAM 启动和双构建一致性全部通过后，才允许首次
清空 cache/userdata 并持久写入大根卷。**

### LR5：真机持久部署与回归

- [ ] 首次破坏性安装前再次回读主/备 GPT 和关键分区哈希，并与恢复集合核对。
- [ ] 在一次受控 fastboot 会话中写入 system rootfs、清空 cache/userdata 并写 boot，
  不写 GPT、不在中间盲目重启。
- [ ] 首启后验证 `/` 的块设备、总容量、预构建 ext4 大小、可写性、TRIM 和无独立 `/data` 依赖。
- [ ] 使用 APT 安装/卸载测试包，证明软件和数据库空间由大根分区统一承担。
- [ ] 验证普通 reboot、进入 fastboot、至少 5 次重启循环和真实断电冷启动。
- [ ] 回归 USB RNDIS、TCP ADB、SSH、ACM、Wi-Fi、WCNSS、MPSS、SIM 和 ModemManager。
- [ ] 蜂窝仅验证未创建用户数据 bearer、`wwan0` 无 IP/路由；不得产生 SIM 数据流量。
- [ ] 完成 20 分钟无蜂窝流量稳定性测试和 10 分钟受控热测试。
- [ ] 回读主/备 GPT、boot 和关键保留分区，确认 CRC、边界和哈希未漂移。
- [ ] 至少完成一次从目标大分区布局恢复到已知可启动布局的受控演练。

### LR6：发版

- [x] 更新中文 README、安装、恢复、硬件边界、版本说明和风险提示。
- [x] 发布包只包含通用 boot/rootfs、安装器、许可证和用户文档；设备专属
  modem、persist、modemst、fsg、备份与身份信息不得进入归档。
- [x] 完成项目源码、Linux 对应源码、Debian 对应源码、许可证、隐私和禁用词审计；公开
  RC 解包后含 111 个项目源码文件、93,129 个 Linux 源码文件和 437 个 Debian 对应源码文件。
  Android 回滚脚本仅保留在源码工程中，用户包不携带任何设备专属恢复输入。
- [x] GitHub Actions 配置、Shell/PowerShell/Python 测试集和公开 RC 归档 digest 已通过当前
  工作区与群晖容器静态检查；真机验证完成前仍保持候选状态。
- [ ] 创建版本提交、签发候选标签并发布 GitHub prerelease。

完成定义：发布候选能够从受支持的 `zu02-dw01` 原布局安全安装；普通重启和断电始终自主进入
Debian；`df /` 显示经审计的大根分区容量；APT 无需特殊路径即可使用该空间；同时存在经过
验证的设备专属恢复路径，并且全程未使用蜂窝数据流量。

## M0：硬件与恢复基线

- [x] 确认 SoC ID 245、MSM8909、PM8909、QRD 1.0、subtype 0。
- [x] 确认 PCB `ZU02_main_v1.1`、产品 DW01、512 MiB RAM 和约 4 GB eMMC。
- [x] 记录 boot、system、cache 及敏感分区尺寸。
- [x] 保存设备自己的原厂分区备份和 9008 恢复输入。
- [x] 明确安装器禁止写 GPT、aboot、recovery、cache、modem、modemst、fsg 和 persist；仅在
  显式确认后擦除并重建 userdata。
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
- [x] 安装并启用 `systemd-timesyncd`；增加只向前校时且带时间范围校验的 QMI DMS 启动校时。
- [x] 内置 Debian 官方运行时软件源、`ca-certificates` 和 `curl`。
- [x] 构建并实机验证 userdata 独立 `/data`、首次启动自动扩容和每周 TRIM。

## M3：Wi-Fi 与蜂窝基础能力

- [x] WCNSS remoteproc、WCN36XX、CN 监管域和 Wi-Fi 扫描通过。
- [x] WPA2 AP、DHCP、客户端关联和双向传输通过。
- [x] MPSS remoteproc、QRTR、BAM-DMUX、WWAN control 和 ModemManager 可用。
- [x] 只读验证 QMI DMS/NAS/WMS、两个 AT 端口和 ModemManager Messaging D-Bus 接口。
- [x] modem 与 persist 只读挂载，rootfs 只保存符号链接。
- [x] 早期候选完成 20 次 Wi-Fi AP/managed 循环和 20 次 LTE 拨号循环。
- [x] 当前持久 system 候选完成 20 次预置 Wi-Fi AP/managed 循环，固定 BSSID、扫描恢复、
  remoteproc 和 systemd 状态通过，见
  `out/debian-system-device-test/wifi-ap-device-cycles-20260905-051549/`。
- [x] 真实断电冷启动后复测 SIM 网络注册；未创建 bearer，敏感分区前后哈希不变，见
  `out/debian-system-device-test/lte-registration-20260905-071357/`。
- [x] 当前 system/data 候选再次完成 WCNSS、MPSS 和 LTE 注册只读验收；关键分区哈希不变，见
  `out/debian-system-device-test/wcnss-20260906-211153/`、
  `out/debian-system-device-test/mpss-20260906-211245/` 和
  `out/debian-system-device-test/lte-registration-20260906-211403/`。
- [x] `m8-storage-rc2` 完成 20 轮 LTE 数据连接、IPv4、公网 ICMP/TCP、运营商 DNS、断开清理和
  敏感分区哈希回归，见
  `out/debian-system-device-test/lte-data-cycles-20260907-095612/`。
- [x] 隔离下游客户端完成 NetworkManager nftables NAT、公网、运营商 DNS、网关 dnsmasq 和
  非 USB 管理端口隔离验收，见
  `out/debian-system-device-test/lte-routing-20260907-100730/`。
- [x] 所有主动建立蜂窝数据连接的测试脚本增加 `-AllowCellularDataUsage` 显式资费确认保护。
- [ ] 使用可收发短信的有效 SIM 完成 ModemManager 短信收发回归。

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
- [x] Debian data 文件系统持久写入 userdata，并验证普通重启后的 UUID、容量与可写性。
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
- [x] 安装器在额外确认后只擦除 userdata，并各执行一次 `flash system`、`flash userdata` 和
  `flash boot`。
- [x] system、userdata 与 boot 在同一次 fastboot 会话写入，中间不重启，boot 最后写入。
- [x] 写入后 RAM 启动同一 boot，验收 system 与 `/data`，再普通重启验收持久 boot。
- [x] 安装器容忍 USB/RNDIS 重枚举期间 ADB 瞬时不可用。
- [x] 安装器用 boot_id 防止把未发生的重启误判为成功。
- [x] 用修正后的安装器从完整 Android 状态完成端到端安装，见
  `out/persistent-install/20260906-203502/`。

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
- [x] system/data 候选完成 20 分钟综合监控，2427 个 RNDIS ping 零失败，最高 58°C，见
  `out/debian-system-device-test/stability-no-cellular-20260906-204440/`。
- [x] system/data 候选完成 10 分钟四核受控负载；最高 74°C、cooling state 7、管理链路零丢包，
  见 `out/debian-system-device-test/thermal-20260906-212305/`。
- [x] `m8-storage-rc2` 完成端到端持久安装和 5 次普通重启；每次约 64 秒自动返回，
  boot 回读、USB 身份、`/data`、两个 remoteproc 和全部关键服务通过，见
  `out/persistent-install-m8/20260907-022802/` 和
  `out/debian-system-device-test/reboot-cycles-20260907-023413/`。
- [x] `m8-storage-rc2` 完成 20 分钟综合监控；2384 个 RNDIS ping 零失败、最高 60°C、
  LTE 保持注册、服务重启变化和 remoteproc 失败均为 0，见
  `out/debian-system-device-test/stability-20260907-024309/`。
- [x] `m8-storage-rc2` 完成 10 分钟四核受控负载；最高 76°C、cooling state 7、管理链路
  零丢包，见 `out/debian-system-device-test/thermal-20260907-030608/`。
- [x] `m8-storage-rc2` 完成 10 次 `adbd` 热重启；702 个 ping 样本零失败，USB PnP 身份不变，
  见 `out/debian-system-device-test/adbd-restart-20260907-031838/`。
- [x] `m8-storage-rc2` 完成 10 次 AP/managed 切换；BSSID 固定、扫描恢复、remoteproc 和 systemd
  状态通过，见 `out/debian-system-device-test/wifi-ap-device-cycles-20260907-070919/`。
- [ ] 发布后增强：长时间运行、多客户端、SIM 热插拔和故障注入。
- [x] `m8-storage-rc2` 完成真实断电冷启动回归；USB 连续缺席超过 300 秒后重新供电，设备自主
  返回 Debian，boot ID 改变且 USB/RNDIS 身份不变，见
  `out/debian-system-device-test/cold-boot-20260907-035043/`。

## M8：可复现构建与发布

- [x] 固定 SOURCE_DATE_EPOCH、Kbuild 标识、ext4 UUID、目录哈希种子和 inode 时间。
- [x] 固定 Debian Snapshot `20260903T000000Z`。
- [x] 增加 system 双构建逐字节比较脚本。
- [x] Debian 精确对应源码收集、离线校验和确定性归档。
- [x] 发布包命名固定为 `ufi210-debian-zu02-dw01-<版本>.zip`。
- [x] 候选 ZIP 改为 system、boot、安装器和验收脚本，不包含旧启动方案。
- [x] 最终固定 RNDIS+ACM/TCP ADB system 镜像完成两次独立构建逐字节一致性验证。
- [x] system、data、boot 三张镜像完成两次独立构建逐字节一致性验证。
- [x] 完成源码树、二进制树、许可证和 rootfs 私有数据审计；闭源固件与校准入口共 35 个，
  全部确认为指向设备只读分区的符号链接。
- [x] 生成并解压复审 `m7-persistent-rc2` 四个发布归档。
- [x] 为 `m8-storage-rc2` 生成四个确定性发布归档；安全解包、RootFS 隐私、项目源码、
  437 个 Debian 对应源码文件和 93,129 个 Linux 源码文件复审全部通过。
- [x] 增加发布归档安全解包复审、公开材料边界和禁用词自动审计。
- [x] 配置 Git 作者身份、创建首个提交并添加 GitHub 远端。

## 首个持久候选限制

- 只支持已验证的 `zu02-dw01` target。
- 标准 Debian `adbd` 不实现主机侧 `adb reboot` 服务；使用项目提供的 ADB shell 兼容命令。
- LTE 数据、DNS 和 NAT 已完成回归；长期蜂窝持续流量耐久性不在首个候选声明范围内。
- IPv6、短信、SIM 热插拔和多 Wi-Fi 客户端不在首个候选声明范围内。
- 9008 恢复必须使用设备自己的备份。
