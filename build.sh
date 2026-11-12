#!/usr/bin/env bash
# 把 src/ 下的模块按固定顺序合并成一个明文单文件 dist/pbox.sh。只做拼接，不压缩、不混淆。
set -euo pipefail
cd "$(dirname "$0")"

parts="
src/header.sh
src/i18n/zh.sh
src/i18n/en.sh
src/lib/ui.sh
src/lib/sys.sh
src/lib/net.sh
src/lib/state.sh
src/lib/cert.sh
src/lib/reality.sh
src/cores/core.sh
src/protocols/reality-vision.sh
src/protocols/hysteria2.sh
src/protocols/vless-ws.sh
src/protocols/tuic.sh
src/protocols/anytls.sh
src/lib/conflict.sh
src/lib/render.sh
src/lib/firewall.sh
src/lib/hop.sh
src/lib/warp.sh
src/lib/argo.sh
src/lib/nodes.sh
src/lib/sub.sh
src/lib/users.sh
src/lib/doctor.sh
src/lib/backup.sh
src/lib/update.sh
src/cmd.sh
src/menu.sh
src/main.sh
"

mkdir -p dist
{
  echo '#!/usr/bin/env bash'
  echo '# pbox：在自己的 VPS 上安装和管理代理节点。明文、单文件、可审计。'
  echo '# 本文件由 build.sh 从 src/ 合并生成，修改请改 src/ 下的源文件。'
  for f in $parts; do
    printf '\n# ---- %s ----\n' "$f"
    cat "$f"
  done
} >dist/pbox.sh
chmod +x dist/pbox.sh
bash -n dist/pbox.sh

if command -v sha256sum >/dev/null 2>&1; then
  (cd dist && sha256sum pbox.sh >pbox.sh.sha256)
else
  (cd dist && shasum -a 256 pbox.sh >pbox.sh.sha256)
fi
echo "dist/pbox.sh  $(wc -l <dist/pbox.sh | tr -d ' ') 行"
