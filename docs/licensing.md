# 许可证与源码对应关系

## 项目内容

除文件内另有 SPDX 标识外，本工程的构建脚本、测试脚本、配置和中文文档采用 MIT 许可证，
完整文本见本包根目录 `LICENSE` 和 `LICENSES/MIT.txt`。

`patches/linux/0001-arm-dts-qcom-add-zu02-dw01-minimal.patch` 中新增的 Linux DTS 内容按文件内
`GPL-2.0-only` 标识授权，许可证文本见 `LICENSES/GPL-2.0-only.txt`。

Debian rootfs、Linux 内核、BusyBox 和其他构建输入分别遵循各自上游许可证；本工程 MIT
许可证不会覆盖或替代这些许可证。

## 对应源码

项目源码、Linux 完整对应源码，以及 rootfs 内 Debian 二进制包的精确对应源码
归档与固件分开提供。这三份源码归档不用于刷机。

## 闭源固件与设备数据

Qualcomm/厂商闭源 firmware、原厂分区镜像、WLAN 校准 NV、EFS、IMEI、密钥和证书不进入
公开源码或二进制包。rootfs 只保存指向设备现有只读 modem/persist 分区的符号链接规则。
公开 manifest 不记录校准文件哈希。
