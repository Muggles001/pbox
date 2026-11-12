# 交互菜单。每次重画前清屏，界面始终停在同一个画面里；顶部是状态区。
# 具体操作都调用 cmd.sh 里的同一套命令，并放在子进程里执行：
# 这样某个操作报错退出时，只结束那个子进程，菜单本身不会跟着退出。

pause() {
  printf '\n%s' "$(t m_pause)"
  IFS= read -r _ || true
}

run() {
  echo
  ("$@")
  pause
}

rule() { printf '%s────────────────────────────────────────────────────%s\n' "$C_D" "$C_0"; }

dot() { if "$@"; then printf '%s●%s' "$C_G" "$C_0"; else printf '%s●%s' "$C_R" "$C_0"; fi; }

mem_usage() {
  awk '/^MemTotal/ {t=$2} /^MemAvailable/ {a=$2} END {if (t) printf "%d/%dM", (t-a)/1024, t/1024}' /proc/meminfo 2>/dev/null
}

onoff() { if [ "$1" = 1 ]; then t on; else t off; fi; }

# 菜单项：编号、名称、说明。格式串本身含占位符，所以直接取变量而不经过 t。
#中文名称统一四个字，天然对齐；英文靠 printf 补齐。
item() { printf "$T_m_fmt" "$1" "$(t "$2")" "$C_D$(t "$3")$C_0"; }

menu_header() {
  local id core label st
  clear 2>/dev/null || printf '\033c'
  st="${C_G}● $(t m_running)${C_0}"
  for core in $(cores_needed); do svc active "$(core_svc "$core")" || st="${C_R}● $(t m_stopped)${C_0}"; done
  printf ' %spbox %s%s    %s\n' "$C_B" "$PBOX_VERSION" "$C_0" "$st"
  rule
  printf ' %s   %s      %s   %s\n' "$(t mh_region)" "$(gget region -)" "$(t mh_mem)" "$(mem_usage)"
  [ -n "$(gget ip4)" ] && printf ' IPv4   %s\n' "$(gget ip4)"
  [ -n "$(gget ip6)" ] && printf ' IPv6   %s\n' "$(gget ip6)"
  label=$(t plan_proto)
  for id in $(protos_enabled); do
    printf ' %s   %-22s %s %s%s\n' "$label" "$(pmeta "$id" title)" "$(pmeta "$id" l4 | tr a-z A-Z)" "$(pget "$id" port)" \
      "$([ -n "$(pget "$id" ext_port)" ] && printf ' → %s' "$(pget "$id" ext_port)")"
    label=$(t plan_blank)
  done
  label=$(t plan_core)
  for core in $(cores_needed); do
    printf ' %s   %s %s\n' "$label" "$(dot svc active "$(core_svc "$core")")" "$(core_title "$core")"
    label=$(t plan_blank)
  done
  update_notice
  rule
  [ -n "${1:-}" ] && printf ' %s%s%s\n\n' "$C_B" "$1" "$C_0"
  return 0
}

choose() {
  printf '\n %s: ' "$(t m_choose)"
  IFS= read -r REPLY || REPLY=0
}

