# 安全策略

## 支持范围

安全修复只进入最新候选版本和后续版本。未通过 `scripts/verify_debian_system.sh` 的本地构建
不在支持范围内。

## 固定安全边界

- 安装器只允许持久写入 `boot`、`system` 和 `userdata`。
- `userdata` 只在用户显式传入 `-ConfirmEraseUserdata` 后擦除并重建为 Debian `/data`。
- 禁止写入 GPT、aboot、recovery、cache、modem、modemst1/2、fsg 或 persist。
- 安装前必须备份 boot，并准备设备自己的完整原厂恢复输入。
- 禁止向公开议题、日志或仓库上传设备全量备份、IMEI/IMSI、SIM 标识、校准数据、校准数据哈希
  或运营商凭据。
- Debian `adbd` 不提供 Android 式客户端授权；TCP ADB 5555 和 SSH 22 由 nftables 限制到
  USB 管理接口 `usb0`，不得暴露到 Wi-Fi 或蜂窝网络。
- 公开发布包不得包含 Qualcomm 闭源 firmware、WLAN 校准 NV、9008 firehose、rawprogram 或
  设备专用恢复镜像。
- 普通重启必须保持 `reboot=warm`，避免无电池设备撤销 PS_HOLD 后无法自行上电。

## 报告漏洞

不要先公开可直接利用的细节。请使用目标 GitHub 仓库的私有安全公告功能提交报告，并提供：

1. 受影响的发布版本、manifest 和文件 SHA256。
2. 设备型号、板号和 SoC ID；删除序列号、IMEI、IMSI、手机号和 SIM 标识。
3. 最小复现步骤、预期结果、实际结果和恢复状态。
4. 是否触及持久分区、是否进入 900E/9008、USB RNDIS/ADB/ACM 是否仍可用。
5. 可公开的脱敏日志；不要附带私有分区镜像。

涉及分区写入、boot chain、远程 root、未授权管理端口、基带校准数据损坏或稳定触发 900E 的
问题按高优先级处理。在修复完成、实机验证和新候选发布前，不应公开利用代码。
