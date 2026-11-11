#!/usr/bin/env bash
# 不需要 root、不碰系统的测试：在临时目录里跑状态、冲突、渲染、节点输出这几层逻辑。
# 真实的安装、服务、防火墙要在虚拟机里另测。
set -uo pipefail
cd "$(dirname "$0")/.."
./build.sh >/dev/null || exit 1

pass=0 fail=0
check() { # <说明> <命令...>
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass=$((pass + 1))
    printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n' "$name"
  fi
}
json_ok() { python3 -m json.tool "$1"; }

new_root() {
  export PBOX_ROOT
  PBOX_ROOT=$(mktemp -d)
  export PBOX_TEST=1 PBOX_LANG=zh PBOX_TEST_IP4=203.0.113.10 PBOX_TEST_IP6=2001:db8::10
  export PBOX_TEST_SNI=www.example.org PBOX_TEST_PORTS=""
}
pbox() { bash dist/pbox.sh "$@"; }
E() { echo "$PBOX_ROOT/etc/pbox"; }

echo "文案"
keys_used=$(grep -rohE '\$\(t [a-z][a-z0-9_]*' src | awk '{print $2}' | sort -u)
for lang in zh en; do
  missing=""
  for k in $keys_used; do grep -q "T_$k=" "src/i18n/$lang.sh" || missing="$missing $k"; done
  check "$lang 文案齐全${missing:+（缺：$missing）}" test -z "$missing"
done
check "中英文案的键一致" diff <(grep -oE 'T_[a-z0-9_]+=' src/i18n/zh.sh | sort) <(grep -oE 'T_[a-z0-9_]+=' src/i18n/en.sh | sort)

echo "安装（推荐档）"
new_root
check "无人值守安装成功" pbox install --yes
check "Reality 用 TCP 443" grep -qx 'port=443' "$(E)/state/protocols/reality-vision.env"
check "Hysteria2 用 UDP 443" grep -qx 'port=443' "$(E)/state/protocols/hysteria2.env"
check "Xray 基础配置是合法 JSON" json_ok "$(E)/generated/xray/00_base.json"
check "Reality 入站是合法 JSON" json_ok "$(E)/generated/xray/10_reality-vision.json"
check "sing-box 基础配置是合法 JSON" json_ok "$(E)/generated/sing-box/00_base.json"
check "Hysteria2 入站是合法 JSON" json_ok "$(E)/generated/sing-box/10_hysteria2.json"
check "sing-box 客户端配置是合法 JSON" json_ok "$(E)/nodes/sing-box.json"
check "默认分开输出：4 条链接" test "$(wc -l <"$(E)/nodes/links.txt")" -eq 4
check "IPv6 地址带方括号" grep -q '@\[2001:db8::10\]:443' "$(E)/nodes/links.txt"
check "Hysteria2 链接带指纹固定且不跳过验证" sh -c "grep hysteria2:// '$(E)/nodes/links.txt' | grep -q pinSHA256= && ! grep -q insecure=1 '$(E)/nodes/links.txt'"
check "Mihomo 配置含 4 个节点" test "$(grep -c '^    server:' "$(E)/nodes/mihomo.yaml")" -eq 4
check "自签证书已生成" test -s "$(E)/certs/hysteria2.crt"
check "默认屏蔽内网地址" grep -q '"10.0.0.0/8"' "$(E)/generated/xray/00_base.json"
first_root="$PBOX_ROOT"

echo "特征审计"
new_root
pbox install --yes >/dev/null 2>&1
for k in private_key public_key short_id; do
  check "两次安装的 $k 不同" bash -c "! diff <(grep ^$k= '$first_root/etc/pbox/state/protocols/reality-vision.env') <(grep ^$k= '$(E)/state/protocols/reality-vision.env')"
done
check "两次安装的用户凭据不同" sh -c "! diff '$first_root/etc/pbox/state/users/default.env' '$(E)/state/users/default.env'"
check "两次安装的证书指纹不同" bash -c "! diff <(grep ^cert_sha256= '$first_root/etc/pbox/state/protocols/hysteria2.env') <(grep ^cert_sha256= '$(E)/state/protocols/hysteria2.env')"
check "源码里没有写死的 UUID" sh -c "! grep -rEq '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' src"

echo "端口占用与冲突"
new_root
export PBOX_TEST_PORTS="tcp/443 udp/443"
check "443 被占时仍能安装" pbox install --yes
check "Reality 退到 8443" grep -qx 'port=8443' "$(E)/state/protocols/reality-vision.env"
check "Hysteria2 改用随机端口" sh -c "! grep -qx 'port=443' '$(E)/state/protocols/hysteria2.env'"
export PBOX_TEST_PORTS="tcp/9999"
check "改到被占用的端口时，--yes 报错退出" sh -c "! bash dist/pbox.sh change reality-vision port 9999 --yes"
check "报错后端口保持不变" grep -qx 'port=8443' "$(E)/state/protocols/reality-vision.env"
export PBOX_TEST_PORTS=""

