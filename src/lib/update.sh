update_latest_tag() { # [超时秒数]
  fetch --max-time "${1:-10}" "https://api.github.com/repos/$PBOX_REPO/releases/latest" 2>/dev/null |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1
}

# 只有线上的版本确实比本机新才算有更新。本机比线上新（例如装的是尚未发布的版本）时不能提示，
# 否则"更新"会变成降级。
ver_newer() { # <线上标签，如 v1.2.3> <本机版本>
  local a="${1#v}" b="$2" i x y
  for i in 1 2 3; do
    x=$(printf '%s' "$a" | cut -d. -f"$i" | tr -cd '0-9')
    y=$(printf '%s' "$b" | cut -d. -f"$i" | tr -cd '0-9')
    [ "${x:-0}" -gt "${y:-0}" ] && return 0
    [ "${x:-0}" -lt "${y:-0}" ] && return 1
  done
  return 1
}

# 列出比本机新的那些版本各改了什么。清单每行"版本<TAB>一句话"，新版本在前，见 tools/changes.sh。
# 太长时只列前面的，免得新手面对一整屏；有内容可列时返回成功
UPD_SHOW_MAX=12
update_changes() { # <清单文件> <本机版本>
  local tag line n=0
  while IFS=$'\t' read -r tag line; do
    [ -n "$line" ] && ver_newer "$tag" "$2" || continue
    n=$((n + 1))
    [ "$n" -le "$UPD_SHOW_MAX" ] && printf '  %-8s %s\n' "$tag" "$line"
  done <"$1"
  [ "$n" -gt "$UPD_SHOW_MAX" ] && say "  $(t upd_more $((n - UPD_SHOW_MAX)))"
  [ "$n" -gt 0 ]
}

# 打开菜单时调用：每 6 小时最多联网一次，两秒超时，只提示不更新。可用 pbox set update-check off 关闭。
update_notice() {
  local cache="$LIBDIR/update.cache" now last tag
  [ -n "$PBOX_REPO" ] || return 0
  testing && return 0
  [ "$(kv_get "$STATE/global.env" update_check 1)" = 1 ] || return 0
  now=$(date +%s)
  last=$(kv_get "$cache" time 0)
  if [ $((now - last)) -ge 21600 ]; then
    tag=$(update_latest_tag 2)
    kv_set "$cache" time "$now" 2>/dev/null
    [ -n "$tag" ] && kv_set "$cache" tag "$tag" 2>/dev/null
  fi
  tag=$(kv_get "$cache" tag)
  if [ -n "$tag" ] && ver_newer "$tag" "$PBOX_VERSION"; then note "$(t upd_available "$tag")"; fi
  return 0
}

# 更新脚本本体。新脚本与同一发布里公布的哈希核对后才替换，随后由新脚本完成内核与配置的更新。
cmd_update() {
  local tag base tmp want
  need_root
  need_installed
  [ -n "$PBOX_REPO" ] || die "$(t upd_norepo)"
  spin_start "$(t spin_wait)"
  tag=$(update_latest_tag) || tag=""
  spin_stop
  [ -n "$tag" ] || die "$(t upd_fail)"
  # 手动检查的结果也记下来，菜单里的提示随之更新
  kv_set "$LIBDIR/update.cache" time "$(date +%s)" 2>/dev/null
  kv_set "$LIBDIR/update.cache" tag "$tag" 2>/dev/null
  if ! ver_newer "$tag" "$PBOX_VERSION"; then
    say "$(t upd_latest "$PBOX_VERSION")"
  else
    say "$(t upd_found "$PBOX_VERSION" "$tag")"
    base="https://github.com/$PBOX_REPO/releases/download/$tag"
    tmp=$(mktemp -d)
    # 清单拿不到不影响更新，只是少了这段说明
    if fetch --max-time 10 -o "$tmp/changes.txt" "$base/changes.txt" 2>/dev/null; then
      update_changes "$tmp/changes.txt" "$PBOX_VERSION" || true
    fi
    say "  $(t upd_link "https://github.com/$PBOX_REPO/releases/tag/$tag")"
    confirm "$(t upd_q)" || { rm -rf "$tmp"; die "$(t cancelled)"; }
    spin_start "$(t spin_wait)"
    fetch -o "$tmp/pbox.sh" "$base/pbox.sh" && fetch -o "$tmp/sum" "$base/pbox.sh.sha256" || { rm -rf "$tmp"; die "$(t upd_fail)"; }
    spin_stop
    want=$(awk '{print $1}' "$tmp/sum")
    [ "$(sha256_of "$tmp/pbox.sh")" = "$want" ] || { rm -rf "$tmp"; die "$(t upd_hash)"; }
    bash -n "$tmp/pbox.sh" || { rm -rf "$tmp"; die "$(t upd_hash)"; }
    cp "$LIBDIR/pbox.sh" "$LIBDIR/pbox.sh.previous"
    install -m 0755 "$tmp/pbox.sh" "$LIBDIR/pbox.sh"
    rm -rf "$tmp"
    exec "$LIBDIR/pbox.sh" post-update
  fi
  cmd_post_update
}

# 把内核升到本脚本锁定的版本，并用本脚本的模板重新渲染。失败时内核与配置一起回退。
cmd_post_update() {
  local core b geo_new=0
  need_root
  need_installed
  detect_sys
  lock
  txn_begin
  cores_ensure || { txn_abort; die "$(t dl_abort)"; }
  # 屏蔽回国用的数据跟着更新；下载不到就继续用旧的
  if block_cn_on; then
    if geo_fetch; then geo_new=1; else warn "$(t geo_stale)"; fi
  fi
  if txn_commit; then
    # 配置没变时内核不会重启，数据换了要让它重新读
    if [ "$geo_new" = 1 ] && ! testing; then
      for core in xray singbox; do
        case " $(cores_needed | tr '\n' ' ') " in *" $core "*) svc restart "$(core_svc "$core")" ;; esac
      done
    fi
    nodes_write
    # 新版本可能改了客户端配置的写法，而本机片段不一定变，所以无论如何重新合并一次
    sub_push force || warn "$(t sub_push_fail)"
    say "$(t upd_done)"
    return 0
  fi
  for core in xray singbox; do
    b=$(core_bin "$core")
    if [ -f "$BINDIR/previous/$(basename "$b")" ]; then
      mv -f "$BINDIR/previous/$(basename "$b")" "$b"
      rm -f "$LIBDIR/installed.env"
    fi
    core_sync "$core"
  done
  die "$(t upd_rolled)"
}
