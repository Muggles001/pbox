# 检测到其他代理脚本或建站面板时只提醒并询问，绝不改动对方的文件。
preflight_others() {
  local d found=""
  testing && return 0
  for d in /etc/v2ray-agent /etc/s-box /etc/sing-box /usr/local/etc/xray /etc/x-ui /usr/local/x-ui /opt/reality-ezpz /www/server/panel; do
    [ -e "$d" ] && found="$found $d"
  done
  [ -z "$found" ] && return 0
  warn "$(t pre_others "$found")"
  confirm "$(t pre_others_q)" || die "$(t cancelled)"
}

# 把正在运行的脚本装到固定位置。之后脚本只在用户主动更新时才变化。
self_install() {
  local self="${BASH_SOURCE[0]}"
  testing && return 0
  mkdir -p "$LIBDIR" "$(dirname "$ENTRY")"
  if [ -f "$self" ] && [ "$(cd "$(dirname "$self")" && pwd)/$(basename "$self")" != "$LIBDIR/pbox.sh" ]; then
    install -m 0755 "$self" "$LIBDIR/pbox.sh"
  fi
  ln -sf "$LIBDIR/pbox.sh" "$ENTRY"
  manifest_add dir "$LIBDIR"
  manifest_add file "$ENTRY"
}

show_plan() {
  local id label core cores=""
  head1 "$(t plan_title)"
  # 中文标签是全角字符，printf 的宽度按字节算会对不齐，所以标签后统一用固定间隔
  label=$(t plan_proto)
  for id in $(protos_enabled); do
    printf '  %s   %-22s %s %s%s\n' "$label" "$(pmeta "$id" title)" "$(pmeta "$id" l4 | tr a-z A-Z)" "$(pget "$id" port)" \
      "$([ -n "$(pget "$id" ext_port)" ] && printf ' → %s' "$(pget "$id" ext_port)")"
    label=$(t plan_blank)
  done
  for core in $(cores_needed); do cores="$cores${cores:+  ·  }$(core_title "$core")"; done
  printf '  %s   %s\n' "$(t plan_core)" "$cores"
  printf '  %s   %s   %s\n' "$(t plan_path)" "${ETC#"$R"}" "${LIBDIR#"$R"}"
  [ "$(gget block_private 1)" = 1 ] && printf '  %s   %s\n' "$(t plan_limit)" "$(t plan_limit_private)"
  say ""
  [ -n "${PLAN_NOTES:-}" ] && printf '%s' "$PLAN_NOTES" | while IFS= read -r id; do note "$id"; done
  return 0
}

# NAT 机器：没有独立公网地址，只有商家转发出来的几个端口。
# 逐个协议问清外网端口；留空表示这台机器不装这个协议（例如商家不转发 UDP）。
nat_setup() {
  local id k e
  [ "${NAT4:-0}" = 1 ] || return 0
  # 网卡上是内网地址有两种可能：一对一映射的云主机（所有端口直通，占多数），
  # 或只转发指定端口的 NAT 机器。无人值守时只有给了外网端口才按后者处理；交互时问一句，默认不是。
  if [ -z "$(opt REALITY_EXT_PORT)$(opt HY2_EXT_PORT)" ]; then
    [ "$ASSUME_YES" = 1 ] && return 0
    confirm "$(t nat_q)" n || return 0
  fi
  gset nat 1
  [ "$ASSUME_YES" = 1 ] || { head1 "$(t nat_title)"; say "$(t nat_explain)"; }
  for id in $(protos_enabled); do
    [ "$(pmeta "$id" local)" = 1 ] && continue
    case "$id" in reality-vision) k=REALITY_EXT_PORT ;; hysteria2) k=HY2_EXT_PORT ;; *) k="" ;; esac
    e=$(opt "$k")
    if [ -z "$e" ] && [ "$ASSUME_YES" != 1 ]; then
      say ""
      say "  $(t nat_rule "$(pmeta "$id" title)" "$(pget "$id" port)" "$(pmeta "$id" l4 | tr a-z A-Z)")"
      ask "  $(t nat_ask)" ""
      e="$REPLY"
    fi
    if [ -z "$e" ]; then
      rm -f "$CUR/protocols/$id.env"
      continue
    fi
    valid_port "$e" || { txn_abort; die "$(t bad_port "$e")"; }
    pset "$id" ext_port "$e"
  done
  [ -n "$(protos_enabled)" ] || { txn_abort; die "$(t nat_none)"; }
}

install_abort() {
  warn "$1"
  txn_abort
  [ "${FRESH:-0}" = 1 ] && do_uninstall quiet
  die "$(t install_undone)"
}

