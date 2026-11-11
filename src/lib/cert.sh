# cert_selfsigned <名称> <域名>：生成 certs/<名称>.key 与 .crt。有效期在范围内随机。
cert_selfsigned() {
  local n="$1" cn="$2" days
  days=$(rand_int 3000 3650)
  mkdir -p "$CERTS"
  openssl ecparam -genkey -name prime256v1 -noout -out "$CERTS/$n.key" 2>/dev/null || return 1
  openssl req -new -x509 -key "$CERTS/$n.key" -out "$CERTS/$n.crt" -days "$days" \
    -subj "/CN=$cn" -addext "subjectAltName=DNS:$cn" 2>/dev/null || return 1
}

# 整张证书的 SHA-256，小写十六进制。Mihomo 与 hysteria2 链接的 pinSHA256 用它。
cert_sha256() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f'
}

# 证书公钥的 SHA-256，Base64。sing-box 客户端的 certificate_public_key_sha256 用它。
cert_spki() {
  openssl x509 -in "$1" -pubkey -noout | openssl pkey -pubin -outform der 2>/dev/null |
    openssl dgst -sha256 -binary | openssl base64
}

cert_valid_days() { # <证书> <天数>：剩余有效期是否多于给定天数
  openssl x509 -in "$1" -noout -checkend $(($2 * 86400)) >/dev/null 2>&1
}
