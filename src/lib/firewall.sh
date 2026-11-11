# 只识别已经启用的 ufw 或 firewalld。不安装、不替换、不停用、不清空任何防火墙。
fw_backend() {
  testing && { echo none; return; }
  if has ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    echo ufw
  elif has firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    echo firewalld
  else
    echo none
  fi
}

fw_is_open() { # <后端> <端口/协议>
  case "$1" in
    ufw) ufw status | grep -Eq "^${2}[[:space:]]+ALLOW" ;;
    firewalld) firewall-cmd --query-port="$2" >/dev/null 2>&1 ;;
    *) return 0 ;;
  esac
}

fw_open() {
  case "$1" in
    ufw) ufw allow "$2" comment pbox >/dev/null ;;
    firewalld) firewall-cmd --permanent --add-port="$2" >/dev/null && firewall-cmd --reload >/dev/null ;;
  esac && manifest_add fw "$1 $2"
}

fw_close() {
  case "$1" in
    ufw) ufw delete allow "$2" >/dev/null 2>&1 ;;
    firewalld) firewall-cmd --permanent --remove-port="$2" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null ;;
  esac
  manifest_del fw "$1 $2"
}

ports_wanted() {
  local id
  for id in $(protos_enabled); do echo "$(pget "$id" port)/$(pmeta "$id" l4)"; done
}

# 放行当前需要的端口（先询问），并撤销 pbox 以前放行、现在不再使用的端口。
fw_sync() {
  local be p want line
  be=$(fw_backend)
  want=$(ports_wanted)
  if [ -f "$MANIFEST" ]; then
    grep '^fw	' "$MANIFEST" | cut -f2 | while read -r line; do
      printf '%s\n' "$want" | grep -qxF "${line#* }" || fw_close "${line% *}" "${line#* }"
    done
  fi
  [ "$be" = none ] && return 0
  for p in $want; do
    fw_is_open "$be" "$p" && continue
    if confirm "$(t fw_open_q "$be" "$p")"; then
      fw_open "$be" "$p" || warn "$(t fw_open_fail "$p")"
    fi
  done
}
