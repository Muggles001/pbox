# VLESS-XHTTP-TLS：伪装站上的又一个隐蔽路径，传输是 XHTTP：上传和下载拆成普通的网页请求，
# 比 WebSocket 更像正常浏览，也能套 CDN。需要先开伪装站。
# 服务端由 Xray 承载。客户端有通用链接（v2rayN、v2rayNG）和 Clash（Mihomo v1.19.22 起支持）；sing-box 没有 XHTTP。
proto_vless_xhttp_meta() {
  case "$1" in
    title) echo "VLESS-XHTTP-TLS" ;;
    short) echo "XHTTP" ;;
    core) echo xray ;;
    l4) echo tcp ;;
    local) echo 1 ;;
    behind) echo site ;;
    no_singbox) echo 1 ;;
    note) echo note_vless_xhttp_clients ;;
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

proto_vless_xhttp_hosts() {
  local cdn pref
  wstls_hosts vless-xhttp
  xhttp_split_on || return 0
  cdn=$(gget cdn_host) pref=$(pget vless-xhttp cdn_addr)
  echo "Split|${pref:-$cdn}|$cdn"
}

# 上下行分离：上传经 CDN（设了优选地址时连它），下载直连本机 443 上自己的域名。
# 两路都由伪装站按同一个路径转给这个入站，服务端凭路径里的会话编号把它们配成一对，所以服务端不用改。
# 只有 Xray 和 Mihomo 支持。Reality 那一路是另一个入站，配不成对
xhttp_split_missing() { # 缺哪些前提，一行一条
  proto_enabled vless-xhttp || { t split_need_xhttp; echo; }
  [ -n "$(gget cdn_host)" ] || { t split_need_cdn; echo; }
  return 0
}

xhttp_split_on() { [ "$(gget xhttp_split 0)" = 1 ] && [ -z "$(xhttp_split_missing)" ]; }

xhttp_split_node() { [ "${NODE_LABEL:-}" = Split ]; }

# 分离节点的上传经 Cloudflare，它不转发持续上传的请求体，所以只能用 packet-up（每段上传一个请求）
vless_xhttp_mode() { if xhttp_split_node; then echo packet-up; else echo auto; fi; }

# 下载那一路的 Xray 配置，同时用于通用链接的 extra 和自测。<连接的地址> <端口>
xhttp_split_json() {
  local d
  d=$(gget tls_domain)
  printf '{"downloadSettings": {"address": "%s", "port": %s, "network": "xhttp", "security": "tls", "tlsSettings": {"serverName": "%s", "fingerprint": "%s", "alpn": ["%s"]}, "xhttpSettings": {"path": "%s", "host": "%s"}}}' \
    "$1" "$2" "$d" "$(fp_of vless-xhttp)" "$(vless_xhttp_alpn "$d")" "$(pget vless-xhttp path)" "$d"
}

xhttp_split_link_param() {
  xhttp_split_node || return 0
  printf '&extra=%s' "$(xhttp_split_json "$(gget tls_domain)" "$(pubport vless-xhttp)" | tr -d ' ' | sed 's/{/%7B/g; s/}/%7D/g; s/"/%22/g; s/:/%3A/g; s/,/%2C/g; s/\[/%5B/g; s/\]/%5D/g; s#/#%2F#g')"
}

# Mihomo 的下载设置不写的项沿用上传那一路，所以 ECH 要明确关掉：直连的域名没有 ECH 配置
xhttp_split_mihomo() {
  local d
  xhttp_split_node || return 0
  d=$(gget tls_domain)
  printf '\n      download-settings:\n        path: "%s"\n        host: "%s"\n        server: "%s"\n        port: %s\n        tls: true\n        servername: "%s"\n        alpn: ["%s"]\n        client-fingerprint: %s\n        ech-opts:\n          enable: false' \
    "$(pget vless-xhttp path)" "$d" "$d" "$(pubport vless-xhttp)" "$d" "$(vless_xhttp_alpn "$d")" "$(fp_of vless-xhttp)"
}

# pbox site split [on|off]
cmd_xhttp_split() {
  local miss
  case "${1:-}" in
    on)
      need_root
      need_installed
      miss=$(xhttp_split_missing)
      [ -z "$miss" ] || die "$(t split_missing)
