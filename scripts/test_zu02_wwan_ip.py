#!/usr/bin/env python3
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
DISPATCHER = PROJECT_ROOT / "patches/rootfs/usr/sbin/zu02-wwan-ip"


class Zu02WwanIpTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.state_dir = Path(self.temp_dir.name) / "state"
        self.bin_dir = Path(self.temp_dir.name) / "bin"
        self.state_dir.mkdir()
        self.bin_dir.mkdir()
        self._write_command(
            "mmcli",
            r'''#!/bin/sh
set -eu
if [ "${1:-}" = '-m' ]; then
    count="$(cat "$MOCK_STATE/count" 2>/dev/null || printf '0')"
    count=$((count + 1))
    printf '%s\n' "$count" > "$MOCK_STATE/count"
    if [ "$count" -lt 3 ]; then
        printf 'modem.generic.bearers : --\n'
    elif [ "$MOCK_BEARER_FORMAT" = 'scalar' ]; then
        printf 'modem.generic.bearers : /org/freedesktop/ModemManager1/Bearer/7\n'
    else
        printf 'modem.generic.bearers.value[1] : /org/freedesktop/ModemManager1/Bearer/7\n'
    fi
    exit 0
fi
cat <<'EOF'
bearer.status.connected : yes
bearer.status.interface : wwan0
bearer.ipv4-config.address : 10.0.0.2
bearer.ipv4-config.prefix : 30
bearer.ipv4-config.gateway : 10.0.0.1
bearer.ipv4-config.mtu : 1500
bearer.ipv4-config.dns.value[1] : 1.1.1.1
EOF
''',
        )
        self._write_recorder("nmcli")
        self._write_recorder("ip")
        self._write_recorder("logger")
        self._write_recorder("sleep")

    def tearDown(self):
        self.temp_dir.cleanup()

    def _write_command(self, name, content):
        path = self.bin_dir / name
        path.write_text(content, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def _write_recorder(self, name):
        self._write_command(
            name,
            f'''#!/bin/sh
printf '%s\\n' "$*" >> "$MOCK_STATE/{name}"
''',
        )

    def _run_dispatcher(self, bearer_format, action="up"):
        env = os.environ.copy()
        env.update(
            {
                "MOCK_STATE": str(self.state_dir),
                "MOCK_BEARER_FORMAT": bearer_format,
                "PATH": f"{self.bin_dir}:/usr/bin:/bin",
            }
        )
        return subprocess.run(
            ["/bin/sh", str(DISPATCHER), "wwan0qmi0", action],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )

    def test_waits_for_scalar_and_indexed_bearer_lists(self):
        for bearer_format in ("scalar", "indexed"):
            with self.subTest(bearer_format=bearer_format):
                result = self._run_dispatcher(bearer_format)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((self.state_dir / "count").read_text().strip(), "3")
                self.assertIn(
                    "device modify wwan0qmi0 ipv4.method manual",
                    (self.state_dir / "nmcli").read_text(),
                )
                ip_calls = (self.state_dir / "ip").read_text()
                self.assertIn("address replace 10.0.0.2/30 dev wwan0", ip_calls)
                self.assertIn("route replace default via 10.0.0.1 dev wwan0 metric 700", ip_calls)
                self.assertIn(
                    "applied bearer IPv4 configuration to wwan0",
                    (self.state_dir / "logger").read_text(),
                )
                for path in self.state_dir.iterdir():
                    path.unlink()

    def test_down_clears_managed_network_state(self):
        result = self._run_dispatcher("scalar", action="down")
        self.assertEqual(result.returncode, 0, result.stderr)
        ip_calls = (self.state_dir / "ip").read_text()
        self.assertIn("route del default dev wwan0 metric 700", ip_calls)
        self.assertIn("address flush dev wwan0 scope global", ip_calls)
        self.assertFalse((self.state_dir / "count").exists())


if __name__ == "__main__":
    unittest.main()
