# 域名模式：用自己的域名申请受信任的证书，Hysteria2、TUIC、AnyTLS 改用它。
# 之后客户端按正常方式验证证书，不再需要指纹固定，也不再有"跳过证书验证"的链接。
#
# 没有域名时也可以给本机的公网 IP 申请证书（pbox domain set ip）。这种证书只有约 6 天有效期，
# 客户端连接时不带网站名字、按 IP 验证。状态里仍然记在 tls_domain 这个键下，值是 IP。
#
# 证书由 acme.sh 向 Let's Encrypt 申请。acme.sh 只取它的主程序一个文件，版本与哈希锁定，
# 不走它自己的安装流程：不改 shell 配置、不装它的定时任务，续期由本脚本自己的定时器触发。
# 默认的验证方式是 HTTP-01：签发方会来访问本机的 80 端口，所以申请和续期时 80 端口都必须可达且空闲。
# 域名托管在 Cloudflare 时还可以用 DNS-01（pbox domain set 域名 dns）：由脚本通过 Cloudflare 的接口
# 临时加一条解析记录来证明域名归属，不需要 80 端口，只转发指定端口的 NAT 机器也能用。
# 它需要一个 Cloudflare 接口令牌；令牌由 acme.sh 保存在只有 root 可读的配置里，续期时还要用。

ACME_HOME="$LIBDIR/acme"
ACME_CONF="$ETC/acme"
DOMAIN_CRT="$CERTS/domain.crt"
DOMAIN_KEY="$CERTS/domain.key"

# 以下几个函数供协议模块使用：有正规证书时用域名和它的证书，否则用各协议自己的自签证书。
tls_real() { [ -n "$(gget tls_domain)" ]; }
is_ip4() { printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; }
tls_is_ip() { is_ip4 "$(gget tls_domain)"; }
# 证书临近到期的判断线：IP 证书总共只有约 6 天
tls_min_days() { if tls_is_ip; then echo 2; else echo 15; fi; }
tls_name() { if tls_real; then echo domain; else echo "$1"; fi; }
tls_sni() { if tls_real; then gget tls_domain; else pget "$1" sni; fi; }
# 自测用的本机客户端始终固定公钥，这样用测试签发方的证书时也能自测
tls_spki() { if tls_real; then cert_spki "$DOMAIN_CRT"; else pget "$1" cert_spki; fi; }
# 给客户端的输出：正规证书不带指纹（续期后指纹会变，而客户端本来就能验证它）
tls_sb_pin() {
  tls_real && return 0
  printf ',\n        "certificate_public_key_sha256": ["%s"]' "$(pget "$1" cert_spki)"
}
tls_mh_pin() {
  tls_real && return 0
  printf 'fingerprint: "%s"' "$(pget "$1" cert_sha256)"
}

acme() { "$ACME_HOME/acme.sh" --home "$ACME_HOME" --config-home "$ACME_CONF" "$@"; }
acme_server() { printf '%s' "${PBOX_ACME_SERVER:-letsencrypt}"; }

acme_ensure() {
  local tmp
  [ -x "$ACME_HOME/acme.sh" ] && [ "$(sha256_of "$ACME_HOME/acme.sh")" = "$ACME_SHA256" ] && return 0
  tmp=$(mktemp -d)
  dl_verify "https://raw.githubusercontent.com/acmesh-official/acme.sh/$ACME_VERSION/acme.sh" "$ACME_SHA256" "$tmp/acme.sh" || { rm -rf "$tmp"; return 1; }
  mkdir -p "$ACME_HOME" "$ACME_CONF"
  install -m 0755 "$tmp/acme.sh" "$ACME_HOME/acme.sh"
  rm -rf "$tmp"
  chmod 700 "$ACME_CONF"
}

acme_ensure_dns() {
  local f="$ACME_HOME/dnsapi/dns_cf.sh" tmp
  [ -f "$f" ] && [ "$(sha256_of "$f")" = "$ACME_DNS_CF_SHA256" ] && return 0
  tmp=$(mktemp -d)
  dl_verify "https://raw.githubusercontent.com/acmesh-official/acme.sh/$ACME_VERSION/dnsapi/dns_cf.sh" "$ACME_DNS_CF_SHA256" "$tmp/dns_cf.sh" || { rm -rf "$tmp"; return 1; }
  mkdir -p "$ACME_HOME/dnsapi"
  install -m 0644 "$tmp/dns_cf.sh" "$f"
  rm -rf "$tmp"
}

