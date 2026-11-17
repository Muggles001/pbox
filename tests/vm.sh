#!/usr/bin/env bash
# 真机测试：会真的安装内核、创建服务和账号，最后卸载。
# 只在可以随时重装的测试机或自动化流水线里运行，需要 root。
# 用法：sudo bash tests/vm.sh [--no-services]
#   --no-services  容器里没有 systemd 时使用：只验证下载、哈希、内核对配置的校验
set -uo pipefail
cd "$(dirname "$0")/.."
[ "$(id -u)" = 0 ] || { echo "需要 root" >&2; exit 1; }
[ -e /etc/pbox ] && { echo "/etc/pbox 已存在，拒绝在已安装的机器上运行" >&2; exit 1; }

P="bash dist/pbox.sh"
pass=0 fail=0
check() {
  local name="$1"
  shift
  if "$@" >/tmp/pbox-vm.log 2>&1; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n' "$name"; sed 's/^/       /' /tmp/pbox-vm.log | tail -15
  fi
}
listening() { ss -H -ln"$1" | awk '{print $4}' | grep -Eq "[:.]$2\$"; }
port_of() { sed -n 's/^port=//p' "/etc/pbox/state/protocols/$1.env"; }

if [ "${1:-}" = --no-services ]; then
  # 借用脚本自己的函数完成：下载并校验内核 → 渲染 → 让内核校验配置
  export PBOX_LANG=zh
  # shellcheck disable=SC1091
  . dist/pbox.sh
  lang_init
  # 容器里没有服务管理器，detect_sys 会直接退出，所以先在子进程里试
  if (detect_sys) >/dev/null 2>&1; then detect_sys; else
    OS_ID=container INIT=none PKG=none
    case "$(uname -m)" in x86_64) ARCH=amd64 ;; *) ARCH=arm64 ;; esac
  fi
  detect_ips
  [ -n "$IP4$IP6" ] || IP4=203.0.113.10
  ASSUME_YES=1
  txn_begin
  gset ip4 "$IP4"; gset ip6 "$IP6"; gset block_private 1; gset addr_mode split
  for id in $PRESET_RECOMMENDED; do : >"$CUR/protocols/$id.env"; pcall "$id" plan; done
  user_new default
  check "下载内核并通过哈希校验" cores_ensure
  check "sing-box 能运行" "$BINDIR/sing-box" version
  # 逐个实测内置候选，结果只作参考，用来修剪名单
  okc="" badc=""
  for d in $(reality_candidates); do
    if reality_check "$d" >/dev/null; then okc="$okc $d"; else badc="$badc $d"; fi
  done
  echo "  候选可用：$okc"
  echo "  候选不可用：$badc"
  check "实测挑选到伪装目标" bash -c '. dist/pbox.sh; d=$(reality_pick) && echo "$d"'
  for id in $(protos_enabled); do (pcall "$id" secrets) || fail=$((fail + 1)); done
  render_all "$ETC/.txn/generated"
  check "sing-box 接受生成的配置" core_validate singbox "$ETC/.txn/generated/sing-box"
  rm -rf /etc/pbox /usr/local/lib/pbox
