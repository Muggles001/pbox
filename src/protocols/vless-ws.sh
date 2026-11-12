# VLESS-WS，经由 Cloudflare 的 Argo 隧道对外提供。
# 内核只监听本机；cloudflared 主动连到 Cloudflare，把隧道域名上的请求转给它。
# 所以这个节点不需要域名、不需要开放任何端口，NAT 机器和 IP 被墙的机器也能用。
proto_vless_ws_meta() {
  case "$1" in
    title) echo "VLESS-WS-Argo" ;;
    short) echo "Argo" ;;
    core) echo singbox ;;
    l4) echo tcp ;;
    # 只监听本机：不需要放行防火墙，NAT 机器上也不需要外网端口
    local) echo 1 ;;
  esac
}

proto_vless_ws_plan() {
  pset vless-ws port "$(random_port tcp)" || return 1
  pset vless-ws metrics_port "$(random_port tcp)"
  # 路径长度也随机
  pset vless-ws path "/$(rand_str "$(rand_int 8 16)")"
}

proto_vless_ws_secrets() { :; }

proto_vless_ws_render_inbound() {
  local u users="" sep=""
  for u in $(users_list); do
    users="$users$sep{\"name\": \"$u\", \"uuid\": \"$(uget "$u" uuid)\"}"
    sep=", "
  done
  cat <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "listen_port": $(pget vless-ws port),
      "users": [$users],
      "transport": {"type": "ws", "path": "$(pget vless-ws path)"}
    }
  ]
}
EOF
}

# 一条隧道对应一个域名。临时隧道和固定隧道可以同时存在。
# 每条隧道输出一个直连隧道域名的节点；设了优选地址时再多输出一个优选节点。
# 两者并存的好处是：优选地址失效时，直连的那个还能用。
# 输出格式：标签|客户端连接的地址|隧道域名
proto_vless_ws_hosts() {
  local h cdn tag
  cdn=$(pget vless-ws cdn_addr)
  for tag in Temp Fixed; do
    case "$tag" in
      Temp) [ "$(pget vless-ws temp on)" = on ] && h=$(pget vless-ws argo_host) || h="" ;;
      Fixed) h=$(pget vless-ws fixed_host) ;;
    esac
    [ -n "$h" ] || continue
    echo "$tag|$h|$h"
    [ -n "$cdn" ] && echo "$tag-Pref|$cdn|$h"
  done
  return 0
}

# 当前这个节点对应的隧道域名。TLS 的域名和 Host 头都用它，Cloudflare 靠它把请求送到正确的隧道。
vless_ws_tunnel() { printf '%s' "${NODE_EXTRA:-$(pget vless-ws argo_host)}"; }

proto_vless_ws_share_link() {
  local h p
  h=$(vless_ws_tunnel)
  p=$(pget vless-ws path | sed 's#/#%2F#g')
  printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%s#%s\n' \
    "$(uget "$1" uuid)" "$(host_fmt "$2")" "$h" "$h" "$p" "$3"
}

proto_vless_ws_client_singbox() {
  local h
  h=$(vless_ws_tunnel)
  cat <<EOF
    {
      "type": "vless",
      "tag": "$3",
      "server": "$2",
      "server_port": 443,
      "uuid": "$(uget "$1" uuid)",
      "tls": {"enabled": true, "server_name": "$h", "utls": {"enabled": true, "fingerprint": "chrome"}},
      "transport": {"type": "ws", "path": "$(pget vless-ws path)", "headers": {"Host": "$h"}}
    }
EOF
}

proto_vless_ws_client_mihomo() {
  local h
  h=$(vless_ws_tunnel)
  cat <<EOF
  - name: "$3"
    type: vless
    server: "$2"
    port: 443
    uuid: "$(uget "$1" uuid)"
    network: ws
    udp: true
    tls: true
    servername: "$h"
    client-fingerprint: chrome
    ws-opts:
      path: "$(pget vless-ws path)"
      headers:
        Host: "$h"
EOF
}

# 自测走的是完整链路：本机 → Cloudflare → 隧道 → 本机内核 → 外网
# vless_ws_selftest <客户端连接的地址> <隧道域名>
vless_ws_selftest() {
  local d p u rc
  d=$(mktemp -d) p=$(random_port tcp) u=$(users_list | head -1)
  cat >"$d/c.json" <<EOF
{"log": {"disabled": true},
 "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": $p}],
 "outbounds": [{"type": "vless", "server": "$1", "server_port": 443, "uuid": "$(uget "$u" uuid)",
  "tls": {"enabled": true, "server_name": "$2"},
  "transport": {"type": "ws", "path": "$(pget vless-ws path)", "headers": {"Host": "$2"}}}]}
EOF
  selftest singbox "$d/c.json" "$p"
  rc=$?
  rm -rf "$d"
  return $rc
}

# 供 WARP 验证等处调用：取第一个可用的节点
proto_vless_ws_selftest() {
  local line rest
  line=$(proto_vless_ws_hosts | head -1)
  [ -n "$line" ] || return 1
  rest="${line#*|}"
  vless_ws_selftest "${rest%%|*}" "${rest#*|}"
}

# 逐个节点自测，所以临时、固定、各自的优选都会被分别验证
proto_vless_ws_doctor() {
  local line tag rest rc=0 n=0
  if [ "$(pget vless-ws temp on)" = on ] && ! svc active pbox-argo; then
    bad "$(t d_argo_dead)"
    rc=1
  fi
  if [ -f "$STATE/argo-fixed.env" ] && ! svc active pbox-argo-fixed; then
    bad "$(t d_argo_fixed_dead)"
    rc=1
  fi
  proto_vless_ws_hosts >"${TMPDIR:-/tmp}/pbox-hosts.$$"
  while IFS= read -r line; do
    n=$((n + 1))
    tag="${line%%|*}" rest="${line#*|}"
    if vless_ws_selftest "${rest%%|*}" "${rest#*|}"; then
      ok "$(t d_self_ok "Argo-$tag")"
    else
      bad "$(t d_self_bad "Argo-$tag")"
      case "$tag" in *-Pref) hint "$(t d_argo_cdn_hint "${rest%%|*}")" ;; esac
      rc=1
    fi
  done <"${TMPDIR:-/tmp}/pbox-hosts.$$"
  rm -f "${TMPDIR:-/tmp}/pbox-hosts.$$"
  if [ "$n" = 0 ]; then
    bad "$(t d_argo_nohost)"
    hint "pbox argo-sync"
    rc=1
  fi
  return $rc
}
