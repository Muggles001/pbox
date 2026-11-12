# 多用户：每人一套独立的凭据。删掉一个人，他的节点立即失效，其他人不受影响。

valid_user() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_-]{1,16}$'; }

# 把"a,b c"整理成空格分隔的协议名单，结果在 REPLY；all 表示不限制（存为空）
user_protos_parse() {
  local in id out=""
  in=$(printf '%s' "$1" | tr ',' ' ')
  REPLY=""
  case "$in" in "" | all) return 0 ;; esac
  for id in $in; do
    proto_known "$id" || return 1
    case " $out " in *" $id "*) ;; *) out="$out $id" ;; esac
  done
  REPLY="${out# }"
}

user_show() { # <用户>
  local u="$1" line pl
  [ -f "$STATE/users/$u.env" ] || die "$(t user_missing "$u")"
  [ -f "$NODES/users/$u/links.txt" ] || nodes_write
  head1 "$(t nodes_title) · $u"
  pl=$(kv_get "$STATE/users/$u.env" protocols)
  say "  $(t user_protos)   ${pl:-$(t user_protos_all)}"
  say ""
  while IFS= read -r line; do
    printf '  %s%s%s\n  %s\n\n' "$C_B" "${line##*#}" "$C_0" "$line"
  done <"$NODES/users/$u/links.txt"
  say "  $(t nodes_files)   ${NODES#"$R"}/users/$u/"
  if sub_enabled; then
    say ""
    sub_show "$u"
  fi
}

# pbox user <list|add 名字 [协议]|protocols 名字 <协议|all>|del 名字|show 名字|reset 名字>
cmd_user() {
  local act="${1:-list}" u="${2:-}" pl="${3:-}"
  need_root
  need_installed
  case "$act" in
    list)
      users_list
      return 0
      ;;
    show)
      user_show "$u"
      return 0
      ;;
  esac
  valid_user "$u" || die "$(t user_bad_name)"
  edit_begin
  case "$act" in
    add)
      [ -f "$CUR/users/$u.env" ] && { txn_abort; die "$(t user_exists "$u")"; }
      if [ -z "$pl" ]; then
        ask "$(t user_ask_protos "$(protos_enabled | tr '\n' ' ')")" all
        pl="$REPLY"
      fi
      user_protos_parse "$pl" || { txn_abort; die "$(t user_bad_protos "$PROTO_ALL")"; }
      user_new "$u"
      uset "$u" protocols "$REPLY"
      edit_end
      # 订阅用的是同一个只读令牌，用户之间不是严格隔离，这里说清楚
      sub_enabled && note "$(t sub_shared_note)"
      user_show "$u"
      ;;
    del)
      [ -f "$CUR/users/$u.env" ] || { txn_abort; die "$(t user_missing "$u")"; }
      [ "$(users_list | wc -l)" -gt 1 ] || { txn_abort; die "$(t user_last)"; }
      confirm "$(t user_del_q "$u")" n || { txn_abort; die "$(t cancelled)"; }
      rm -f "$CUR/users/$u.env"
      edit_end
      ;;
    protocols)
      [ -f "$CUR/users/$u.env" ] || { txn_abort; die "$(t user_missing "$u")"; }
      if [ -z "$pl" ]; then
        ask "$(t user_ask_protos "$(protos_enabled | tr '\n' ' ')")" all
        pl="$REPLY"
      fi
      user_protos_parse "$pl" || { txn_abort; die "$(t user_bad_protos "$PROTO_ALL")"; }
      uset "$u" protocols "$REPLY"
      edit_end
      user_show "$u"
      ;;
    reset)
      [ -f "$CUR/users/$u.env" ] || { txn_abort; die "$(t user_missing "$u")"; }
      confirm "$(t user_reset_q "$u")" n || { txn_abort; die "$(t cancelled)"; }
      uset "$u" uuid "$(gen_uuid)"
      uset "$u" password "$(rand_str "$(rand_int 20 32)")"
      edit_end
      user_show "$u"
      ;;
    *)
      txn_abort
      die "$(t user_usage)"
      ;;
  esac
}
