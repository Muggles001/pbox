# VLESS-WS-TLS：伪装站上的一个隐蔽路径。浏览器打开域名看到网页，
# 只有带着这个路径发起 WebSocket 的请求才被 Nginx 转给内核。需要先开伪装站。
# 和 Argo 版的区别是不经过 Cloudflare 隧道，客户端直连自己的机器。
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

proto_vless_wstls_hosts() { echo "TLS|$(gget tls_domain)"; }

# WebSocket 只能跑在 HTTP/1.1 上，所以客户端只报 http/1.1，免得和网站协商成 HTTP/2
proto_vless_wstls_share_link() {
  local p
  p=$(pget vless-wstls path | sed 's#/#%2F#g')
  printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=%s&alpn=http%%2F1.1&type=ws&host=%s&path=%s#%s\n' \
    "$(uget "$1" uuid)" "$2" "$2" "$(fp_of vless-wstls)" "$2" "$p" "$3"
}

proto_vless_wstls_client_singbox() {
  cat <<EOF
    {
      "type": "vless",
      "tag": "$3",
      "server": "$2",
      "server_port": 443,
      "uuid": "$(uget "$1" uuid)",
      "tls": {"enabled": true, "server_name": "$2", "alpn": ["http/1.1"], "utls": {"enabled": true, "fingerprint": "$(fp_of vless-wstls)"}},
      "transport": {"type": "ws", "path": "$(pget vless-wstls path)", "headers": {"Host": "$2"}}
    }
EOF
}

proto_vless_wstls_client_mihomo() {
  cat <<EOF
  - name: "$3"
    type: vless
    server: "$2"
    port: 443
    uuid: "$(uget "$1" uuid)"
    network: ws
    udp: true
    tls: true
    servername: "$2"
    alpn: ["http/1.1"]
    client-fingerprint: $(fp_of vless-wstls)
    ws-opts:
      path: "$(pget vless-wstls path)"
      headers:
        Host: "$2"
EOF
}

proto_vless_wstls_selftest() {
  local d p u dom rc
  d=$(mktemp -d) p=$(random_port tcp) u=$(proto_users vless-wstls | head -1) dom=$(gget tls_domain)
  cat >"$d/c.json" <<EOF
{"log": {"disabled": true},
 "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": $p}],
 "outbounds": [{"type": "vless", "server": "127.0.0.1", "server_port": 443, "uuid": "$(uget "$u" uuid)",
  "tls": {"enabled": true, "server_name": "$dom", "alpn": ["http/1.1"]},
  "transport": {"type": "ws", "path": "$(pget vless-wstls path)", "headers": {"Host": "$dom"}}}]}
EOF
  selftest singbox "$d/c.json" "$p"
  rc=$?
  rm -rf "$d"
  return $rc
}

proto_vless_wstls_doctor() {
  if proto_vless_wstls_selftest; then
    ok "$(t d_self_ok VLESS-WS-TLS)"
  else
    bad "$(t d_self_bad VLESS-WS-TLS)"
    return 1
  fi
}