menu_proto() {
  local id="$1" n=0 k_port k_sni k_ext k_off k_hop k_cdn k_fix k_tmp k_obfs k_path k_cc
  while :; do
    menu_header "$(pmeta "$id" title)"
    if ! proto_enabled "$id"; then
      item 1 mp_enable mp_enable_d
      item 0 m_back m_blank
      choose
      case "$REPLY" in
        1)
          ask " $(t mp_ask_port)" ""
          run cmd_add "$id" "${REPLY:-auto}"
          ;;
        *) return 0 ;;
      esac
      continue
    fi
    n=1 k_port=1 k_sni="" k_ext=""
    item $n mp_port mp_port_d
    if [ "$id" = reality-vision ]; then n=$((n + 1)) k_sni=$n; item $n mp_sni mp_sni_d; fi
    if [ "$(gget nat 0)" = 1 ]; then n=$((n + 1)) k_ext=$n; item $n mp_ext mp_ext_d; fi
    k_cdn=""
    if [ "$id" = vless-ws ]; then
      n=$((n + 1)) k_cdn=$n
      printf "$T_m_fmt" "$n" "$(t mp_cdn)" "${C_D}[$(pget vless-ws cdn_addr "$(t off)")] $(t mp_cdn_d)${C_0}"
    fi
    k_cc=""
    if [ "$id" = tuic ]; then
      n=$((n + 1)) k_cc=$n
      printf "$T_m_fmt" "$n" "$(t mp_cc)" "${C_D}[$(pget tuic cc bbr)] $(t mp_cc_d)${C_0}"
    fi
    k_obfs="" k_path=""
    if [ "$id" = hysteria2 ]; then
      n=$((n + 1)) k_obfs=$n
      printf "$T_m_fmt" "$n" "$(t mp_obfs)" "${C_D}[$(onoff "$([ -n "$(pget hysteria2 obfs_password)" ] && echo 1 || echo 0)")] $(t mp_obfs_d)${C_0}"
    fi
    if [ "$id" = vless-ws ]; then
      n=$((n + 1)) k_path=$n
      printf "$T_m_fmt" "$n" "$(t mp_path)" "${C_D}$(t mp_path_d)${C_0}"
    fi
    k_fix="" k_tmp=""
    if [ "$id" = vless-ws ]; then
      n=$((n + 1)) k_fix=$n
      printf "$T_m_fmt" "$n" "$(t mp_fixed)" "${C_D}[$(pget vless-ws fixed_host "$(t off)")] $(t mp_fixed_d)${C_0}"
      n=$((n + 1)) k_tmp=$n
      printf "$T_m_fmt" "$n" "$(t mp_temp)" "${C_D}[$(onoff "$([ "$(pget vless-ws temp on)" = on ] && echo 1 || echo 0)")] $(t mp_temp_d)${C_0}"
    fi
    k_hop=""
    if [ "$id" = hysteria2 ] && [ "$(gget nat 0)" != 1 ]; then
      n=$((n + 1)) k_hop=$n
      printf "$T_m_fmt" "$n" "$(t mp_hop)" "${C_D}[$(pget hysteria2 hop_range "$(t off)")] $(t mp_hop_d)${C_0}"
    fi
    n=$((n + 1)) k_off=$n
    item $n mp_disable mp_disable_d
    item 0 m_back m_blank
    choose
    case "$REPLY" in
      "$k_port")
        ask " $(t mp_ask_port)" ""
        run cmd_change "$id" port "${REPLY:-auto}"
        ;;
      "$k_off") run cmd_del "$id" ;;
      0 | "" | q) return 0 ;;
      *)
        if [ -n "$k_sni" ] && [ "$REPLY" = "$k_sni" ]; then
          ask " $(t mp_ask_sni)" ""
          run cmd_change "$id" sni "${REPLY:-auto}"
        elif [ -n "$k_cc" ] && [ "$REPLY" = "$k_cc" ]; then
          ask " $(t mp_ask_cc)" "bbr"
          run cmd_change tuic cc "$REPLY"
        elif [ -n "$k_obfs" ] && [ "$REPLY" = "$k_obfs" ]; then
          if [ -n "$(pget hysteria2 obfs_password)" ]; then run cmd_change hysteria2 obfs off; else run cmd_change hysteria2 obfs on; fi
        elif [ -n "$k_path" ] && [ "$REPLY" = "$k_path" ]; then
          ask " $(t mp_ask_path)" "auto"
          run cmd_change vless-ws path "$REPLY"
        elif [ -n "$k_fix" ] && [ "$REPLY" = "$k_fix" ]; then
          if [ -n "$(pget vless-ws fixed_host)" ] && confirm " $(t mp_fixed_off_q)" n; then
            run cmd_argo fixed off
          else
            run cmd_argo fixed
          fi
        elif [ -n "$k_tmp" ] && [ "$REPLY" = "$k_tmp" ]; then
          if [ "$(pget vless-ws temp on)" = on ]; then run cmd_argo temp off; else run cmd_argo temp on; fi
        elif [ -n "$k_cdn" ] && [ "$REPLY" = "$k_cdn" ]; then
          menu_cdn
        elif [ -n "$k_hop" ] && [ "$REPLY" = "$k_hop" ]; then
          ask " $(t mp_ask_hop)" "on"
          run cmd_change "$id" hop "$REPLY"
        elif [ -n "$k_ext" ] && [ "$REPLY" = "$k_ext" ]; then
          ask " $(t mp_ask_ext)" ""
          [ -n "$REPLY" ] && run cmd_change "$id" ext-port "$REPLY"
        fi
        ;;
    esac
  done
}

