core_bin() { case "$1" in xray) echo "$BINDIR/xray" ;; singbox) echo "$BINDIR/sing-box" ;; esac; }
core_svc() { case "$1" in xray) echo pbox-xray ;; singbox) echo pbox-singbox ;; esac; }
core_dir() { case "$1" in xray) echo xray ;; singbox) echo sing-box ;; esac; }
core_title() { case "$1" in xray) echo "Xray $XRAY_VERSION" ;; singbox) echo "sing-box $SINGBOX_VERSION" ;; esac; }
core_pinned() { case "$1" in xray) echo "$XRAY_VERSION" ;; singbox) echo "$SINGBOX_VERSION" ;; esac; }

core_url() {
  local a
  case "$1" in
    xray)
      [ "$ARCH" = amd64 ] && a=64 || a=arm64-v8a
      echo "https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-$a.zip"
      ;;
    singbox)
      echo "https://github.com/SagerNet/sing-box/releases/download/v$SINGBOX_VERSION/sing-box-$SINGBOX_VERSION-linux-$ARCH$(is_musl && echo -musl).tar.gz"
      ;;
  esac
}

core_sha() {
  local k
  case "$1" in xray) k="XRAY_SHA256_$ARCH" ;; singbox) k="SINGBOX_SHA256_$ARCH$(is_musl && echo _musl)" ;; esac
  echo "${!k}"
}

core_cmd() {
  case "$1" in
    xray) echo "$BINDIR/xray run -confdir $GEN/xray" ;;
    singbox) echo "$BINDIR/sing-box run -C $GEN/sing-box -D $VARDIR" ;;
  esac
}

# 已启用的协议用到哪些内核
cores_needed() {
  local id
  for id in $(protos_enabled); do pmeta "$id" core; echo; done | sort -u
}

# dl_verify <网址> <期望的 SHA256> <保存路径>
# 来源可以是离线目录、直连或用户指定的镜像；无论哪种，哈希不符一律拒绝。
dl_verify() {
  local url="$1" sha="$2" out="$3" base got
  base=$(basename "$url")
  if [ -n "${PBOX_OFFLINE:-}" ]; then
    [ -f "$PBOX_OFFLINE/$base" ] || { warn "$(t dl_offline_missing "$PBOX_OFFLINE/$base")"; return 1; }
    cp "$PBOX_OFFLINE/$base" "$out"
  elif ! fetch ${PBOX_PROXY:+-x "$PBOX_PROXY"} --retry 2 --connect-timeout 15 -o "$out" "$url"; then
    [ -n "${PBOX_MIRROR:-}" ] || { warn "$(t dl_fail "$base")"; return 1; }
    fetch --retry 2 --connect-timeout 15 -o "$out" "${PBOX_MIRROR}${url}" || { warn "$(t dl_fail "$base")"; return 1; }
  fi
  got=$(sha256_of "$out")
  if [ "$got" != "$sha" ]; then
    rm -f "$out"
    warn "$(t dl_hash_bad "$base" "$sha" "$got")"
    return 1
  fi
}

# 下载并解出内核的可执行文件到 <目录>/<内核>.bin
core_fetch() {
  local core="$1" dir="$2" pkg
  pkg="$dir/$core.pkg"
  dl_verify "$(core_url "$core")" "$(core_sha "$core")" "$pkg" || return 1
  mkdir -p "$dir/$core.x"
  case "$core" in
    xray) unzip -qo "$pkg" xray -d "$dir/$core.x" && mv "$dir/$core.x/xray" "$dir/$core.bin" ;;
    singbox) tar -xzf "$pkg" -C "$dir/$core.x" --strip-components 1 && mv "$dir/$core.x/sing-box" "$dir/$core.bin" ;;
  esac
}

# 安装缺失或版本不符的内核。多个内核并行下载；旧版本留在 previous/ 供回滚。
cores_ensure() {
  local core todo="" tmp pids="" p fail=0 b
  testing && return 0
  for core in $(cores_needed); do
    [ "$(kv_get "$LIBDIR/installed.env" "$core")" = "$(core_pinned "$core")" ] && [ -x "$(core_bin "$core")" ] && continue
    todo="$todo $core"
  done
  [ -z "$todo" ] && return 0
  tmp=$(mktemp -d) || return 1
  for core in $todo; do
    say "$(t dl_fetch "$(core_title "$core")")"
    core_fetch "$core" "$tmp" &
    pids="$pids $!"
  done
  for p in $pids; do wait "$p" || fail=1; done
  if [ "$fail" = 1 ]; then rm -rf "$tmp"; return 1; fi
  mkdir -p "$BINDIR/previous"
  manifest_add dir "$LIBDIR"
  for core in $todo; do
    b=$(core_bin "$core")
    [ -f "$b" ] && mv -f "$b" "$BINDIR/previous/$(basename "$b")"
    install -m 0755 "$tmp/$core.bin" "$b" || { rm -rf "$tmp"; return 1; }
    kv_set "$LIBDIR/installed.env" "$core" "$(core_pinned "$core")"
  done
  rm -rf "$tmp"
}

core_validate() { # <内核> <配置目录>，错误信息输出到标准输出
  local b
  b=$(core_bin "$1")
  [ -x "$b" ] || { testing && return 0; return 1; }
  case "$1" in
    xray) "$b" run -test -confdir "$2" 2>&1 ;;
    singbox) "$b" check -C "$2" 2>&1 ;;
  esac
}

# Reality 密钥对：输出两行，私钥、公钥。两个内核的输出格式都是第一行私钥、第二行公钥。
gen_reality_keypair() {
  local out
  if [ -x "$BINDIR/xray" ]; then
    out=$("$BINDIR/xray" x25519 2>/dev/null)
  elif [ -x "$BINDIR/sing-box" ]; then
    out=$("$BINDIR/sing-box" generate reality-keypair 2>/dev/null)
  elif testing; then
    out="PrivateKey: TEST_PRIVATE_$(rand_hex 4)
PublicKey: TEST_PUBLIC_$(rand_hex 4)"
  fi
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed -n '1,2s/^[^:]*: *//p'
}
