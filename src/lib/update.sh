update_latest_tag() { # [超时秒数]
  fetch --max-time "${1:-10}" "https://api.github.com/repos/$PBOX_REPO/releases/latest" 2>/dev/null |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1
}

# 打开菜单时调用：每天最多联网一次，两秒超时，只提示不更新。可用 pbox set update-check off 关闭。
update_notice() {
  local cache="$LIBDIR/update.cache" now last tag
  [ -n "$PBOX_REPO" ] || return 0
  [ "$(kv_get "$STATE/global.env" update_check 1)" = 1 ] || return 0
  now=$(date +%s)
  last=$(kv_get "$cache" time 0)
  if [ $((now - last)) -ge 86400 ]; then
    tag=$(update_latest_tag 2)
    kv_set "$cache" time "$now" 2>/dev/null
    [ -n "$tag" ] && kv_set "$cache" tag "$tag" 2>/dev/null
  fi
  tag=$(kv_get "$cache" tag)
  if [ -n "$tag" ] && [ "$tag" != "v$PBOX_VERSION" ]; then note "$(t upd_available "$tag")"; fi
  return 0
}

# 更新脚本本体。新脚本与同一发布里公布的哈希核对后才替换，随后由新脚本完成内核与配置的更新。
cmd_update() {
  local tag base tmp want
  need_root
  need_installed
  [ -n "$PBOX_REPO" ] || die "$(t upd_norepo)"
  tag=$(update_latest_tag) || tag=""
  [ -n "$tag" ] || die "$(t upd_fail)"
  if [ "$tag" = "v$PBOX_VERSION" ]; then
    say "$(t upd_latest "$PBOX_VERSION")"
  else
    say "$(t upd_found "$PBOX_VERSION" "$tag")"
    say "  https://github.com/$PBOX_REPO/releases/tag/$tag"
    confirm "$(t upd_q)" || die "$(t cancelled)"
    base="https://github.com/$PBOX_REPO/releases/download/$tag"
    tmp=$(mktemp -d)
    fetch -o "$tmp/pbox.sh" "$base/pbox.sh" && fetch -o "$tmp/sum" "$base/pbox.sh.sha256" || { rm -rf "$tmp"; die "$(t upd_fail)"; }
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
  local core b
  need_root
  need_installed
  detect_sys
  lock
  txn_begin
  cores_ensure || { txn_abort; die "$(t dl_abort)"; }
  if txn_commit; then
    nodes_write
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
