# VMess-WS-TLS：和 VLESS-WS-TLS 一样是伪装站上的一个隐蔽路径，可以直连，也可以套 CDN。
# 保留它是为了不支持 VLESS 的老客户端，新客户端用 VLESS-WS-TLS 就好。需要先开伪装站。
# 外面已经有一层 TLS，VMess 自己的加密只是多余的开销，所以用 alterId 0、加密方式 auto。
proto_vmess_meta() {
  case "$1" in
    title) echo "VMess-WS-TLS" ;;
    short) echo "VMess" ;;
    core) echo singbox ;;
    l4) echo tcp ;;
    local) echo 1 ;;
    behind) echo site ;;
  esac
}

proto_vmess_plan() { wstls_plan vmess vless-wstls; }

proto_vmess_secrets() { :; }

proto_vmess_render_inbound() {
  local u users="" sep=""
  for u in $(proto_users vmess); do
    users="$users$sep{\"name\": \"$u\", \"uuid\": \"$(uget "$u" uuid)\", \"alterId\": 0}"
    sep=", "
  done
  cat <<EOF
{
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess",
      "listen": "127.0.0.1",
      "listen_port": $(pget vmess port),
      "users": [$users],
      "transport": {"type": "ws", "path": "$(pget vmess path)"}
    }
  ]
}
EOF
}

proto_vmess_hosts() { wstls_hosts vmess; }

# v2rayN 的写法：一段 JSON 整体 base64
proto_vmess_share_link() {
  local h j
  h=$(wstls_name)
  j=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s","alpn":"http/1.1","fp":"%s"}' \
    "$3" "$2" "$(pubport vmess)" "$(uget "$1" uuid)" "$h" "$(pget vmess path)" "$h" "$(fp_of vmess)")
  printf 'vmess://%s\n' "$(printf '%s' "$j" | openssl base64 -A)"
}

proto_vmess_client_singbox() {
  local h
  h=$(wstls_name)
  cat <<EOF
    {
      "type": "vmess",
      "tag": "$3",
      "server": "$2",
      "server_port": $(pubport vmess),
      "uuid": "$(uget "$1" uuid)",
      "security": "auto",
      "alter_id": 0,
      "tls": {"enabled": true, "server_name": "$h", "alpn": ["http/1.1"], "utls": {"enabled": true, "fingerprint": "$(fp_of vmess)"}},
      "transport": {"type": "ws", "path": "$(pget vmess path)", "headers": {"Host": "$h"}}
    }
EOF
}

proto_vmess_client_mihomo() {
  local h
  h=$(wstls_name)
  cat <<EOF
  - name: "$3"
    type: vmess
    server: "$2"
    port: $(pubport vmess)
    uuid: "$(uget "$1" uuid)"
    alterId: 0
    cipher: auto
    network: ws
    udp: true
    tls: true
    servername: "$h"
    alpn: ["http/1.1"]
    client-fingerprint: $(fp_of vmess)
    ws-opts:
      path: "$(pget vmess path)"
      headers:
        Host: "$h"
EOF
}

proto_vmess_selftest() { wstls_selftest vmess "$(gget tls_domain)" "$(gget tls_domain)"; }

proto_vmess_doctor() { wstls_doctor vmess; }