# 清掉 acme.sh 保存的 Cloudflare 令牌
acme_forget_token() {
  [ -f "$ACME_CONF/account.conf" ] || return 0
  grep -v -E 'CF_(Token|Account_ID|Zone_ID)' "$ACME_CONF/account.conf" >"$ACME_CONF/account.conf.tmp"
  mv "$ACME_CONF/account.conf.tmp" "$ACME_CONF/account.conf"
  chmod 600 "$ACME_CONF/account.conf"
}

# 把签下来的证书放到内核读取的位置
domain_install_cert() { # <域名>
  mkdir -p "$CERTS"
  if testing; then
    cert_selfsigned domain "$1"
    return
  fi
  acme --install-cert -d "$1" --ecc --fullchain-file "$DOMAIN_CRT" --key-file "$DOMAIN_KEY" >/dev/null 2>&1 || return 1
  fix_perms
}

# 续期定时器：每 12 小时检查一次（没有 systemd 的系统上每小时一次），到了续期时间 acme.sh 才会真的续。
# 查得这么勤是因为 IP 证书约 6 天就到期，一天一次留的余地太小。
domain_timer() { # <on|off>
  local f
  testing && return 0
  if [ "$INIT" = systemd ]; then
    if [ "$1" = off ]; then
      systemctl disable --now pbox-renew.timer >/dev/null 2>&1
      for f in /etc/systemd/system/pbox-renew.service /etc/systemd/system/pbox-renew.timer; do
        [ -f "$f" ] && rm -f "$f" && manifest_del file "$f"
      done
      systemctl daemon-reload
      return 0
    fi
    cat >/etc/systemd/system/pbox-renew.service <<EOF
[Unit]
Description=pbox certificate renewal
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$(exec_prefix)$LIBDIR/pbox.sh domain renew
EOF
    cat >/etc/systemd/system/pbox-renew.timer <<EOF
[Unit]
Description=pbox certificate renewal check

[Timer]
OnCalendar=*-*-* 00/12:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    manifest_add file /etc/systemd/system/pbox-renew.service
    manifest_add file /etc/systemd/system/pbox-renew.timer
    systemctl daemon-reload
    systemctl enable --now pbox-renew.timer >/dev/null 2>&1
  else
    f=/etc/periodic/hourly/pbox-renew
    if [ "$1" = off ]; then
      [ -f "$f" ] && rm -f "$f" && manifest_del file "$f"
      return 0
    fi
    mkdir -p /etc/periodic/hourly
    printf '#!/bin/sh\nexec %s domain renew\n' "$LIBDIR/pbox.sh" >"$f"
    chmod 755 "$f"
    manifest_add file "$f"
    # /etc/periodic 由 crond 执行，有的系统模板没有让它开机运行
    if ! rc-update show default 2>/dev/null | grep -qw crond; then
      rc-update add crond default >/dev/null 2>&1 && manifest_add rc crond
    fi
    rc-service crond status >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1
  fi
}

# 申请前的检查：问题在这里指出，而不是等签发方报一个看不懂的错
domain_precheck() { # <域名> [dns]
  local dom="$1" ip4 ip6 got owner
  if [ "${2:-}" = dns ]; then
    is_ip4 "$dom" && die "$(t dom_dns_ip)"
    valid_domain "$dom" || die "$(t bad_domain "$dom")"
    return 0
  fi
  [ "$(gget nat 0)" = 1 ] && die "$(t dom_nat)"
  if is_ip4 "$dom"; then
    if ! testing && port_in_use tcp 80; then
      owner=$(port_owner tcp 80)
      die "$(t dom_80_busy "${owner:-?}")"
    fi
    return 0
  fi
  valid_domain "$dom" || die "$(t bad_domain "$dom")"
  ip4=$(gget ip4) ip6=$(gget ip6)
  got=$( { resolve A "$dom"; resolve AAAA "$dom"; } | tr '\n' ' ')
  [ -n "${got// /}" ] || die "$(t dom_no_dns "$dom" "${ip4:-$ip6}")"
  if ! { [ -n "$ip4" ] && resolve A "$dom" | grep -qxF "$ip4"; } && ! { [ -n "$ip6" ] && resolve AAAA "$dom" | grep -qxF "$ip6"; }; then
    die "$(t dom_wrong_dns "$dom" "$got" "${ip4:-$ip6}")"
  fi
  if ! testing && port_in_use tcp 80; then
    owner=$(port_owner tcp 80)
    die "$(t dom_80_busy "${owner:-?}")"
  fi
  return 0
}