# 交互安装时可以自选协议和端口；直接回车就是推荐配置。
install_customize() {
  local id k picked=""
  [ "$ASSUME_YES" = 1 ] && return 0
  [ -n "$(opt PROTOCOLS)" ] && return 0
  ask "$(t inst_mode)" ""
  case "$REPLY" in c | C) ;; *) return 0 ;; esac
  for id in $PROTO_ALL; do
    confirm "  $(t inst_enable_q "$(pmeta "$id" title)")" || continue
    picked="$picked $id"
    case "$id" in reality-vision) k=PBOX_REALITY_PORT ;; hysteria2) k=PBOX_HY2_PORT ;; *) k="" ;; esac
    [ -n "$k" ] || continue
    ask "  $(t inst_port_q)" ""
    if [ -n "$REPLY" ]; then
      valid_port "$REPLY" || die "$(t bad_port "$REPLY")"
      export "$k=$REPLY"
    fi
  done
  [ -n "$picked" ] || die "$(t cancelled)"
  PBOX_PROTOCOLS="$picked"
}

cmd_install() {
  local protos id mode dom region
  need_root
  [ -d "$STATE" ] && die "$(t already_installed)"
  detect_sys
  lock
  preflight_others
  ensure_deps
  detect_ips
  [ -n "$IP4$IP6" ] || die "$(t no_ip)"
  install_customize
  protos=$(opt PROTOCOLS)
  [ -n "$protos" ] || protos="$PRESET_RECOMMENDED"
  txn_begin
  gset lang "$LANG_CODE"
  gset ip4 "$IP4"
  gset ip6 "$IP6"
  gset block_private 1
  gset update_check 1
  region=$(opt REGION)
  case "$region" in
    none) region="" ;;
    "") region=$(detect_region) ;;
  esac
  gset region "$region"
  mode=$(opt ADDR_MODE)
  dom=$(opt DOMAIN)
  gset addr_mode "${mode:-split}"
  [ -n "$dom" ] && gset domain "$dom"
  [ "$(gget addr_mode)" != split ] && addr_mode_check "$dom"
  PLAN_NOTES=""
  for id in $protos; do
    proto_known "$id" || { txn_abort; die "$(t c_unknown "$id")"; }
    : >"$CUR/protocols/$id.env"
    pcall "$id" plan || { txn_abort; die "$(t no_port)"; }
  done
  conflict_check
  nat_setup
  show_plan
  if [ "$DRY_RUN" = 1 ]; then txn_abort; return 0; fi
  confirm "$(t plan_go)" || { txn_abort; return 0; }
  FRESH=1
  user_new default
  run_user_create || install_abort "$(t user_fail)"
  cores_ensure || install_abort "$(t dl_abort)"
  for id in $(protos_enabled); do
    # 放在子进程里：其中任何一步失败都回到这里，按清单撤销已做的改动
    (pcall "$id" secrets) || install_abort "$(t secrets_fail "$(pmeta "$id" title)")"
  done
  txn_commit || install_abort "$(t apply_fail)"
  self_install
  fw_sync
  nodes_write
  argo_apply || warn "$(t argo_fail)"
  say ""
  say "${C_G}$(t install_done)${C_0}"
  nodes_show
  cmd_doctor || true
}

# 卸载按安装清单逐项撤销，全程不需要联网。
do_uninstall() {
  local kind val
  if [ -f "$MANIFEST" ]; then
    grep '^svc	' "$MANIFEST" | cut -f2 | while read -r val; do svc_remove "$val"; done
    grep '^fw	' "$MANIFEST" | cut -f2 | while read -r val; do fw_close "${val% *}" "${val#* }"; done
    grep -q '^hop	' "$MANIFEST" && hop_clear
    grep -E '^(file|dir|user)	' "$MANIFEST" | while IFS='	' read -r kind val; do
      case "$kind" in
        file) rm -f "$val" ;;
        dir) [ "$val" != "$ETC" ] && rm -rf "$val" ;;
        user) testing || { if [ "$PKG" = apk ]; then deluser "$val"; else userdel "$val"; fi; } >/dev/null 2>&1 ;;
      esac
    done
  fi
  rm -rf "$ETC"
  [ "${1:-}" = quiet ] || say "$(t uninstall_done)"
}

cmd_uninstall() {
  need_root
  [ -d "$ETC" ] || die "$(t not_installed)"
  detect_sys
  lock
  [ "$ASSUME_YES" = 1 ] || confirm "$(t uninstall_q)" n || die "$(t cancelled)"
  do_uninstall
}

# 以下命令共用的开头与结尾
edit_begin() {
  need_root
  need_installed
  detect_sys
  lock
  txn_begin
}

