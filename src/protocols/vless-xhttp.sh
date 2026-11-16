# VLESS-XHTTP-TLS：伪装站上的又一个隐蔽路径，传输是 XHTTP：上传和下载拆成普通的网页请求，
# 比 WebSocket 更像正常浏览，也能套 CDN。需要先开伪装站。
# XHTTP 只有 Xray 实现，所以由 Xray 承载，也只有通用链接（给 v2rayN、v2rayNG 这类客户端）。
proto_vless_xhttp_meta() {
  case "$1" in
    title) echo "VLESS-XHTTP-TLS" ;;
    short) echo "XHTTP" ;;
    core) echo xray ;;
    l4) echo tcp ;;
    local) echo 1 ;;
    behind) echo site ;;
    link_only) echo 1 ;;
    note) echo note_xhttp_clients ;;
  esac
}

proto_vless_xhttp_plan() { wstls_plan vless-xhttp; }

proto_vless_xhttp_secrets() { :; }

proto_vless_xhttp_render_inbound() {
  local u users="" sep=""
  for u in $(proto_users vless-xhttp); do
    users="$users$sep{\"id\": \"$(uget "$u" uuid)\", \"email\": \"$u\"}"
    sep=", "
  done
  cat <<EOF
{
  "inbounds": [
    {
      "tag": "vless-xhttp",
      "listen": "127.0.0.1",
      "port": $(pget vless-xhttp port),
      "protocol": "vless",
      "settings": {"clients": [$users], "decryption": "none"},$(xray_sniffing)
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {"path": "$(pget vless-xhttp path)"}
      }
    }
  ]
}
EOF
}

proto_vless_xhttp_hosts() { wstls_hosts vless-xhttp; }

# 自己的域名前面有 Trojan 时，握手由它完成，它只协商 HTTP/1.1；
# 经 CDN 的连接不过 Trojan，直接到网站，用 HTTP/2
vless_xhttp_alpn() { # <握手里的名字>
  if proto_enabled trojan && [ "$1" = "$(gget tls_domain)" ]; then echo http/1.1; else echo h2; fi
}

proto_vless_xhttp_share_link() {
  local h
  h=$(wstls_name)
  printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=%s&alpn=%s&type=xhttp&host=%s&path=%s&mode=auto#%s\n' \
    "$(uget "$1" uuid)" "$(host_fmt "$2")" "$(pubport vless-xhttp)" "$h" "$(fp_of vless-xhttp)" \
    "$(vless_xhttp_alpn "$h" | sed 's#/#%2F#g')" "$h" "$(pget vless-xhttp path | sed 's#/#%2F#g')" "$3"
}

proto_vless_xhttp_client_singbox() { :; }
proto_vless_xhttp_client_mihomo() { :; }

# 只能用 Xray 自己当客户端。<客户端连接的地址> <握手里的名字>
vless_xhttp_selftest() {
  local d p u rc
  d=$(mktemp -d) p=$(random_port tcp) u=$(proto_users vless-xhttp | head -1)
  cat >"$d/c.json" <<EOF
{"log": {"loglevel": "none"},
 "inbounds": [{"listen": "127.0.0.1", "port": $p, "protocol": "socks", "settings": {"udp": false}}],
 "outbounds": [{"protocol": "vless",
  "settings": {"address": "$1", "port": 443, "id": "$(uget "$u" uuid)", "encryption": "none"},
  "streamSettings": {"network": "xhttp", "xhttpSettings": {"path": "$(pget vless-xhttp path)", "host": "$2"}, "security": "tls",
   "tlsSettings": {"serverName": "$2", "fingerprint": "chrome", "alpn": ["$(vless_xhttp_alpn "$2")"]}}}]}
EOF
  selftest xray "$d/c.json" "$p"
  rc=$?
  rm -rf "$d"
  return $rc
}

proto_vless_xhttp_selftest() { wstls_selftest vless-xhttp "$(gget tls_domain)" "$(gget tls_domain)"; }

proto_vless_xhttp_doctor() { wstls_doctor vless-xhttp; }
