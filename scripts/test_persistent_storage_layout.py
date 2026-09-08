#!/usr/bin/env python3

from pathlib import Path
import unittest


PROJECT_ROOT = Path(__file__).resolve().parent.parent


class PersistentStorageLayoutTests(unittest.TestCase):
    def test_installer_requires_explicit_cache_and_userdata_erasure(self) -> None:
        installer = (PROJECT_ROOT / "scripts/install_debian_large_rootfs.ps1").read_text(
            encoding="utf-8"
        )
        batch = (PROJECT_ROOT / "install.bat").read_text(encoding="utf-8")
        self.assertIn("[switch]$ConfirmEraseCacheAndUserdata", installer)
        self.assertIn("if (-not $ConfirmEraseCacheAndUserdata)", installer)
        self.assertIn("-ConfirmEraseCacheAndUserdata", batch)

    def test_installer_can_resume_post_install_validation_without_reflashing(self) -> None:
        installer = (PROJECT_ROOT / "scripts/install_debian_large_rootfs.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("[switch]$ResumePostInstallValidation", installer)
        self.assertIn("[int]$LinuxTimeoutSeconds = 600", installer)
        self.assertIn(
            'if ($ResumePostInstallValidation) {',
            installer,
        )
        self.assertIn(
            'validation_mode=resume-post-install-no-flash',
            installer,
        )
        self.assertIn("[Convert]::ToBase64String", installer)
        self.assertIn('base64 -d | /bin/sh', installer)
        resume_start = installer.index("if ($ResumePostInstallValidation) {")
        resume_end = installer.index(
            'Invoke-Native -Executable $Adb -CommandArgs @("connect", $TcpAdbSerial)',
            resume_start,
        )
        resume_block = installer[resume_start:resume_end]
        self.assertNotIn('"erase"', resume_block)
        self.assertNotIn('"flash"', resume_block)

    def test_installer_flashes_boot_last_without_touching_sensitive_partitions(self) -> None:
        installer = (PROJECT_ROOT / "scripts/install_debian_large_rootfs.ps1").read_text(
            encoding="utf-8"
        )
        operations = (
            '("-s", $fastbootSerial, "erase", "system")',
            '("-s", $fastbootSerial, "erase", "cache")',
            '("-s", $fastbootSerial, "erase", "userdata")',
            '("-s", $fastbootSerial, "flash", "system", $RootfsSystemImage)',
            '("-s", $fastbootSerial, "flash", "cache", $RootfsCacheImage)',
            '("-s", $fastbootSerial, "flash", "userdata", $RootfsUserdataImage)',
            '("-s", $fastbootSerial, "flash", "boot", $BootImage)',
        )
        positions = [installer.index(operation) for operation in operations]
        self.assertEqual(positions, sorted(positions))
        for partition in (
            "aboot",
            "fsg",
            "modem",
            "modemst1",
            "modemst2",
            "persist",
            "recovery",
        ):
            self.assertNotIn(f'"flash", "{partition}"', installer)
            self.assertNotIn(f'"erase", "{partition}"', installer)
        for gpt_name in ("gpt", "partition", "primarygpt", "backupgpt"):
            self.assertNotIn(f'"flash", "{gpt_name}"', installer.lower())
            self.assertNotIn(f'"erase", "{gpt_name}"', installer.lower())

    def test_installer_uses_unambiguous_native_command_binding(self) -> None:
        installer = (PROJECT_ROOT / "scripts/install_debian_large_rootfs.ps1").read_text(
            encoding="utf-8"
        )
        self.assertNotRegex(installer, r"Invoke-Native\s+\$(?:Adb|Fastboot)\s+@\(")
        self.assertIn("Invoke-Native -Executable $Adb -CommandArgs @(", installer)
        self.assertIn("Invoke-Native -Executable $Fastboot -CommandArgs @(", installer)

    def test_build_defines_deterministic_large_rootfs_segments(self) -> None:
        build = (PROJECT_ROOT / "scripts/build_debian_cache.sh").read_text(
            encoding="utf-8"
        )
        expected = (
            'LARGE_ROOTFS_SIZE=3485240832',
            'LARGE_ROOTFS_FILESYSTEM_SIZE=3485237248',
            'ROOTFS_UUID="89090000-0000-4000-8000-000000000031"',
            'ROOTFS_HASH_SEED="89090000-0000-4000-8000-000000000032"',
            'ROOTFS_LABEL="ufi210-root"',
            'ROOTFS_DEVICE="/dev/mapper/ufi210-root"',
            'ROOTFS_AUTO_GROW=disabled',
            'ROOTFS_SYSTEM_IMAGE="$OUT_DIR/debian-${SUITE}-armhf-large-rootfs-system.img"',
            'ROOTFS_CACHE_IMAGE="$OUT_DIR/debian-${SUITE}-armhf-large-rootfs-cache.img"',
            'ROOTFS_USERDATA_IMAGE="$OUT_DIR/debian-${SUITE}-armhf-large-rootfs-userdata.img"',
            'rootfs_segments=complete-prebuilt-filesystem',
            'install -d -m 1777 "$ROOTFS/data/local/tmp"',
            "printf 'data_mount=none\\n'",
            "printf 'adbd_shell_tmpdir=/data/local/tmp\\n'",
            "printf 'adbd_shell_tmpdir_storage=rootfs\\n'",
        )
        for value in expected:
            self.assertIn(value, build)

    def test_installer_validates_private_gpt_before_writing(self) -> None:
        installer = (PROJECT_ROOT / "scripts/install_debian_large_rootfs.ps1").read_text(
            encoding="utf-8"
        )
        for value in (
            "Assert-GptBackups",
            "Get-Crc32",
            "主备 GPT 磁盘 GUID 不一致",
            "主备 GPT 分区条目不一致",
            'Start = 461920L; Last = 2978503L',
            'Start = 3044040L; Last = 3568327L',
            'Start = 3803136L; Last = 7569374L',
            'gpt_changes = "none"',
        ):
            self.assertIn(value, installer)
        self.assertEqual(installer.count("@{ Number ="), 29)
        self.assertIn(
            '@{ Number = 1; Name = "modem"; Start = 131072L; Last = 262143L }',
            installer,
        )
        self.assertIn(
            '@{ Number = 19; Name = "sec"; Start = 396352L; Last = 396383L }',
            installer,
        )

    def test_modem_time_sync_is_forward_only_and_bounded(self) -> None:
        script = (
            PROJECT_ROOT / "patches/rootfs/usr/sbin/ufi210-modem-time-sync"
        ).read_text(encoding="utf-8")
        build = (PROJECT_ROOT / "scripts/build_debian_cache.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("--dms-get-time", script)
        self.assertIn("minimum_unix_seconds=1704067200", script)
        self.assertIn("maximum_unix_seconds=2147483647", script)
        self.assertIn(
            'if [ "$modem_unix_seconds" -le $((current_unix_seconds + 5)) ]',
            script,
        )
        self.assertIn("ufi210-modem-time-sync.service", build)
        self.assertIn("qmi-dms-forward-only+systemd-timesyncd", build)

    def test_reproducible_build_resume_revalidates_first_run(self) -> None:
        script = (
            PROJECT_ROOT / "scripts/build_debian_cache_reproducibly.sh"
        ).read_text(encoding="utf-8")
        self.assertIn('RESUME_VERIFIED_A="${RESUME_VERIFIED_A:-0}"', script)
        self.assertIn('[[ -s "$RUN_A/$file" ]]', script)
        self.assertIn(
            'TARGET_PARTITION="$TARGET_PARTITION" OUT_DIR="$RUN_A" '
            'bash "$VERIFY_SCRIPT"',
            script,
        )
        self.assertIn('rm -rf -- "$RUN_B" "$BUILD_B"', script)
        runner = (
            PROJECT_ROOT / "scripts/run_debian_reproducibility_background.sh"
        ).read_text(encoding="utf-8")
        self.assertGreaterEqual(
            runner.count('RESUME_VERIFIED_A="$RESUME_VERIFIED_A"'), 2
        )

    def test_installer_validates_every_input_before_first_write(self) -> None:
        installer = (PROJECT_ROOT / "scripts/install_debian_large_rootfs.ps1").read_text(
            encoding="utf-8"
        )
        first_write = installer.index(
            'Invoke-Native -Executable $Fastboot -CommandArgs @("-s", $fastbootSerial, "erase", "system")'
        )
        for validation in (
            "Assert-GptBackups $RecoveryBackupDirectory",
            "Assert-Hash $RootfsSystemImage",
            "Assert-Hash $RootfsCacheImage",
            "Assert-Hash $RootfsUserdataImage",
            "Assert-Hash $BootImage",
            "system 根卷分段大小错误",
            "cache 根卷分段大小错误",
            "userdata 根卷分段大小错误",
            'Get-FastbootVariable $fastbootSerial "partition-size:system"',
            'Get-FastbootVariable $fastbootSerial "partition-size:cache"',
            'Get-FastbootVariable $fastbootSerial "partition-size:userdata"',
        ):
            with self.subTest(validation=validation):
                self.assertLess(installer.index(validation), first_write)

    def test_fault_injection_covers_release_blockers_without_device_access(self) -> None:
        script = (
            PROJECT_ROOT / "scripts/test_large_rootfs_installer_fail_closed.ps1"
        ).read_text(encoding="utf-8")
        for case in (
            'Invoke-ExpectedFailure "missing-gpt"',
            'Invoke-ExpectedFailure "bad-primary-gpt-result"',
            'Invoke-ExpectedFailure "bad-backup-gpt-result"',
            'Invoke-ExpectedFailure "wrong-disk-sectors-result"',
            'Invoke-ExpectedFailure "wrong-manifest-result"',
            'Invoke-ExpectedFailure "wrong-hash-result"',
            'Invoke-ExpectedFailure "truncated-result"',
            '"device_access=none"',
            '"fastboot_erase_or_flash=none"',
        ):
            self.assertIn(case, script)


if __name__ == "__main__":
    unittest.main()