echo "修改与回滚"
check "改端口成功" pbox change reality-vision port 12345 --yes
check "新端口写入生成的配置" grep -q '"port": 12345' "$(E)/generated/xray/10_reality-vision.json"
check "链接随之更新" grep -q ':12345?' "$(E)/nodes/links.txt"
check "只改 Reality 时 sing-box 的生成物不变" diff -r "$(E)/previous/generated/sing-box" "$(E)/generated/sing-box"
check "预览不落盘" sh -c "bash dist/pbox.sh change reality-vision port 23456 --dry-run --yes && grep -qx port=12345 '$(E)/state/protocols/reality-vision.env'"
check "回滚到上一份配置" pbox rollback
check "回滚后端口还原" grep -qx 'port=8443' "$(E)/state/protocols/reality-vision.env"
check "非法端口被拒绝" sh -c "! bash dist/pbox.sh change reality-vision port 99999 --yes"
check "删除 Hysteria2 成功" pbox del hysteria2 --yes
check "删除后不再生成 sing-box 配置" test ! -d "$(E)/generated/sing-box"
check "再删最后一个协议被拒绝" sh -c "! bash dist/pbox.sh del reality-vision --yes"
check "重新添加 Hysteria2" pbox add hysteria2 --yes

echo "节点地址模式"
export PBOX_TEST_DNS_A=203.0.113.10 PBOX_TEST_DNS_AAAA=""
check "缺 AAAA 记录时拒绝 all 模式" sh -c "! bash dist/pbox.sh set addr-mode all node.example.org --yes"
export PBOX_TEST_DNS_AAAA=2001:db8::10
check "记录齐全时 all 模式成功" pbox set addr-mode all node.example.org --yes
check "all 模式：每个协议 3 条链接" test "$(wc -l <"$(E)/nodes/links.txt")" -eq 6
check "merged 属于软冲突，--yes 不代答" sh -c "! bash dist/pbox.sh set addr-mode merged node.example.org --yes"
check "关闭屏蔽内网属于软冲突，--yes 不代答" sh -c "! bash dist/pbox.sh set block-private off --yes"

echo "自定义片段、重置、备份"
mkdir -p "$(E)/custom/xray"
echo '{"log": {"loglevel": "warning"}}' >"$(E)/custom/xray/mine.json"
check "自定义片段随生成物一起加载" sh -c "bash dist/pbox.sh change hysteria2 port auto --yes && test -f '$(E)/generated/xray/90_custom_mine.json'"
old_uuid=$(grep ^uuid= "$(E)/state/users/default.env")
check "重置密钥后 UUID 改变" sh -c "bash dist/pbox.sh reset-keys --yes && ! grep -qx '$old_uuid' '$(E)/state/users/default.env'"
export PBOX_BACKUP_PASSWORD=test-pass
bk="$PBOX_ROOT/bk.bin"
check "备份成功且不是明文" sh -c "bash dist/pbox.sh backup '$bk' --yes && ! grep -q uuid '$bk'"
src_uuid=$(grep ^uuid= "$(E)/state/users/default.env")
new_root
export PBOX_BACKUP_PASSWORD=test-pass
check "在新环境恢复成功" pbox restore "$bk" --yes
check "恢复后 UUID 与原来一致" grep -qx "$src_uuid" "$(E)/state/users/default.env"
export PBOX_BACKUP_PASSWORD=wrong
new_root
check "密码错误时拒绝恢复" sh -c "! bash dist/pbox.sh restore '$bk' --yes"

echo "地区缩写"
new_root
export PBOX_TEST_REGION=HK
check "安装时写入地区" bash -c "bash dist/pbox.sh install --yes && grep -qx region=HK '$PBOX_ROOT/etc/pbox/state/global.env'"
check "节点名带地区缩写" grep -q '#HK-Reality-IPv4' "$(E)/nodes/links.txt"
check "可以手动改地区" bash -c "bash dist/pbox.sh set region JP --yes && grep -q '#JP-Hysteria2-IPv4' '$(E)/nodes/links.txt'"
check "可以关闭地区" bash -c "bash dist/pbox.sh set region off --yes && grep -q '#Reality-IPv4' '$(E)/nodes/links.txt'"
unset PBOX_TEST_REGION

echo "菜单"
check "主菜单能画出来并正常退出" bash -c "printf '0\n' | bash dist/pbox.sh | grep -q 'VLESS-Reality-Vision'"
check "进协议管理、进某个协议、逐级返回" bash -c "printf '3\n1\n0\n0\n0\n' | bash dist/pbox.sh >/dev/null"
check "进设置再返回" bash -c "printf '4\n0\n0\n' | bash dist/pbox.sh >/dev/null"

echo "NAT 机器"
new_root
export PBOX_TEST_NAT=1 PBOX_REALITY_EXT_PORT=31001
check "只给了 Reality 的外网端口时安装成功" pbox install --yes
check "链接里是外网端口" grep -q '@203.0.113.10:31001?' "$(E)/nodes/links.txt"
check "内核监听的仍是内网端口" grep -q '"port": 443' "$(E)/generated/xray/10_reality-vision.json"
check "没给外网端口的 Hysteria2 没有安装" test ! -e "$(E)/state/protocols/hysteria2.env"
check "事后可以修改外网端口" bash -c "bash dist/pbox.sh change reality-vision ext-port 31002 --yes && grep -q ':31002?' '$(E)/nodes/links.txt'"
unset PBOX_TEST_NAT PBOX_REALITY_EXT_PORT

echo "卸载"
new_root
pbox install --yes >/dev/null 2>&1
check "卸载成功" pbox uninstall --yes
check "卸载后配置目录不存在" test ! -e "$(E)"

echo
echo "通过 $pass，失败 $fail"
[ "$fail" = 0 ]
