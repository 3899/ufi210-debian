#!/usr/bin/env python3

from pathlib import Path
import unittest


INITRAMFS = Path(__file__).parents[1] / "patches/initramfs/init-debian.sh"
BUILD = Path(__file__).with_name("build_debian_cache.sh")
VERIFY = Path(__file__).with_name("verify_debian_cache.sh")
PROBE_BUILD = Path(__file__).with_name("build_large_rootfs_probe_boot.sh")
PROBE_TEST = Path(__file__).with_name("test_large_rootfs_dm_probe.ps1")
PUBLIC_PACKAGE = Path(__file__).with_name("package_public_release_candidate.sh")
RESTORE_SCRIPT = Path(__file__).with_name("restore_android_fastboot.ps1")
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
        self.assertIn("rescue_shell 'system partition is missing, duplicated, or has the wrong size'", init)
        self.assertIn("rescue_shell 'cache partition is missing, duplicated, or has the wrong size'", init)
        self.assertIn("rescue_shell 'userdata partition is missing, duplicated, or has the wrong size'", init)

    def test_initramfs_waits_for_both_usb_recovery_functions(self) -> None:
        init = INITRAMFS.read_text(encoding="utf-8")
        self.assertIn('for candidate in /sys/class/udc/*; do', init)
        self.assertIn("[ \"$attempt\" -le 60 ]", init)
        self.assertIn("USB Device Controller did not appear within 60 seconds", init)
        self.assertIn('[ ! -e /sys/class/net/usb0 ] || [ ! -c /dev/ttyGS0 ]', init)
        self.assertIn("USB recovery RNDIS and ACM did not appear", init)

    def test_ram_probe_is_read_only_and_never_flashes(self) -> None:
        init = INITRAMFS.read_text(encoding="utf-8")
        probe = PROBE_BUILD.read_text(encoding="utf-8")
        self.assertIn("dmsetup create --readonly", init)
        self.assertIn("read-only ufi210-root probe completed successfully", init)
        self.assertIn("ufi210.dm_probe=1", probe)
        self.assertIn("只用于 fastboot boot", probe)
        self.assertNotIn("fastboot flash", probe.lower())
        probe_test = PROBE_TEST.read_text(encoding="utf-8")
        self.assertIn('"boot", $ProbeBoot', probe_test)
        self.assertIn("DM_READONLY=1", probe_test)
        self.assertIn("DM_SECTORS=6807111", probe_test)
        self.assertIn("rootfs_mount=none", probe_test)
        self.assertIn("PreDmStepwise", probe_test)
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
        usb = "start_recovery_network || rescue_shell"
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
