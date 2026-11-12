# 订阅：把各客户端格式的节点文件推送到用户自己的 GitLab 私有仓库。
# 所有格式都在本机生成；仓库、令牌都是用户自己的，脚本只在用户填入后使用。
#
# 用两个令牌：
#   可写令牌（api 权限）只存在服务器上，用来推送；
#   只读令牌（read_repository 权限）写进订阅地址给客户端用。
# 这样订阅地址泄露时，别人能读到节点，但改不了订阅内容。
#
# 几台机器可以填同一个仓库。仓库里有三类文件：
#   pbox-index      登记表：每行 "machine <机器号> <标签>" 或 "user <用户名> <文件后缀>"
#   part-<机器号>   这台机器上每个用户的节点片段
#   v2ray、clash、singbox（其他用户带 -<后缀>）   客户端实际订阅的文件，由各机器的片段合并而成
# 任何一台机器的节点有变化，就更新自己的片段，再读回其他机器的片段重新合并。
# 用户按名字对应：两台机器上同名的用户共用一个订阅地址，后缀以先登记的为准。
#
# 注意：所有人的订阅地址用的是同一个只读令牌，它能读整个仓库，
# 所以用户之间并不是严格隔离的——这一点在添加用户时会明说。

SUB_KINDS="v2ray clash singbox"
SUB_INDEX="pbox-index"
SUB_SECTIONS="links names clash singbox"

# 由 nodes_write 调用：在本机留一份每个用户的订阅文件（只含本机节点），方便直接查看
sub_build() {
  local u d first
  for u in $(users_list); do
    d="$NODES/users/$u/sub"
    mkdir -p "$d"
    openssl base64 -A <"$NODES/users/$u/links.txt" >"$d/v2ray"
    cp "$NODES/users/$u/mihomo.yaml" "$d/clash"
    cp "$NODES/users/$u/sing-box.json" "$d/singbox"
  done
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

sub_api() { # <项目路径> → 文件接口的地址前缀
  printf 'https://gitlab.com/api/v4/projects/%s/repository/files' "$(printf '%s' "$1" | sed 's#/#%2F#g')"
}

# 下面三个函数是与仓库打交道的全部动作，依赖 SUB_API、SUB_BR、SUB_HDR。
# 测试时设 PBOX_SUB_DIR，用一个本机目录代替仓库，这样合并逻辑不联网也能验证。
sub_fetch() { # <文件名> <输出> → 0 取到；1 仓库里没有；2 其他失败
  local code
  if testing && [ -n "${PBOX_SUB_DIR:-}" ]; then
    : >"$2"
    [ -f "$PBOX_SUB_DIR/$1" ] || return 1
    cp "$PBOX_SUB_DIR/$1" "$2"
    return 0
  fi
  code=$(curl -s -o "$2" -w '%{http_code}' --max-time 20 -H @"$SUB_HDR" "$SUB_API/$1/raw?ref=$SUB_BR")
  case "$code" in
    200) return 0 ;;
    404)
      : >"$2"
      return 1
      ;;
  esac
  return 2
}

# 内容没变就不提交；否则先按"更新"提交，失败再按"新建"提交
sub_put() { # <文件名> <本机文件>
  local code="" m cur
  cur=$(mktemp)
  if sub_fetch "$1" "$cur" && cmp -s "$cur" "$2"; then
    rm -f "$cur"
    return 0
  fi
  rm -f "$cur"
  if testing && [ -n "${PBOX_SUB_DIR:-}" ]; then
    cp "$2" "$PBOX_SUB_DIR/$1"
    return 0
  fi
  for m in PUT POST; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X "$m" -H @"$SUB_HDR" \
      --data-urlencode "branch=$SUB_BR" --data-urlencode "commit_message=pbox: update $1" \
      --data-urlencode "content@$2" "$SUB_API/$1")
    case "$code" in 200 | 201) return 0 ;; esac
  done
  return 1
}

sub_del() { # <文件名>；尽力而为
  if testing && [ -n "${PBOX_SUB_DIR:-}" ]; then
    rm -f "$PBOX_SUB_DIR/$1"
    return 0
  fi
  curl -s -o /dev/null --max-time 20 -X DELETE -H @"$SUB_HDR" \
    --data-urlencode "branch=$SUB_BR" --data-urlencode "commit_message=pbox: remove $1" "$SUB_API/$1"
  return 0
}

