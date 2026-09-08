# ZU02 / DW01 9008 恢复基线

## 当前结论

本项目已完成以下静态恢复准备：

- 保存并校验当前设备主 GPT。
- 核对 GPT header CRC 和 partition entries CRC。
- 核对 `resource/backup` 中 29 个分区镜像与当前 GPT 分区尺寸。
- 按当前磁盘布局重建并校验备 GPT。
- 生成 Android OS-only 和全分区 QFIL rawprogram。

尚未使用新生成的 rawprogram 完成一次实际 QFIL 写入和回读，因此不能宣称 9008 恢复链已闭环。

## 恢复文件

开发环境可重新生成：

```powershell
py -3 .\scripts\generate_9008_recovery.py
```

主要输出：

```text
out/recovery-baseline/rawprogram-zu02-android-os-only.xml
out/recovery-baseline/rawprogram-zu02-full.xml
out/recovery-baseline/patch0-empty.xml
out/recovery-baseline/zu02-recovery-manifest.json
```

这些文件和原厂分区镜像属于设备私有恢复资料，不进入公开仓库或发布包。

## Android OS-only 恢复

`rawprogram-zu02-android-os-only.xml` 只写同一台设备自己的：

- boot
- system
- recovery

当前 Debian 安装器覆盖 boot、system、cache 和 userdata。GPT 与 bootloader 完整时仍优先使用 OS-only
恢复 boot/system/recovery，但 Android cache 和 userdata 还必须按目标 Android 固件的要求重新格式化或恢复。
该流程本身不会写 modem、modemst、fsg、persist、DDR、sbl1、aboot、rpm、tz、cache、userdata
或 GPT。

## 全分区恢复

`rawprogram-zu02-full.xml` 写入当前设备的原厂分区及主/备 GPT。仅在 GPT 或 bootloader 已损坏时
使用。它含设备专属 modemst、fsg、persist、DDR 和身份相关数据，绝不能用于另一台设备。

## QFIL 边界

1. Windows 设备管理器确认目标是 `Qualcomm HS-USB QDLoader 9008 (COMx)`。
2. 使用与当前设备和 eMMC 匹配、已验证可通信的 programmer。
3. `Storage Type` 选择 `eMMC`。
4. GPT 未损坏时优先选择 Android OS-only rawprogram。
5. patch 使用项目生成的空 patch 文件。
6. 核对 COM 端口后执行 Download，并检查日志中的全部 ACK。
7. 只有明确确认 GPT 或 bootloader 损坏时才使用全分区恢复。

programmer 能握手不等于已验证可写；首次受控写入演练完成前，必须保留这一限制说明。

## Programmer 无写入探测

正式恢复前先确认 programmer 能在当前设备上完成 Sahara 和 firehose 握手。该步骤只读取 eMMC
几何信息，不加载 rawprogram，不写分区：

```powershell
.\scripts\probe_9008_programmer.ps1 `
  -ComPort COM4 `
  -Programmer 'D:\recovery\prog_emmc_firehose_8909.mbn' `
  -ExpectedProgrammerSha256 '<预先核对的 SHA256>' `
  -ConfirmNoWriteProbe
```

必须同时满足：

- Windows 只连接一台 `VID_05C6&PID_9008` 设备，COM 端口与参数一致。
- Sahara 明确完成，firehose 只执行 `getstorageinfo`。
- eMMC 为 7,569,408 个 512 字节扇区，共 3,875,536,896 字节。
- 日志中没有 `sendxml`、program、erase 或 firmware write。
- 探测后由 firehose reset 返回已安装的 Debian；脚本只接受主机名、SoC ID 和根设备均符合
  已验证 m8 或大根卷布局的系统。

不同文件名的 programmer 不能仅凭 SoC 名称判定兼容。没有当前设备的成功握手日志时，不得直接
执行 rawprogram。

## Fastboot 回滚 Android

如果设备仍能进入 fastboot，可使用本机原始分区备份回滚 Android。脚本要求提供由同一备份目录
生成的 SHA256 清单，并在校验产品、分区尺寸和每个镜像哈希后才允许写入；它不修改 GPT，也不会
自动重启，便于先检查 fastboot 输出：

```powershell
.\scripts\restore_android_fastboot.ps1 `
  -BackupDirectory '.\resource\backup' `
  -ManifestPath '.\resource\backup\sha256sums-device-original.txt' `
  -ConfirmRestoreAndroid
```

确认恢复结果后再执行：

```powershell
.\scripts\restore_android_fastboot.ps1 `
  -BackupDirectory '.\resource\backup' `
  -ManifestPath '.\resource\backup\sha256sums-device-original.txt' `
  -ConfirmRestoreAndroid -RebootAfterRestore
```

该脚本只适用于生成这些备份的同一台设备。恢复后的 Android 仍可能需要按原固件流程重新
格式化 userdata；如果 bootloader 或 GPT 已损坏，应改用设备专属 9008 恢复流程。

## 禁止事项

- 禁止写入其他型号、其他 PCB 或其他设备的整盘镜像。
- 禁止混用不同分区布局的 GPT、boot、system 或 recovery。
- 禁止复制其他设备的 modemst、fsg、persist、EFS、IMEI、密钥或证书。
- 设备处于 900E 时没有可用 ADB/fastboot，不应继续发送这两类命令。
- 无法确认目标状态时先停止，不尝试盲写。

恢复 Android 后应核对：

```powershell
.\adb.exe devices -l
.\adb.exe shell getprop ro.product.device
.\adb.exe shell cat /sys/devices/soc0/soc_id
```

目标应为 `msm8909` 和 `245`。
