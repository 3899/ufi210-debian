#!/usr/bin/env python3

from pathlib import Path
import unittest


INITRAMFS = Path(__file__).parents[1] / "patches/initramfs/init-debian.sh"
BUILD = Path(__file__).with_name("build_debian_cache.sh")
VERIFY = Path(__file__).with_name("verify_debian_cache.sh")
PROBE_BUILD = Path(__file__).with_name("build_large_rootfs_probe_boot.sh")
PROBE_TEST = Path(__file__).with_name("test_large_rootfs_dm_probe.ps1")
PUBLIC_PACKAGE = Path(__file__).with_name("package_public_release_candidate.sh")
PACKAGE_SCRIPT = Path(__file__).with_name("package_release_candidate.sh")
AUDIT_SCRIPT = Path(__file__).with_name("audit_public_release.sh")
RESTORE_SCRIPT = Path(__file__).with_name("restore_android_fastboot.ps1")
COLD_BOOT_TEST = Path(__file__).with_name("test_debian_cold_boot.ps1")
USB_ADB_EXPERIMENT = (
    Path(__file__).parents[1]
    / "patches/rootfs/usr/sbin/zu02-usb-adb-experiment"
)
USB_ADB_TEST = Path(__file__).with_name("test_debian_usb_adb_experimental.ps1")
SCRIPTS = Path(__file__).parent