# 向签发方申请证书。第三个参数非空时，证书同时写上这个名字（套 CDN 的子域名）。
# 令牌为空时 acme.sh 用它上次保存的那个。force 用于名字变了但证书还没到续期时间的情况。
domain_issue() { # <域名> <http|dns> [附加名字] [令牌] [force]
  local dom="$1" method="$2" alt="${3:-}" tok="${4:-}" log="$LOGDIR/acme.log" be rc extra=""
  testing && return 0
  [ -n "$alt" ] && extra="-d $alt"
  [ "${5:-}" = force ] && extra="$extra --force"
  is_ip4 "$dom" && extra="$extra --certificate-profile shortlived"
  mkdir -p "$LOGDIR"
  if [ "$method" = dns ]; then
    acme_ensure || die "$(t dl_abort)"
    acme_ensure_dns || die "$(t dl_abort)"
    say "$(t dom_issuing_dns)"
    # shellcheck disable=SC2086
    CF_Token="$tok" acme --issue --dns dns_cf -d "$dom" $extra --server "$(acme_server)" --keylength ec-256 --log "$log" >/dev/null 2>&1
    rc=$?
    chmod 600 "$ACME_CONF/account.conf" 2>/dev/null
  else
    if ! has socat; then
      say "$(t deps_missing " socat")"
      pkg_install socat >/dev/null || die "$(t deps_fail " socat")"
    fi
    acme_ensure || die "$(t dl_abort)"
    be=$(fw_backend)
    [ -n "$be" ] && { fw_is_open "$be" 80/tcp || fw_open "$be" 80/tcp; }
    say "$(t dom_issuing)"
    # shellcheck disable=SC2086
    acme --issue --standalone -d "$dom" $extra --server "$(acme_server)" --keylength ec-256 --log "$log" >/dev/null 2>&1
    rc=$?
  fi
  [ $rc = 0 ] && return 0
  # 不强制重签时，已经签过且尚未到期 acme.sh 返回"跳过"，这不算失败
  [ "${5:-}" != force ] && [ -f "$ACME_CONF/${dom}_ecc/fullchain.cer" ]
}

domain_set() { # <域名|ip> [dns]
  local dom="${1:-}" method="${2:-http}" old tok=""
  need_root
  need_installed
  detect_sys
  if [ -z "$dom" ]; then
    ask "$(t dom_ask)" ""
    dom="$REPLY"
  fi
  dom=$(printf '%s' "$dom" | tr 'A-Z' 'a-z')
  if [ "$dom" = ip ]; then
    site_on_p && die "$(t site_blocks_domain)"
    dom=$(gget ip4)
    # 只为 IPv4 申请：IPv6 的情况没有验证过
    [ -n "$dom" ] || die "$(t dom_ip_no4)"
  fi
  [ "$method" = dns ] || method=http
  domain_precheck "$dom" "$method"
  head1 "$(t dom_plan_title)"
  if is_ip4 "$dom"; then
    say "$(t dom_plan_ip "$dom")"
  elif [ "$method" = dns ]; then
    say "$(t dom_plan_dns "$dom")"
  else
    say "$(t dom_plan "$dom")"
  fi
  say ""
  confirm "$(t dom_plan_q)" || die "$(t cancelled)"
  if [ "$method" = dns ]; then
    tok="${PBOX_CF_TOKEN:-}"
    if [ -z "$tok" ]; then
      say ""
      say "$(t dom_token_help)"
      read_secret "$(t dom_ask_token)"
      tok="$REPLY"
    fi
    [ -n "$tok" ] || die "$(t dom_need_token)"
  fi
  if ! testing && [ "$method" = dns ]; then
    # 先确认令牌本身有效，免得等到申请失败才发现
    fetch --max-time 15 -H "Authorization: Bearer $tok" https://api.cloudflare.com/client/v4/user/tokens/verify 2>/dev/null |
      grep -q '"success": *true' || die "$(t dom_token_bad)"
  fi
  # 套 CDN 的子域名跟着主域名走：换主域名时新证书里也带上它
  if ! domain_issue "$dom" "$method" "$(gget cdn_host)" "$tok"; then
    if [ "$method" = dns ]; then die "$(t dom_issue_fail_dns "$LOGDIR/acme.log")"; else die "$(t dom_issue_fail "$LOGDIR/acme.log")"; fi
  fi
  domain_install_cert "$dom" || die "$(t dom_issue_fail "$LOGDIR/acme.log")"
  old=$(gget tls_domain)
  edit_begin
  gset tls_domain "$dom"
  gset tls_method "$method"
  edit_end
  domain_timer on
  [ "$method" = dns ] || testing || acme_forget_token
  # 换了域名（或在域名与 IP 之间切换）时，旧的那份不再续期
  if [ -n "$old" ] && [ "$old" != "$dom" ] && ! testing; then
    acme --remove -d "$old" --ecc >/dev/null 2>&1
    rm -rf "$ACME_CONF/${old}_ecc"
  fi
  say "${C_G}$(t dom_done "$dom")${C_0}"
}

