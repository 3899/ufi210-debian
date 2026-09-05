# 本机设备资源目录

本目录只保存构建所需的本机私有输入说明。设备分区备份、Qualcomm 固件、校准数据和身份数据
不得提交到公开 Git 仓库，也不得打入公开源码发布包。

`resource/backup/` 是当前 ZU02/DW01 随身 WiFi 的原始出厂固件备份，应作为只读的原厂恢复和
硬件分析基线保存。当前实机 Android 与本目录内的原厂系统镜像不同；从当前实机临时读取的
分区或属性不能自动视为原厂内容。

## 目录布局

构建 ZU02/DW01 候选固件前，由设备所有者自行准备：

```text
resource/backup/0.modem.fat
resource/backup/0.modem/image/
resource/backup/19.boot.img
resource/backup/22.cache.img
resource/backup/persist/WCNSS_qcom_wlan_nv.bin
```

其中 `0.modem/image` 至少应包含：

```text
mba.mbn
modem.mdt
modem.b00 ... modem.b24（按 modem.mdt 实际引用的分段）
wcnss.mdt
wcnss.b00 ... wcnss.b12（按 wcnss.mdt 实际引用的分段）
```

禁止从其他设备复制 modemst、fsg、persist、IMEI、校准数据或设备证书。正式构建必须使用目标
设备自己的原厂备份。

## 已确认的关键哈希

当前 ZU02/DW01 样机输入：

```text
0.modem.fat
ed84737a248a36ed3a59446f50b1cc249813de2ea814ace9a1fd7e976278152e

mba.mbn
96d8813bd4d6decb92b6b3694addd04b31a9d7a21e46f60665667d9102757dc1

modem.mdt
c24d196cee13585c39995c11d869ef2068255719c018ccf704a639db8fb2717f
```

`modemst1`、`modemst2` 和 `persist` 会被设备当前运行的系统及基带正常更新，不能用出厂备份
哈希作为永久固定值。每次高风险测试应记录测试前基线并在测试后比较，不应把这些分区内容提交
或公开。

## 发布边界

公开仓库只包含：

- 提取方法和所需文件名。
- 可复现构建脚本。
- 不包含设备身份的输入哈希。
- rootfs 中指向原厂只读 modem/persist 分区的固件和校准 NV 符号链接规则。

公开仓库不包含：

- Qualcomm/厂商闭源固件内容。
- 原厂完整分区镜像。
- modemst、fsg、persist、EFS、IMEI、IMSI、ICCID、密钥或证书。
