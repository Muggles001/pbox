# 订阅：把各客户端格式的节点文件推送到用户自己的 GitLab 私有仓库。
# 所有格式都在本机生成；仓库、令牌都是用户自己的，脚本只在用户填入后使用。
#
# 用两个令牌：
#   可写令牌（api 权限）只存在服务器上，用来推送；
#   只读令牌（read_repository 权限）写进订阅地址给客户端用。
# 这样订阅地址泄露时，别人能读到节点，但改不了订阅内容。
#
# 多用户时每人一组文件。名为 default 的用户沿用不带后缀的文件名，所以早先发出去的订阅地址不变；
# 其他用户的文件名带一段随机后缀。注意：所有人的订阅地址用的是同一个只读令牌，
# 它能读整个仓库，所以用户之间并不是严格隔离的——这一点在添加用户时会明说。

SUB_KINDS="v2ray clash singbox"

# 由 nodes_write 调用：每次节点有变化都重新生成每个用户的订阅文件
sub_build() {
  local u d first
  for u in $(users_list); do
    d="$NODES/users/$u/sub"
    mkdir -p "$d"
    openssl base64 -A <"$NODES/users/$u/links.txt" >"$d/v2ray"
    cp "$NODES/users/$u/mihomo.yaml" "$d/clash"
    cp "$NODES/users/$u/sing-box.json" "$d/singbox"
  done
  # 顶层保留一份第一个用户的，方便直接查看
  first=$(users_list | sed -n 1p)
  rm -rf "$NODES/sub"
  [ -n "$first" ] && cp -R "$NODES/users/$first/sub" "$NODES/sub"
  return 0
}

sub_get() { kv_get "$STATE/global.env" "sub_$1" "${2:-}"; }
sub_enabled() { [ -n "$(sub_get project)" ]; }

# 某个用户在仓库里的文件名后缀
sub_suffix() {
  [ "$1" = default ] && return 0
  printf -- '-%s' "$(kv_get "$STATE/users/$1.env" sub_key)"
}

# 列出要推送的文件：每行"仓库里的文件名|本机路径"
sub_list() {
  local u k
  for u in $(users_list); do
    for k in $SUB_KINDS; do
      echo "$k$(sub_suffix "$u")|$NODES/users/$u/sub/$k"
    done
  done
}

sub_api() { # <项目路径> → 文件接口的地址前缀
  printf 'https://gitlab.com/api/v4/projects/%s/repository/files' "$(printf '%s' "$1" | sed 's#/#%2F#g')"
}

# sub_push_with <项目> <分支> <可写令牌>
# 逐个文件：内容没变就跳过；否则先按"更新"提交，失败再按"新建"提交。
sub_push_with() {
  local api br="$2" hdr tmp code rc=0 line name file
  api=$(sub_api "$1")
  tmp=$(mktemp -d)
  # 令牌放进只有 root 可读的临时文件再交给 curl，不出现在进程列表里
  hdr="$tmp/h"
  (umask 077 && printf 'PRIVATE-TOKEN: %s\n' "$3" >"$hdr")
  sub_list >"$tmp/list"
  while IFS= read -r line; do
    name="${line%%|*}" file="${line#*|}"
    if curl -fsS --max-time 20 -H @"$hdr" -o "$tmp/cur" "$api/$name/raw?ref=$br" 2>/dev/null && cmp -s "$tmp/cur" "$file"; then
      continue
    fi
    code=""
    for m in PUT POST; do
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X "$m" -H @"$hdr" \
        --data-urlencode "branch=$br" --data-urlencode "commit_message=pbox: update $name" \
        --data-urlencode "content@$file" "$api/$name")
      case "$code" in 200 | 201) break ;; esac
    done
    case "$code" in 200 | 201) ;; *) rc=1 ;; esac
  done <"$tmp/list"
  rm -rf "$tmp"
  return $rc
}

# 节点有变化后自动调用。没开订阅就什么都不做。
sub_push() {
  sub_enabled || return 0
  testing && return 0
  sub_push_with "$(sub_get project)" "$(sub_get branch main)" "$(sub_get wtoken)"
}

# 删除用户后，把他在仓库里的订阅文件也删掉。尽力而为，失败不影响本机。
sub_remote_del() { # <后缀>
  local api tmp k
  sub_enabled || return 0
  testing && return 0
  api=$(sub_api "$(sub_get project)")
  tmp=$(mktemp -d)
  (umask 077 && printf 'PRIVATE-TOKEN: %s\n' "$(sub_get wtoken)" >"$tmp/h")
  for k in $SUB_KINDS; do
    curl -s -o /dev/null --max-time 20 -X DELETE -H @"$tmp/h" \
      --data-urlencode "branch=$(sub_get branch main)" --data-urlencode "commit_message=pbox: remove $k$1" "$api/$k$1"
  done
  rm -rf "$tmp"
}

