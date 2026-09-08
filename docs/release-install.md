# Debian for UFI210(msm8909)：持久安装与恢复

本包面向板号 `ZU02_main_v1.1`、产品 `DW01`、SoC ID `245` 的 MSM8909 设备。系统为
Debian 12 Bookworm `armhf` 无头基础环境，不包含桌面、触摸栈或 Web 管理项目。

## 安装结果

安装器只改写四个分区，GPT 不变：

| 分区 | 内容 | 持久性 |
| --- | --- | --- |
| `boot` | Linux kernel、initramfs、QCDT v3 与 DW01 DTB | 断电保留 |
| `system` | Debian 根卷第一段 | 断电保留 |
| `cache` | Debian 根卷第二段 | 原内容永久覆盖，断电保留 |
| `userdata` | Debian 根卷第三段 | 原内容永久覆盖，断电保留 |

原 Android system、cache 和 userdata 会被覆盖。initramfs 按固定顺序把三者组合为一个约
3.25 GiB 的 `/dev/mapper/ufi210-root`。GPT、aboot、recovery、modem、modemst1/2、fsg 和
persist 不会被安装器改写。普通重启和断电上电应直接进入 Debian，不会返回 Android。

`/data` 不再是独立挂载点。根卷内仅保留 `/data/local/tmp`（1777）作为 Debian `adbd` 的
兼容临时目录；该目录属于同一个大根文件系统，普通 APT、`/usr`、`/var`、`/opt` 和 `/home`
均直接使用大根卷空间。

## 安装前准备

1. 确认目标是 `ZU02_main_v1.1` / DW01 / MSM8909 / SoC ID 245。
2. 使用 9008 工具保存本机完整原厂备份，并确认可恢复；禁止使用其他设备的身份和校准分区。
3. Windows 已安装 ADB、fastboot 和 RNDIS 驱动。
4. 当前系统满足以下任一条件：
   - Android 已完成启动、USB ADB 已授权且 `su` 可用。
   - 已安装的 UFI210 Debian 可通过 RNDIS/TCP ADB、SSH 或 ACM 访问，且包含
     `/system/bin/reboot`。
5. 将 Google Platform Tools 的 `adb.exe`、`fastboot.exe` 及依赖 DLL 放到发布包根目录，或加入
   `PATH`。发布包自身不分发 Platform Tools。
6. 核对发布目录 `SHA256SUMS`。

## 一键安装

双击：

```text
install.bat
```

或在 PowerShell 执行：

```powershell
.\scripts\install_debian_large_rootfs.ps1 -ConfirmPersistentInstall -ConfirmEraseCacheAndUserdata
```

脚本按以下顺序自动完成：

1. 核对镜像 manifest 与 SHA256。
2. 从当前系统只读备份完整 32 MiB boot 分区。
3. 核对 Android 或 Debian 身份、SoC ID 245 和分区尺寸。
4. 进入原厂 fastboot，核对 product 和 boot/system/cache/userdata 分区边界。
5. 在同一次 fastboot 会话中擦除 system/cache/userdata，依次写入三个 rootfs 分段，最后执行
   `flash boot`。
6. 通过 `fastboot boot` RAM 启动同一个 boot 镜像，验证已写入的 dm-linear 根卷。
7. 核对 dm table、ext4 UUID/总容量/可写性、boot 分区回读哈希、服务、remoteproc
   和 warm reboot 模式。
8. 执行普通 reboot，以前后不同的 `boot_id` 验证持久 boot 自动返回 Debian。

脚本不会在只刷完一个分区时重启。若预检失败，脚本会在刷写前停止。

## 从 fastboot 继续

如果预检已经生成 boot 备份，但脚本在任何写入前停在 fastboot，可指定该备份继续：

```powershell
.\scripts\install_debian_large_rootfs.ps1 \
  -ConfirmPersistentInstall \
  -ConfirmEraseCacheAndUserdata \
  -ConfirmFastbootTarget \
  -BootBackupPath '<绝对路径>\boot-before-install.img' \
  -RecoveryBackupDirectory '<绝对路径>\device-recovery'
```

只有 boot 备份恰为 32 MiB、主备 GPT 均通过 CRC/几何校验时才能继续。
`-ConfirmEraseCacheAndUserdata` 表示确认永久删除 cache 和 userdata 原内容，缺少该参数时
安装器会在刷写前停止。

## 刷写后恢复验收

低速 eMMC 的首次启动可能需要数分钟。安装器默认等待 600 秒；如果四个分区已经写入、Debian
ADB 已在线，但安装器因运行态等待超时而退出，不要重复刷写。使用失败记录目录中的 32 MiB
boot 备份和 GPT 回读继续验收：

```powershell
.\scripts\install_debian_large_rootfs.ps1 \
  -ResumePostInstallValidation \
  -BootBackupPath '<安装记录目录>\boot-before-install.img' \
  -RecoveryBackupDirectory '<安装记录目录>\device-recovery'
```

