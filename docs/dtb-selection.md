# DW01 / ZU02_main_v1.1 DTB 与 QCDT 选择

## 结论

当前硬件目标使用：

```text
qcom-msm8909-zu02-dw01.dtb
```

它由本项目板级 DTS 构建。原厂 boot 中的下游 DTB 只用于确认硬件 ID、reserved-memory 和外设
基线，不能直接替代主线 DTB。

## 原厂匹配键

| 字段 | 值 |
| --- | ---: |
| `platform_id` | 245 |
| `variant_id` | 65547 (`0x0001000b`) |
| `board_hw_subtype` | 0 |
| `pmic0` | 65549 (`0x0001000d`) |
| 平台 | QRD 1.0 |
| PMIC | PM8909 |

原厂 QCDT v3 含 137 条记录和 38 个唯一 DTB。实机 ID 唯一匹配 entry 16；对应下游 DTB 仅作
板级迁移基线。

## 主线板级内容

`qcom-msm8909-zu02-dw01.dts` 使用主线 binding，并描述：

- PM8909、电源、TLMM、eMMC、UART 和 USB。
- 512 MiB 地址空间及 WCNSS、MPSS、RMTFS、SMEM、MBA reserved-memory。
- WCN3620 Iris、WCNSS remoteproc。
- MPSS remoteproc、QRTR、BAM-DMUX 和 WWAN control。
- PMIC PON bootloader/recovery reboot-mode 映射。
- thermal zone、75°C 被动降频点和 3°C 回差。

## 原厂 aboot 直接启动

仅把主线 DTB 追加到 kernel 末尾时，原厂 fastboot 拒绝并返回 `dtb not found`。因此正式 boot
必须携带原厂 aboot 能解析的 QCDT 表。

`scripts/build_stock_qcdt.py` 从设备自己的原厂 boot 中选择全部 MSM8909 `platform_id=245` 记录，
保留各记录的 variant、subtype、SoC revision 和 PMIC 匹配字段，但让全部记录指向唯一的主线
DW01 DTB。正式 QCDT 必须满足：

```text
QCDT version=3
platform_id=245
entries=30
unique DTB=1
model=DW01 (ZU02_main_v1.1)
compatible=zu02,dw01
```

实机已经通过原厂 fastboot 直接 RAM 启动该 boot image。正式持久镜像使用同一 QCDT 格式写入
boot 分区，无需更改 aboot 或 GPT。

## 验收

`scripts/verify_debian_system.sh` 会解析最终 Android boot image，并核对：

- Android boot page size 为 2048。
- cmdline 指向 `PARTLABEL=system` 且含 `reboot=warm`。
- kernel、initramfs 和 QCDT 与正式构建产物逐字节一致。
- 30 条 QCDT 记录全部指向唯一 DW01 DTB。
- DTB model、compatible、remoteproc、reserved-memory 和 thermal trip 均匹配。