class LargeRootfsLayoutTests(unittest.TestCase):
    def test_dm_table_is_fixed_and_contiguous(self) -> None:
        init = INITRAMFS.read_text(encoding="utf-8")
        self.assertIn('system_start=461920', init)
        self.assertIn('cache_start=3044040', init)
        self.assertIn('userdata_lba=3803136', init)
        self.assertIn('dmsetup create --noudevsync ufi210-root --table "$table"', init)
        self.assertIn('dmsetup mknodes ufi210-root', init)
        self.assertIn('blockdev --getsz /dev/mapper/ufi210-root', init)
        self.assertIn('blockdev --getro /dev/mapper/ufi210-root', init)

        values = [2516584, 524288, 3766239]
        self.assertEqual(sum(values), 6807111)
        self.assertEqual(6807111 * 512, 3485240832)

    def test_build_and_verify_agree_on_large_rootfs_contract(self) -> None:
        build = BUILD.read_text(encoding="utf-8")
        verify = VERIFY.read_text(encoding="utf-8")
        for text in (build, verify):
            self.assertIn('large-rootfs)', text)
            self.assertIn('ROOTFS_DEVICE="/dev/mapper/ufi210-root"', text)
            self.assertIn('ROOTFS_LABEL="ufi210-root"', text)
            self.assertIn('LARGE_ROOTFS_SIZE=3485240832', text)
            self.assertIn('dm-linear-system-cache-userdata', text)
            self.assertIn('ROOTFS_AUTO_GROW=disabled', text)
        initramfs_build = (Path(__file__).with_name("build_debian_initramfs.sh"))
        initramfs_text = initramfs_build.read_text(encoding="utf-8")
        self.assertIn('realpath -ms', initramfs_text)
        self.assertIn('qemu-arm-static -L "$tmp_dir/initramfs-root"', verify)
        self.assertIn('initramfs-dmsetup-help.txt', verify)

    def test_segment_reassembly_preserves_all_previous_segments(self) -> None:
        verify = VERIFY.read_text(encoding="utf-8")
        self.assertEqual(verify.count("conv=notrunc,sparse"), 3)
        self.assertIn(
            '[[ "$(stat -c %s "$IMAGE")" == "$LARGE_ROOTFS_FILESYSTEM_SIZE" ]]',
            verify,
        )
        self.assertNotIn(
            '$(stat -c %s "$IMAGE") < SYSTEM_PARTITION_SIZE', verify
        )

    def test_large_rootfs_cache_uses_published_segments(self) -> None:
        build = BUILD.read_text(encoding="utf-8")
        self.assertIn('rootfs_artifacts_present=0', build)
        self.assertIn('logical_rootfs_hash="$(cat "$ROOTFS_SYSTEM_IMAGE"', build)
        self.assertIn('segment_bytes_recorded=', build)

    def test_initramfs_fails_closed_on_geometry_mismatch(self) -> None:
        init = INITRAMFS.read_text(encoding="utf-8")
        self.assertIn('if [ "$actual_sectors" != "$expected_sectors" ]; then', init)
        self.assertIn('if [ "$actual_start" != "$expected_start" ]; then', init)
        for partition in ("system", "cache", "userdata"):
            self.assertIn(
                f"large_root_failure \"$readonly_flag\" '{partition} partition "
                "is missing, duplicated, or has the wrong size'",
                init,
            )
        self.assertIn('if [ "$readonly_flag" = yes ]; then', init)
        self.assertIn('rescue_shell "$reason"', init)

    def test_initramfs_retries_the_complete_usb_gadget_setup(self) -> None:
        init = INITRAMFS.read_text(encoding="utf-8")
        self.assertIn(
            "if /sbin/zu02-usb-gadget setup && "
            "/sbin/zu02-usb-gadget activate; then",
            init,
        )
        self.assertIn('max_attempts="${1:-1}"', init)
        self.assertIn("start_recovery_network 1 || log", init)
        self.assertIn("start_recovery_network 60 || log", init)
        self.assertNotIn('udc="$(ls /sys/class/udc', init)
        self.assertNotIn('for candidate in /sys/class/udc/*; do', init)
        self.assertIn('[ "$attempt" -le "$max_attempts" ]', init)
        self.assertIn("USB recovery gadget deferred to Debian userspace", init)
        self.assertIn("USB recovery RNDIS did not appear", init)
        self.assertIn("USB recovery ACM is unavailable; continuing", init)
        self.assertNotIn(
            '[ ! -e /sys/class/net/usb0 ] || [ ! -c /dev/ttyGS0 ]', init
        )

    def test_ram_probe_is_read_only_and_never_flashes(self) -> None:
        init = INITRAMFS.read_text(encoding="utf-8")
        probe = PROBE_BUILD.read_text(encoding="utf-8")
        self.assertIn("dmsetup create --readonly", init)
        self.assertIn('actual_table="$(dmsetup table ufi210-root', init)
        self.assertIn('[ "$actual_table" = "$expected_table" ]', init)
        self.assertIn("! mountpoint -q /sysroot", init)
        self.assertIn("read-only ufi210-root probe completed successfully", init)
        self.assertIn(
            "finish_readonly_probe "
            "'read-only ufi210-root probe completed successfully'",
            init,
        )
        self.assertIn("/system/bin/reboot bootloader", init)
        self.assertIn("read-only probe failed, returning to persistent boot", init)
        self.assertIn(
            '/system/bin/reboot \\\n'
            '            || rescue_shell "$reason; automatic persistent reboot failed"',
            init,
        )
        self.assertIn("ufi210.dm_probe=1", probe)
        self.assertIn("只用于 fastboot boot", probe)
        self.assertNotIn("fastboot flash", probe.lower())
        probe_test = PROBE_TEST.read_text(encoding="utf-8")
        self.assertIn('"boot", $ProbeBoot', probe_test)
        self.assertIn("DM_READONLY=1", probe_test)
        self.assertIn("DM_SECTORS=6807111", probe_test)
        self.assertIn("rootfs_mount=none", probe_test)
        self.assertIn("PreDmStepwise", probe_test)
        self.assertIn("Wait-FastbootReturn", probe_test)
        self.assertIn("probe_mode=automatic-fastboot-return", probe_test)
        self.assertIn(
            "geometry-dm-node-sector-count-readonly-then-restart2", probe_test
        )
        self.assertIn("UFI210_PRE_DM_OK", probe_test)
        self.assertIn("acm-pre-dm.txt", probe_test)
        self.assertIn("acm-dm-error.txt", probe_test)
        self.assertIn(
            'dmsetup create --readonly --noudevsync ufi210-root', probe_test
        )
        self.assertNotRegex(
            probe_test,
            r'(?i)\$Fastboot\s+@\([^\n]*(?:"flash"|"erase")',
        )
        self.assertNotIn('"flash"', probe_test.lower())
        self.assertNotIn('"erase"', probe_test.lower())

    def test_pre_dm_diagnostic_stops_after_usb_and_before_dm_setup(self) -> None:
        init = INITRAMFS.read_text(encoding="utf-8")
        usb = "start_recovery_network 1 || log"
        diagnostic = "has_cmdline_flag 'ufi210.pre_dm_rescue=1'"
        dm_path = "if uses_large_root; then"
        self.assertLess(init.index(usb), init.index(diagnostic))
        self.assertLess(init.index(diagnostic), init.index(dm_path))
        self.assertIn("pre-dm diagnostic rescue requested", init)

    def test_reused_kernel_archive_is_re_rooted_for_current_release(self) -> None:
        package = PUBLIC_PACKAGE.read_text(encoding="utf-8")
        self.assertIn("reused_kernel_roots", package)
        self.assertIn("--strip-components=1", package)
        self.assertIn('create_archive "$tmp_dir" "$kernel_source_name"', package)
        self.assertIn("reused_kernel_root/UFI210-BUILD-METADATA.txt", package)

    def test_binary_manifest_preserves_adbd_tmpdir_storage_contract(self) -> None:
        package = PACKAGE_SCRIPT.read_text(encoding="utf-8")
        audit = AUDIT_SCRIPT.read_text(encoding="utf-8")
        for value in (
            "data_mount=$(manifest_value data_mount)",
            "adbd_shell_tmpdir=$(manifest_value adbd_shell_tmpdir)",
            "adbd_shell_tmpdir_storage=$(manifest_value adbd_shell_tmpdir_storage)",
        ):
            self.assertIn(value, package)
        for value in (
            "'data_mount=none'",
            "'adbd_shell_tmpdir=/data/local/tmp'",
            "'adbd_shell_tmpdir_storage=rootfs'",
        ):
            self.assertIn(value, audit)

    def test_usb_adb_is_opt_in_and_uses_a_separate_product_id(self) -> None:
        build = BUILD.read_text(encoding="utf-8")
        verify = VERIFY.read_text(encoding="utf-8")
        experiment = USB_ADB_EXPERIMENT.read_text(encoding="utf-8")
        host_test = USB_ADB_TEST.read_text(encoding="utf-8-sig")
        self.assertIn("usb_adb=opt-in-experimental-disabled", build)
        self.assertIn("usb_adb_experiment_product_id=0xD002", build)
        self.assertIn("manifest_value usb_adb", verify)
        self.assertIn('== "opt-in-experimental-disabled"', verify)
        self.assertIn("manifest_value usb_adb_experiment_product_id", verify)
        self.assertIn('== "0xD002"', verify)
        self.assertIn("DEFAULT_PID=0xD001", experiment)
        self.assertIn("EXPERIMENT_PID=0xD002", experiment)
        self.assertIn("trap restore EXIT INT TERM HUP", experiment)
        self.assertIn("mount -t functionfs adb /dev/usb-ffs/adb", experiment)
        self.assertNotIn("WantedBy=", experiment)
        self.assertIn("USB\\VID_18D1&PID_D002", host_test)
        self.assertIn("$TcpSerial = '192.168.68.1:5555'", host_test)

    def test_cold_boot_probe_waits_for_all_services_and_handles_empty_usb_query(self) -> None:
        cold_boot = COLD_BOOT_TEST.read_text(encoding="utf-8-sig")
        self.assertIn("[object[]]$devices = @(", cold_boot)
        self.assertIn("for _ in $(seq 1 60); do", cold_boot)
        self.assertIn("__ACTIVE_COUNT__", cold_boot)
        self.assertIn("$ActiveServiceCount = $ActiveServices.Count", cold_boot)

    def test_fastboot_android_restore_is_explicit_and_does_not_touch_gpt(self) -> None:
        restore = RESTORE_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("ConfirmRestoreAndroid", restore)
        self.assertIn('"system", "cache", "userdata", "recovery", "boot"', restore)
        self.assertIn('Get-FastbootVariable $serial "product"', restore)
        self.assertNotIn('"erase"', restore.lower())
        self.assertNotIn('"gpt"', restore.lower())

    def test_large_rootfs_runtime_tests_do_not_use_legacy_storage_contract(self) -> None:
        runtime_scripts = (
            "collect_debian_usb_postmortem.ps1",
            "monitor_debian_stability.ps1",
            "test_debian_cold_boot.ps1",
            "test_debian_fastboot_reboot.ps1",
            "test_debian_reboot_cycles.ps1",
            "test_debian_thermal.ps1",
            "test_debian_wcnss.ps1",
        )
        for name in runtime_scripts:
            text = (SCRIPTS / name).read_text(encoding="utf-8")
            with self.subTest(script=name):
                self.assertNotIn("out\\mainline\\debian-system", text)
                self.assertNotIn("out\\debian-system-device-test", text)
                self.assertNotIn("root=PARTLABEL=system", text)
                self.assertNotIn("/dev/mmcblk0p21", text)

        monitor = (SCRIPTS / "monitor_debian_stability.ps1").read_text(
            encoding="utf-8"
        )
        for value in (
            "ROOT=/dev/mapper/ufi210-root",
            "ROOT_UUID=",
            "DATA_MOUNTED=no",
            "DM_BYTES=3485240832",
            "DM_LINES=3",
            "WWAN_IPV4_GLOBAL=",
            "WWAN_IPV6_GLOBAL=",
            "WWAN_IPV4_DEFAULT=",
            "WWAN_IPV6_DEFAULT=",
            "ACTIVE_GSM=",
            '"cellular_global_addresses=0"',
            '"cellular_default_routes=0"',
            '"active_gsm_connections=0"',
        ):
            self.assertIn(value, monitor)

    def test_device_test_outputs_are_separated_from_previous_layout(self) -> None:
        for path in SCRIPTS.glob("*.ps1"):
            text = path.read_text(encoding="utf-8")
            with self.subTest(script=path.name):
                self.assertNotIn("out\\debian-system-device-test", text)

    def test_windows_powershell_scripts_have_utf8_bom(self) -> None:
        for path in SCRIPTS.glob("*.ps1"):
            with self.subTest(script=path.name):
                self.assertTrue(path.read_bytes().startswith(b"\xef\xbb\xbf"))


if __name__ == "__main__":
    unittest.main()
