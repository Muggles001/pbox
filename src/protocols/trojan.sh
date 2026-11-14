# Trojan：用自己域名的真实证书，外表就是一个普通的 HTTPS 网站。
# 放在 443 分流后面：握手里是自己域名的连接先交给它，密码对得上就是代理，
# 对不上（浏览器、扫描器）就原样转给伪装站，看到的是网页。所以它需要先开伪装站。
proto_trojan_meta() {
  case "$1" in
    title) echo "Trojan" ;;
    short) echo "Trojan" ;;
    core) echo singbox ;;
    l4) echo tcp ;;
    local) echo 1 ;;
    behind) echo site ;;
  esac
}

proto_trojan_plan() {
  local p
  p=$(random_port tcp) || return 1
  pset trojan port "$p"
  # 伪装站在 Trojan 后面时，要一个不加密的入口接它转过来的连接
  [ -n "$(gget site_plain_port)" ] && return 0
  p=$(random_port tcp) || return 1
  gset site_plain_port "$p"
}

proto_trojan_secrets() { :; }

# 只协商 HTTP/1.1：转给伪装站的是解密后的原始字节，那一侧是不加密的 HTTP/1.1
proto_trojan_render_inbound() {
  local u users="" sep="" certs="${CERTS#"$R"}"
  for u in $(proto_users trojan); do
    users="$users$sep{\"name\": \"$u\", \"password\": \"$(uget "$u" password)\"}"
    sep=", "
  done
  cat <<EOF
{
  "inbounds": [
    {
      "type": "trojan",
      "tag": "trojan",
      "listen": "127.0.0.1",
      "listen_port": $(pget trojan port),
      "users": [$users],
      "tls": {
        "enabled": true,
        "server_name": "$(gget tls_domain)",
        "alpn": ["http/1.1"],
        "certificate_path": "$certs/domain.crt",
        "key_path": "$certs/domain.key"
      },
      "fallback": {"server": "127.0.0.1", "server_port": $(gget site_plain_port)}
    }
  ]
}
EOF
}

proto_trojan_hosts() { echo "TLS|$(gget tls_domain)"; }

proto_trojan_share_link() {
  printf 'trojan://%s@%s:%s?security=tls&sni=%s&fp=%s&type=tcp#%s\n' \
    "$(uget "$1" password)" "$(host_fmt "$2")" "$(pubport trojan)" "$(gget tls_domain)" "$(fp_of trojan)" "$3"
}

proto_trojan_client_singbox() {
  cat <<EOF
    {
      "type": "trojan",
      "tag": "$3",
      "server": "$2",
      "server_port": $(pubport trojan),
      "password": "$(uget "$1" password)",
      "tls": {"enabled": true, "server_name": "$(gget tls_domain)", "utls": {"enabled": true, "fingerprint": "$(fp_of trojan)"}}
    }
EOF
}

proto_trojan_client_mihomo() {
  cat <<EOF
  - name: "$3"
    type: trojan
    server: "$2"
    port: $(pubport trojan)
    password: "$(uget "$1" password)"
    udp: true
    sni: "$(gget tls_domain)"
    client-fingerprint: $(fp_of trojan)
EOF
}

# 自测从本机的 443 进去，经过分流再到 Trojan，和客户端走的路一样
proto_trojan_selftest() { selftest_client trojan; }

proto_trojan_doctor() { doctor_selftest trojan; }
