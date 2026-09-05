#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C.UTF-8

KEYRING_VERSION="2023.3+deb12u2"
KEYRING_PACKAGE="debian-archive-keyring_${KEYRING_VERSION}_all.deb"
KEYRING_URL="${DEBIAN_KEYRING_URL:-https://deb.debian.org/debian/pool/main/d/debian-archive-keyring/$KEYRING_PACKAGE}"
KEYRING_SHA256="f699e2f88dca05212f2a452b58475f2993cb6993dfbafb1d0205a3291eb8b4b8"
KEYRING_PATH="/usr/share/keyrings/debian-archive-keyring.gpg"

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

(( EUID == 0 )) || die "必须以 root 身份安装 Debian archive keyring"
for command_name in curl dpkg dpkg-query mktemp sha256sum; do
    command -v "$command_name" >/dev/null 2>&1 || die "缺少命令：$command_name"
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
deb="$tmp_dir/$KEYRING_PACKAGE"

printf '下载 Debian archive keyring %s\n' "$KEYRING_VERSION"
curl --fail --location --retry 3 --output "$deb" "$KEYRING_URL"
printf '%s  %s\n' "$KEYRING_SHA256" "$deb" | sha256sum --check --strict
dpkg --install "$deb"

[[ -s "$KEYRING_PATH" ]] || die "安装完成后仍缺少 keyring：$KEYRING_PATH"
installed_version="$(dpkg-query -W -f='${Version}' debian-archive-keyring)"
installed_sha256="$(sha256sum "$KEYRING_PATH" | awk '{print $1}')"
printf '已安装 debian-archive-keyring=%s\n' "$installed_version"
printf '%s SHA256=%s\n' "$KEYRING_PATH" "$installed_sha256"