# 本机的片段文件：按用户分段，每段里再分链接、节点名和两种客户端的片段
sub_part_build() {
  local u s
  for u in $(users_list); do
    echo "@user $u"
    for s in $SUB_SECTIONS; do
      echo "@$s"
      case "$s" in
        links) cat "$NODES/users/$u/links.txt" ;;
        *) cat "$NODES/users/$u/parts/$s" ;;
      esac
    done
  done
}

sub_part_users() { sed -n 's/^@user //p' "$1"; }

sub_part_get() { # <片段文件> <用户> <段名>
  awk -v u="$2" -v s="@$3" '
    /^@user /{cur=$2; sec=""; next}
    /^@(links|names|clash|singbox)$/{sec=$0; next}
    cur==u && sec==s' "$1"
}

sub_machine_id() {
  local m
  m=$(sub_get machine)
  if [ -z "$m" ]; then
    m=$(rand_hex 4)
    kv_set "$STATE/global.env" sub_machine "$m"
  fi
  printf '%s' "$m"
}

# 节点名以地区标签开头。两台机器标签相同会让合并后的节点重名，客户端会拒收，
# 所以后加入的那台自动改用带序号的标签。
sub_tag_fix() { # <登记表> <本机机器号>
  local tag base n=1 others
  base=$(gget region)
  tag="$base"
  others=$(awk -v m="$2" '$1=="machine" && $2!=m {print $3}' "$1")
  while printf '%s\n' "$others" | grep -qx -- "${tag:--}"; do
    n=$((n + 1))
    tag="${base:-N}$n"
  done
  if [ "$tag" != "$base" ]; then
    kv_set "$STATE/global.env" region "$tag"
    nodes_write
    note "$(t sub_tag_changed "$tag")"
  fi
}

# sub_sync <项目> <分支> <可写令牌> [force|leave|forget:<机器号>]
#   不带第四个参数：本机片段没变就什么都不做
#   force   无论如何重新合并
#   leave   把本机从订阅里撤出
#   forget  把另一台（已经不存在的）机器从订阅里去掉
sub_sync() {
  local mode="${4:-}" tmp mid idx u k lk line m tag f name sfx kind s rc=0 dirty="$VARDIR/sub-dirty"
  SUB_API=$(sub_api "$1") SUB_BR="$2"
  tmp=$(mktemp -d)
  # 令牌放进只有 root 可读的临时文件再交给 curl，不出现在进程列表里
  SUB_HDR="$tmp/h"
  (umask 077 && printf 'PRIVATE-TOKEN: %s\n' "$3" >"$SUB_HDR")
  idx="$tmp/index"
  sub_fetch "$SUB_INDEX" "$idx"
  [ $? = 2 ] && { rm -rf "$tmp"; return 1; }
  mid=$(sub_machine_id)

  if [ "$mode" != leave ]; then
    sub_tag_fix "$idx" "$mid"
    # 同名用户沿用登记表里已有的后缀，这样他在各台机器上是同一个订阅地址
    for u in $(users_list); do
      [ "$u" = default ] && continue
      k=$(awk -v n="$u" '$1=="user" && $2==n {print $3}' "$idx")
      lk=$(kv_get "$STATE/users/$u.env" sub_key)
      [ -n "$k" ] && [ "$k" != "$lk" ] && kv_set "$STATE/users/$u.env" sub_key "$k"
    done
    sub_part_build >"$tmp/part-$mid"
    tag=$(gget region)
    if [ -z "$mode" ] && [ ! -e "$dirty" ] && grep -qx "machine $mid ${tag:--}" "$idx" &&
      sub_fetch "part-$mid" "$tmp/cur" && cmp -s "$tmp/cur" "$tmp/part-$mid"; then
      rm -rf "$tmp"
      return 0
    fi
  fi
  mkdir -p "$VARDIR"
  : >"$dirty"

  # 参与合并的机器，按登记的先后排列；本机是新加入的就排在最后
  : >"$tmp/machines"
  while read -r kind m tag; do
    [ "$kind" = machine ] || continue
    [ "$m" = "$mid" ] && continue
    [ "$mode" = "forget:$m" ] && { sub_del "part-$m"; continue; }
    sub_fetch "part-$m" "$tmp/part-$m"
    case $? in
      0) echo "$m $tag" >>"$tmp/machines" ;;
      2) rm -rf "$tmp"; return 1 ;;
    esac
  done <"$idx"
  if [ "$mode" = leave ]; then
    sub_del "part-$mid"
  else
    tag=$(gget region)
    if grep -q "^machine $mid " "$idx"; then
      # 保持本机原来的位置
      awk -v m="$mid" -v t="${tag:--}" '
        FILENAME==ARGV[1] {keep[$1]=$0; next}
        $1=="machine" && $2==m {print m, t; next}
        $1=="machine" && ($2 in keep) {print keep[$2]}' "$tmp/machines" "$idx" >"$tmp/machines.new"
      mv "$tmp/machines.new" "$tmp/machines"
    else
      echo "$mid ${tag:--}" >>"$tmp/machines"
    fi
  fi

  # 新的登记表
  while read -r m tag; do sub_part_users "$tmp/part-$m"; done <"$tmp/machines" | sort -u >"$tmp/names"
  {
    sed 's/^/machine /' "$tmp/machines"
    while IFS= read -r name; do
      [ "$name" = default ] && continue
      k=$(awk -v n="$name" '$1=="user" && $2==n {print $3}' "$idx")
      [ -n "$k" ] || k=$(kv_get "$STATE/users/$name.env" sub_key)
      echo "user $name $k"
    done <"$tmp/names"
  } >"$tmp/index.new"

  # 哪台机器上都不再有的用户，删掉他的订阅文件
  while read -r kind name k; do
    [ "$kind" = user ] || continue
    grep -q "^user $name " "$tmp/index.new" && continue
    for s in $SUB_KINDS; do sub_del "$s-$k"; done
  done <"$idx"
  if [ -s "$idx" ] && ! grep -qx default "$tmp/names"; then
    for s in $SUB_KINDS; do sub_del "$s"; done
  fi

  [ "$mode" = leave ] || sub_put "part-$mid" "$tmp/part-$mid" || rc=1

  # 逐个用户合并
  while IFS= read -r name; do
    sfx=""
    [ "$name" = default ] || sfx="-$(awk -v n="$name" '$1=="user" && $2==n {print $3}' "$tmp/index.new")"
    for s in $SUB_SECTIONS; do
      while read -r m tag; do sub_part_get "$tmp/part-$m" "$name" "$s"; done <"$tmp/machines" >"$tmp/m.$s"
    done
    openssl base64 -A <"$tmp/m.links" >"$tmp/out"
    sub_put "v2ray$sfx" "$tmp/out" || rc=1
    wrap_mihomo "$tmp/m.names" "$tmp/m.clash" >"$tmp/out"
    sub_put "clash$sfx" "$tmp/out" || rc=1
    wrap_singbox "$tmp/m.names" "$tmp/m.singbox" >"$tmp/out"
    sub_put "singbox$sfx" "$tmp/out" || rc=1
  done <"$tmp/names"

  if [ -s "$tmp/index.new" ]; then
    sub_put "$SUB_INDEX" "$tmp/index.new" || rc=1
  else
    sub_del "$SUB_INDEX"
  fi
  [ $rc = 0 ] && rm -f "$dirty"
  rm -rf "$tmp"
  return $rc
}

