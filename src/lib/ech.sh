# ECH：经 CDN 的节点把握手里的子域名加密，旁路只能看到 Cloudflare 的公共名字 cloudflare-ech.com。
# 只作用于握手名字是套 CDN 子域名的节点；直连自己机器的节点没有可以藏身的公共名字，开了也没用。
# 服务端不用改：Cloudflare 免费版默认开着 ECH，加密配置在子域名的 HTTPS 记录里。
#
# Cloudflare 大约每一两个小时换一次密钥，客户端取得加密配置的方式按各自能否重试来定：
# - sing-box：生成配置时写入当前的。过期后按服务器给的新配置重试，但开着 uTLS 时不会，所以这些节点不用 uTLS 指纹
# - Mihomo、Xray（通用链接）：拿着过期配置不会重试，只能连接时自己查，用 DoH 查，
#   因为国内的普通 DNS 查不到 HTTPS 记录

ECH_DOH="https://1.1.1.1/dns-query"

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

# 生成节点前取一次，所有用户、所有节点共用，免得每个节点都查一遍
ech_load() {
  ECH_CFG=""
  ech_on && ECH_CFG=$(ech_fetch "$(gget cdn_host)")
  ECH_LOADED=1
}

ech_cfg() {
  [ -n "${ECH_LOADED:-}" ] || ech_load
  printf '%s' "$ECH_CFG"
}

# sing-box 的 tls 段。<名字> <alpn> <指纹>
ech_sb_tls() {
  local c
  if ech_for "$1"; then
    c=$(ech_cfg)
    if [ -n "$c" ]; then
      printf '{"enabled": true, "server_name": "%s", "alpn": ["%s"], "ech": {"enabled": true, "config": ["-----BEGIN ECH CONFIGS-----", "%s", "-----END ECH CONFIGS-----"]}}' "$1" "$2" "$c"
    else
      printf '{"enabled": true, "server_name": "%s", "alpn": ["%s"], "ech": {"enabled": true}}' "$1" "$2"
    fi
  else
    printf '{"enabled": true, "server_name": "%s", "alpn": ["%s"], "utls": {"enabled": true, "fingerprint": "%s"}}' "$1" "$2" "$3"
  fi
}

# Mihomo 里替代 client-fingerprint 的那几行。<名字> <指纹>
ech_mh_lines() {
  if ech_for "$1"; then
    printf '    ech-opts:\n      enable: true\n'
  else
    printf '    client-fingerprint: %s\n' "$2"
  fi
  return 0
}

# Mihomo 的 DNS 段：只有开了 ECH 的那些名字改用 DoH 查，其余照旧用系统的。
# 从代理片段里找，合并多台机器的订阅时也能覆盖别的机器的子域名
ech_mh_dns() { # <代理片段文件>
  local h
  h=$(awk '/^  - name:/{sn=""} /^    servername:/{gsub(/"/, "", $2); sn=$2} /^    ech-opts:/{if (sn != "") print sn}' "$1" | sort -u)
  [ -n "$h" ] || return 0
  printf 'dns:\n  enable: true\n  ipv6: true\n  nameserver:\n    - system\n  nameserver-policy:\n'
  printf '%s\n' "$h" | while IFS= read -r n; do printf '    "%s": %s\n' "$n" "$ECH_DOH"; done
}

# 通用链接的参数，已转义
ech_link_param() { # <名字>
  ech_for "$1" && printf '&ech=%s' "$(printf '%s+%s' "$1" "$ECH_DOH" | sed 's#:#%3A#g; s#/#%2F#g; s#+#%2B#g')"
  return 0
}

# Xray 自测用的 tlsSettings 片段
ech_xray_field() { # <名字>
  ech_for "$1" && printf ', "echConfigList": "%s+%s"' "$1" "$ECH_DOH"
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
      [ -n "$(ech_cfg)" ] || warn "$(t d_ech_bad "$(gget cdn_host)") $(t ech_cf_hint)"
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
