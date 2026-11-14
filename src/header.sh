set -o pipefail
umask 027

PBOX_VERSION="0.11.0"
# 发布仓库（owner/name）。检查更新和在线更新都从这里取。
PBOX_REPO="${PBOX_REPO:-Muggles001/pbox}"

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

ACME_VERSION="3.1.6"
ACME_SHA256="c7d68b021cfd6380ea83a82962abde5b484779fee0b97d38681dfa1396bbc8d7"
ACME_DNS_CF_SHA256="9628ee8238cb3f9cfa1b1a985c0e9593436a3e4f8a9d65a6f775b981be9e76c8"
CLOUDFLARED_VERSION="2026.10.7"
CLOUDFLARED_SHA256_amd64="1f99fb518b83dec2ba8d870a7cc991d82a77e6196295a3d2754ba17ab9f91872"
CLOUDFLARED_SHA256_arm64="3df43aedc9ff291d1735b5cb576cb97e0b157488796db2e32b28aecabb445775"

PROTO_ALL="reality-vision hysteria2 vless-ws tuic anytls trojan vless-wstls reality-xhttp shadowtls ss2022 socks"
PRESET_RECOMMENDED="reality-vision hysteria2"
