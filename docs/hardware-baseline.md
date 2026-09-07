# DW01 / ZU02_main_v1.1 硬件基线

## 已确认信息

| 项目 | 值 |
| --- | --- |
| 产品 | DW01 |
| PCB | `ZU02_main_v1.1` |
| SoC | Qualcomm MSM8909 / Snapdragon 210 |
| SoC ID | 245 |
| CPU 架构 | ARMv7 32 位 |
| Debian 架构 | `armhf` |
| PMIC | PM8909，运行时值 65549 |
| 平台 | QRD 1.0，variant 65547，subtype 0 |
| RAM | 512 MiB，Linux `MemTotal` 约 404 MiB |
| eMMC | 约 4 GB，7,569,408 个 512 字节扇区 |
| eMMC 控制器 | `7824900.sdhci` |
| USB gadget controller | `msm_hsusb` |

安装脚本检查 Android `ro.product.device=msm8909`、SoC ID、启动完成状态、boot/system/cache/userdata
分区尺寸、fastboot product 和候选镜像哈希。

## 分区边界

| 分区 | 字节数 | 当前策略 |
| --- | ---: | --- |
| boot | 33,554,432 | 写入 Debian boot image |
| recovery | 33,554,432 | 保持不变 |
| cache | 268,435,456 | 写入 Debian 根卷的第二段 |
| system | 1,288,491,008 | 写入 Debian 根卷的第一段 |
| userdata | 1,928,314,368 | 写入 Debian 根卷的第三段；末尾 3,584 字节不属于 ext4 |
| persist | 33,554,432 | 只读挂载，禁止写入 |
| modemst1 | 1,572,864 | 禁止写入 |
| modemst2 | 1,572,864 | 禁止写入 |
| fsg | 1,572,864 | 禁止写入 |

构建时生成 3,485,237,248 字节的完整 ext4，再按固定边界切成 system、cache 和 userdata
三张 fastboot 镜像。initramfs 只在三个 PARTNAME、起始 LBA 和扇区数全部精确匹配时创建
6,807,111 扇区的 `ufi210-root` 线性卷。文件系统预先达到最终大小，不依赖首启在线扩容；
逻辑卷尾部保留 3,584 字节以满足 ext4 4 KiB 块边界。boot image 必须小于 32 MiB。

## QCDT 与内存

原厂 boot：

```text
Android boot page size: 2048
QCDT version: 3
QCDT entries: 137
unique DTB blobs: 38
```

实机 ID 唯一匹配原厂 entry 16：

```text
platform_id=245
variant_id=65547
board_hw_subtype=0
pmic0=65549
```

实机 System RAM 地址范围为：

```text
0x80000000-0x879fffff
0x8da00000-0x9fffffff
```

总物理范围为 512 MiB，其中约 96 MiB 保留给 modem、WCNSS 和连续内存。下游 DTB 文件名中的
容量标记不能替代实机地址证据。

## 固件与校准数据

- MPSS、MBA 和 WCNSS firmware 来自设备既有 modem 分区。
- WLAN NV 来自设备既有 persist 分区。
- modem 以 `ro,nosuid,nodev,noexec` 挂载。
- persist 以 `ro,noload,nosuid,nodev,noexec` 挂载。
- rootfs 只含指向上述只读挂载的符号链接，不复制闭源内容。
- 校准数据不进入公开发布包，也不公开哈希。

## 启动与重启

正式启动链：

```text
原厂 PBL/SBL/aboot
  -> boot 分区 Android boot image
  -> QCDT v3 匹配唯一 DW01 DTB
  -> Linux 7.0.0-msm8909
  -> initramfs 组合 system + cache + userdata
  -> /dev/mapper/ufi210-root 上的 Debian 12
```

无 QCDT 直启会被原厂 fastboot 以 `dtb not found` 拒绝；带 QCDT 的同一 kernel/initramfs 已实机
直启成功。设备无电池，cold reboot 会撤销 PS_HOLD，因此正式 cmdline 固定 `reboot=warm`。普通
reboot 已验证无需物理插拔并返回持久 Debian。