sub_url() { # <仓库里的文件名>
  printf '%s/%s/raw?ref=%s&private_token=%s' "$(sub_api "$(sub_get project)")" "$1" "$(sub_get branch main)" "$(sub_get rtoken)"
}

sub_show() { # [用户]
  local u="${1:-}" sfx
  sub_enabled || die "$(t sub_not_set)"
  [ -n "$u" ] || u=$(users_list | sed -n 1p)
  [ -f "$STATE/users/$u.env" ] || die "$(t user_missing "$u")"
  sfx=$(sub_suffix "$u")
  head1 "$(t sub_urls_title) · $u"
  printf '  %s%s%s\n  %s\n\n' "$C_B" "$(t sub_c_v2ray)" "$C_0" "$(sub_url "v2ray$sfx")"
  printf '  %s%s%s\n  %s\n\n' "$C_B" "$(t sub_c_clash)" "$C_0" "$(sub_url "clash$sfx")"
  printf '  %s%s%s\n  %s\n\n' "$C_B" "$(t sub_c_singbox)" "$C_0" "$(sub_url "singbox$sfx")"
  note "$(t sub_url_note)"
  [ "$(users_list | wc -l)" -gt 1 ] && note "$(t sub_shared_note)"
  return 0
}

read_secret() { # <提示>，结果在 REPLY；不回显
  printf '%s: ' "$1"
  IFS= read -rs REPLY || REPLY=""
  echo
}

sub_setup() {
  local proj wt rt br=main tmp
  need_root
  need_installed
  proj="${PBOX_SUB_PROJECT:-}" wt="${PBOX_SUB_WTOKEN:-}" rt="${PBOX_SUB_RTOKEN:-}"
  if [ -z "$proj$wt$rt" ]; then
    head1 "$(t m_sub)"
    say "$(t sub_intro)"
    say ""
    ask "$(t sub_ask_project)" "$(sub_get project)"
    proj="$REPLY"
    read_secret "$(t sub_ask_wtoken)"
    wt="$REPLY"
    read_secret "$(t sub_ask_rtoken)"
    rt="$REPLY"
  fi
  proj=$(printf '%s' "$proj" | sed 's#^https://gitlab.com/##; s#\.git$##; s#/*$##')
  printf '%s' "$proj" | grep -Eq '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+$' || die "$(t sub_bad_project)"
  [ -n "$wt" ] && [ -n "$rt" ] || die "$(t sub_need_tokens)"
  [ -f "$NODES/sub/v2ray" ] || nodes_write
  say "$(t sub_verify)"
  # 先用可写令牌真的推一次，再用只读令牌真的读一次，两步都通过才保存
  sub_push_with "$proj" "$br" "$wt" || die "$(t sub_write_fail)"
  tmp=$(mktemp)
  if ! curl -fsS --max-time 20 -o "$tmp" "$(sub_api "$proj")/$(sub_list | sed -n 1p | cut -d'|' -f1)/raw?ref=$br&private_token=$rt" 2>/dev/null ||
    ! cmp -s "$tmp" "$(sub_list | sed -n 1p | cut -d'|' -f2)"; then
    rm -f "$tmp"
    die "$(t sub_read_fail)"
  fi
  rm -f "$tmp"
  kv_set "$STATE/global.env" sub_project "$proj"
  kv_set "$STATE/global.env" sub_branch "$br"
  kv_set "$STATE/global.env" sub_wtoken "$wt"
  kv_set "$STATE/global.env" sub_rtoken "$rt"
  chmod 600 "$STATE/global.env" 2>/dev/null
  say "${C_G}$(t sub_saved)${C_0}"
  sub_show
}

sub_off() {
  local k
  need_root
  need_installed
  sub_enabled || die "$(t sub_not_set)"
  for k in project branch wtoken rtoken; do kv_set "$STATE/global.env" "sub_$k" ""; done
  say "$(t sub_off_done)"
}

# pbox sub [setup|show [用户]|push|off]
cmd_sub() {
  case "${1:-show}" in
    setup) sub_setup ;;
    show) need_root; need_installed; sub_show "${2:-}" ;;
    push)
      need_root
      need_installed
      sub_enabled || die "$(t sub_not_set)"
      nodes_write
      if sub_push; then say "$(t sub_push_ok)"; else die "$(t sub_push_fail)"; fi
      ;;
    off) sub_off ;;
    *) cmd_help ;;
  esac
}
