main() {
  local args="" cmd
  # 全局开关可以出现在任意位置
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes | -y) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      -f) ANSWERS="$2"; shift ;;
      --offline) PBOX_OFFLINE="$2"; shift ;;
      --proxy) PBOX_PROXY="$2"; shift ;;
      --preset) shift ;;
      *) args="$args $1" ;;
    esac
    shift
  done
  # shellcheck disable=SC2086
  set -- $args
  cmd="${1:-menu}"
  [ $# -gt 0 ] && shift
  state_recover
  lang_init
  case "$cmd" in
    menu) cmd_menu ;;
    install) cmd_install ;;
    nodes) cmd_nodes "$@" ;;
    qr) need_root; need_installed; nodes_qr ;;
    doctor) need_root; detect_sys; cmd_doctor "$@" ;;
    add) cmd_add "$@" ;;
    del) cmd_del "$@" ;;
    change) cmd_change "$@" ;;
    reset-keys) cmd_reset_keys ;;
    set) cmd_set "$@" ;;
    user) cmd_user "$@" ;;
    sub) cmd_sub "$@" ;;
    warp) cmd_warp "$@" ;;
    bbr) cmd_bbr "$@" ;;
    argo) cmd_argo "$@" ;;
    firewall) cmd_firewall ;;
    rollback) cmd_rollback ;;
    log) cmd_log "$@" ;;
    backup) cmd_backup "$@" ;;
    restore) cmd_restore "$@" ;;
    update) cmd_update ;;
    post-update) cmd_post_update ;;
    hop-apply) need_root; need_installed; detect_sys; hop_apply ;;
    argo-sync) need_root; need_installed; detect_sys; lock_try && argo_sync ;;
    uninstall) cmd_uninstall ;;
    lang) cmd_lang ;;
    version | -v | --version) echo "$PBOX_VERSION" ;;
    help | -h | --help) cmd_help ;;
    *) cmd_help; exit 1 ;;
  esac
}

# 被测试脚本 source 时不执行
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