else
  check "无人值守安装" $P install --yes
  check "sing-box 服务运行中" systemctl is-active --quiet pbox-singbox
  check "内核不是以 root 运行" bash -c '[ "$(ps -o user= -C sing-box | head -1)" = pbox ]'
  check "Reality 端口在监听" listening t "$(port_of reality-vision)"
  check "Hysteria2 端口在监听" listening u "$(port_of hysteria2)"
  check "状态目录只有 root 能读" bash -c '[ "$(stat -c %a /etc/pbox/state)" = 700 ]'
  check "入口命令可用" pbox version
  spid=$(pgrep -x sing-box)
  check "只改 Hysteria2 的端口" $P change hysteria2 port auto --yes
  check "改端口用的是热重载，内核进程没有换" bash -c "[ \"\$(pgrep -x sing-box)\" = '$spid' ]"
  check "改 Reality 端口后在新端口监听" bash -c "$P change reality-vision port 24443 --yes && sleep 1 && ss -H -lnt | grep -q ':24443 '"
  check "回滚" $P rollback
  check "体检全部通过（含两个协议的节点自测）" $P doctor
  $P doctor || true
  # 复现服务商模板的问题：解析配置只有 root 可读
  cat /etc/resolv.conf >/tmp/resolv.keep
  rm -f /etc/resolv.conf
  cp /tmp/resolv.keep /etc/resolv.conf
  chmod 600 /etc/resolv.conf
  check "解析配置只有 root 可读时，重新生效后节点仍然可用" bash -c "$P change hysteria2 port auto --yes && sleep 2 && $P doctor"
  chmod 644 /etc/resolv.conf
  check "开启端口跳跃后转发规则存在" bash -c "$P change hysteria2 hop on --yes && (nft list table inet pbox_hop || iptables -t nat -S PREROUTING | grep pbox-hop)"
  check "开启端口跳跃后体检仍全过" $P doctor
  check "关闭端口跳跃后规则消失" bash -c "$P change hysteria2 hop off --yes && ! nft list table inet pbox_hop 2>/dev/null && ! (iptables -t nat -S PREROUTING 2>/dev/null | grep -q pbox-hop)"
  check "添加 TUIC 与 AnyTLS 后体检全过（真实内核、真实连接）" bash -c "$P add tuic --yes && $P add anytls --yes && sleep 2 && $P doctor"
  check "删除它们" bash -c "$P del tuic --yes && $P del anytls --yes"
  check "添加第二个用户后体检全过" bash -c "$P user add bob --yes && sleep 2 && $P doctor"
  check "删除第二个用户" $P user del bob --yes
  slog=/var/log/pbox/pbox-singbox.log
  check "打开调试日志后到期检查的定时器在运行" bash -c "$P debug on 10 --yes && systemctl is-active --quiet pbox-debug.timer"
  check "定时器调用的检查能正常执行，没到期时不关" bash -c "systemctl start pbox-debug.service && grep -q '^debug_until=.' /etc/pbox/state/global.env"
  check "调试时节点自测的连接写进了日志" bash -c "$P doctor && grep -qi 'inbound' $slog"
  check "到期后检查会关掉、清空日志并撤掉定时器" bash -c "PBOX_TEST_NOW=\$((\$(date +%s) + 700)) $P debug check && ! grep -qi 'inbound' $slog && ! [ -e /etc/systemd/system/pbox-debug.timer ] && ! grep -q pbox-debug /etc/pbox/manifest"
  check "关闭后体检全过" $P doctor
  export PBOX_BACKUP_PASSWORD=vm-test
  check "备份" $P backup /tmp/pbox-vm.bin --yes
  check "卸载" $P uninstall --yes
  check "卸载后无残留" bash -c '! [ -e /etc/pbox ] && ! [ -e /usr/local/lib/pbox ] && ! [ -e /usr/local/bin/pbox ] && ! [ -e /etc/systemd/system/pbox-singbox.service ] && ! id pbox 2>/dev/null'
  check "从备份恢复到干净系统" $P restore /tmp/pbox-vm.bin --yes
  check "恢复后服务运行中" bash -c 'sleep 1; systemctl is-active --quiet pbox-singbox'
  # 自建订阅：流水线拿不到正式证书，用一张自签的 IP 证书代替，取订阅时把它当作信任的根
  gfile=/etc/pbox/state/global.env
  ca=/etc/pbox/certs/domain.crt
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 -subj /CN=127.0.0.1 \
    -addext subjectAltName=IP:127.0.0.1 -keyout /etc/pbox/certs/domain.key -out "$ca" 2>/dev/null
  sed -i '/^tls_domain=/d' "$gfile" && echo tls_domain=127.0.0.1 >>"$gfile"
  check "开启自建订阅后 Nginx 在单独的端口上运行" bash -c "$P sub self on --yes && sleep 1 && systemctl is-active --quiet pbox-nginx && ss -H -lnt | grep -q \":\$(sed -n 's/^selfsub_port=//p' $gfile) \""
  ssurl() { echo "https://127.0.0.1:$(sed -n 's/^selfsub_port=//p' "$gfile")/$1/clash"; }
  spath=$(sed -n 's/^sub_path=//p' /etc/pbox/state/users/default.env)
  check "用订阅地址取到的就是本机生成的订阅" bash -c "curl -sf --cacert $ca '$(ssurl "$spath")' | cmp - /etc/pbox/nodes/users/default/sub/clash"
  check "猜错路径得到 404" bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --cacert $ca '$(ssurl 0123456789abcdef0123456789abcdef)')\" = 404 ]"
  check "Nginx 不是以 root 运行" bash -c '[ "$(ps -o user= -C nginx | sort -u)" = pbox ]'
  check "换路径后旧地址立即失效" bash -c "$P sub self reset --yes >/dev/null && [ \"\$(curl -s -o /dev/null -w '%{http_code}' --cacert $ca '$(ssurl "$spath")')\" = 404 ]"
  check "关闭后 Nginx 服务撤掉" bash -c "$P sub self off --yes && ! systemctl is-active --quiet pbox-nginx && ! [ -e /etc/systemd/system/pbox-nginx.service ]"
  $P uninstall --yes >/dev/null 2>&1

  # 系统防火墙：只在流水线里打开，会改动本机的 ufw。先放行 SSH，免得在远程机器上把自己关在门外
  if [ "${PBOX_VM_UFW:-0}" = 1 ] && command -v ufw >/dev/null; then
    echo "ufw"
    ufw allow 22/tcp >/dev/null
    ufw --force enable >/dev/null
    allowed() { ufw status | grep -E "^$1 +ALLOW" >/dev/null; }
    check "ufw 开着时安装" $P install --yes
    check "放行了 Reality 与 Hysteria2 的端口" bash -c "$(declare -f allowed); allowed $(port_of reality-vision)/tcp && allowed $(port_of hysteria2)/udp"
    check "改端口后放行新的、撤销旧的" bash -c "$(declare -f allowed); $P change reality-vision port 24443 --yes && allowed 24443/tcp && ! allowed 443/tcp"
    check "端口跳跃放行整段" bash -c "$(declare -f allowed); $P change hysteria2 hop on --yes && r=\$(sed -n 's/^hop_range=//p' /etc/pbox/state/protocols/hysteria2.env) && allowed \${r%-*}:\${r#*-}/udp"
    check "ufw 下体检全过" $P doctor
    check "卸载后只剩自己加的 SSH 规则" bash -c "$P uninstall --yes && [ -z \"\$(ufw status | grep ALLOW | grep -v '^22/tcp')\" ]"
    ufw --force disable >/dev/null
    ufw delete allow 22/tcp >/dev/null
  fi

  # 服务商镜像常见的 iptables 兜底拒绝：pbox 不改它，只列出要手动放行的端口。保住本机回环、已建立的连接和 SSH
  if [ "${PBOX_VM_UFW:-0}" = 1 ] && command -v iptables >/dev/null && ! { command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; }; then
    echo "iptables 兜底拒绝"
    iptables -I INPUT 1 -i lo -j ACCEPT
    iptables -I INPUT 2 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -I INPUT 3 -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -j REJECT
    $P install --yes >/dev/null 2>&1
    check "体检指出只自动处理 ufw、firewalld，并列出端口" bash -c "o=\$($P doctor 2>&1); echo \"\$o\" | grep -q 'iptables 里有拦截入站的规则' && echo \"\$o\" | grep -q '$(port_of reality-vision)/tcp'"
    check "没有改动 iptables" bash -c "[ \$(iptables -S INPUT | grep -c -- '-j REJECT') = 1 ] && ! iptables -S INPUT | grep -q 'dport $(port_of reality-vision)'"
    $P uninstall --yes >/dev/null 2>&1
    iptables -D INPUT -j REJECT
    iptables -D INPUT -p tcp --dport 22 -j ACCEPT
    iptables -D INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -D INPUT -i lo -j ACCEPT
  fi
fi

echo
echo "通过 $pass，失败 $fail"
[ "$fail" = 0 ]
