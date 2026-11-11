# 直接列出私网网段，不依赖内核附带的地址库文件（本项目不安装它）
PRIVATE_CIDRS='"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16", "100.64.0.0/10", "fc00::/7", "fe80::/10", "::1/128"'

core_render_base() {
  local block
  block=$(gget block_private 1)
  case "$1" in
    xray)
      cat <<EOF
{
  "log": {"loglevel": "error", "access": "none"},
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {
    "rules": [$([ "$block" = 1 ] && printf '{"type": "field", "ip": [%s], "outboundTag": "block"}' "$PRIVATE_CIDRS")]
  }
}
EOF
      ;;
    singbox)
      cat <<EOF
{
  "log": {"level": "error", "timestamp": true},
  "outbounds": [
    {"type": "direct", "tag": "direct"}
  ],
  "route": {
    "rules": [$([ "$block" = 1 ] && printf '{"ip_is_private": true, "action": "reject"}')]
  }
}
EOF
      ;;
  esac
}

# render_all <输出目录>：按 $CUR 渲染。每个协议一个文件，由内核自己合并加载。
# custom/ 里的用户片段一并复制进来，和生成物一起接受校验。
render_all() {
  local out="$1" core id f d
  rm -rf "$out"
  for core in $(cores_needed); do
    d="$out/$(core_dir "$core")"
    mkdir -p "$d"
    core_render_base "$core" >"$d/00_base.json"
    for f in "$CUSTOM/$(core_dir "$core")"/*.json; do
      [ -f "$f" ] && cp "$f" "$d/90_custom_$(basename "$f")"
    done
  done
  for id in $(protos_enabled); do
    pcall "$id" render_inbound >"$out/$(core_dir "$(pmeta "$id" core)")/10_$id.json" || return 1
  done
  mkdir -p "$out"
}

validate_all() { # <目录>
  local core d msg rc=0
  for core in xray singbox; do
    d="$1/$(core_dir "$core")"
    [ -d "$d" ] || continue
    if ! msg=$(core_validate "$core" "$d"); then
      warn "$(t validate_fail "$(core_title "$core")")"
      printf '%s\n' "$msg" | tail -8 >&2
      printf '%s\n' "$msg" | grep -q '90_custom_' && warn "$(t validate_custom)"
      rc=1
    fi
  done
  return $rc
}

# 让一个内核按 $GEN 的现状生效；不再需要的内核停掉。
core_sync() {
  local core="$1" n
  n=$(core_svc "$core")
  if [ -d "$GEN/$(core_dir "$core")" ]; then
    # 每次都重写服务文件，这样运行环境的变化（例如解析配置的映射）能跟上
    svc_write "$n" "$(core_cmd "$core")" "$([ "$core" = singbox ] && echo 1 || echo 0)"
    svc enable "$n"
    if svc active "$n"; then
      # sing-box 支持热重载，连接不断；Xray 只能重启。服务文件变了则一律重启。
      [ "$core" = singbox ] && [ "$UNIT_CHANGED" = 0 ] && svc reload "$n" 2>/dev/null || svc restart "$n"
    else
      svc start "$n"
    fi
  else
    testing || svc_remove "$n"
  fi
}

probe() {
  local core id
  testing && return 0
  sleep 2
  for core in $(cores_needed); do
    if ! svc active "$(core_svc "$core")"; then
      warn "$(t probe_dead "$(core_title "$core")")"
      # 把内核自己的报错给用户看，否则只知道"没起来"而不知道原因
      tail -n 6 "$LOGDIR/$(core_svc "$core").log" 2>/dev/null >&2
      [ "$INIT" = systemd ] && journalctl -u "$(core_svc "$core")" -n 6 --no-pager 2>/dev/null >&2
      return 1
    fi
  done
  for id in $(protos_enabled); do
    port_in_use "$(pmeta "$id" l4)" "$(pget "$id" port)" || { warn "$(t probe_port "$(pmeta "$id" title)" "$(pget "$id" port)")"; return 1; }
  done
}

rollback() {
  local core
  [ -d "$PREV/state" ] || return 1
  rm -rf "$STATE" "$GEN"
  cp -R "$PREV/state" "$STATE"
  [ -d "$PREV/generated" ] && cp -R "$PREV/generated" "$GEN"
  CUR="$STATE"
  fix_perms
  for core in xray singbox; do core_sync "$core"; done
}

# 提交事务：渲染 → 校验 → 比对 → 备份现状 → 替换 → 只动有变化的内核 → 探活，失败回滚。
# 返回 0 表示已生效；非 0 表示未生效且已恢复原状。
txn_commit() {
  local new="$ETC/.txn" core d changed=""
  render_all "$new/generated" || { txn_abort; return 1; }
  if ! validate_all "$new/generated"; then
    txn_abort
    return 1
  fi
  for core in xray singbox; do
    d=$(core_dir "$core")
    if [ -d "$GEN/$d" ] || [ -d "$new/generated/$d" ]; then
      diff -rq "$GEN/$d" "$new/generated/$d" >/dev/null 2>&1 || changed="$changed $core"
    fi
  done
  if [ "$DRY_RUN" = 1 ]; then
    head1 "$(t dry_title)"
    diff -ru "$STATE" "$new/state" 2>/dev/null | grep -E '^[+-][a-z_0-9]+=' | sed -E 's/^([+-][a-z_0-9]*(key|password|uuid)[a-z_0-9]*)=.*/\1=***/; s/^/  /'
    say "  $(t dry_cores "${changed:- -}")"
    txn_abort
    return 0
  fi
  rm -rf "$PREV"
  mkdir -p "$PREV"
  [ -d "$STATE" ] && cp -R "$STATE" "$PREV/state"
  [ -d "$GEN" ] && cp -R "$GEN" "$PREV/generated"
  rm -rf "$STATE" "$GEN"
  mv "$new/state" "$STATE"
  mv "$new/generated" "$GEN"
  rm -rf "$new"
  CUR="$STATE"
  manifest_add dir "$ETC"
  fix_perms
  for core in $changed; do core_sync "$core"; done
  if ! probe; then
    if rollback; then warn "$(t rolled_back)"; elif [ "${FRESH:-0}" != 1 ]; then warn "$(t rollback_none)"; fi
    return 1
  fi
  return 0
}