edit_end() {
  conflict_check
  cores_ensure || { txn_abort; die "$(t dl_abort)"; }
  txn_commit || die "$(t apply_fail)"
  [ "$DRY_RUN" = 1 ] && return 0
  hop_apply || warn "$(t hop_fail)"
  fw_sync
  nodes_write
  argo_apply || warn "$(t argo_fail)"
  sub_push || warn "$(t sub_push_fail)"
  say "${C_G}$(t applied)${C_0}"
  note "$(t links_changed)"
}

cmd_add() {
  local id="${1:-}" p="${2:-}"
  proto_known "$id" || die "$(t c_unknown "$id") ($PROTO_ALL)"
  edit_begin
  proto_enabled "$id" && { txn_abort; die "$(t add_exists "$id")"; }
  : >"$CUR/protocols/$id.env"
  PLAN_NOTES=""
  pcall "$id" plan || { txn_abort; die "$(t no_port)"; }
  if [ -n "$p" ] && [ "$p" != auto ]; then
    valid_port "$p" || { txn_abort; die "$(t bad_port "$p")"; }
    pset "$id" port "$p"
  fi
  conflict_check
  cores_ensure || { txn_abort; die "$(t dl_abort)"; }
  pcall "$id" secrets
  edit_end
}

cmd_del() {
  local id="${1:-}"
  edit_begin
  proto_enabled "$id" || { txn_abort; die "$(t del_missing "$id")"; }
  [ "$(protos_enabled | wc -l)" -gt 1 ] || { txn_abort; die "$(t del_last)"; }
  confirm "$(t del_q "$(pmeta "$id" title)")" n || { txn_abort; die "$(t cancelled)"; }
  rm -f "$CUR/protocols/$id.env"
  edit_end
}

# pbox change <协议> port <端口|auto>
# pbox change reality-vision sni <域名|auto>
cmd_change() {
  local id="${1:-}" key="${2:-}" val="${3:-auto}" l4
  edit_begin
  proto_enabled "$id" || { txn_abort; die "$(t del_missing "$id")"; }
  case "$key" in
    port)
      l4=$(pmeta "$id" l4)
      [ "$val" = auto ] && val=$(random_port "$l4")
      valid_port "$val" || { txn_abort; die "$(t bad_port "$val")"; }
      pset "$id" port "$val"
      ;;
    cdn)
      # 优选地址：客户端改连这个地址，再由 Cloudflare 送回自己的隧道
      [ "$id" = vless-ws ] || { txn_abort; die "$(t change_usage)"; }
      case "$val" in
        off | auto | none) val="" ;;
        *) valid_domain "$val" || printf '%s' "$val" | grep -Eq '^[0-9a-fA-F:.]+$' || { txn_abort; die "$(t bad_domain "$val")"; } ;;
      esac
      pset vless-ws cdn_addr "$val"
      ;;
    hop)
      [ "$id" = hysteria2 ] || { txn_abort; die "$(t change_usage)"; }
      hop_set "$val"
      ;;
    ext-port)
      valid_port "$val" || { txn_abort; die "$(t bad_port "$val")"; }
      pset "$id" ext_port "$val"
      gset nat 1
      ;;
    sni)
      [ "$id" = reality-vision ] || { txn_abort; die "$(t change_usage)"; }
      if [ "$val" = auto ]; then
        say "$(t reality_picking)"
        val=$(reality_pick) || { txn_abort; die "$(t reality_none)"; }
      else
        valid_domain "$val" || { txn_abort; die "$(t bad_domain "$val")"; }
        reality_check "$val" >/dev/null || { txn_abort; die "$(t reality_bad_target "$val")"; }
      fi
      pset "$id" sni "$val"
      ;;
    *)
      txn_abort
      die "$(t change_usage)"
      ;;
  esac
  edit_end
}

cmd_reset_keys() {
  local id u
  edit_begin
  confirm "$(t reset_q)" n || { txn_abort; die "$(t cancelled)"; }
  for u in $(users_list); do user_new "$u"; done
  for id in $(protos_enabled); do pcall "$id" secrets; done
  edit_end
}

# 合并模式要求域名同时解析到本机的 IPv4 和 IPv6，缺哪条就明说。
addr_mode_check() {
  local dom="$1" ip4 ip6
  valid_domain "$dom" || die "$(t bad_domain "$dom")"
  ip4=$(gget ip4) ip6=$(gget ip6)
  if [ -n "$ip4" ] && ! resolve A "$dom" | grep -qxF "$ip4"; then die "$(t addr_missing A "$dom" "$ip4")"; fi
  if [ -n "$ip6" ] && ! resolve AAAA "$dom" | grep -qxF "$ip6"; then die "$(t addr_missing AAAA "$dom" "$ip6")"; fi
  return 0
}

