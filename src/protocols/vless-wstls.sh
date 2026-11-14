# VLESS-WS-TLS：伪装站上的一个隐蔽路径。浏览器打开域名看到网页，
# 只有带着这个路径发起 WebSocket 的请求才被 Nginx 转给内核。需要先开伪装站。
# 和 Argo 版的区别是不经过 Cloudflare 隧道：客户端直连自己的机器，
# 或者设了套 CDN 的子域名后，经 Cloudflare 的 CDN 再回到这台机器。
proto_vless_wstls_meta() {
  case "$1" in
    title) echo "VLESS-WS-TLS" ;;
    short) echo "WS" ;;
    core) echo singbox ;;
    l4) echo tcp ;;
    local) echo 1 ;;
    behind) echo site ;;
  esac
}

proto_vless_wstls_plan() {
  pset vless-wstls port "$(random_port tcp)" || return 1
  pset vless-wstls path "/$(rand_str "$(rand_int 8 16)")"
}

proto_vless_wstls_secrets() { :; }

proto_vless_wstls_render_inbound() {
  local u users="" sep=""
  for u in $(proto_users vless-wstls); do
    users="$users$sep{\"name\": \"$u\", \"uuid\": \"$(uget "$u" uuid)\"}"
    sep=", "
  done
  cat <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-wstls",
      "listen": "127.0.0.1",
      "listen_port": $(pget vless-wstls port),
      "users": [$users],
      "transport": {"type": "ws", "path": "$(pget vless-wstls path)"}
    }
  ]
}
EOF
}

# 输出格式：标签|客户端连接的地址|握手和 Host 里写的名字。
# 直连节点之外，设了 CDN 子域名时多一个经 CDN 的节点；再设了优选地址时多一个优选节点，
# 两者并存的好处是优选地址失效时，前一个还能用。
proto_vless_wstls_hosts() {
  local dom cdn pref
  dom=$(gget tls_domain) cdn=$(gget cdn_host) pref=$(pget vless-wstls cdn_addr)
  echo "TLS|$dom|$dom"
  [ -n "$cdn" ] || return 0
  echo "CDN|$cdn|$cdn"
  [ -n "$pref" ] && echo "CDN-Pref|$pref|$cdn"
  return 0
}

vless_wstls_name() { printf '%s' "${NODE_EXTRA:-$(gget tls_domain)}"; }

# WebSocket 只能跑在 HTTP/1.1 上，所以客户端只报 http/1.1，免得和网站协商成 HTTP/2
proto_vless_wstls_share_link() {
  local p h
  p=$(pget vless-wstls path | sed 's#/#%2F#g') h=$(vless_wstls_name)
  printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=%s&alpn=http%%2F1.1&type=ws&host=%s&path=%s#%s\n' \
    "$(uget "$1" uuid)" "$(host_fmt "$2")" "$(pubport vless-wstls)" "$h" "$(fp_of vless-wstls)" "$h" "$p" "$3"
}

proto_vless_wstls_client_singbox() {
  local h
  h=$(vless_wstls_name)
  cat <<EOF
    {
      "type": "vless",
      "tag": "$3",
      "server": "$2",
      "server_port": $(pubport vless-wstls),
      "uuid": "$(uget "$1" uuid)",
      "tls": {"enabled": true, "server_name": "$h", "alpn": ["http/1.1"], "utls": {"enabled": true, "fingerprint": "$(fp_of vless-wstls)"}},
      "transport": {"type": "ws", "path": "$(pget vless-wstls path)", "headers": {"Host": "$h"}}
    }
EOF
}

proto_vless_wstls_client_mihomo() {
  local h
  h=$(vless_wstls_name)
  cat <<EOF
  - name: "$3"
    type: vless
    server: "$2"
    port: $(pubport vless-wstls)
    uuid: "$(uget "$1" uuid)"
    network: ws
    udp: true
    tls: true
    servername: "$h"
    alpn: ["http/1.1"]
    client-fingerprint: $(fp_of vless-wstls)
    ws-opts:
      path: "$(pget vless-wstls path)"
      headers:
        Host: "$h"
EOF
}

# vless_wstls_selftest <客户端连接的地址> <握手里的名字>。直连节点从本机的 443 进去；
# 经 CDN 的节点走完整链路：本机 → Cloudflare → 本机的 443 → 内核 → 外网
vless_wstls_selftest() {
  local d p u srv rc
  d=$(mktemp -d) p=$(random_port tcp) u=$(proto_users vless-wstls | head -1) srv="$1"
  [ "$1" = "$(gget tls_domain)" ] && srv=127.0.0.1
  cat >"$d/c.json" <<EOF
{"log": {"disabled": true},
 "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": $p}],
 "outbounds": [{"type": "vless", "server": "$srv", "server_port": 443, "uuid": "$(uget "$u" uuid)",
  "tls": {"enabled": true, "server_name": "$2", "alpn": ["http/1.1"]},
  "transport": {"type": "ws", "path": "$(pget vless-wstls path)", "headers": {"Host": "$2"}}}]}
EOF
  selftest singbox "$d/c.json" "$p"
  rc=$?
  rm -rf "$d"
  return $rc
}

proto_vless_wstls_selftest() {
  local dom
  dom=$(gget tls_domain)
  vless_wstls_selftest "$dom" "$dom"
}

proto_vless_wstls_doctor() {
  local line tag rest rc=0
  proto_vless_wstls_hosts >"${TMPDIR:-/tmp}/pbox-wstls.$$"
  while IFS= read -r line; do
    tag="${line%%|*}" rest="${line#*|}"
    if vless_wstls_selftest "${rest%%|*}" "${rest#*|}"; then
      ok "$(t d_self_ok "WS-$tag")"
    else
      bad "$(t d_self_bad "WS-$tag")"
      case "$tag" in CDN-Pref) hint "$(t d_argo_cdn_hint "${rest%%|*}")" ;; esac
      rc=1
    fi
  done <"${TMPDIR:-/tmp}/pbox-wstls.$$"
  rm -f "${TMPDIR:-/tmp}/pbox-wstls.$$"
  return $rc
}
