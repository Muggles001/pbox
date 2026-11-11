set -o pipefail
umask 027

PBOX_VERSION="0.1.0"
# 发布仓库（owner/name）。未发布前为空，此时不检查更新。
PBOX_REPO="${PBOX_REPO:-}"

# PBOX_ROOT 只用于测试：把所有路径挪到一个临时目录下。
R="${PBOX_ROOT:-}"
ETC="$R/etc/pbox"
STATE="$ETC/state"
GEN="$ETC/generated"
PREV="$ETC/previous"
CUSTOM="$ETC/custom"
CERTS="$ETC/certs"
NODES="$ETC/nodes"
MANIFEST="$ETC/manifest"
LIBDIR="$R/usr/local/lib/pbox"
BINDIR="$LIBDIR/bin"
ENTRY="$R/usr/local/bin/pbox"
LOGDIR="$R/var/log/pbox"
VARDIR="$R/var/lib/pbox"
LOCKDIR="$R/run/pbox.lock"
RUN_USER="pbox"

ASSUME_YES=0
DRY_RUN=0
LOCKED=0
# 当前读写的状态目录。事务进行中指向临时副本，提交后才指回 $STATE。
CUR="$STATE"

# 锁定的组件版本与哈希。升级内核 = 发布新版脚本，不提供"追最新"。
XRAY_VERSION="v26.11.9"
XRAY_SHA256_amd64="b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82"
XRAY_SHA256_arm64="64ed6858982a7f5eb85d88b811089063bd4f17561f4c8f44e0f1dc8e6f6430be"
SINGBOX_VERSION="1.14.4"
SINGBOX_SHA256_amd64="699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968"
SINGBOX_SHA256_arm64="436441f76ee2f7fe21b5b2d426d3cb261a480455a704865789ad533e4273ec26"
# Alpine 用 musl 而不是 glibc，sing-box 的普通构建在上面无法运行，要用它单独提供的 musl 构建
SINGBOX_SHA256_amd64_musl="8f7c5f0651238850d96a0e488e5473cd77ec1a0098f63942e943f475a12057ca"
SINGBOX_SHA256_arm64_musl="b95e25f921dc5e17a4cf13327243d1177642c7e35425bf5372862c477c359f56"

PROTO_ALL="reality-vision hysteria2"
PRESET_RECOMMENDED="reality-vision hysteria2"