# 节点有变化后自动调用。没开订阅就什么都不做。
sub_push() { # [force]
  sub_enabled || return 0
  testing && [ -z "${PBOX_SUB_DIR:-}" ] && return 0
  sub_sync "$(sub_get project)" "$(sub_get branch main)" "$(sub_get wtoken)" "${1:-}"
}

sub_url() { # <仓库里的文件名>
  printf '%s/%s/raw?ref=%s&private_token=%s' "$(sub_api "$(sub_get project)")" "$1" "$(sub_get branch main)" "$(sub_get rtoken)"
}

# 不指定用户时一屏列出所有人的订阅地址：管理的人只有一个，不需要先"切换"到谁
sub_show() { # [用户]
  local u sfx
  sub_enabled || die "$(t sub_not_set)"
  [ -z "${1:-}" ] || [ -f "$STATE/users/$1.env" ] || die "$(t user_missing "$1")"
  for u in ${1:-$(users_list)}; do
    sfx=$(sub_suffix "$u")
    head1 "$(t sub_urls_title) · $u"
    printf '  %s%s%s\n  %s\n\n' "$C_B" "$(t sub_c_v2ray)" "$C_0" "$(sub_url "v2ray$sfx")"
    printf '  %s%s%s\n  %s\n\n' "$C_B" "$(t sub_c_clash)" "$C_0" "$(sub_url "clash$sfx")"
    printf '  %s%s%s\n  %s\n' "$C_B" "$(t sub_c_singbox)" "$C_0" "$(sub_url "singbox$sfx")"
  done
  say ""
  note "$(t sub_url_note)"
  [ "$(users_list | wc -l)" -gt 1 ] && note "$(t sub_shared_note)"
  return 0
}

