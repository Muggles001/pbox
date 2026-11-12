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
  export PBOX_BACKUP_PASSWORD=vm-test
  check "备份" $P backup /tmp/pbox-vm.bin --yes
  check "卸载" $P uninstall --yes
  check "卸载后无残留" bash -c '! [ -e /etc/pbox ] && ! [ -e /usr/local/lib/pbox ] && ! [ -e /usr/local/bin/pbox ] && ! [ -e /etc/systemd/system/pbox-singbox.service ] && ! id pbox 2>/dev/null'
  check "从备份恢复到干净系统" $P restore /tmp/pbox-vm.bin --yes
  check "恢复后服务运行中" bash -c 'sleep 1; systemctl is-active --quiet pbox-singbox'
  $P uninstall --yes >/dev/null 2>&1
fi

echo
echo "通过 $pass，失败 $fail"
[ "$fail" = 0 ]
