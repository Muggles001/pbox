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

# 客户端实际连接的地址：设了优选地址就用它，否则直接连隧道域名。
# 无论哪种，TLS 的域名和 Host 头都是隧道域名，Cloudflare 靠它把请求送到这条隧道。
vless_ws_addr() {
  local a
  a=$(pget vless-ws cdn_addr)
  printf '%s' "${a:-$(pget vless-ws argo_host)}"
}

# 这个节点不用服务器 IP，所以自己给出地址。隧道域名还没拿到时不输出节点。
proto_vless_ws_hosts() {
  [ -n "$(pget vless-ws argo_host)" ] || return 0
  echo "CDN|$(vless_ws_addr)"
}

proto_vless_ws_share_link() {
  local h p
  h=$(pget vless-ws argo_host)
  p=$(pget vless-ws path | sed 's#/#%2F#g')
  printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%s#%s\n' \
    "$(uget "$1" uuid)" "$(host_fmt "$2")" "$h" "$h" "$p" "$3"
}

proto_vless_ws_client_singbox() {
  local h
  h=$(pget vless-ws argo_host)
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
  h=$(pget vless-ws argo_host)
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
proto_vless_ws_selftest() {
  local d p u rc h
  h=$(pget vless-ws argo_host)
  [ -n "$h" ] || return 1
  d=$(mktemp -d) p=$(random_port tcp) u=$(users_list | head -1)
  cat >"$d/c.json" <<EOF
{"log": {"disabled": true},
 "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": $p}],
 "outbounds": [{"type": "vless", "server": "$(vless_ws_addr)", "server_port": 443, "uuid": "$(uget "$u" uuid)",
  "tls": {"enabled": true, "server_name": "$h"},
  "transport": {"type": "ws", "path": "$(pget vless-ws path)", "headers": {"Host": "$h"}}}]}
EOF
  selftest singbox "$d/c.json" "$p"
  rc=$?
  rm -rf "$d"
  return $rc
}

proto_vless_ws_doctor() {
  if ! svc active pbox-argo; then
    bad "$(t d_argo_dead)"
    hint "pbox log"
    return 1
  fi
  if [ -z "$(pget vless-ws argo_host)" ]; then
    bad "$(t d_argo_nohost)"
    hint "pbox argo-sync"
    return 1
  fi
  if proto_vless_ws_selftest; then
    ok "$(t d_self_ok Argo)"
  else
    bad "$(t d_self_bad Argo)"
    [ -n "$(pget vless-ws cdn_addr)" ] && hint "$(t d_argo_cdn_hint "$(pget vless-ws cdn_addr)")"
    return 1
  fi
}