domain_off() {
  local dom be
  need_root
  need_installed
  detect_sys
  dom=$(gget tls_domain)
  [ -n "$dom" ] || die "$(t dom_not_set)"
  site_on_p && die "$(t site_blocks_domain)"
  confirm "$(t dom_off_q)" n || die "$(t cancelled)"
  edit_begin
  gset tls_domain ""
  edit_end
  domain_timer off
  if ! testing; then
    acme --remove -d "$dom" --ecc >/dev/null 2>&1
    rm -rf "$ACME_CONF/${dom}_ecc"
    acme_forget_token
    be=$(fw_backend)
    [ -n "$be" ] && grep -qxF "fw	$be 80/tcp" "$MANIFEST" 2>/dev/null && fw_close "$be" 80/tcp
  fi
  rm -f "$DOMAIN_CRT" "$DOMAIN_KEY"
  say "$(t dom_off_done)"
}

# 由定时器调用。证书没到续期时间时 acme.sh 返回 2，什么都不做。
# force 不管到没到期都续一次，用来确认续期这条路真的走得通，不必等到期才发现问题。
# 签发方会在约一个月内复用已通过的验证，不先作废的话强制续期根本不验证，什么也证明不了。
domain_renew() { # [force]
  local dom alt core rc extra=""
  case "${1:-}" in '') ;; force) extra=--force ;; *) cmd_help; exit 1 ;; esac
  need_root
  dom=$(kv_get "$STATE/global.env" tls_domain)
  if [ -z "$dom" ]; then
    say "$(t dom_not_set)"
    return 0
  fi
  detect_sys
  lock_try || return 0
  if [ -n "$extra" ]; then
    alt=$(kv_get "$STATE/global.env" cdn_host)
    acme --deactivate -d "$dom" ${alt:+-d "$alt"} --server "$(acme_server)" --log "$LOGDIR/acme.log" >/dev/null 2>&1
  fi
  acme --renew -d "$dom" --ecc $extra --server "$(acme_server)" --log "$LOGDIR/acme.log" >/dev/null 2>&1
  rc=$?
  if [ $rc = 0 ]; then
    domain_install_cert "$dom"
    for core in $(cores_needed); do svc restart "$(core_svc "$core")"; done
  fi
  unlock
  case $rc in
    0) say "$(t dom_renewed)" ;;
    2) say "$(t dom_renew_skip)" ;;
    *) warn "$(t dom_renew_fail "$LOGDIR/acme.log")"; return 1 ;;
  esac
  domain_status
}

cert_end_date() { openssl x509 -in "$1" -noout -enddate 2>/dev/null | sed 's/^notAfter=//'; }

domain_status() {
  local dom
  dom=$(gget tls_domain)
  if [ -z "$dom" ]; then
    say "$(t dom_not_set)"
    return 0
  fi
  say "$(t dom_status "$dom" "$(cert_end_date "$DOMAIN_CRT")")"
}

# 体检项：证书还剩多久、域名是否仍然指向本机
d_domain() {
  local dom ip4 ip6
  dom=$(gget tls_domain)
  [ -n "$dom" ] || return 0
  if cert_valid_days "$DOMAIN_CRT" "$(tls_min_days)"; then
    ok "$(t d_dom_cert_ok "$dom" "$(cert_end_date "$DOMAIN_CRT")")"
  else
    bad "$(t d_dom_cert_bad "$dom" "$(tls_min_days)")"
    hint "pbox domain renew"
    hint "$LOGDIR/acme.log"
    return 1
  fi
  tls_is_ip && return 0
  # 用接口验证的证书，续期不依赖域名指向哪里
  [ "$(gget tls_method)" = dns ] && return 0
  ip4=$(gget ip4) ip6=$(gget ip6)
  if { [ -n "$ip4" ] && resolve A "$dom" | grep -qxF "$ip4"; } || { [ -n "$ip6" ] && resolve AAAA "$dom" | grep -qxF "$ip6"; }; then
    ok "$(t d_dom_dns_ok "$dom")"
  else
    bad "$(t d_dom_dns_bad "$dom" "${ip4:-$ip6}")"
    return 1
  fi
}

# pbox domain [status|set 域名 [dns]|set ip|off|renew [force]]
cmd_domain() {
  case "${1:-status}" in
    set) domain_set "${2:-}" "${3:-}" ;;
    off) domain_off ;;
    renew) domain_renew "${2:-}" ;;
    status) need_root; need_installed; domain_status ;;
    *) cmd_help ;;
  esac
}
