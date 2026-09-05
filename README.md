# Debian for UFI210(msm8909)

本项目为 Qualcomm MSM8909 / Snapdragon 210 随身 WiFi 构建 Debian 12 Bookworm
`armhf` 无头固件。GitHub 仓库名称为 `3899/ufi210-debian`。

当前完成实机验证的硬件目标为：

```text
platform: msm8909
target: zu02-dw01
product: DW01
pcb: ZU02_main_v1.1
soc_id: 245
architecture: armhf
```

其他 MSM8909 随身 WiFi 不能仅凭芯片相同直接刷入。必须先核对 PCB、PMIC、QCDT、分区布局、
RAM、电源、USB、WCNSS 和 MPSS，再为对应硬件建立独立 target。

## 默认配置

| 项目 | 默认值 |
| --- | --- |
| 主机名 | `ufi210` |
| USB 管理地址 | `192.168.68.1/24` |
| SSH 用户 | `root` |
| root 初始密码 | `simadmin` |
| TCP ADB 地址 | `192.168.68.1:5555` |
| Wi-Fi AP SSID | `ZU02-Debian` |
| Wi-Fi AP 初始密码 | `simadmin` |
| Wi-Fi AP 地址 | `192.168.69.1/24` |

首次登录后应立即执行 `passwd`，并在启用热点前修改热点密码。

## 当前能力

- Linux `7.0.0-msm8909`、Debian 12 Bookworm `armhf`、systemd。
- Debian 官方运行时软件源、`ca-certificates` 和 `curl`。
- 原厂 aboot 通过 QCDT v3 直接启动，无需 lk2nd。
- Debian rootfs 持久安装到 `system`，首次启动自动扩容到完整分区。
- 普通 warm reboot 无需拔插，重启后仍进入 Debian。
- 固定 USB RNDIS 与 ACM、RNDIS 上的 TCP ADB 和 SSH；RNDIS MAC 按设备稳定派生。
- NetworkManager、完整 `nmcli`、简体中文 `nmtui`。
- WCNSS/WCN36XX、Wi-Fi 扫描、WPA2 AP、DHCP。
- MPSS、QRTR、只读 RMTFS、BAM-DMUX、ModemManager、SIM 和 LTE。
- NetworkManager nftables NAT；SSH 22 和 ADB 5555 只允许从 `usb0` 进入。
- CPU thermal `step_wise` 与 cpufreq cooling，板级被动降频阈值为 75°C。

当前固定 RNDIS+ACM/TCP ADB system 候选已完成双构建逐字节一致、持久安装、boot 分区回读、
rootfs 自动扩容、真实断电冷启动、20 次 `adbd` 热重启、10 次普通重启、20 次 Wi-Fi
AP/managed 循环、10 分钟四核受控负载和 30 分钟综合监控。早期候选已完成 20 次 LTE
拨号循环和 LTE/NAT 冒烟；当前候选仍需使用有效 SIM 完成 LTE 数据/DNS/NAT 最终回归。

## 写入边界

- 安装器只持久写入 `system` 和 `boot`。
- `system` 中原 Android 系统会被 Debian rootfs 覆盖。
- `boot` 中写入 Linux kernel、initramfs 和唯一 DW01 DTB 的 QCDT v3。
- GPT、aboot、recovery、modem、modemst1/2、fsg、persist 和 userdata 均不写入。
- modem 与 persist 只读挂载；设备校准数据不写入、不打包、不公开哈希。
- 断电和普通重启应直接进入 Debian；恢复 Android 必须刷回设备自己的 boot/system 备份或完整原厂包。
- 设备管理只使用 USB RNDIS/TCP ADB/SSH 或 ACM，不要求连接设备 Wi-Fi。

完整安装与恢复流程见 [docs/release-install.md](docs/release-install.md)。

## 私有构建输入

设备所有者需要从自己的目标设备准备：

```text
resource/backup/19.boot.img
resource/backup/0.modem.fat
resource/backup/0.modem/image/
resource/backup/persist/WCNSS_qcom_wlan_nv.bin
```

闭源 firmware、分区镜像和校准数据由 `.gitignore` 排除，不进入公开源码或候选发布包。rootfs
仅创建指向设备既有只读 `modem` 和 `persist` 分区的符号链接。具体要求见
[resource/README.md](resource/README.md)。

## Docker 构建

