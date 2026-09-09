# USB ADB 诊断与实验

## 当前默认方案

正式镜像默认使用固定 `RNDIS + ACM` 复合设备。Debian `adbd` 监听
`192.168.68.1:5555`，通过 USB RNDIS 管理网络访问：

```powershell
adb connect 192.168.68.1:5555
adb -s 192.168.68.1:5555 shell
```

这不是把 ADB 绑定到设备 Wi-Fi。`192.168.68.1` 是 USB 管理接口地址。

## 原因

USB ADB 需要同时满足三个条件：内核 FunctionFS、`/dev/usb-ffs/adb` 挂载点和
ConfigFS 中的 `ffs.adb` 功能。`adbd` 进程存在或 TCP 5555 正在监听，并不能证明
USB ADB 已经枚举。

MSM8909 的 FunctionFS 已编入本项目内核，但实机验证表明把 `ffs.adb` 临时加入现有
`RNDIS + ACM` 后，USB 复合设备可能整体不再枚举。因此正式服务不会在 `adbd` 重启时
解绑或重建 UDC，TCP ADB 仍作为可靠维护入口。

## 有界实验

实验工具默认不启用，只在已经能通过 TCP ADB 管理设备时手动启动。它使用独立的
systemd transient service，避免 ADB shell 断开时杀掉恢复脚本；时限到达、进程退出或
收到信号后都会恢复固定 `RNDIS + ACM` gadget。

在 Windows PowerShell 执行：

```powershell
cd <工程目录>
.\scripts\test_debian_usb_adb_experimental.ps1 -Mode rndis-adb -DurationSeconds 120
```

可选模式为 `rndis-adb`、`acm-adb` 和 `rndis-acm-adb`。实验临时使用独立的 USB
product ID `0xD002`，正式配置仍为 `0xD001`；实验结束后会恢复正式 product ID。
实验可能导致 Windows USB 设备短暂消失，不能在未确认设备可断电恢复时执行。脚本只允许使用
`192.168.68.1:5555`，不会选择其他 ADB 序列号。

当前实机结果：普通 FunctionFS 挂载可以完成 USB ADB 冷枚举；`ACM + USB ADB`
可以同时枚举 ADB 和串口，但实验性 `adbd` 热重启后 USB ADB 在观察期内消失。
`RNDIS + USB ADB` 还会使 Windows RNDIS 接口报错，TCP ADB 回退不可用。因此正式镜像
继续默认关闭 USB ADB，保留已经验证的 RNDIS + ACM + TCP ADB。

## 发布判定

只有以下条件全部在独立冷启动和多次 `adbd` 热重启中通过，才可以把 USB ADB 改为默认：

1. Windows 枚举 Android ADB、RNDIS 和 ACM；
2. `adb devices -l` 出现 USB transport；
3. TCP ADB 在 USB ADB 建立后仍可连接；
4. `systemctl restart adbd` 不导致 UDC、RNDIS 或 ACM 消失；
5. 实验超时和异常退出都能自动恢复 TCP ADB；
6. 普通重启与断电重新上电后仍能重复枚举。
