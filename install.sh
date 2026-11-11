#!/usr/bin/env bash
# 引导脚本：取回已发布的 pbox.sh，核对同一发布里公布的哈希，然后交给它完成安装。
# 发布前请把 PBOX_REPO 改成实际的仓库（owner/name）。
set -euo pipefail

PBOX_REPO="${PBOX_REPO:-}"
[ -n "$PBOX_REPO" ] || { echo "PBOX_REPO is not set: this build has no release location yet." >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "Please run as root (sudo -i)." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required." >&2; exit 1; }

base="https://github.com/$PBOX_REPO/releases/latest/download"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/pbox.sh" "$base/pbox.sh"
curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/pbox.sh.sha256" "$base/pbox.sh.sha256"

want=$(awk '{print $1}' "$tmp/pbox.sh.sha256")
if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$tmp/pbox.sh" | awk '{print $1}'); else got=$(shasum -a 256 "$tmp/pbox.sh" | awk '{print $1}'); fi
[ "$want" = "$got" ] || { echo "Checksum mismatch; refusing to run." >&2; exit 1; }

PBOX_REPO="$PBOX_REPO" bash "$tmp/pbox.sh" install "$@"