$(printf '%s\n' "$miss" | sed 's/^/  - /')"
      edit_begin
      gset xhttp_split 1
      edit_end
      [ "$DRY_RUN" = 1 ] && return 0
      note "$(t split_clients)"
      ;;
    off)
      edit_begin
      gset xhttp_split 0
      edit_end
      ;;
    "") need_root; need_installed; say "$(t split_title): $(onoff "$(gget xhttp_split 0)")" ;;
    *) cmd_help ;;
  esac
}

# 开着分离但前提后来没了（关了 XHTTP 或取消了 CDN）时，节点不再生成，体检说明原因；前提都在时实际走一次
d_xhttp_split() {
  local miss pref
  [ "$(gget xhttp_split 0)" = 1 ] || return 0
  miss=$(xhttp_split_missing)
  if [ -n "$miss" ]; then
    note "$(t split_inactive "$(printf '%s' "$miss" | tr '\n' ';' | sed 's/;$//; s/;/；/g')")"
    return 0
  fi
  pref=$(pget vless-xhttp cdn_addr)
  if vless_xhttp_selftest "${pref:-$(gget cdn_host)}" "$(gget cdn_host)" "$(xhttp_split_json 127.0.0.1 443)"; then
    ok "$(t d_self_ok "XHTTP-Split")"
  else
    bad "$(t d_self_bad "XHTTP-Split")"
    hint "$(t split_bad_hint)"
    return 1
  fi
}

# 自己的域名前面有 Trojan 时，握手由它完成，它只协商 HTTP/1.1；
# 经 CDN 的连接不过 Trojan，直接到网站，用 HTTP/2
vless_xhttp_alpn() { # <握手里的名字>
  if proto_enabled trojan && [ "$1" = "$(gget tls_domain)" ]; then echo http/1.1; else echo h2; fi
}

proto_vless_xhttp_share_link() {
  local h
  h=$(wstls_name)
  printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=%s&alpn=%s&type=xhttp&host=%s&path=%s&mode=%s%s#%s\n' \
    "$(uget "$1" uuid)" "$(host_fmt "$2")" "$(pubport vless-xhttp)" "$h" "$(fp_of vless-xhttp)" \
    "$(vless_xhttp_alpn "$h" | sed 's#/#%2F#g')" "$h" "$(pget vless-xhttp path | sed 's#/#%2F#g')" "$(vless_xhttp_mode)" "$(ech_link_param "$h")$(xhttp_split_link_param)" "$3"
}

proto_vless_xhttp_client_mihomo() {
  local h
  h=$(wstls_name)
  cat <<EOF
  - name: "$3"
    type: vless
    server: "$2"
    port: $(pubport vless-xhttp)
    uuid: "$(uget "$1" uuid)"
    network: xhttp
    udp: true
    tls: true
    servername: "$h"
    alpn: ["$(vless_xhttp_alpn "$h")"]
    client-fingerprint: $(fp_of vless-xhttp)$(ech_mh_opts "$h")
    xhttp-opts:
      path: "$(pget vless-xhttp path)"
      host: "$h"
      mode: $(vless_xhttp_mode)$(xhttp_split_mihomo)
EOF
}

# 只能用 Xray 自己当客户端。<客户端连接的地址> <握手里的名字> [下载那一路的设置]
vless_xhttp_selftest() {
  local d p u rc ex=""
  d=$(mktemp -d) p=$(random_port tcp) u=$(proto_users vless-xhttp | head -1)
  [ -n "${3:-}" ] && ex=", \"extra\": $3"
  cat >"$d/c.json" <<EOF
{"log": {"loglevel": "none"},
 "inbounds": [{"listen": "127.0.0.1", "port": $p, "protocol": "socks", "settings": {"udp": false}}],
 "outbounds": [{"protocol": "vless",
  "settings": {"address": "$1", "port": 443, "id": "$(uget "$u" uuid)", "encryption": "none"},
  "streamSettings": {"network": "xhttp", "xhttpSettings": {"path": "$(pget vless-xhttp path)", "host": "$2"$ex}, "security": "tls",
   "tlsSettings": {"serverName": "$2", "fingerprint": "chrome", "alpn": ["$(vless_xhttp_alpn "$2")"]$(ech_xray_field "$2")}}}]}
EOF
  selftest xray "$d/c.json" "$p"
  rc=$?
  rm -rf "$d"
  return $rc
}

proto_vless_xhttp_selftest() { wstls_selftest vless-xhttp "$(gget tls_domain)" "$(gget tls_domain)"; }

proto_vless_xhttp_doctor() { wstls_doctor vless-xhttp; }
