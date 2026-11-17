# ECH：经 CDN 的节点把握手里的子域名加密，旁路只能看到 Cloudflare 的公共名字 cloudflare-ech.com。
# 只作用于握手名字是套 CDN 子域名的节点；直连自己机器的节点没有可以藏身的公共名字，开了也没用。
# 服务端不用改：Cloudflare 免费版默认开着 ECH，加密配置在子域名的 HTTPS 记录里。
#
# 握手里明文的那一层也要像浏览器：国内实测公开层只报 http/1.1 的 ECH 握手会被阻断，
# 之后几分钟连这个 IP 的连接都会失败；报 h2、http/1.1 的（Chrome、Xray）能通。所以只给这几种开：
# - 通用链接（Xray）：WebSocket 和 XHTTP 都行，Xray 只把真实的 ALPN 放在加密层
# - Mihomo：只给 XHTTP。它的 WebSocket 把 http/1.1 原样写到公开层，改不了
# - sing-box：不开。它的 WebSocket 同样只报 http/1.1，又没有 XHTTP
#
# Cloudflare 大约每一两个小时换一次密钥，Mihomo 和 Xray 拿着过期配置都不会重试，所以不写死配置，
# 由客户端连接时用 DoH 查。客户端在国内时 1.1.1.1 常常连不上，所以用国内的 DoH：
# Mihomo 同时问几家、取先回来的，Xray 只能写一个。子域名本来就要经系统 DNS 解析地址，交给国内的 DoH 查不多泄露什么

# 服务器在境外，体检时取配置用 Cloudflare 自己的
ECH_DOH="https://1.1.1.1/dns-query"
ECH_DOH_XRAY="https://223.5.5.5/dns-query"
ECH_DOH_MIHOMO="[https://223.5.5.5/dns-query, https://1.12.12.12/dns-query, https://1.1.1.1/dns-query]"

ech_on() { [ "$(gget ech 0)" = 1 ] && [ -n "$(gget cdn_host)" ]; }

# 这个握手名字要不要加密
ech_for() { ech_on && [ "$1" = "$(gget cdn_host)" ]; }

# 从 DoH 取当前的加密配置（base64），取不到时输出为空
ech_fetch() { # <域名>
  if testing; then
    printf '%s' "${PBOX_TEST_ECH:-}"
    return 0
  fi
  {
    curl -s --max-time 8 -H 'accept: application/dns-json' "$ECH_DOH?name=$1&type=HTTPS" 2>/dev/null
    has dig && dig +short HTTPS "$1" 2>/dev/null
  } | grep -o 'ech=[A-Za-z0-9+/=]*' | head -1 | cut -d= -f2-
}

# Mihomo 节点的 ECH 那几行，接在上一行末尾，只给 XHTTP 用。<名字>
ech_mh_opts() {
  ech_for "$1" && printf '\n    ech-opts:\n      enable: true'
  return 0
}

# Mihomo 的 DNS 段：只有开了 ECH 的那些名字改用 DoH 查，其余照旧用系统的。
# 从代理片段里找，合并多台机器的订阅时也能覆盖别的机器的子域名
ech_mh_dns() { # <代理片段文件>
  local h
  h=$(awk '/^  - name:/{sn=""} /^    servername:/{gsub(/"/, "", $2); sn=$2} /^    ech-opts:/{if (sn != "") print sn}' "$1" | sort -u)
  [ -n "$h" ] || return 0
  printf 'dns:\n  enable: true\n  ipv6: true\n  nameserver:\n    - system\n  nameserver-policy:\n'
  printf '%s\n' "$h" | while IFS= read -r n; do printf '    "%s": %s\n' "$n" "$ECH_DOH_MIHOMO"; done
}

# 通用链接的参数，已转义
ech_link_param() { # <名字>
  ech_for "$1" && printf '&ech=%s' "$(printf '%s+%s' "$1" "$ECH_DOH_XRAY" | sed 's#:#%3A#g; s#/#%2F#g; s#+#%2B#g')"
  return 0
}

# Xray 自测用的 tlsSettings 片段
ech_xray_field() { # <名字>
  ech_for "$1" && printf ', "echConfigList": "%s+%s"' "$1" "$ECH_DOH_XRAY"
  return 0
}

d_ech() {
  local h
  [ "$(gget ech 0)" = 1 ] || return 0
  h=$(gget cdn_host)
  [ -n "$h" ] || { note "$(t ech_need_cdn)"; return 0; }
  if [ -n "$(ech_fetch "$h")" ]; then
    ok "$(t d_ech_ok "$h")"
  else
    bad "$(t d_ech_bad "$h")"
    hint "$(t ech_cf_hint)"
    return 1
  fi
}

cmd_ech() {
  case "${1:-}" in
    on)
      edit_begin
      [ -n "$(gget cdn_host)" ] || { txn_abort; die "$(t ech_need_cdn)"; }
      gset ech 1
      edit_end
      [ "$DRY_RUN" = 1 ] && return 0
      [ -n "$(ech_fetch "$(gget cdn_host)")" ] || warn "$(t d_ech_bad "$(gget cdn_host)") $(t ech_cf_hint)"
      note "$(t ech_clients)"
      ;;
    off)
      edit_begin
      gset ech 0
      edit_end
      ;;
    "") need_root; need_installed; say "ECH: $(onoff "$(gget ech 0)")" ;;
    *) cmd_help ;;
  esac
}
