# 只自动放行已经启用的 ufw 或 firewalld。不安装、不替换、不停用、不清空任何防火墙。
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

# 没有 ufw、firewalld 时，看 iptables、nftables 有没有把入站兜底拒绝（默认策略为丢弃，或最后一条无条件拒绝）。
# 这类规则写法太多，判断不了某个端口是否已放行，只能提醒用户自己处理。
# 有些服务商的系统镜像自带这种规则，例如末尾一条 -j REJECT。只拦异常包的规则（ct state invalid drop）不算
fw_other() {
  testing && { printf '%s' "${PBOX_TEST_FW_OTHER:-}"; return 0; }
  if has iptables && iptables -S INPUT 2>/dev/null | grep -Eq -- '^-P INPUT DROP|^-A INPUT -j (DROP|REJECT)'; then
    echo iptables
  elif has nft && nft list ruleset 2>/dev/null | awk '
      /^[[:space:]]*chain /{inp=0} /hook input/{inp=1; if (/policy drop/) f=1}
      inp && /^[[:space:]]*(counter( packets [0-9]+ bytes [0-9]+)? )?(drop|reject)/{f=1}
      END{exit !f}'; then
    echo nftables
  fi
  return 0
}

# 提醒用户手动放行，列出要放行的端口
fw_manual_note() {
  local o
  o=$(fw_other)
  [ -n "$o" ] && warn "$(t fw_manual "$o" "$(ports_wanted | tr '\n' ' ' | sed 's/ $//')")"
  return 0
}

fw_is_open() { # <后端> <端口/协议>，端口可以是 起:止
  case "$1" in
    ufw) ufw status | grep -Eq "^${2}[[:space:]]+ALLOW" ;;
    firewalld) firewall-cmd --query-port="$(printf '%s' "$2" | tr : -)" >/dev/null 2>&1 ;;
    *) return 0 ;;
  esac
}

fw_open() {
  case "$1" in
    ufw) ufw allow "$2" comment pbox >/dev/null ;;
    firewalld) firewall-cmd --permanent --add-port="$(printf '%s' "$2" | tr : -)" >/dev/null && firewall-cmd --reload >/dev/null ;;
  esac && manifest_add fw "$1 $2"
}

fw_close() {
  case "$1" in
    ufw) ufw delete allow "$2" >/dev/null 2>&1 ;;
    firewalld) firewall-cmd --permanent --remove-port="$(printf '%s' "$2" | tr : -)" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null ;;
  esac
  manifest_del fw "$1 $2"
}

ports_wanted() {
  local id r
  {
    for id in $(protos_enabled); do
      [ "$(pmeta "$id" local)" = 1 ] && continue
      echo "$(pget "$id" port)/$(pmeta "$id" l4)"
      [ "$(pmeta "$id" udp_too)" = 1 ] && echo "$(pget "$id" port)/udp"
    done
    relay_fwd_ports
    r=$(pget hysteria2 hop_range)
    [ -n "$r" ] && echo "${r%-*}:${r#*-}/udp"
    # 分流开着时 443 由 Nginx 监听，不论 Reality 在不在 443
    site_on_p && echo 443/tcp
    selfsub_port_on && echo "$(gget selfsub_port)/tcp"
    :
  } | awk '!seen[$0]++'
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
  [ "$be" = none ] && { fw_manual_note; return 0; }
  for p in $want; do
    fw_is_open "$be" "$p" && continue
    if confirm "$(t fw_open_q "$be" "$p")"; then
      fw_open "$be" "$p" || warn "$(t fw_open_fail "$p")"
    fi
  done
}
