# 备份包含全部密钥，等同于节点本身：只落本机、默认加密、仅 root 可读。
backup_password() { # <是否需要二次确认 0|1>，结果在 PBOX_BK_PASS
  local p1 p2
  if [ -n "${PBOX_BACKUP_PASSWORD:-}" ]; then
    PBOX_BK_PASS="$PBOX_BACKUP_PASSWORD"
  else
    [ "$ASSUME_YES" = 1 ] && die "$(t bk_need_pass)"
    printf '%s: ' "$(t bk_pass)"
    IFS= read -rs p1
    echo
    if [ "$1" = 1 ]; then
      printf '%s: ' "$(t bk_pass2)"
      IFS= read -rs p2
      echo
      [ "$p1" = "$p2" ] || die "$(t bk_mismatch)"
    fi
    PBOX_BK_PASS="$p1"
  fi
  [ -n "$PBOX_BK_PASS" ] || die "$(t bk_need_pass)"
  export PBOX_BK_PASS
}

cmd_backup() {
  local f="${1:-pbox-backup-$(date +%Y%m%d-%H%M%S).bin}" items="state"
  need_root
  need_installed
  backup_password 1
  [ -d "$CERTS" ] && items="$items certs"
  [ -d "$CUSTOM" ] && items="$items custom"
  # 域名证书的账号与续期信息，恢复到新机器后才能继续续期
  [ -d "$ACME_CONF" ] && items="$items acme"
  [ -d "$SITE_DIR" ] && items="$items site"
  # shellcheck disable=SC2086
  (umask 077 && tar -czf - -C "$ETC" $items |
    openssl enc -aes-256-cbc -pbkdf2 -salt -pass env:PBOX_BK_PASS -out "$f") || die "$(t bk_fail)"
  say "$(t bk_done "$f")"
  note "$(t bk_warn)"
}

# 恢复：先解到临时目录，走完整的渲染与校验，通过后才替换现有配置。
cmd_restore() {
  local f="${1:-}" tmp
  need_root
  [ -f "$f" ] || die "$(t rs_nofile "$f")"
  detect_sys
  lock
  backup_password 0
  tmp=$(mktemp -d)
  if ! openssl enc -d -aes-256-cbc -pbkdf2 -pass env:PBOX_BK_PASS -in "$f" 2>/dev/null | tar -xzf - -C "$tmp" 2>/dev/null ||
    [ ! -f "$tmp/state/global.env" ]; then
    rm -rf "$tmp"
    die "$(t rs_bad)"
  fi
  confirm "$(t rs_confirm)" || { rm -rf "$tmp"; die "$(t cancelled)"; }
  txn_begin
  rm -rf "$ETC/.txn/state"
  cp -R "$tmp/state" "$ETC/.txn/state"
  # 换了机器时地址会变，按本机重新探测
  detect_ips
  gset ip4 "$IP4"
  gset ip6 "$IP6"
  # 给 IP 签的证书换了机器就不对了，退回自签
  if tls_is_ip && [ "$(gget tls_domain)" != "$IP4" ]; then
    gset tls_domain ""
    note "$(t dom_ip_dropped)"
  fi
  conflict_check
  run_user_create
  cores_ensure || { txn_abort; rm -rf "$tmp"; die "$(t dl_abort)"; }
  mkdir -p "$CERTS" "$CUSTOM"
  [ -d "$tmp/certs" ] && cp -R "$tmp/certs/." "$CERTS/"
  [ -d "$tmp/custom" ] && cp -R "$tmp/custom/." "$CUSTOM/"
  [ -d "$tmp/site" ] && mkdir -p "$SITE_DIR" && cp -R "$tmp/site/." "$SITE_DIR/"
  [ -d "$tmp/acme" ] && mkdir -p "$ACME_CONF" && cp -R "$tmp/acme/." "$ACME_CONF/" && chmod 700 "$ACME_CONF"
  rm -rf "$tmp"
  txn_commit || die "$(t apply_fail)"
  self_install
  hop_apply
  fw_sync
  nodes_write
  argo_apply
  if tls_real; then
    testing || acme_ensure || warn "$(t dl_abort)"
    domain_timer on
    note "$(t dom_restored "$(gget tls_domain)")"
  fi
  nodes_show
}