menu_cdn() {
  local n c pick
  menu_header "$(t mp_cdn)"
  say " $(t cdn_intro)"
  say ""
  n=0
  for c in $ARGO_CDN_CHOICES; do
    n=$((n + 1))
    printf '  %s  %s\n' "$n" "$c"
  done
  printf "$T_m_fmt" 8 "$(t cdn_custom)" "${C_D}$(t cdn_custom_d)${C_0}"
  printf "$T_m_fmt" 9 "$(t cdn_off)" "${C_D}$(t cdn_off_d)${C_0}"
  item 0 m_back m_blank
  choose
  case "$REPLY" in
    0 | "" | q) return 0 ;;
    8)
      ask " $(t cdn_ask)" ""
      [ -n "$REPLY" ] && run cmd_change vless-ws cdn "$REPLY"
      return 0
      ;;
    9) run cmd_change vless-ws cdn off; return 0 ;;
  esac
  n=0 pick=""
  for c in $ARGO_CDN_CHOICES; do
    n=$((n + 1))
    [ "$REPLY" = "$n" ] && pick="$c"
  done
  [ -n "$pick" ] && run cmd_change vless-ws cdn "$pick"
}

menu_protocols() {
  local id n pick
  while :; do
    menu_header "$(t m_protocols)"
    n=0
    for id in $PROTO_ALL; do
      n=$((n + 1))
      if proto_enabled "$id"; then
        printf '  %s  %s●%s %-22s %s %s\n' "$n" "$C_G" "$C_0" "$(pmeta "$id" title)" "$(pmeta "$id" l4 | tr a-z A-Z)" "$(pget "$id" port)"
      else
        printf '  %s  %s○ %-22s %s%s\n' "$n" "$C_D" "$(pmeta "$id" title)" "$(t mp_off)" "$C_0"
      fi
    done
    item 0 m_back m_blank
    choose
    case "$REPLY" in 0 | "" | q) return 0 ;; esac
    n=0 pick=""
    for id in $PROTO_ALL; do
      n=$((n + 1))
      [ "$REPLY" = "$n" ] && pick="$id"
    done
    [ -n "$pick" ] && menu_proto "$pick"
  done
}

menu_addr_mode() {
  local mode dom
  menu_header "$(t mset_addr)"
  item 1 ma_split ma_split_d
  item 2 ma_all ma_all_d
  item 3 ma_merged ma_merged_d
  item 0 m_back m_blank
  choose
  case "$REPLY" in 1) mode="split" ;; 2) mode="all" ;; 3) mode="merged" ;; *) return 0 ;; esac
  dom=""
  if [ "$mode" != split ]; then
    ask " $(t mset_ask_domain)" "$(gget domain)"
    dom="$REPLY"
  fi
  run cmd_set addr-mode "$mode" "$dom"
}

menu_settings() {
  local v
  while :; do
    menu_header "$(t m_settings)"
    item 1 mset_reset mset_reset_d
    printf "$T_m_fmt" 2 "$(t mset_addr)" "${C_D}[$(gget addr_mode split)]${C_0}"
    printf "$T_m_fmt" 3 "$(t mset_region)" "${C_D}[$(gget region -)]${C_0}"
    printf "$T_m_fmt" 4 "$(t mset_block)" "${C_D}[$(onoff "$(gget block_private 1)")]${C_0}"
    printf "$T_m_fmt" 5 "$(t mset_upd)" "${C_D}[$(onoff "$(gget update_check 1)")]${C_0}"
    item 6 mset_fw mset_fw_d
    item 7 mset_lang mset_lang_d
    printf "$T_m_fmt" 8 "$(t mset_warp)" "${C_D}[$(onoff "$([ "$(kv_get "$STATE/outbound.env" warp off)" = on ] && echo 1 || echo 0)")] $(t mset_warp_d)${C_0}"
    item 0 m_back m_blank
    choose
    case "$REPLY" in
      1) run cmd_reset_keys ;;
      2) menu_addr_mode ;;
      3)
        ask " $(t mset_ask_region)" "auto"
        run cmd_set region "$REPLY"
        ;;
      4)
        v=on
        [ "$(gget block_private 1)" = 1 ] && v=off
        run cmd_set block-private "$v"
        ;;
      5)
        v=on
        [ "$(gget update_check 1)" = 1 ] && v=off
        run cmd_set update-check "$v"
        ;;
      6) run cmd_firewall ;;
      7)
        cmd_lang >/dev/null
        ;;
      8) menu_warp ;;
      *) return 0 ;;
    esac
  done
}