# pbox set addr-mode <split|merged|all> [域名]
# pbox set update-check <on|off>
# pbox set block-private <on|off>
cmd_set() {
  local key="${1:-}" val="${2:-}" dom="${3:-}"
  edit_begin
  case "$key" in
    addr-mode)
      case "$val" in
        split) ;;
        merged | all)
          [ -n "$(gget ip4)" ] && [ -n "$(gget ip6)" ] || { txn_abort; die "$(t addr_single)"; }
          [ -n "$dom" ] || dom=$(gget domain)
          addr_mode_check "$dom"
          gset domain "$dom"
          # S6：走哪条路由客户端决定，本地 IPv6 有问题时会受影响
          if [ "$val" = merged ]; then
            warn "$(t s6_warn)"
            confirm_risk "$(t s_continue)" || { txn_abort; die "$(t cancelled)"; }
          fi
          ;;
        *) txn_abort; die "$(t set_usage)" ;;
      esac
      gset addr_mode "$val"
      ;;
    region)
      case "$val" in
        auto | "") val=$(detect_region) ;;
        off | none) val="" ;;
      esac
      gset region "$(printf '%s' "$val" | tr -cd 'A-Za-z0-9' | cut -c1-8)"
      ;;
    update-check)
      case "$val" in on) gset update_check 1 ;; off) gset update_check 0 ;; *) txn_abort; die "$(t set_usage)" ;; esac
      ;;
    block-private)
      case "$val" in
        on) gset block_private 1 ;;
        off)
          # S7：关闭后节点可被用来访问 VPS 的内部网络
          warn "$(t s7_warn)"
          confirm_risk "$(t s_continue)" || { txn_abort; die "$(t cancelled)"; }
          gset block_private 0
          ;;
        *) txn_abort; die "$(t set_usage)" ;;
      esac
      ;;
    *) txn_abort; die "$(t set_usage)" ;;
  esac
  edit_end
}

cmd_nodes() {
  need_root
  need_installed
  [ -f "$NODES/links.txt" ] || nodes_write
  if [ "${1:-}" = --insecure ]; then
    # S5：跳过证书验证的链接可被中间人冒充
    warn "$(t s5_warn)"
    confirm_risk "$(t s_continue)" || die "$(t cancelled)"
    nodes_show insecure
  else
    nodes_show
  fi
}

cmd_rollback() {
  need_root
  need_installed
  detect_sys
  lock
  rollback || die "$(t rollback_none)"
  hop_apply
  fw_sync
  nodes_write
  argo_apply
  say "$(t rolled_back)"
}

cmd_log() {
  local f
  need_root
  if [ "${1:-}" = clear ]; then
    for f in "$LOGDIR"/*.log; do [ -f "$f" ] && : >"$f"; done
    say "$(t log_cleared)"
    return 0
  fi
  for f in "$LOGDIR"/*.log; do
    [ -f "$f" ] || continue
    printf '%s== %s ==%s\n' "$C_B" "$(basename "$f")" "$C_0"
    tail -n 40 "$f"
  done
}

cmd_firewall() {
  need_root
  need_installed
  detect_sys
  [ "$(fw_backend)" = none ] && { note "$(t d_fw_none)"; return 0; }
  fw_sync
}

cmd_lang() {
  need_root
  need_installed
  local l=zh
  [ "$LANG_CODE" = zh ] && l=en
  kv_set "$STATE/global.env" lang "$l"
  i18n_load "$l"
  nodes_write
  say "$(t lang_set)"
}

cmd_help() {
  cat <<EOF
pbox $PBOX_VERSION

  pbox                                  $(t h_menu)
  pbox install [-f FILE] [--offline DIR] [--proxy URL]
  pbox nodes [--insecure]   pbox qr
  pbox doctor [--report]
  pbox add <proto> [port]   pbox del <proto>
  pbox change <proto> port <n|auto>
  pbox change <proto> ext-port <n>
  pbox change hysteria2 hop <on|off|A-B>
  pbox change vless-ws cdn <addr|off>
  pbox change reality-vision sni <domain|auto>
  pbox reset-keys
  pbox set addr-mode <split|merged|all> [domain]
  pbox set region <XX|auto|off>
  pbox set update-check <on|off>   pbox set block-private <on|off>
  pbox sub [setup|show|push|off]
  pbox warp [on|off|all|domains a.com,b.com|status|test]
  pbox firewall   pbox rollback   pbox log [clear]
  pbox backup [FILE]   pbox restore FILE
  pbox update   pbox uninstall   pbox lang

  --yes       $(t h_yes)
  --dry-run   $(t h_dry)
EOF
}