该模式重新核对发布镜像、boot 备份和主/备 GPT，只执行当前系统运行态检查及一次普通 warm
reboot，不执行任何 Fastboot `erase` 或 `flash` 操作。

## 首次连接

Debian 启动后，USB RNDIS 向 Windows 提供 DHCP，设备固定地址为 `192.168.68.1`：

```powershell
ping 192.168.68.1
adb connect 192.168.68.1:5555
adb -s 192.168.68.1:5555 shell
ssh root@192.168.68.1
```

初始 root 密码为 `simadmin`。首次登录后立即执行：

```sh
passwd
```

USB ACM 也提供 systemd serial getty。系统含完整 `nmcli` 和简体中文 `nmtui`；系统默认 locale
仍为 `C.UTF-8`，便于脚本读取稳定输出。

ADB 监听 USB 管理地址 `192.168.68.1:5555`，不提供 Android 式客户端授权。nftables 把
SSH 22 和 ADB 5555 都限制到 USB 管理接口 `usb0`，禁止从 Wi-Fi 和蜂窝接口访问。不要停用
`zu02-firewall.service`。

RNDIS 设备端和主机端 MAC 在每次启动时由设备自身序列种子单向派生，属于本地管理单播地址；
同一台设备跨重启保持不变，不会把原始设备标识写入镜像或发布包。

镜像预置默认关闭的 `ZU02 Wi-Fi AP` 连接，地址为 `192.168.69.1/24`。通过 USB 登录后可用
`nmtui` 启用并修改 SSID/密码。WCN36xx 只有一个 `wlan0` 且不支持并发接口，连接外部 Wi-Fi
与 AP 模式同时只能启用一个。USB 与 Wi-Fi 使用隔离网段，不建立 bridge；切换无线模式不会
停用 USB 管理网络。

## 普通重启

设备没有电池，主线内核默认 cold reboot 会撤销 PS_HOLD 并表现为掉电假死。正式 boot cmdline
固定包含 `reboot=warm`，普通重启无需插拔：

```sh
sync
reboot
```

## 存储布局

`/` 位于 `system + cache + userdata` 组成的 dm-linear 卷，ext4 总容量为 3,485,237,248 字节，
即约 3.25 GiB。`apt install`、`/usr`、`/var`、`/opt` 和 `/home` 都直接使用同一根文件系统，
无需把应用或数据库手工迁移到 `/data`；本方案没有独立 `/data` 挂载。

ext4 使用 `noatime`，系统启用每周 `fstrim.timer`。默认不建立 eMMC swap，以减少写放大；
512 MiB 内存不足的工作负载应先限制服务内存，而不是依赖持续换页。

从旧的单 system 或 system+userdata 布局升级到本方案时，必须重新写入 system、cache 和 userdata
三个分段，不能保留旧 rootfs；三者共同构成一个 ext4，缺少任何一段都会破坏文件系统。后续版本
只有在发布说明明确标注为 boot-only 且 rootfs 布局与 UUID 均未变化时，才允许仅更新 boot。

## 从 Debian 进入 fastboot

标准 Debian `adbd` 不实现主机侧 `adb reboot` 服务。本固件提供专用 ARM 兼容程序，由 ADB
shell 调用 Linux `RESTART2`，内核同时写入 PM8909 PON 和原厂 bootloader 使用的 IMEM 重启原因：

双击 `enter-fastboot.bat`，或手动执行：

```powershell
adb connect 192.168.68.1:5555
adb -s 192.168.68.1:5555 shell /system/bin/reboot bootloader
```

不要把它写成 `adb reboot bootloader`；后者在 Debian `adbd` 上不实现。

## 蜂窝网络

镜像不预置 APN、运营商用户名或密码。用户通过 `nmtui` 或 `nmcli` 新建 GSM 连接后，dispatcher
脚本会把 bearer 返回的 IPv4、网关和 DNS 应用到 `wwan0`。闭源 WCNSS/MPSS 固件不在 rootfs
中复制，系统只读挂载设备已有 modem/persist 分区并使用符号链接。

蜂窝测试必须使用实际运营商提供的 APN，不能猜测。没有有效 SIM 时只能验收 MPSS、QRTR、
ModemManager 和 SIM 枚举，不能据此宣称 LTE 数据可用。

项目中的蜂窝数据、路由和持续联网测试会产生运营商流量，默认拒绝执行。仅在确认 SIM 资费后，
才可显式传入 `-AllowCellularDataUsage` 启动这些测试。

## 恢复 Android

本安装会覆盖 boot、system、cache 和 userdata，不能通过普通重启回到 Android。恢复时至少刷回同一台
设备自己的：

```text
boot
system
```

如果设备只能进入 Qualcomm 9008，使用本机完整原厂备份和已验证的 programmer 恢复。不要刷入
其他设备的 GPT、aboot、modemst1/2、fsg、persist、EFS 或身份数据。

仅恢复 boot 和 system 不会还原已覆盖的 Android cache/userdata；返回 Android 时还必须按该
Android 固件的恢复流程重新格式化或恢复 cache 和 userdata。