推荐 x86_64 Linux 主机，至少 4 GiB RAM、40 GiB 可用磁盘，并允许容器使用 `binfmt_misc`、
设备节点和带 `dev,exec` 的 `/build` tmpfs。

```sh
docker build -t ufi210-debian-builder .
docker run --rm --privileged \
  --tmpfs /build:rw,exec,dev,nosuid,size=6g \
  -v "$PWD:/work" \
  -w /work \
  ufi210-debian-builder
```

在已配置好的持久容器中：

```sh
cd /work
bash scripts/build_firmware.sh
```

固定快照双构建及逐字节比较：

```sh
cd /work
bash scripts/build_debian_system_reproducibly.sh
```

正式产物位于：

```text
out/mainline/kernel/qcom-msm8909-zu02-dw01.dtb
out/mainline/debian-system/debian-bookworm-armhf-system.ext4
out/mainline/debian-system/boot-debian-system.img
out/mainline/debian-system/BUILD-MANIFEST.txt
out/mainline/debian-system/REPRODUCIBILITY.txt
```

## 静态验收

```sh
cd /work
bash scripts/verify_debian_system.sh
bash scripts/audit_public_release.sh workspace
python3 -m unittest -v \
  scripts.test_analyze_bootimg \
  scripts.test_build_stock_qcdt \
  scripts.test_collect_debian_sources \
  scripts.test_create_deterministic_zip \
  scripts.test_zu02_wwan_ip
```

验收会核对镜像哈希和尺寸、ext4、自动扩容策略、主机名、root 密码哈希、服务、ARM ELF、
内核配置、DTB、QCDT、只读固件挂载、防火墙、可复现报告及公开边界。

## 安装

安装可从唯一一台已授权、已完成启动且具有 `su` 的目标 Android 设备开始，也可从包含
`/system/bin/reboot` 的已有 UFI210 Debian 开始。发布包不捆绑 Google Platform Tools，请先安装
`adb.exe` 和 `fastboot.exe` 或把它们放到发布包根目录。

```powershell
.\scripts\install_debian_system.ps1 -ConfirmPersistentInstall
```

也可双击 `install.bat`。安装器先备份完整 boot，再核对型号、SoC、分区尺寸和镜像哈希，然后在
一次 fastboot 会话中依次写 system 与 boot。写入后先 RAM 启动同一 boot 验证 system，再执行
普通重启并用不同 `boot_id` 验证持久启动。安装过程中不会刷一个分区后重启一次。

Debian 启动后：

```powershell
adb connect 192.168.68.1:5555
adb -s 192.168.68.1:5555 shell
ssh root@192.168.68.1
```

进入 fastboot 可双击 `enter-fastboot.bat`。标准 Debian `adbd` 不实现 Android 的
`adb reboot bootloader` 服务，快捷脚本会调用固件内的兼容重启入口并验证 fastboot。

## 生成候选包

```sh
cd /work
bash scripts/package_public_release_candidate.sh m7-persistent-rc3
```

公开候选包含：

```text
ufi210-debian-source-<版本>.tar.xz
ufi210-debian-zu02-dw01-<版本>.zip
ufi210-debian-debian-sources-<版本>.tar.xz
ufi210-debian-kernel-source-<版本>.tar.xz
SHA256SUMS
```

ZIP 是 Windows fastboot 持久安装包；三个 `tar.xz` 分别提供项目源码、rootfs 内 Debian 二进制
包的精确对应源码，以及已应用补丁和精确配置的 Linux 完整对应源码。所有归档采用固定时间、
稳定排序和固定元数据生成。

## 已知限制

- 仅对 `zu02-dw01` target 完成实机验证。
- 标准 Debian `adbd` 不实现主机侧 `adb reboot` 服务；使用项目提供的 ADB shell 兼容入口。
- 有效 SIM 的 LTE 数据、DNS 和 NAT 最终回归尚未完成。
- 当前只声明 LTE B1/B3/B5；不声明其他频段或运营商兼容性。
- IPv6、短信、SIM 热插拔、多 Wi-Fi 客户端和故障注入不在首个候选声明范围内。
- 9008 恢复必须使用设备自己的原厂备份。

## 许可证

项目自有代码和文档默认使用 MIT。Linux DTS 补丁使用 `GPL-2.0-only`。完整说明见
[docs/licensing.md](docs/licensing.md) 和 `LICENSES/`。