menu_warp() {
  while :; do
    menu_header "$(t mset_warp)"
    printf '  %s' "$C_D"
    (warp_status)
    printf '%s\n' "$C_0"
    item 1 mw_on mw_on_d
    item 2 mw_domains mw_domains_d
    item 3 mw_all mw_all_d
    item 4 mw_off mw_off_d
    item 5 mw_test mw_test_d
    item 0 m_back m_blank
    choose
    case "$REPLY" in
      5) run cmd_warp test ;;
      1) run cmd_warp on ;;
      2)
        ask " $(t mw_ask_domains)" "$(kv_get "$STATE/outbound.env" warp_domains "$WARP_DEFAULT_DOMAINS")"
        run cmd_warp domains "$REPLY"
        ;;
      3) run cmd_warp all ;;
      4) run cmd_warp off ;;
      *) return 0 ;;
    esac
  done
}

menu_backup() {
  while :; do
    menu_header "$(t m_backup)"
    item 1 mb_backup mb_backup_d
    item 2 mb_restore mb_restore_d
    item 3 mb_rollback mb_rollback_d
    item 0 m_back m_blank
    choose
    case "$REPLY" in
      1) run cmd_backup ;;
      2)
        ask " $(t mb_ask_file)" ""
        [ -n "$REPLY" ] && run cmd_restore "$REPLY"
        ;;
      3) run cmd_rollback ;;
      *) return 0 ;;
    esac
  done
}

menu_log() {
  while :; do
    menu_header "$(t m_log)"
    item 1 ml_view ml_view_d
    item 2 ml_clear ml_clear_d
    item 0 m_back m_blank
    choose
    case "$REPLY" in
      1) run cmd_log ;;
      2) run cmd_log clear ;;
      *) return 0 ;;
    esac
  done
}

menu_sub() {
  while :; do
    menu_header "$(t m_sub)"
    if sub_enabled; then
      printf '  %s%s  %s%s\n\n' "$C_D" "$(t msub_on)" "$(sub_get project)" "$C_0"
    else
      printf '  %s%s%s\n\n' "$C_D" "$(t msub_none)" "$C_0"
    fi
    item 1 msub_setup msub_setup_d
    item 2 msub_show msub_show_d
    item 3 msub_push msub_push_d
    item 4 msub_off msub_off_d
    item 0 m_back m_blank
    choose
    case "$REPLY" in
      1) run cmd_sub setup ;;
      2) run cmd_sub show ;;
      3) run cmd_sub push ;;
      4) run cmd_sub off ;;
      *) return 0 ;;
    esac
  done
}

cmd_menu() {
  need_root
  if [ ! -d "$STATE" ]; then
    (cmd_install)
    [ -d "$STATE" ] || return 0
    pause
  fi
  detect_sys
  while :; do
    menu_header
    item 1 m_nodes m_nodes_d
    item 2 m_doctor m_doctor_d
    item 3 m_protocols m_protocols_d
    item 4 m_sub m_sub_d
    item 5 m_settings m_settings_d
    item 6 m_update m_update_d
    item 7 m_backup m_backup_d
    item 8 m_log m_log_d
    item 9 m_uninstall m_uninstall_d
    item 0 m_exit m_blank
    choose
    case "$REPLY" in
      1) run cmd_nodes ;;
      2) run cmd_doctor ;;
      3) menu_protocols ;;
      4) menu_sub ;;
      5) menu_settings ;;
      6) run cmd_update ;;
      7) menu_backup ;;
      8) menu_log ;;
      9)
        echo
        (cmd_uninstall)
        [ -d "$STATE" ] || return 0
        pause
        ;;
      0 | q) clear 2>/dev/null; return 0 ;;
    esac
  done
}