# 列出同一个仓库里的各台机器
sub_machines() {
  local tmp mid kind m tag
  sub_enabled || die "$(t sub_not_set)"
  SUB_API=$(sub_api "$(sub_get project)") SUB_BR=$(sub_get branch main)
  tmp=$(mktemp -d)
  SUB_HDR="$tmp/h"
  (umask 077 && printf 'PRIVATE-TOKEN: %s\n' "$(sub_get wtoken)" >"$SUB_HDR")
  sub_fetch "$SUB_INDEX" "$tmp/index"
  [ $? = 2 ] && { rm -rf "$tmp"; die "$(t sub_push_fail)"; }
  mid=$(sub_get machine)
  head1 "$(t sub_machines_title)"
  while read -r kind m tag; do
    [ "$kind" = machine ] || continue
    if [ "$m" = "$mid" ]; then
      printf '  %s  %s%s%s\n' "$tag" "$C_D" "$(t sub_machine_self)" "$C_0"
    else
      printf '  %s\n' "$tag"
    fi
  done <"$tmp/index"
  rm -rf "$tmp"
  say ""
  say "  ${C_D}$(t sub_forget_hint)${C_0}"
}

sub_forget() { # <标签>
  local tag="${1:-}" tmp m
  need_root
  need_installed
  sub_enabled || die "$(t sub_not_set)"
  [ -n "$tag" ] || die "$(t sub_forget_hint)"
  SUB_API=$(sub_api "$(sub_get project)") SUB_BR=$(sub_get branch main)
  tmp=$(mktemp -d)
  SUB_HDR="$tmp/h"
  (umask 077 && printf 'PRIVATE-TOKEN: %s\n' "$(sub_get wtoken)" >"$SUB_HDR")
  sub_fetch "$SUB_INDEX" "$tmp/index"
  m=$(awk -v t="$tag" -v me="$(sub_get machine)" '$1=="machine" && $3==t && $2!=me {print $2; exit}' "$tmp/index")
  rm -rf "$tmp"
  [ -n "$m" ] || die "$(t sub_forget_missing "$tag")"
  confirm "$(t sub_forget_q "$tag")" n || die "$(t cancelled)"
  if sub_push "forget:$m"; then say "$(t sub_push_ok)"; else die "$(t sub_push_fail)"; fi
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
  [ -d "$NODES/users" ] || nodes_write
  say "$(t sub_verify)"
  # 先用可写令牌真的推一次，再用只读令牌真的读一次，两步都通过才保存
  sub_sync "$proj" "$br" "$wt" force || die "$(t sub_write_fail)"
  if ! testing; then
    tmp=$(mktemp)
    if ! curl -fsS --max-time 20 -o "$tmp" "$(sub_api "$proj")/v2ray$(sub_suffix "$(users_list | sed -n 1p)")/raw?ref=$br&private_token=$rt" 2>/dev/null ||
      [ ! -s "$tmp" ]; then
      rm -f "$tmp"
      die "$(t sub_read_fail)"
    fi
    rm -f "$tmp"
  fi
  kv_set "$STATE/global.env" sub_project "$proj"
  kv_set "$STATE/global.env" sub_branch "$br"
  kv_set "$STATE/global.env" sub_wtoken "$wt"
  kv_set "$STATE/global.env" sub_rtoken "$rt"
  chmod 600 "$STATE/global.env" 2>/dev/null
  say "${C_G}$(t sub_saved)${C_0}"
  sub_show
}

# 关闭订阅或卸载时调用：把本机的节点从合并后的订阅里撤掉。尽力而为。
sub_leave() {
  sub_enabled || return 0
  testing && [ -z "${PBOX_SUB_DIR:-}" ] && return 0
  sub_sync "$(sub_get project)" "$(sub_get branch main)" "$(sub_get wtoken)" leave
}

sub_off() {
  local k
  need_root
  need_installed
  sub_enabled || die "$(t sub_not_set)"
  sub_leave || warn "$(t sub_leave_fail)"
  for k in project branch wtoken rtoken; do kv_set "$STATE/global.env" "sub_$k" ""; done
  say "$(t sub_off_done)"
}

# pbox sub [setup|show [用户]|push|machines|forget 标签|off]
cmd_sub() {
  case "${1:-show}" in
    setup) sub_setup ;;
    show) need_root; need_installed; sub_show "${2:-}" ;;
    push)
      need_root
      need_installed
      sub_enabled || die "$(t sub_not_set)"
      nodes_write
      if sub_push force; then say "$(t sub_push_ok)"; else die "$(t sub_push_fail)"; fi
      ;;
    machines) need_root; need_installed; sub_machines ;;
    forget) sub_forget "${2:-}" ;;
    off) sub_off ;;
    *) cmd_help ;;
  esac
}
