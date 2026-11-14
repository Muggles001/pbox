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

proto_vless_wstls_plan() { wstls_plan vless-wstls vmess; }

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

# 以下 wstls_* 由伪装站上的两个 WS 协议（VLESS-WS-TLS、VMess-WS-TLS）共用。
#
# 输出格式：标签|客户端连接的地址|握手和 Host 里写的名字。
# 直连节点之外，设了 CDN 子域名时多一个经 CDN 的节点；再设了优选地址时多一个优选节点，
# 两者并存的好处是优选地址失效时，前一个还能用。
wstls_hosts() { # <协议>
  local dom cdn pref
  dom=$(gget tls_domain) cdn=$(gget cdn_host) pref=$(pget "$1" cdn_addr)
  echo "TLS|$dom|$dom"
  [ -n "$cdn" ] || return 0
  echo "CDN|$cdn|$cdn"
  [ -n "$pref" ] && echo "CDN-Pref|$pref|$cdn"
  return 0
}

wstls_name() { printf '%s' "${NODE_EXTRA:-$(gget tls_domain)}"; }

# wstls_selftest <协议> <客户端连接的地址> <握手里的名字>。直连节点从本机的 443 进去；
# 经 CDN 的节点走完整链路：本机 → Cloudflare → 本机的 443 → 内核 → 外网。
# 出站就用给客户端的那份配置，只把地址换掉
wstls_selftest() {
  local d p u srv rc
  d=$(mktemp -d) p=$(random_port tcp) u=$(proto_users "$1" | head -1) srv="$2"
  [ "$2" = "$(gget tls_domain)" ] && srv=127.0.0.1
  cat >"$d/c.json" <<EOF
{"log": {"disabled": true},
 "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": $p}],
 "outbounds": [$(NODE_EXTRA="$3" NODE_VIA="" pcall "$1" client_singbox "$u" "$srv" selftest)]}
EOF
  selftest singbox "$d/c.json" "$p"
  rc=$?
  rm -rf "$d"
  return $rc
}

wstls_doctor() { # <协议>
  local line tag rest rc=0 short f
  short=$(pmeta "$1" short) f="${TMPDIR:-/tmp}/pbox-wstls.$$"
  wstls_hosts "$1" >"$f"
  while IFS= read -r line; do
    tag="${line%%|*}" rest="${line#*|}"
    if wstls_selftest "$1" "${rest%%|*}" "${rest#*|}"; then
      ok "$(t d_self_ok "$short-$tag")"
    else
      bad "$(t d_self_bad "$short-$tag")"
      case "$tag" in CDN-Pref) hint "$(t d_argo_cdn_hint "${rest%%|*}")" ;; esac
      rc=1
    fi
  done <"$f"
  rm -f "$f"
  return $rc
}

# 内部端口和路径随机；沿用另一个 WS 协议已设的优选地址，不必再设一遍
wstls_plan() { # <协议> <另一个协议>
  local p
  p=$(random_port tcp) || return 1
  pset "$1" port "$p"
  pset "$1" path "/$(rand_str "$(rand_int 8 16)")"
  [ -n "$(gget cdn_host)" ] && pset "$1" cdn_addr "$(pget "$2" cdn_addr)"
  return 0
}

proto_vless_wstls_hosts() { wstls_hosts vless-wstls; }

# WebSocket 只能跑在 HTTP/1.1 上，所以客户端只报 http/1.1，免得和网站协商成 HTTP/2
proto_vless_wstls_share_link() {
  local p h
  p=$(pget vless-wstls path | sed 's#/#%2F#g') h=$(wstls_name)
  printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=%s&alpn=http%%2F1.1&type=ws&host=%s&path=%s#%s\n' \
    "$(uget "$1" uuid)" "$(host_fmt "$2")" "$(pubport vless-wstls)" "$h" "$(fp_of vless-wstls)" "$h" "$p" "$3"
}

proto_vless_wstls_client_singbox() {
  local h
  h=$(wstls_name)
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
  h=$(wstls_name)
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

proto_vless_wstls_selftest() { wstls_selftest vless-wstls "$(gget tls_domain)" "$(gget tls_domain)"; }

proto_vless_wstls_doctor() { wstls_doctor vless-wstls; }
