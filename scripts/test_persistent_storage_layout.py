#!/usr/bin/env python3

from pathlib import Path
import unittest


PROJECT_ROOT = Path(__file__).resolve().parent.parent


class PersistentStorageLayoutTests(unittest.TestCase):
    def test_installer_requires_explicit_userdata_erasure(self) -> None:
        installer = (PROJECT_ROOT / "scripts/install_debian_system.ps1").read_text(
            encoding="utf-8"
        )
        batch = (PROJECT_ROOT / "install.bat").read_text(encoding="utf-8")
        self.assertIn("[switch]$ConfirmEraseUserdata", installer)
        self.assertIn("if (-not $ConfirmEraseUserdata)", installer)
        self.assertIn("-ConfirmEraseUserdata", batch)

    def test_installer_flashes_boot_last_without_touching_sensitive_partitions(self) -> None:
        installer = (PROJECT_ROOT / "scripts/install_debian_system.ps1").read_text(
            encoding="utf-8"
        )
        operations = (
            '("-s", $fastbootSerial, "flash", "system", $RootfsImage)',
            '("-s", $fastbootSerial, "erase", "userdata")',
            '("-s", $fastbootSerial, "flash", "userdata", $DataImage)',
            '("-s", $fastbootSerial, "flash", "boot", $BootImage)',
        )
        positions = [installer.index(operation) for operation in operations]
        self.assertEqual(positions, sorted(positions))
        for partition in (
            "aboot",
            "cache",
            "fsg",
            "modem",
            "modemst1",
            "modemst2",
            "persist",
            "recovery",
        ):
            self.assertNotIn(f'"flash", "{partition}"', installer)
            self.assertNotIn(f'"erase", "{partition}"', installer)

    def test_installer_uses_unambiguous_native_command_binding(self) -> None:
        installer = (PROJECT_ROOT / "scripts/install_debian_system.ps1").read_text(
            encoding="utf-8"
        )
        self.assertNotRegex(installer, r"Invoke-Native\s+\$(?:Adb|Fastboot)\s+@\(")
        self.assertIn("Invoke-Native -Executable $Adb -CommandArgs @(", installer)
        self.assertIn("Invoke-Native -Executable $Fastboot -CommandArgs @(", installer)

    def test_build_defines_deterministic_userdata_filesystem(self) -> None:
        build = (PROJECT_ROOT / "scripts/build_debian_cache.sh").read_text(
            encoding="utf-8"
        )
        expected = (
            'DATA_PARTITION_SIZE=1928314368',
            'DATA_FILESYSTEM_SIZE=1928310784',
            'DATA_UUID="89090000-0000-4000-8000-000000000029"',
            'DATA_HASH_SEED="89090000-0000-4000-8000-000000000030"',
            'DATA_LABEL="ufi210-data"',
            "PARTLABEL=userdata /data ext4 defaults,noatime,nosuid,nodev,nofail,"
            "x-systemd.growfs,x-systemd.device-timeout=30s 0 2",
        )
        for value in expected:
            self.assertIn(value, build)

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


if __name__ == "__main__":
    unittest.main()
