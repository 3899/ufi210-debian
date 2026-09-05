#!/system/bin/sh

# 只读采集当前 Android 的 MSM8909 板级信息；脚本名为兼容旧调用保留。
# 本脚本不挂载文件系统、不修改属性、不写分区，也不重启设备。

PATH=/sbin:/system/sbin:/system/bin:/system/xbin:/vendor/bin
export PATH

section() {
    echo
    echo "================================================================"
    echo "## $1"
    echo "================================================================"
}

dump_file() {
    file="$1"
    if [ -r "$file" ]; then
        echo "-- $file"
        cat "$file" 2>&1
        echo
    fi
}

dump_dir_files() {
    dir="$1"
    if [ ! -d "$dir" ]; then
        echo "目录不存在: $dir"
        return
    fi

    for file in "$dir"/*; do
        if [ -f "$file" ] && [ -r "$file" ]; then
            dump_file "$file"
        fi
    done
}

section "采集元数据"
date 2>&1
echo "probe_version=2"
identity="$(id 2>/dev/null)"
echo "identity=$identity"
echo "$identity"
uname -a 2>&1

section "Android 属性"
getprop 2>&1

section "SoC 与 PMIC"
dump_dir_files /sys/devices/soc0
dump_dir_files /sys/devices/system/soc/soc0

section "内核命令行与内存"
dump_file /proc/cmdline
dump_file /proc/meminfo
dump_file /proc/iomem
dump_file /proc/interrupts
dump_file /proc/modules
dump_file /proc/version

section "设备树入口"
ls -la /proc/device-tree 2>&1
ls -la /proc/device-tree/chosen 2>&1
ls -la /sys/firmware/devicetree/base 2>&1
ls -la /sys/firmware/devicetree/base/chosen 2>&1

section "eMMC 与分区"
dump_file /proc/partitions
dump_file /sys/class/block/mmcblk0/size
dump_file /sys/class/block/mmcblk0/queue/logical_block_size
dump_file /sys/class/block/mmcblk0/queue/physical_block_size
dump_file /sys/class/block/mmcblk0/device/name
dump_file /sys/class/block/mmcblk0/device/cid
dump_file /sys/class/block/mmcblk0/device/csd
dump_file /sys/class/block/mmcblk0/device/ext_csd
ls -la /dev/block/bootdevice/by-name 2>&1
ls -la /dev/block/platform/*/by-name 2>&1
df 2>&1
mount 2>&1

section "USB gadget 与供电"
ls -la /sys/class/android_usb/android0 2>&1
dump_dir_files /sys/class/android_usb/android0
ls -la /sys/class/udc 2>&1
dump_dir_files /sys/class/power_supply/usb
dump_dir_files /sys/class/power_supply/battery

section "网络接口"
ls -la /sys/class/net 2>&1
ip addr 2>&1
ip route 2>&1
ifconfig -a 2>&1
route -n 2>&1

section "WCNSS 与校准数据"
ls -la /firmware/image 2>&1
ls -la /persist 2>&1
ls -la /persist/WCNSS_qcom_wlan_nv.bin 2>&1
md5sum /persist/WCNSS_qcom_wlan_nv.bin 2>&1
sha1sum /persist/WCNSS_qcom_wlan_nv.bin 2>&1

section "Modem 与 Qualcomm IPC 设备"
ls -la /dev/smd* 2>&1
ls -la /dev/diag 2>&1
ls -la /dev/qcqmi* 2>&1
ls -la /dev/rmnet* 2>&1
ls -la /dev/wwan* 2>&1
ls -la /sys/class/remoteproc 2>&1
ls -la /sys/bus/msm_subsys/devices 2>&1

section "Watchdog、温度和 LED"
ls -la /dev/watchdog* 2>&1
ls -la /sys/class/watchdog 2>&1
dump_dir_files /sys/class/thermal/thermal_zone0
ls -la /sys/class/thermal 2>&1
ls -la /sys/class/leds 2>&1

section "内核日志"
dmesg 2>&1

section "root 专用 debugfs 信息"
case "$identity" in
uid=0*)
    dump_file /sys/kernel/debug/gpio
    dump_file /sys/kernel/debug/clk/clk_summary
    dump_file /sys/kernel/debug/regulator/regulator_summary

    if [ -d /sys/kernel/debug/pinctrl ]; then
        for controller in /sys/kernel/debug/pinctrl/*; do
            [ -d "$controller" ] || continue
            dump_file "$controller/pins"
            dump_file "$controller/pinmux-pins"
            dump_file "$controller/pinconf-pins"
        done
    fi
    ;;
*)
    echo "当前 adbd 不是 root；跳过 debugfs。脚本没有执行 adb root 或 su。"
    ;;
esac

section "采集结束"
date 2>&1
echo "probe_complete=1"
