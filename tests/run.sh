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

echo "版本比较"
eval "$(sed -n '/^ver_newer()/,/^}/p' src/lib/update.sh)"
check "线上更新才算有更新" ver_newer v0.3.0 0.2.0
check "多位数按数值比较" ver_newer v0.10.0 0.9.9
vn_not() { ! ver_newer "$@"; }
check "版本相同不算" vn_not v0.3.0 0.3.0
check "本机比线上新时不提示" vn_not v0.2.0 0.3.0

eval "$(sed -n '/^update_changes()/,/^}/p' src/lib/update.sh)"
say() { printf '%s\n' "$*"; }
t() { printf 'more %s' "$2"; }
cl=$(mktemp)
printf 'v0.3.0\t新增丙\nv0.3.0\t修好乙\nv0.2.0\t新增甲\nv0.1.0\t最初\n' >"$cl"
uc_tags() { UPD_SHOW_MAX=12 update_changes "$cl" "$1" | awk '{print $1}' | tr '\n' ' '; }
uc_short() { local out; out=$(UPD_SHOW_MAX=2 update_changes "$cl" 0.1.0); [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 3 ] && printf '%s\n' "$out" | tail -1 | grep -q 'more 1'; }
uc_none() { ! UPD_SHOW_MAX=12 update_changes "$cl" 0.3.0; }
check "改动清单只列比本机新的版本" test "$(uc_tags 0.1.0)" = 'v0.3.0 v0.3.0 v0.2.0 '
check "改动清单太长时只列前几条并说还剩几条" uc_short
check "已是最新时没有可列的" uc_none
unset -f say t

echo "安装（推荐档）"
new_root
check "自选协议时一路回车，只开推荐的" bash -c "R=\$(mktemp -d) && { printf 'c\\n'; yes ''; } | head -60 | PBOX_ROOT=\$R bash dist/pbox.sh install >/dev/null 2>&1; [ \"\$(ls \$R/etc/pbox/state/protocols | tr '\\n' ' ')\" = 'hysteria2.env reality-vision.env ' ]"
check "无人值守安装成功" pbox install --yes
check "Reality 用 TCP 443" grep -qx 'port=443' "$(E)/state/protocols/reality-vision.env"
check "Hysteria2 用 UDP 443" grep -qx 'port=443' "$(E)/state/protocols/hysteria2.env"
check "Reality 入站是合法 JSON" json_ok "$(E)/generated/sing-box/10_reality-vision.json"
check "sing-box 基础配置是合法 JSON" json_ok "$(E)/generated/sing-box/00_base.json"
check "Hysteria2 入站是合法 JSON" json_ok "$(E)/generated/sing-box/10_hysteria2.json"
check "sing-box 客户端配置是合法 JSON" json_ok "$(E)/nodes/sing-box.json"
check "默认分开输出：4 条链接" test "$(wc -l <"$(E)/nodes/links.txt")" -eq 4
check "IPv6 地址带方括号" grep -q '@\[2001:db8::10\]:443' "$(E)/nodes/links.txt"
check "Hysteria2 链接带指纹固定且不跳过验证" sh -c "grep hysteria2:// '$(E)/nodes/links.txt' | grep -q pinSHA256= && ! grep -q insecure=1 '$(E)/nodes/links.txt'"
check "Mihomo 配置含 4 个节点" test "$(grep -c '^    server:' "$(E)/nodes/mihomo.yaml")" -eq 4
check "自签证书已生成" test -s "$(E)/certs/hysteria2.crt"
check "默认屏蔽内网地址" grep -q 'ip_is_private' "$(E)/generated/sing-box/00_base.json"
first_root="$PBOX_ROOT"

check "推荐档只用一个内核" test ! -d "$(E)/generated/xray"

echo "特征审计"
new_root
pbox install --yes >/dev/null 2>&1
for k in private_key public_key short_id; do
  check "两次安装的 $k 不同" bash -c "! diff <(grep ^$k= '$first_root/etc/pbox/state/protocols/reality-vision.env') <(grep ^$k= '$(E)/state/protocols/reality-vision.env')"
done
check "两次安装的用户凭据不同" sh -c "! diff '$first_root/etc/pbox/state/users/default.env' '$(E)/state/users/default.env'"
check "两次安装的证书指纹不同" bash -c "! diff <(grep ^cert_sha256= '$first_root/etc/pbox/state/protocols/hysteria2.env') <(grep ^cert_sha256= '$(E)/state/protocols/hysteria2.env')"
check "源码里没有写死的 UUID（本机回环握手测试用的占位值除外）" sh -c "! grep -rE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' src | grep -v '00000000-0000-4000-8000-000000000001' | grep -q ."

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
check "新端口写入生成的配置" grep -q '"listen_port": 12345' "$(E)/generated/sing-box/10_reality-vision.json"
check "链接随之更新" grep -q ':12345?' "$(E)/nodes/links.txt"
check "预览不落盘" sh -c "bash dist/pbox.sh change reality-vision port 23456 --dry-run --yes && grep -qx port=12345 '$(E)/state/protocols/reality-vision.env'"
check "回滚到上一份配置" pbox rollback
check "回滚后端口还原" grep -qx 'port=8443' "$(E)/state/protocols/reality-vision.env"
check "非法端口被拒绝" sh -c "! bash dist/pbox.sh change reality-vision port 99999 --yes"
check "删除 Hysteria2 成功" pbox del hysteria2 --yes
check "删除后不再生成它的入站配置" test ! -e "$(E)/generated/sing-box/10_hysteria2.json"
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
mkdir -p "$(E)/custom/sing-box"
echo '{"log": {"level": "warn"}}' >"$(E)/custom/sing-box/mine.json"
check "自定义片段随生成物一起加载" sh -c "bash dist/pbox.sh change hysteria2 port auto --yes && test -f '$(E)/generated/sing-box/90_custom_mine.json'"
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

echo "订阅文件"
check "通用订阅解码后就是全部链接" bash -c "openssl base64 -d -A <'$(E)/nodes/sub/v2ray' | diff - '$(E)/nodes/links.txt'"
check "Clash 与 sing-box 订阅文件已生成" bash -c "test -s '$(E)/nodes/sub/clash' && python3 -m json.tool '$(E)/nodes/sub/singbox'"
check "未开启订阅时查看地址会提示" bash -c "! bash dist/pbox.sh sub show"
check "项目路径不合法时被拒绝" bash -c "! PBOX_SUB_PROJECT='bad path' PBOX_SUB_WTOKEN=a PBOX_SUB_RTOKEN=b bash dist/pbox.sh sub setup"

echo "WARP 出口"
check "开启 WARP" pbox warp on --yes
check "开启后基础配置仍是合法 JSON" json_ok "$(E)/generated/sing-box/00_base.json"
check "默认按网站分流" grep -q '"domain_suffix": \["openai.com"' "$(E)/generated/sing-box/00_base.json"
check "可以改分流的网站" bash -c "bash dist/pbox.sh warp domains example.com,example.org --yes && grep -q '\"example.com\", \"example.org\"' '$(E)/generated/sing-box/00_base.json'"
check "非法域名被拒绝" bash -c "! bash dist/pbox.sh warp domains 'bad domain' --yes"
check "切到全部网站" bash -c "bash dist/pbox.sh warp all --yes && grep -q '\"final\": \"warp\"' '$(E)/generated/sing-box/00_base.json' && python3 -m json.tool '$(E)/generated/sing-box/00_base.json'"
check "关闭后配置里不再有 WARP" bash -c "bash dist/pbox.sh warp off --yes && ! grep -q warp '$(E)/generated/sing-box/00_base.json'"

echo "Argo 节点与优选地址"
check "添加 Argo 节点" pbox add vless-ws --yes
check "入站只监听本机" grep -q '"listen": "127.0.0.1"' "$(E)/generated/sing-box/10_vless-ws.json"
check "链接用隧道域名作地址和 Host" grep -q '@example-test.trycloudflare.com:443?.*host=example-test.trycloudflare.com.*#.*Argo-Temp$' "$(E)/nodes/links.txt"
check "设置优选后多出一个优选节点，直连的仍保留" bash -c "bash dist/pbox.sh change vless-ws cdn www.visa.com.sg --yes && grep -q '@www.visa.com.sg:443?.*sni=example-test.trycloudflare.com.*Argo-Temp-Pref' '$(E)/nodes/links.txt' && grep -q '@example-test.trycloudflare.com:443.*Argo-Temp\$' '$(E)/nodes/links.txt'"
check "加上固定隧道后共四个 Argo 节点" bash -c "PBOX_ARGO_TOKEN=eyJhIjoiMTIzNDU2Nzg5MGFiY2RlZiJ9 bash dist/pbox.sh argo fixed t.example.org --yes && test \"\$(grep -c Argo- '$(E)/nodes/links.txt')\" -eq 4 && grep -q 'sni=t.example.org.*Argo-Fixed-Pref' '$(E)/nodes/links.txt'"
check "精简时固定隧道和临时隧道各列一个，都用优选" bash -c "bash dist/pbox.sh set compact-nodes on --yes && l='$(E)/nodes/links.txt' && [ \"\$(grep -c Argo- \$l)\" = 2 ] && grep -q 'Argo-Fixed-Pref\$' \$l && grep -q 'Argo-Temp-Pref\$' \$l && bash dist/pbox.sh set compact-nodes off --yes"
check "令牌不出现在生成的节点和内核配置里" bash -c "! grep -rq eyJhIjoi '$(E)/nodes' '$(E)/generated'"
check "交互设置：先填令牌、再填域名" bash -c "printf 'eyJhIjoiYWJjZGVmMTIzNDU2Nzg5MCJ9\nt2.example.org\n' | bash dist/pbox.sh argo fixed >'$PBOX_ROOT/out.txt' 2>&1 && grep -q 'sni=t2.example.org' '$(E)/nodes/links.txt' && grep -q 'localhost:' '$PBOX_ROOT/out.txt'"
check "非法令牌被拒绝" bash -c "! PBOX_ARGO_TOKEN='bad token' bash dist/pbox.sh argo fixed t.example.org --yes"
check "可以只留固定隧道" bash -c "bash dist/pbox.sh argo temp off --yes && ! grep -q Argo-Temp '$(E)/nodes/links.txt'"
check "两个隧道不能都关" bash -c "! bash dist/pbox.sh argo fixed off --yes"
check "恢复临时隧道并关闭固定隧道" bash -c "bash dist/pbox.sh argo temp on --yes && bash dist/pbox.sh argo fixed off --yes && ! grep -q Argo-Fixed '$(E)/nodes/links.txt'"
check "客户端配置仍合法" bash -c "python3 -m json.tool '$(E)/nodes/sing-box.json' && grep -q 'Host: \"example-test.trycloudflare.com\"' '$(E)/nodes/mihomo.yaml'"
check "关闭优选后只剩直连节点" bash -c "bash dist/pbox.sh change vless-ws cdn off --yes && ! grep -q Pref '$(E)/nodes/links.txt'"
check "WARP 网站名单可恢复默认" bash -c "bash dist/pbox.sh warp on --yes && bash dist/pbox.sh warp domains a.example.com --yes && bash dist/pbox.sh warp domains default --yes && grep -q openai.com '$(E)/generated/sing-box/00_base.json' && bash dist/pbox.sh warp off --yes"
check "删除 Argo 节点" pbox del vless-ws --yes

echo "进阶选项"
check "开启 Hysteria2 混淆" pbox change hysteria2 obfs on --yes
check "服务端、链接、两种客户端配置都带上混淆" bash -c "grep -q salamander '$(E)/generated/sing-box/10_hysteria2.json' && grep -q 'obfs=salamander&obfs-password=' '$(E)/nodes/links.txt' && grep -q 'obfs: salamander' '$(E)/nodes/mihomo.yaml' && python3 -m json.tool '$(E)/nodes/sing-box.json' && python3 -m json.tool '$(E)/generated/sing-box/10_hysteria2.json'"
check "关闭混淆后不留痕迹" bash -c "bash dist/pbox.sh change hysteria2 obfs off --yes && ! grep -rq salamander '$(E)/generated' '$(E)/nodes'"
check "非法的 WS 路径被拒绝" bash -c "bash dist/pbox.sh add vless-ws --yes && ! bash dist/pbox.sh change vless-ws path 'no slash' --yes"
check "可以自定义 WS 路径" bash -c "bash dist/pbox.sh change vless-ws path /my-path_1 --yes && grep -q '\"path\": \"/my-path_1\"' '$(E)/generated/sing-box/10_vless-ws.json' && grep -q 'path=%2Fmy-path_1' '$(E)/nodes/links.txt' && bash dist/pbox.sh del vless-ws --yes"

echo "TUIC 与 AnyTLS"
check "添加 TUIC" pbox add tuic --yes
check "添加 AnyTLS" pbox add anytls --yes
check "两个入站都是合法 JSON" bash -c "python3 -m json.tool '$(E)/generated/sing-box/10_tuic.json' && python3 -m json.tool '$(E)/generated/sing-box/10_anytls.json'"
check "AnyTLS 没有去抢 Reality 的 443" bash -c "! grep -qx port=443 '$(E)/state/protocols/anytls.env'"
check "TUIC 没有去抢 Hysteria2 的 UDP 443" bash -c "! grep -qx port=443 '$(E)/state/protocols/tuic.env'"
check "链接、Clash、sing-box 配置里都有这两个节点" bash -c "grep -q '^tuic://' '$(E)/nodes/links.txt' && grep -q '^anytls://' '$(E)/nodes/links.txt' && grep -q 'type: tuic' '$(E)/nodes/mihomo.yaml' && grep -q 'type: anytls' '$(E)/nodes/mihomo.yaml' && python3 -m json.tool '$(E)/nodes/sing-box.json'"
check "Clash 与 sing-box 配置里用的是指纹固定" bash -c "! grep -q skip-cert-verify '$(E)/nodes/mihomo.yaml' && [ \"\$(grep -c certificate_public_key_sha256 '$(E)/nodes/sing-box.json')\" -ge 3 ]"
check "可以改 TUIC 的拥塞算法" bash -c "bash dist/pbox.sh change tuic cc cubic --yes && grep -q '\"congestion_control\": \"cubic\"' '$(E)/generated/sing-box/10_tuic.json'"
check "非法的拥塞算法被拒绝" bash -c "! bash dist/pbox.sh change tuic cc fast --yes"
check "开启端口跳跃时自动避开 TUIC 的端口" bash -c "bash dist/pbox.sh change hysteria2 hop on --yes && bash dist/pbox.sh change hysteria2 hop off --yes"
check "删除这两个协议" bash -c "bash dist/pbox.sh del tuic --yes && bash dist/pbox.sh del anytls --yes"

echo "中断后的恢复"
mv "$(E)/state" "$(E)/state.old"
check "状态目录在替换途中丢失时，下次启动自动复原" bash -c "bash dist/pbox.sh nodes >/dev/null && test -d '$(E)/state' && ! test -e '$(E)/state.old'"

echo "多用户"
d_uuid=$(sed -n 's/^uuid=//p' "$(E)/state/users/default.env")
check "添加用户" pbox user add alice --yes
a_uuid=$(sed -n 's/^uuid=//p' "$(E)/state/users/alice.env")
check "两人的凭据不同" test "$d_uuid" != "$a_uuid"
check "内核配置里有两个用户" bash -c "grep -q '$d_uuid' '$(E)/generated/sing-box/10_reality-vision.json' && grep -q '$a_uuid' '$(E)/generated/sing-box/10_reality-vision.json'"
check "各人的节点文件只含自己的凭据" bash -c "grep -q '$a_uuid' '$(E)/nodes/users/alice/links.txt' && ! grep -q '$d_uuid' '$(E)/nodes/users/alice/links.txt' && ! grep -q '$a_uuid' '$(E)/nodes/users/default/links.txt'"
check "各人的客户端配置都合法" bash -c "python3 -m json.tool '$(E)/nodes/users/alice/sing-box.json' && python3 -m json.tool '$(E)/nodes/sing-box.json'"
check "汇总里用用户名区分节点" bash -c "grep -q -- '-alice\$' '$(E)/nodes/links.txt' && grep -q -- '-default\$' '$(E)/nodes/links.txt'"
check "各人有自己的订阅文件" bash -c "openssl base64 -d -A <'$(E)/nodes/users/alice/sub/v2ray' | diff - '$(E)/nodes/users/alice/links.txt'"
check "重名被拒绝" bash -c "! bash dist/pbox.sh user add alice --yes"
check "非法用户名被拒绝" bash -c "! bash dist/pbox.sh user add bad.name --yes && ! bash dist/pbox.sh user add this-name-is-way-too-long --yes"
check "重置某人的凭据不影响别人" bash -c "bash dist/pbox.sh user reset alice --yes && ! grep -q '$a_uuid' '$(E)/state/users/alice.env' && grep -q '$d_uuid' '$(E)/state/users/default.env'"
check "删除用户后内核配置里不再有他" bash -c "bash dist/pbox.sh user del alice --yes && ! grep -q alice '$(E)/generated/sing-box/10_reality-vision.json' && ! test -e '$(E)/nodes/users/alice'"
check "删除后节点名恢复为不带用户名" bash -c "! grep -q -- '-default\$' '$(E)/nodes/links.txt'"
check "最后一个用户不能删" bash -c "! bash dist/pbox.sh user del default --yes"

echo "端口跳跃"
check "开启端口跳跃" pbox change hysteria2 hop 30000-30999 --yes
check "链接里带上跳跃范围" grep -q ':443/?.*&mport=30000-30999#' "$(E)/nodes/links.txt"
check "客户端配置仍是合法 JSON" json_ok "$(E)/nodes/sing-box.json"
check "范围盖住自己的端口时被拒绝" bash -c "! bash dist/pbox.sh change hysteria2 hop 400-500 --yes"
check "关闭端口跳跃" bash -c "bash dist/pbox.sh change hysteria2 hop off --yes && ! grep -q 30000 '$(E)/nodes/links.txt'"

echo "内网地址的云主机"
new_root
export PBOX_TEST_NAT=1
check "无人值守且没给外网端口时，按普通云主机安装" pbox install --yes
check "两个协议都装上了" test -e "$(E)/state/protocols/hysteria2.env"
unset PBOX_TEST_NAT

echo "NAT 机器"
new_root
export PBOX_TEST_NAT=1 PBOX_REALITY_EXT_PORT=31001
check "只给了 Reality 的外网端口时安装成功" pbox install --yes
check "链接里是外网端口" grep -q '@203.0.113.10:31001?' "$(E)/nodes/links.txt"
check "内核监听的仍是内网端口" grep -q '"listen_port": 443' "$(E)/generated/sing-box/10_reality-vision.json"
check "没给外网端口的 Hysteria2 没有安装" test ! -e "$(E)/state/protocols/hysteria2.env"
check "事后可以修改外网端口" bash -c "bash dist/pbox.sh change reality-vision ext-port 31002 --yes && grep -q ':31002?' '$(E)/nodes/links.txt'"
check "两个 TCP 协议不能写同一个外网端口" bash -c "bash dist/pbox.sh add anytls --yes && ! bash dist/pbox.sh change anytls ext-port 31002 --yes && ! grep -q ext_port '$(E)/state/protocols/anytls.env'"
check "TCP 和 UDP 可以用同一个外网端口号" bash -c "bash dist/pbox.sh add hysteria2 --yes && bash dist/pbox.sh change hysteria2 ext-port 31002 --yes"
unset PBOX_TEST_NAT PBOX_REALITY_EXT_PORT

echo "每个用户的协议名单"
new_root
pbox install --yes >/dev/null 2>&1
check "添加只能用 Hysteria2 的用户" pbox user add bob hysteria2 --yes
b_uuid=$(sed -n 's/^uuid=//p' "$(E)/state/users/bob.env")
b_pass=$(sed -n 's/^password=//p' "$(E)/state/users/bob.env")
check "名单外的协议里没有他的凭据" bash -c "! grep -q '$b_uuid' '$(E)/generated/sing-box/10_reality-vision.json' && grep -q '$b_pass' '$(E)/generated/sing-box/'*hysteria2.json"
check "他的节点里只有名单内的协议" bash -c "grep -q '^hysteria2://' '$(E)/nodes/users/bob/links.txt' && ! grep -q '^vless://' '$(E)/nodes/users/bob/links.txt'"
check "他的客户端配置仍然合法" json_ok "$(E)/nodes/users/bob/sing-box.json"
check "放开为全部协议" bash -c "bash dist/pbox.sh user protocols bob all --yes && grep -q '$b_uuid' '$(E)/generated/sing-box/10_reality-vision.json'"
check "不认识的协议名被拒绝" bash -c "! bash dist/pbox.sh user protocols bob nosuch --yes"
check "不能让某个协议没有任何用户" bash -c "bash dist/pbox.sh user del bob --yes && ! bash dist/pbox.sh user protocols default hysteria2 --yes"

echo "多台机器合并订阅"
export PBOX_SUB_DIR PBOX_SUB_PROJECT=someone/subs PBOX_SUB_WTOKEN=w PBOX_SUB_RTOKEN=r PBOX_TEST_REGION=JP
PBOX_SUB_DIR=$(mktemp -d)
new_root
A="$PBOX_ROOT"
pbox install --yes >/dev/null 2>&1
check "第一台开启订阅" pbox sub setup --yes
check "只有一台时订阅就是它自己的节点" bash -c "openssl base64 -d -A <'$PBOX_SUB_DIR/v2ray' | diff - '$A/etc/pbox/nodes/users/default/links.txt'"
new_root
B="$PBOX_ROOT"
export PBOX_TEST_IP4=203.0.113.20 PBOX_TEST_IP6=""
pbox install --yes >/dev/null 2>&1
check "第二台填同一个仓库" pbox sub setup --yes
check "标签相同时后加入的自动改名" bash -c "grep -q '^region=JP2$' '$B/etc/pbox/state/global.env' && grep -q '#JP2-' '$B/etc/pbox/nodes/links.txt'"
check "订阅里是两台机器的节点" bash -c "openssl base64 -d -A <'$PBOX_SUB_DIR/v2ray' | diff - <(cat '$A/etc/pbox/nodes/users/default/links.txt' '$B/etc/pbox/nodes/users/default/links.txt')"
check "合并后的 sing-box 配置合法且节点不重名" bash -c "python3 -c \"
import json,sys
o=json.load(open('$PBOX_SUB_DIR/singbox'))['outbounds']
t=[x['tag'] for x in o]
assert len(t)==len(set(t)) and any(x.startswith('JP2-') for x in t) and any(x.startswith('JP-') for x in t)
assert sorted(o[0]['outbounds'])==sorted(x for x in t if x not in ('proxy','direct'))
\""
check "合并后的 Clash 配置里两台都在" bash -c "grep -q 'name: \"\\?JP-' '$PBOX_SUB_DIR/clash' && grep -q 'name: \"\\?JP2-' '$PBOX_SUB_DIR/clash'"
check "更新后重新合并订阅，即使本机节点没变" bash -c "echo stale >'$PBOX_SUB_DIR/clash' && PBOX_ROOT='$A' bash dist/pbox.sh post-update --yes && grep -q 'name: \"\\?JP2-' '$PBOX_SUB_DIR/clash'"
check "同名用户在两台机器上共用一个订阅" bash -c "
  PBOX_ROOT='$A' bash dist/pbox.sh user add carol --yes &&
  PBOX_ROOT='$B' bash dist/pbox.sh user add carol hysteria2 --yes &&
  k=\$(sed -n 's/^sub_key=//p' '$A/etc/pbox/state/users/carol.env') &&
  test \"\$k\" = \"\$(sed -n 's/^sub_key=//p' '$B/etc/pbox/state/users/carol.env')\" &&
  openssl base64 -d -A <\"$PBOX_SUB_DIR/v2ray-\$k\" | diff - <(cat '$A/etc/pbox/nodes/users/carol/links.txt' '$B/etc/pbox/nodes/users/carol/links.txt')"
c_key=$(sed -n 's/^sub_key=//p' "$A/etc/pbox/state/users/carol.env")
check "别人的订阅里没有她的凭据" bash -c "! openssl base64 -d -A <'$PBOX_SUB_DIR/v2ray' | grep -q \"\$(sed -n 's/^uuid=//p' '$A/etc/pbox/state/users/carol.env')\""
check "一台删了她，另一台的还在" bash -c "PBOX_ROOT='$A' bash dist/pbox.sh user del carol --yes && openssl base64 -d -A <'$PBOX_SUB_DIR/v2ray-$c_key' | diff - '$B/etc/pbox/nodes/users/carol/links.txt'"
check "两台都删了，订阅文件也删掉" bash -c "PBOX_ROOT='$B' bash dist/pbox.sh user del carol --yes && ! test -e '$PBOX_SUB_DIR/v2ray-$c_key' && ! grep -q carol '$PBOX_SUB_DIR/pbox-index'"
check "第一台的节点变了，合并结果跟着变" bash -c "PBOX_ROOT='$A' bash dist/pbox.sh change hysteria2 port 4443 --yes && openssl base64 -d -A <'$PBOX_SUB_DIR/v2ray' | grep -q ':4443'"
check "用加入命令加入等同于手动填写" bash -c "
  code=\$(PBOX_ROOT='$A' bash dist/pbox.sh sub invite | sed -n 's/.*pbox sub join //p') && test -n \"\$code\" &&
  env -u PBOX_SUB_PROJECT -u PBOX_SUB_WTOKEN -u PBOX_SUB_RTOKEN PBOX_ROOT='$B' bash dist/pbox.sh sub join \"\$code\" --yes &&
  grep -q '^sub_project=someone/subs$' '$B/etc/pbox/state/global.env'"
check "残缺的加入命令被拒绝" bash -c "! PBOX_ROOT='$B' bash dist/pbox.sh sub join abc --yes"
check "修改本机备注后节点名和列表一起变" bash -c "PBOX_ROOT='$B' bash dist/pbox.sh sub name JP-home --yes && openssl base64 -d -A <'$PBOX_SUB_DIR/v2ray' | grep -q '#JP-home-' && PBOX_ROOT='$A' bash dist/pbox.sh sub machines | grep -q JP-home && PBOX_ROOT='$B' bash dist/pbox.sh sub name JP2 --yes"
check "列出机器" bash -c "PBOX_ROOT='$A' bash dist/pbox.sh sub machines | grep -q JP2"
check "从另一台上去掉一台机器" bash -c "PBOX_ROOT='$A' bash dist/pbox.sh sub forget JP2 --yes && openssl base64 -d -A <'$PBOX_SUB_DIR/v2ray' | diff - '$A/etc/pbox/nodes/users/default/links.txt' && ! test -e '$PBOX_SUB_DIR'/part-\$(sed -n 's/^sub_machine=//p' '$B/etc/pbox/state/global.env')"
check "被去掉的机器再次推送会重新加入" bash -c "PBOX_ROOT='$B' bash dist/pbox.sh sub push && test \$(grep -c '^machine ' '$PBOX_SUB_DIR/pbox-index') = 2"
check "关闭订阅时撤出本机的节点" bash -c "PBOX_ROOT='$B' bash dist/pbox.sh sub off --yes && openssl base64 -d -A <'$PBOX_SUB_DIR/v2ray' | diff - '$A/etc/pbox/nodes/users/default/links.txt'"
check "最后一台卸载后仓库里不留订阅文件" bash -c "PBOX_ROOT='$A' bash dist/pbox.sh uninstall --yes && test -z \"\$(ls '$PBOX_SUB_DIR')\""
unset PBOX_SUB_DIR PBOX_SUB_PROJECT PBOX_SUB_WTOKEN PBOX_SUB_RTOKEN PBOX_TEST_REGION

echo "域名证书"
new_root
unset PBOX_TEST_DNS_A PBOX_TEST_DNS_AAAA
PBOX_PROTOCOLS="reality-vision hysteria2 tuic anytls" pbox install --yes >/dev/null 2>&1
check "解析没指向本机时在申请前就拒绝" bash -c "! PBOX_TEST_DNS_A=198.51.100.9 bash dist/pbox.sh domain set a.example.com --yes"
check "没有解析记录时拒绝" bash -c "! bash dist/pbox.sh domain set a.example.com --yes"
export PBOX_TEST_DNS_A=203.0.113.10
check "80 端口被占用时拒绝，并指出接口验证这条路" bash -c "PBOX_TEST_PORTS=tcp/80 bash dist/pbox.sh domain set a.example.com --yes 2>&1 | grep -F 'pbox domain set a.example.com dns' >/dev/null && ! grep -q '^tls_domain=.' '$(E)/state/global.env'"
check "接口验证不受 80 端口占用影响" bash -c "PBOX_TEST_PORTS=tcp/80 PBOX_CF_TOKEN=x bash dist/pbox.sh domain set a.example.com dns --yes && bash dist/pbox.sh domain off --yes"
check "设置域名" pbox domain set A.Example.com --yes
check "域名统一成小写保存" grep -qx 'tls_domain=a.example.com' "$(E)/state/global.env"
check "三个协议的服务端都改用域名证书" bash -c "for p in hysteria2 tuic anytls; do grep -q 'certs/domain.crt' '$(E)/generated/sing-box/'*\$p.json || exit 1; done"
check "链接里用域名验证，不再固定指纹或跳过验证" bash -c "grep -q '^tuic://.*sni=a.example.com' '$(E)/nodes/links.txt' && ! grep -E '^(hysteria2|tuic|anytls)://' '$(E)/nodes/links.txt' | grep -v 'sni=a.example.com' | grep -q . && ! grep -Eq 'pinSHA256|insecure' '$(E)/nodes/links.txt'"
check "Reality 不受影响" bash -c "grep '^vless://' '$(E)/nodes/links.txt' | grep -q 'sni=www.example.org'"
check "客户端配置合法且不带指纹" bash -c "python3 -m json.tool '$(E)/nodes/sing-box.json' && ! grep -q certificate_public_key_sha256 '$(E)/nodes/sing-box.json' && ! grep -q 'fingerprint: \"' '$(E)/nodes/mihomo.yaml'"
check "停用后回到自签证书和指纹固定" bash -c "bash dist/pbox.sh domain off --yes && grep -q 'certs/hysteria2.crt' '$(E)/generated/sing-box/'*hysteria2.json && grep -q pinSHA256 '$(E)/nodes/links.txt' && ! test -e '$(E)/certs/domain.crt'"
unset PBOX_TEST_DNS_A
check "续期只接受 force 一个选项" bash -c "! bash dist/pbox.sh domain renew now"
check "没有域名时改用本机 IP" bash -c "bash dist/pbox.sh domain set ip --yes && grep -qx 'tls_domain=203.0.113.10' '$(E)/state/global.env'"
check "IP 证书的链接按 IP 验证，不跳过验证" bash -c "grep -q '^tuic://.*sni=203.0.113.10' '$(E)/nodes/links.txt' && ! grep -Eq 'pinSHA256|insecure' '$(E)/nodes/links.txt' && python3 -m json.tool '$(E)/nodes/sing-box.json'"
check "从 IP 换成域名" bash -c "PBOX_TEST_DNS_A=203.0.113.10 bash dist/pbox.sh domain set b.example.com --yes && grep -qx 'tls_domain=b.example.com' '$(E)/state/global.env'"
pbox domain off --yes >/dev/null 2>&1
check "已有证书域名时，地址模式直接用它而不必再填" bash -c "PBOX_TEST_DNS_A=203.0.113.10 PBOX_TEST_DNS_AAAA=2001:db8::10 bash dist/pbox.sh domain set c.example.com --yes && PBOX_TEST_DNS_A=203.0.113.10 PBOX_TEST_DNS_AAAA=2001:db8::10 bash dist/pbox.sh set addr-mode all --yes && grep -qx 'domain=c.example.com' '$(E)/state/global.env'"
pbox set addr-mode split --yes >/dev/null 2>&1
pbox domain off --yes >/dev/null 2>&1
check "没有域名时给出明确提示" bash -c "sed -i.bak '/^domain=/d' '$(E)/state/global.env'; ! bash dist/pbox.sh set addr-mode all --yes"
check "接口验证缺少令牌时拒绝" bash -c "! bash dist/pbox.sh domain set d.example.com dns --yes"
check "接口验证不要求域名指向本机" bash -c "PBOX_CF_TOKEN=x bash dist/pbox.sh domain set d.example.com dns --yes && grep -qx 'tls_method=dns' '$(E)/state/global.env'"
check "接口验证不能用于 IP" bash -c "! PBOX_CF_TOKEN=x bash dist/pbox.sh domain set 203.0.113.10 dns --yes"
pbox domain off --yes >/dev/null 2>&1
check "NAT 机器上说明不能用" bash -c "sed -i.bak 's/^nat=.*/nat=1/' '$(E)/state/global.env'; grep -q '^nat=1' '$(E)/state/global.env' || echo nat=1 >>'$(E)/state/global.env'; ! PBOX_TEST_DNS_A=203.0.113.10 bash dist/pbox.sh domain set a.example.com --yes"

check "NAT 机器可以用接口验证" bash -c "PBOX_CF_TOKEN=x bash dist/pbox.sh domain set d.example.com dns --yes && grep -q 'sni=d.example.com' '$(E)/nodes/links.txt'"

echo "伪装站与 443 分流"
new_root
unset PBOX_TEST_DNS_A PBOX_TEST_DNS_AAAA
PBOX_PROTOCOLS="reality-vision hysteria2 anytls" pbox install --yes >/dev/null 2>&1
check "没有域名证书时不能开" bash -c "! bash dist/pbox.sh site on --yes"
export PBOX_TEST_DNS_A=203.0.113.10
pbox domain set w.example.com --yes >/dev/null 2>&1
before=$(cat "$(E)/nodes/links.txt")
check "开启伪装站" pbox site on --yes
check "Reality 退到本机端口" bash -c "grep -q '\"listen\": \"127.0.0.1\"' '$(E)/generated/sing-box/10_reality-vision.json' && ! grep -q '\"listen_port\": 443' '$(E)/generated/sing-box/10_reality-vision.json'"
check "分流规则：自己的域名给网站，其余给 Reality" bash -c "
  sp=\$(sed -n 's/^site_port=//p' '$(E)/state/global.env'); rp=\$(sed -n 's/^site_front_port=//p' '$(E)/state/global.env')
  grep -q \"w.example.com 127.0.0.1:\$sp;\" '$(E)/generated/nginx/nginx.conf' && grep -q \"default 127.0.0.1:\$rp;\" '$(E)/generated/nginx/nginx.conf' &&
  grep -q \"\\\"listen_port\\\": \$rp\" '$(E)/generated/sing-box/10_reality-vision.json'"
check "节点链接完全不变" test "$before" = "$(cat "$(E)/nodes/links.txt")"
check "生成了内置页面" grep -q '<title>' "$(E)/site/index.html"
check "来源可以换成转发一个网址" bash -c "bash dist/pbox.sh site source https://www.example.org/abc --yes && grep -q 'proxy_pass https://www.example.org;' '$(E)/generated/nginx/nginx.conf'"
check "不合法的来源被拒绝" bash -c "! bash dist/pbox.sh site source http://x.example.org --yes"
check "开着伪装站时不能停用域名或改用 IP" bash -c "! bash dist/pbox.sh domain off --yes && ! bash dist/pbox.sh domain set ip --yes"
check "Reality 换到别的端口后不再经过分流" bash -c "bash dist/pbox.sh change reality-vision port 8444 --yes && grep -q '\"listen_port\": 8444' '$(E)/generated/sing-box/10_reality-vision.json' && ! grep -q 'site_front_port' /dev/null && grep -q \"default 127.0.0.1:\$(sed -n 's/^site_port=//p' '$(E)/state/global.env');\" '$(E)/generated/nginx/nginx.conf'"
check "关闭后 Nginx 配置消失" bash -c "bash dist/pbox.sh site off --yes && ! test -e '$(E)/generated/nginx'"
check "同域名的 TCP 协议占着 443 时拒绝" bash -c "bash dist/pbox.sh change anytls port 443 --yes && ! bash dist/pbox.sh site on --yes"
unset PBOX_TEST_DNS_A

echo "伪装站上的 Trojan 与 VLESS-WS-TLS"
new_root
check "安装时不能直接选" bash -c "! PBOX_PROTOCOLS='reality-vision trojan' bash dist/pbox.sh install --yes && ! test -e '$(E)/state'"
PBOX_PROTOCOLS="reality-vision hysteria2" pbox install --yes >/dev/null 2>&1
export PBOX_TEST_DNS_A=203.0.113.10
pbox domain set w.example.com --yes >/dev/null 2>&1
check "没开伪装站时不能加" bash -c "! bash dist/pbox.sh add trojan --yes && ! test -e '$(E)/state/protocols/trojan.env'"
pbox site on --yes >/dev/null 2>&1
check "加 Trojan" pbox add trojan --yes
check "自己域名的连接先给 Trojan，密码不对的转给不加密的网站入口" bash -c "
  tp=\$(sed -n 's/^port=//p' '$(E)/state/protocols/trojan.env'); pp=\$(sed -n 's/^site_plain_port=//p' '$(E)/state/global.env')
  grep -q \"w.example.com 127.0.0.1:\$tp;\" '$(E)/generated/nginx/nginx.conf' &&
  grep -q \"listen 127.0.0.1:\$pp;\" '$(E)/generated/nginx/nginx.conf' &&
  grep -q \"\\\"fallback\\\": {\\\"server\\\": \\\"127.0.0.1\\\", \\\"server_port\\\": \$pp}\" '$(E)/generated/sing-box/'*_trojan.json"
check "转给网站的连接排在私网拦截之前放行" bash -c "
  pp=\$(sed -n 's/^site_plain_port=//p' '$(E)/state/global.env')
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[\"route\"][\"rules\"]; sys.exit(not (r[0].get(\"inbound\")==[\"trojan\"] and r[0][\"port\"]==[int(sys.argv[2])] and r[0][\"outbound\"]==\"direct\" and r[1].get(\"ip_is_private\")))' '$(E)/generated/sing-box/00_base.json' \"\$pp\""
check "Trojan 链接用域名和 443，不带证书指纹" bash -c "grep -q '^trojan://.*@w.example.com:443?security=tls&sni=w.example.com' '$(E)/nodes/links.txt' && ! grep '^trojan://' '$(E)/nodes/links.txt' | grep -q 'insecure\|203.0.113'"
check "加 VLESS-WS-TLS" pbox add vless-wstls --yes
check "隐蔽路径在加密和不加密两个入口上都转给内核" bash -c "
  p=\$(sed -n 's/^path=//p' '$(E)/state/protocols/vless-wstls.env'); wp=\$(sed -n 's/^port=//p' '$(E)/state/protocols/vless-wstls.env')
  [ \"\$(grep -c \"location = \$p {\" '$(E)/generated/nginx/nginx.conf')\" = 2 ] &&
  [ \"\$(grep -c \"proxy_pass http://127.0.0.1:\$wp;\" '$(E)/generated/nginx/nginx.conf')\" = 2 ]"
check "VLESS-WS-TLS 链接只报 HTTP/1.1" bash -c "grep -q '^vless://.*@w.example.com:443?.*security=tls.*alpn=http%2F1.1&type=ws&host=w.example.com' '$(E)/nodes/links.txt'"
check "客户端配置有效" bash -c "python3 -m json.tool '$(E)/nodes/sing-box.json' >/dev/null && grep -q 'type: trojan' '$(E)/nodes/mihomo.yaml'"
check "换路径后网站配置跟着变" bash -c "bash dist/pbox.sh change vless-wstls path /abc123 --yes && grep -q 'location = /abc123 {' '$(E)/generated/nginx/nginx.conf'"
check "换握手特征" bash -c "bash dist/pbox.sh change trojan fp safari --yes && grep -q '^trojan://.*fp=safari' '$(E)/nodes/links.txt'"
check "协议挂在上面时不能关伪装站" bash -c "! bash dist/pbox.sh site off --yes && grep -q '^site=on' '$(E)/state/global.env'"
check "停用 Trojan 后域名回到网站" bash -c "bash dist/pbox.sh del trojan --yes && grep -q \"w.example.com 127.0.0.1:\$(sed -n 's/^site_port=//p' '$(E)/state/global.env');\" '$(E)/generated/nginx/nginx.conf' && ! grep -q \"listen 127.0.0.1:\$(sed -n 's/^site_plain_port=//p' '$(E)/state/global.env');\" '$(E)/generated/nginx/nginx.conf'"
check "Reality 不在 443 时仍放行 443" bash -c "bash dist/pbox.sh change reality-vision port 8444 --yes && bash dist/pbox.sh nodes | grep -q '443/tcp'"
check "都停用后可以关伪装站" bash -c "bash dist/pbox.sh del vless-wstls --yes && bash dist/pbox.sh site off --yes"
unset PBOX_TEST_DNS_A

echo "自有域名套 CDN 与优选"
new_root
PBOX_PROTOCOLS="reality-vision hysteria2" pbox install --yes >/dev/null 2>&1
export PBOX_TEST_DNS_A=203.0.113.10
pbox domain set w.example.com --yes >/dev/null 2>&1
check "没开伪装站时不能设" bash -c "! bash dist/pbox.sh site cdn c.example.com --yes"
pbox site on --yes >/dev/null 2>&1
pbox add vless-wstls --yes >/dev/null 2>&1
pbox add trojan --yes >/dev/null 2>&1
check "没设子域名时不能开 ECH" bash -c "! bash dist/pbox.sh site ech on --yes && ! grep -q '^ech=1' '$(E)/state/global.env'"
check "不能用直连的域名" bash -c "! bash dist/pbox.sh site cdn w.example.com --yes"
check "没解析也不在 Cloudflare 后面时拒绝" bash -c "! PBOX_TEST_DNS_A= bash dist/pbox.sh site cdn c.example.com --yes && ! grep -q '^cdn_host=c' '$(E)/state/global.env'"
check "没设子域名时不能设优选" bash -c "! bash dist/pbox.sh change vless-wstls cdn www.visa.com.sg --yes"
links_before=$(grep -c . "$(E)/nodes/links.txt")
check "设置子域名" pbox site cdn c.example.com --yes
check "子域名交给网站而不是 Trojan，网站认这个名字" bash -c "
  sp=\$(sed -n 's/^site_port=//p' '$(E)/state/global.env')
  grep -q \"c.example.com 127.0.0.1:\$sp;\" '$(E)/generated/nginx/nginx.conf' &&
  grep -q 'server_name w.example.com c.example.com;' '$(E)/generated/nginx/nginx.conf' &&
  grep -q 'location ^~ /.well-known/acme-challenge/ { proxy_pass http://127.0.0.1:80; }' '$(E)/generated/nginx/nginx.conf'"
check "多出经 CDN 的节点，直连节点不变" bash -c "
  grep -q '^vless://.*@c.example.com:443?.*sni=c.example.com.*host=c.example.com.*#.*WS-CDN' '$(E)/nodes/links.txt' &&
  grep -q '^vless://.*@w.example.com:443?.*sni=w.example.com.*#.*WS-TLS' '$(E)/nodes/links.txt' &&
  [ \$(grep -c . '$(E)/nodes/links.txt') = \$(($links_before + 1)) ]"
check "优选节点连优选地址，握手仍写子域名" bash -c "bash dist/pbox.sh change vless-wstls cdn www.visa.com.sg --yes && grep -q '^vless://.*@www.visa.com.sg:443?.*sni=c.example.com.*host=c.example.com.*#.*WS-CDN-Pref' '$(E)/nodes/links.txt' && grep -q '\"server_name\": \"c.example.com\"' '$(E)/nodes/sing-box.json' && python3 -m json.tool '$(E)/nodes/sing-box.json' >/dev/null"
check "优选地址可以是 IPv6" bash -c "bash dist/pbox.sh change vless-wstls cdn 2606:4700::1 --yes && grep -q '^vless://.*@\[2606:4700::1\]:443?' '$(E)/nodes/links.txt'"
check "精简后只列推荐协议，每个一个节点，兜底用优选" bash -c "bash dist/pbox.sh set compact-nodes on --yes && l='$(E)/nodes/links.txt' && [ \$(grep -c . \$l) = 3 ] && grep -q 'Reality-IPv4\$' \$l && grep -q 'Hysteria2-IPv4\$' \$l && grep -q 'WS-CDN-Pref\$' \$l && ! grep -q 'Trojan' '$(E)/nodes/mihomo.yaml' && python3 -m json.tool '$(E)/nodes/sing-box.json' >/dev/null"
check "精简时体检仍测全部协议" bash -c "bash dist/pbox.sh doctor 2>&1 | grep -q Trojan"
check "自选列出的协议，开关时保留名单" bash -c "l='$(E)/nodes/links.txt' && bash dist/pbox.sh set compact-nodes trojan,hysteria2 --yes && [ \$(grep -c . \$l) = 2 ] && grep -q 'Trojan-' \$l && grep -q 'Hysteria2-IPv4\$' \$l && bash dist/pbox.sh set compact-nodes off --yes && bash dist/pbox.sh set compact-nodes on --yes && [ \$(grep -c . \$l) = 2 ] && grep -qx 'compact_list=trojan hysteria2' '$(E)/state/global.env'"
check "自选名单里有不认识的协议时拒绝" bash -c "! bash dist/pbox.sh set compact-nodes reality-vision,nope --yes"
check "恢复自动挑选" bash -c "bash dist/pbox.sh set compact-nodes auto --yes && [ \$(grep -c . '$(E)/nodes/links.txt') = 3 ]"
check "精简时主力没有就由下一个顶上" bash -c "bash dist/pbox.sh user add carol trojan,vless-wstls --yes && l='$(E)/nodes/links.txt' && [ \$(grep -c -- '-carol\$' \$l) = 2 ] && grep -q 'Trojan-.*-carol\$' \$l && grep -q 'WS-CDN-Pref-carol\$' \$l && bash dist/pbox.sh user del carol --yes"
check "关掉精简后恢复" bash -c "bash dist/pbox.sh set compact-nodes off --yes && grep -q 'WS-CDN\$' '$(E)/nodes/links.txt'"
check "开 ECH 后 WS 节点只在通用链接里加密握手，Clash 和 sing-box 照旧" bash -c "PBOX_TEST_ECH='AEX+t/s=' bash dist/pbox.sh site ech on --yes && ! grep -q '\"ech\"' '$(E)/nodes/sing-box.json' && [ \$(grep -c '\"utls\": {\"enabled\": true' '$(E)/nodes/sing-box.json') -ge 3 ] && m='$(E)/nodes/mihomo.yaml' && ! grep -q 'ech-opts' \$m && ! grep -q '^dns:' \$m && l='$(E)/nodes/links.txt' && [ \$(grep -c '&ech=c.example.com%2Bhttps%3A%2F%2F223.5.5.5%2Fdns-query#' \$l) = 2 ] && ! grep 'WS-TLS\$' \$l | grep -q 'ech='"
check "取不到 ECH 配置时体检报错" bash -c "PBOX_TEST_ECH= bash dist/pbox.sh site ech on --yes && grep -q '&ech=c.example.com' '$(E)/nodes/links.txt' && PBOX_TEST_ECH= bash dist/pbox.sh doctor 2>&1 | grep -q '取不到 c.example.com 的 ECH'"
check "关掉 ECH 后恢复原样" bash -c "bash dist/pbox.sh site ech off --yes && ! grep -q '\"ech\"' '$(E)/nodes/sing-box.json' && ! grep -q 'ech-opts' '$(E)/nodes/mihomo.yaml' && ! grep -q '^dns:' '$(E)/nodes/mihomo.yaml' && ! grep -q 'ech=' '$(E)/nodes/links.txt'"
check "设着子域名时不能关伪装站" bash -c "bash dist/pbox.sh del trojan --yes && bash dist/pbox.sh del vless-wstls --yes && ! bash dist/pbox.sh site off --yes"
check "停用后分流和节点里都没有子域名" bash -c "bash dist/pbox.sh add vless-wstls --yes && bash dist/pbox.sh site cdn off --yes && ! grep -q 'c.example.com' '$(E)/generated/nginx/nginx.conf' && ! grep -q 'c.example.com' '$(E)/nodes/links.txt'"
unset PBOX_TEST_DNS_A

echo "VMess-WS-TLS"
new_root
PBOX_PROTOCOLS="reality-vision" pbox install --yes >/dev/null 2>&1
export PBOX_TEST_DNS_A=203.0.113.10
pbox domain set w.example.com --yes >/dev/null 2>&1
check "没开伪装站时不能加" bash -c "! bash dist/pbox.sh add vmess --yes"
pbox site on --yes >/dev/null 2>&1
check "加上 VMess" pbox add vmess --yes
check "VMess 只听本机，alterId 为 0" bash -c "python3 -c 'import json,sys; i=json.load(open(sys.argv[1]))[\"inbounds\"][0]; sys.exit(not (i[\"type\"]==\"vmess\" and i[\"listen\"]==\"127.0.0.1\" and i[\"users\"][0][\"alterId\"]==0 and i[\"transport\"][\"type\"]==\"ws\"))' '$(E)/generated/sing-box/10_vmess.json'"
check "VMess 链接是 v2rayN 的写法，经 443 和域名握手" bash -c "python3 -c 'import base64,json,sys
l=[x for x in open(sys.argv[1]) if x.startswith(\"vmess://\")][0].strip()
j=json.loads(base64.b64decode(l[8:]))
i=json.load(open(sys.argv[2]))[\"inbounds\"][0]
sys.exit(not (j[\"add\"]==\"w.example.com\" and j[\"port\"]==\"443\" and j[\"tls\"]==\"tls\" and j[\"sni\"]==\"w.example.com\" and j[\"net\"]==\"ws\" and j[\"aid\"]==\"0\" and j[\"path\"]==i[\"transport\"][\"path\"] and j[\"id\"]==i[\"users\"][0][\"uuid\"] and j[\"ps\"].endswith(\"VMess-TLS\")))' '$(E)/nodes/links.txt' '$(E)/generated/sing-box/10_vmess.json'"
check "VMess 在两种客户端配置里" bash -c "python3 -m json.tool '$(E)/nodes/sing-box.json' >/dev/null && grep -q '\"type\": \"vmess\"' '$(E)/nodes/sing-box.json' && grep -q 'type: vmess' '$(E)/nodes/mihomo.yaml'"
check "和 VLESS-WS-TLS 各有一个隐蔽路径" bash -c "bash dist/pbox.sh add vless-wstls --yes && vp=\$(sed -n 's/^path=//p' '$(E)/state/protocols/vmess.env') && wp=\$(sed -n 's/^path=//p' '$(E)/state/protocols/vless-wstls.env') && [ \"\$vp\" != \"\$wp\" ] && grep -q \"location = \$vp \" '$(E)/generated/nginx/nginx.conf' && grep -q \"location = \$wp \" '$(E)/generated/nginx/nginx.conf'"
check "两个 WS 协议不能用同一个路径" bash -c "bash dist/pbox.sh change vmess path /same1 --yes && ! bash dist/pbox.sh change vless-wstls path /same1 --yes"
check "开着 VMess 时不能关伪装站" bash -c "bash dist/pbox.sh del vless-wstls --yes && ! bash dist/pbox.sh site off --yes"
check "没设子域名时不能设优选" bash -c "! bash dist/pbox.sh change vmess cdn www.visa.com.sg --yes"
check "设了子域名和优选后多出经 CDN 的节点" bash -c "bash dist/pbox.sh site cdn c.example.com --yes && bash dist/pbox.sh change vmess cdn www.visa.com.sg --yes && grep -c '^vmess://' '$(E)/nodes/links.txt' | grep -qx 3"
check "精简时 VMess 做兜底，只列优选" bash -c "bash dist/pbox.sh set compact-nodes on --yes && python3 -c 'import base64,json,sys
v=[json.loads(base64.b64decode(x.strip()[8:])) for x in open(sys.argv[1]) if x.startswith(\"vmess://\")]
sys.exit(not (len(v)==1 and v[0][\"add\"]==\"www.visa.com.sg\" and v[0][\"sni\"]==\"c.example.com\" and v[0][\"host\"]==\"c.example.com\"))' '$(E)/nodes/links.txt' && bash dist/pbox.sh add vless-wstls --yes && ! grep -q '^vmess://' '$(E)/nodes/links.txt' && bash dist/pbox.sh set compact-nodes off --yes"
check "后开的 WS 协议沿用已设的优选地址" grep -qx 'cdn_addr=www.visa.com.sg' "$(E)/state/protocols/vless-wstls.env"
unset PBOX_TEST_DNS_A

echo "VLESS-XHTTP-TLS"
new_root
PBOX_PROTOCOLS="reality-vision" pbox install --yes >/dev/null 2>&1
export PBOX_TEST_DNS_A=203.0.113.10
pbox domain set w.example.com --yes >/dev/null 2>&1
check "没开伪装站时不能加" bash -c "! bash dist/pbox.sh add vless-xhttp --yes"
pbox site on --yes >/dev/null 2>&1
check "加上 XHTTP" pbox add vless-xhttp --yes
check "由 Xray 承载，只听本机，不自己做加密" bash -c "python3 -c 'import json,sys; i=json.load(open(sys.argv[1]))[\"inbounds\"][0]; s=i[\"streamSettings\"]; sys.exit(not (i[\"listen\"]==\"127.0.0.1\" and s[\"network\"]==\"xhttp\" and \"security\" not in s and s[\"xhttpSettings\"][\"path\"].startswith(\"/\")))' '$(E)/generated/xray/10_vless-xhttp.json'"
check "网站按路径前缀用 gRPC 的方式转给内核" bash -c "p=\$(sed -n 's/^path=//p' '$(E)/state/protocols/vless-xhttp.env'); port=\$(sed -n 's/^port=//p' '$(E)/state/protocols/vless-xhttp.env'); grep -q \"location \$p {\" '$(E)/generated/nginx/nginx.conf' && grep -q \"grpc_pass grpc://127.0.0.1:\$port;\" '$(E)/generated/nginx/nginx.conf'"
check "直连时用 HTTP/2；Clash 里有，sing-box 里没有" bash -c "grep -q '^vless://.*@w.example.com:443?.*security=tls&sni=w.example.com.*alpn=h2&type=xhttp&host=w.example.com.*#XHTTP-TLS' '$(E)/nodes/links.txt' && ! grep -q XHTTP '$(E)/nodes/sing-box.json' && python3 -m json.tool '$(E)/nodes/sing-box.json' >/dev/null && m='$(E)/nodes/mihomo.yaml' && grep -A16 '^  - name: \"XHTTP-TLS\"' \$m | grep -q 'network: xhttp' && grep -A16 '^  - name: \"XHTTP-TLS\"' \$m | grep -qx '    alpn: \[\"h2\"\]' && grep -qx '      - \"XHTTP-TLS\"' \$m && ! grep -q 'ech-opts' \$m"
check "前面有 Trojan 时直连节点改用 HTTP/1.1" bash -c "bash dist/pbox.sh add trojan --yes && grep -q 'alpn=http%2F1.1&type=xhttp.*#XHTTP-TLS' '$(E)/nodes/links.txt' && grep -A16 '^  - name: \"XHTTP-TLS\"' '$(E)/nodes/mihomo.yaml' | grep -qx '    alpn: \[\"http/1.1\"\]'"
check "路径不能和别的协议相同或互相包含" bash -c "bash dist/pbox.sh add vless-wstls --yes && bash dist/pbox.sh change vless-xhttp path /xh --yes && ! bash dist/pbox.sh change vless-wstls path /xh --yes && ! bash dist/pbox.sh change vless-wstls path /xh/ws --yes && bash dist/pbox.sh change vless-wstls path /ws1 --yes && ! bash dist/pbox.sh change vless-xhttp path /ws1 --yes"
check "经 CDN 的节点用 HTTP/2，沿用已设的优选地址" bash -c "bash dist/pbox.sh del vless-xhttp --yes && bash dist/pbox.sh site cdn c.example.com --yes && bash dist/pbox.sh change vless-wstls cdn www.visa.com.sg --yes && bash dist/pbox.sh add vless-xhttp --yes && grep -q '@www.visa.com.sg:443?.*sni=c.example.com.*alpn=h2&type=xhttp&host=c.example.com.*#XHTTP-CDN-Pref' '$(E)/nodes/links.txt' && [ \$(grep -c '#XHTTP-' '$(E)/nodes/links.txt') = 3 ]"
check "开 ECH 后经 CDN 的 XHTTP 链接带 DoH 查询" bash -c "PBOX_TEST_ECH=AEX bash dist/pbox.sh site ech on --yes && l='$(E)/nodes/links.txt' && grep -q 'mode=auto&ech=c.example.com%2Bhttps%3A%2F%2F223.5.5.5%2Fdns-query#XHTTP-CDN-Pref' \$l && ! grep '#XHTTP-TLS' \$l | grep -q 'ech='"
check "Clash 里只有经 CDN 的 XHTTP 节点开 ECH，子域名改用 DoH 查" bash -c "m='$(E)/nodes/mihomo.yaml' && [ \$(grep -c 'ech-opts:' \$m) = 2 ] && [ \$(grep -B1 'ech-opts:' \$m | grep -c 'client-fingerprint: ') = 2 ] && grep -A14 '^  - name: \"XHTTP-CDN-Pref\"' \$m | grep -q 'ech-opts:' && ! grep -A14 '^  - name: \"WS-CDN-Pref\"' \$m | grep -q 'ech-opts:' && ! grep -A14 '^  - name: \"XHTTP-TLS\"' \$m | grep -q 'ech-opts:' && grep -qx '    \"c.example.com\": \[https://223.5.5.5/dns-query, https://1.12.12.12/dns-query, https://1.1.1.1/dns-query\]' \$m && ! grep -q '\"ech\"' '$(E)/nodes/sing-box.json'"
check "开 ECH 时精简列表也列上 XHTTP，sing-box 的名单里没有它" bash -c "bash dist/pbox.sh set compact-nodes on --yes && grep -q '#XHTTP-CDN-Pref\$' '$(E)/nodes/links.txt' && grep -q 'WS-CDN-Pref\$' '$(E)/nodes/links.txt' && grep -qx '      - \"XHTTP-CDN-Pref\"' '$(E)/nodes/mihomo.yaml' && python3 -c 'import json,sys; o=json.load(open(sys.argv[1]))[\"outbounds\"]; sys.exit(any(\"XHTTP\" in t for t in o[0][\"outbounds\"]))' '$(E)/nodes/sing-box.json' && bash dist/pbox.sh site ech off --yes && ! grep -q '#XHTTP-CDN-Pref\$' '$(E)/nodes/links.txt' && bash dist/pbox.sh set compact-nodes off --yes"
unset PBOX_TEST_DNS_A

echo "Shadowsocks 2022、ShadowTLS、Reality-XHTTP"
new_root
check "一起安装" bash -c "PBOX_PROTOCOLS='reality-vision hysteria2 reality-xhttp shadowtls ss2022' bash dist/pbox.sh install --yes"
check "一起安装时各自挑到不同的端口" bash -c "[ \$(sed -n 's/^port=//p' '$(E)/state/protocols/reality-xhttp.env') != \$(sed -n 's/^port=//p' '$(E)/state/protocols/shadowtls.env') ]"
check "XHTTP 由 Xray 承载" bash -c "python3 -c 'import json,sys; i=json.load(open(sys.argv[1]))[\"inbounds\"][0]; s=i[\"streamSettings\"]; sys.exit(not (s[\"network\"]==\"xhttp\" and s[\"security\"]==\"reality\" and s[\"realitySettings\"][\"target\"].endswith(\":443\")))' '$(E)/generated/xray/10_reality-xhttp.json'"
check "XHTTP 只有通用链接" bash -c "grep -q '^vless://.*type=xhttp.*#XHTTP-IPv4' '$(E)/nodes/links.txt' && ! grep -q XHTTP '$(E)/nodes/sing-box.json' && ! grep -q XHTTP '$(E)/nodes/mihomo.yaml'"
check "ShadowTLS 只在 Clash 和 sing-box 配置里" bash -c "! grep -q ShadowTLS '$(E)/nodes/links.txt' && grep -q 'plugin: shadow-tls' '$(E)/nodes/mihomo.yaml' && grep -q '\"detour\": \"ShadowTLS-IPv4-tls\"' '$(E)/nodes/sing-box.json' && python3 -m json.tool '$(E)/nodes/sing-box.json' >/dev/null"
check "ShadowTLS 里面的 Shadowsocks 只听本机" bash -c "python3 -c 'import json,sys; a,b=json.load(open(sys.argv[1]))[\"inbounds\"]; sys.exit(not (a[\"detour\"]==b[\"tag\"] and b[\"listen\"]==\"127.0.0.1\" and a[\"version\"]==3))' '$(E)/generated/sing-box/10_shadowtls.json'"
check "SS 链接带服务器密钥和用户密钥" bash -c "python3 -c 'import base64,sys
l=[x for x in open(sys.argv[1]) if x.startswith(\"ss://\")][0]
p=base64.b64decode(l[5:].split(\"@\")[0]).decode().split(\":\")
sys.exit(not (p[0]==\"2022-blake3-aes-128-gcm\" and len(base64.b64decode(p[1]))==16 and len(base64.b64decode(p[2]))==16))' '$(E)/nodes/links.txt'"
check "SS 的 TCP 和 UDP 都放行" bash -c "p=\$(sed -n 's/^port=//p' '$(E)/state/protocols/ss2022.env'); bash dist/pbox.sh nodes | grep -q \"\$p/tcp \$p/udp\""
check "SS 不能和 UDP 协议用同一个端口" bash -c "bash dist/pbox.sh change hysteria2 port 50000 --yes && ! bash dist/pbox.sh change ss2022 port 50000 --yes"
ss_before=$(grep '^ss://' "$(E)/nodes/links.txt" | head -1)
check "重置用户后 SS 的用户密钥跟着变" bash -c "bash dist/pbox.sh user reset default --yes && [ \"\$(grep '^ss://' '$(E)/nodes/links.txt' | head -1)\" != '$ss_before' ]"
check "SS 每个用户一个密钥" bash -c "bash dist/pbox.sh user add bob ss2022 --yes && python3 -c 'import json,sys; u=json.load(open(sys.argv[1]))[\"inbounds\"][0][\"users\"]; sys.exit(not (len(u)==2 and u[0][\"password\"]!=u[1][\"password\"]))' '$(E)/generated/sing-box/10_ss2022.json'"
check "精简时不列冷门协议；只有冷门协议的用户照常列出" bash -c "bash dist/pbox.sh set compact-nodes on --yes && l='$(E)/nodes/links.txt' && grep -q 'Reality-IPv4-default\$' \$l && ! grep -q 'IPv6-default\$' \$l && ! grep -q -- '-default\$' <(grep -v -e Reality -e Hysteria2 \$l) && grep -q 'SS-IPv4-bob\$' \$l && ! grep -q 'SS-IPv6-bob\$' \$l && bash dist/pbox.sh set compact-nodes off --yes"
check "换 XHTTP 的伪装目标和路径" bash -c "bash dist/pbox.sh change reality-xhttp sni www.example.net --yes && bash dist/pbox.sh change reality-xhttp path /p1 --yes && grep -q '\"target\": \"www.example.net:443\"' '$(E)/generated/xray/10_reality-xhttp.json' && grep -q '\"path\": \"/p1\"' '$(E)/generated/xray/10_reality-xhttp.json'"
check "换 ShadowTLS 的握手对象" bash -c "bash dist/pbox.sh change shadowtls sni www.example.net --yes && grep -q 'host: \"www.example.net\"' '$(E)/nodes/mihomo.yaml'"

echo "访问限制：屏蔽 BT、屏蔽回国与加密 DNS"
new_root
PBOX_PROTOCOLS="reality-vision reality-xhttp" pbox install --yes >/dev/null 2>&1
sb="$(E)/generated/sing-box/00_base.json"
xr="$(E)/generated/xray/00_base.json"
check "默认不嗅探、不改解析" bash -c "! grep -q sniff '$sb' && ! grep -q '\"dns\"' '$sb' && ! grep -q '\"dns\"' '$xr' && ! grep -q sniffing '$(E)/generated/xray/10_reality-xhttp.json'"
check "屏蔽 BT：两个内核都先嗅探再拦截，排在私网拦截之后" bash -c "bash dist/pbox.sh set block-bt on --yes && python3 -c 'import json,sys
r=json.load(open(sys.argv[1]))[\"route\"][\"rules\"]
x=json.load(open(sys.argv[2]))
i=json.load(open(sys.argv[3]))[\"inbounds\"][0]
sys.exit(not (r[0].get(\"ip_is_private\") and r[1]==dict(action=\"sniff\") and r[2]==dict(protocol=\"bittorrent\",action=\"reject\") and x[\"routing\"][\"rules\"][-1][\"protocol\"]==[\"bittorrent\"] and i[\"sniffing\"][\"routeOnly\"]))' '$sb' '$xr' '$(E)/generated/xray/10_reality-xhttp.json'"
check "和 WARP 按网站分流一起开时只嗅探一次" bash -c "bash dist/pbox.sh warp on --yes && [ \$(grep -o '\"action\": \"sniff\"' '$sb' | wc -l) = 1 ] && python3 -m json.tool '$sb' >/dev/null && bash dist/pbox.sh warp off --yes"
check "加密 DNS：两个内核的出站解析都改走 HTTPS" bash -c "bash dist/pbox.sh set dns cloudflare --yes && python3 -c 'import json,sys
s=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2]))
sys.exit(not (s[\"dns\"][\"servers\"][0]==dict(type=\"https\",tag=\"dns-doh\",server=\"1.1.1.1\") and s[\"route\"][\"default_domain_resolver\"]==\"dns-doh\" and x[\"dns\"][\"servers\"]==[\"https://1.1.1.1/dns-query\"] and x[\"outbounds\"][0][\"settings\"][\"domainStrategy\"]==\"UseIP\"))' '$sb' '$xr'"
check "屏蔽回国：先下载名单，两个内核都按域名和 IP 拦" bash -c "bash dist/pbox.sh set block-cn on --yes && test -s '$PBOX_ROOT/usr/local/lib/pbox/bin/geoip-cn.srs' && test -s '$PBOX_ROOT/usr/local/lib/pbox/bin/geosite-cn.dat' && python3 -c 'import json,sys
s=json.load(open(sys.argv[1]))[\"route\"]; x=json.load(open(sys.argv[2]))[\"routing\"]
r=s[\"rules\"]; i=r.index(dict(action=\"sniff\"))
sys.exit(not ([t[\"tag\"] for t in s[\"rule_set\"]]==[\"geosite-cn\",\"geoip-cn\"] and s[\"rule_set\"][0][\"path\"]==\"/usr/local/lib/pbox/bin/geosite-cn.srs\" and r[-3:]==[dict(rule_set=[\"geosite-cn\"],action=\"reject\"),dict(action=\"resolve\"),dict(rule_set=[\"geoip-cn\"],action=\"reject\")] and i<len(r)-3 and x[\"domainStrategy\"]==\"IPIfNonMatch\" and x[\"rules\"][-2][\"domain\"]==[\"ext:geosite-cn.dat:cn\"] and x[\"rules\"][-1][\"ip\"]==[\"ext:geoip-cn.dat:cn\"]))' '$sb' '$xr' && grep -q sniffing '$(E)/generated/xray/10_reality-xhttp.json'"
check "关掉屏蔽回国后规则去掉" bash -c "bash dist/pbox.sh set block-cn off --yes && ! grep -q geoip-cn '$sb' && ! grep -q geoip-cn '$xr'"
check "不认识的解析器被拒绝" bash -c "! bash dist/pbox.sh set dns 1.2.3.4 --yes"
check "都关掉后回到原样" bash -c "bash dist/pbox.sh set dns system --yes && bash dist/pbox.sh set block-bt off --yes && ! grep -q sniff '$sb' && ! grep -q '\"dns\"' '$sb' && ! grep -q '\"dns\"' '$xr' && python3 -m json.tool '$xr' >/dev/null"

echo "出口优先"
new_root
PBOX_PROTOCOLS="reality-vision reality-xhttp" pbox install --yes >/dev/null 2>&1
sb="$(E)/generated/sing-box/00_base.json"
xr="$(E)/generated/xray/00_base.json"
check "默认不设优先" bash -c "! grep -q '\"dns\"' '$sb' && ! grep -q domainStrategy '$xr'"
check "优先 IPv6：sing-box 经系统解析按 IPv6 优先，Xray 同样" bash -c "bash dist/pbox.sh set ip-pref v6 --yes && python3 -c 'import json,sys
s=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2]))
sys.exit(not (s[\"dns\"][\"servers\"]==[dict(type=\"local\",tag=\"dns-local\")] and s[\"route\"][\"default_domain_resolver\"]==dict(server=\"dns-local\",strategy=\"prefer_ipv6\") and x[\"outbounds\"][0][\"settings\"][\"domainStrategy\"]==\"UseIPv6v4\"))' '$sb' '$xr'"
check "和加密 DNS 一起开时用加密的解析器" bash -c "bash dist/pbox.sh set dns quad9 --yes && bash dist/pbox.sh set ip-pref v4 --yes && python3 -c 'import json,sys
s=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2]))
sys.exit(not (s[\"dns\"][\"servers\"][0][\"tag\"]==\"dns-doh\" and len(s[\"dns\"][\"servers\"])==1 and s[\"route\"][\"default_domain_resolver\"]==dict(server=\"dns-doh\",strategy=\"prefer_ipv4\") and x[\"outbounds\"][0][\"settings\"][\"domainStrategy\"]==\"UseIPv4v6\"))' '$sb' '$xr'"
check "屏蔽回国时提前解析也按优先顺序" bash -c "bash dist/pbox.sh set block-cn on --yes && grep -q '\"action\": \"resolve\", \"strategy\": \"prefer_ipv4\"' '$sb' && python3 -m json.tool '$sb' >/dev/null && bash dist/pbox.sh set block-cn off --yes"
check "改回 auto 后回到原样" bash -c "bash dist/pbox.sh set ip-pref auto --yes && bash dist/pbox.sh set dns system --yes && ! grep -q '\"dns\"' '$sb' && ! grep -q domainStrategy '$xr'"
check "本机没有 IPv6 时不能优先它" bash -c "R=\$(mktemp -d); export PBOX_ROOT=\$R PBOX_TEST_IP6=; bash dist/pbox.sh install --yes >/dev/null 2>&1 && ! bash dist/pbox.sh set ip-pref v6 --yes && bash dist/pbox.sh set ip-pref v4 --yes"
check "写错时拒绝" bash -c "! bash dist/pbox.sh set ip-pref ipv6 --yes"

echo "伪装目标离服务器太远"
new_root
pbox install --yes >/dev/null 2>&1
check "离得近的直接换" bash -c "PBOX_TEST_RTT=0.03 bash dist/pbox.sh change reality-vision sni www.example.net --yes && grep -qx 'sni=www.example.net' '$(E)/state/protocols/reality-vision.env'"
check "太远时提醒，不确认就不换" bash -c "printf '\n' | PBOX_TEST_RTT=0.3 bash dist/pbox.sh change reality-vision sni www.example.com 2>&1 | grep '300 毫秒' >/dev/null; grep -qx 'sni=www.example.net' '$(E)/state/protocols/reality-vision.env'"
check "确认后照换" bash -c "printf 'y\n' | PBOX_TEST_RTT=0.3 bash dist/pbox.sh change reality-vision sni www.example.com >/dev/null 2>&1; grep -qx 'sni=www.example.com' '$(E)/state/protocols/reality-vision.env'"
check "--yes 时只提醒" bash -c "PBOX_TEST_RTT=0.3 bash dist/pbox.sh change reality-vision sni www.example.org --yes 2>&1 | grep '毫秒' >/dev/null && grep -qx 'sni=www.example.org' '$(E)/state/protocols/reality-vision.env'"
check "安装时指定的目标同样检查，不确认就不装" bash -c "R=\$(mktemp -d); printf '\n\n' | PBOX_ROOT=\$R PBOX_TEST_RTT=0.3 PBOX_PROTOCOLS=reality-vision PBOX_REALITY_SNI=www.example.net bash dist/pbox.sh install >\$R/out.txt 2>&1; grep -q '毫秒' \$R/out.txt && test ! -e \$R/etc/pbox"
eval "$(sed -n '/^REALITY_FAR=/p; /^reality_far()/p; /^ms_of()/p' src/lib/reality.sh)"
far_not() { ! reality_far "$1"; }
check "50 毫秒以内算近" far_not 0.05
check "超过 50 毫秒算远" reality_far 0.051
check "耗时换算成毫秒" test "$(ms_of 0.3)" = 300

echo "体检报告脱敏"
new_root
PBOX_PROTOCOLS="reality-vision hysteria2" pbox install --yes >/dev/null 2>&1
PBOX_TEST_DNS_A=203.0.113.10 pbox domain set r.example.com --yes >/dev/null 2>&1
pbox doctor --report >"$PBOX_ROOT/rep.txt" 2>&1
check "报告里有体检结果和版本" bash -c "grep -q '体检' '$PBOX_ROOT/rep.txt' && grep -q '^pbox ' '$PBOX_ROOT/rep.txt'"
check "报告里没有本机 IP 和证书域名" bash -c "! grep -qE '203\.0\.113\.10|2001:db8::10|r\.example\.com' '$PBOX_ROOT/rep.txt' && grep -q '<IPv4>' '$PBOX_ROOT/rep.txt'"
eval "$(sed -n '/^doctor_redact()/,/^}/p' src/lib/doctor.sh)"
redact_words() { printf '<domain>\tr.example.com\n<cdn-domain>\tcdn.r.example.com\n<relay>\tland.example.net\n'; }
say() { :; }
PBOX_VERSION=test
red() { printf '%s\n' "$1" | doctor_redact; }
check "长的先换：子域名整体换掉，不留前缀" test "$(red 'cdn.r.example.com r.example.com')" = '<cdn-domain> <domain>'
check "名单外的 IPv4 也隐去，回环地址保留" test "$(red '连到 198.51.100.7:23123，本机 127.0.0.1')" = '连到 <IP>:23123，本机 127.0.0.1'
check "域名里的点按字面匹配" test "$(red 'land-example.net land.example.net')" = 'land-example.net <relay>'
check "IPv6 客户端地址隐去，时间不受影响" test "$(red '12:30:45 from [2408:8207:1e::5]:51234')" = '12:30:45 from [<IP>]:51234'
unset -f redact_words say red

echo "定时重启"
new_root
pbox install --yes >/dev/null 2>&1
check "默认关闭" bash -c "! grep -q '^restart_at=.' '$(E)/state/global.env'"
check "设定时间" bash -c "bash dist/pbox.sh set restart 04:30 --yes 2>&1 | grep -q '04:30' && grep -qx 'restart_at=04:30' '$(E)/state/global.env'"
check "on 等于凌晨四点" bash -c "bash dist/pbox.sh set restart on --yes && grep -qx 'restart_at=04:00' '$(E)/state/global.env'"
check "时间写错时拒绝" bash -c "! bash dist/pbox.sh set restart 24:00 --yes && ! bash dist/pbox.sh set restart 4:00 --yes && grep -qx 'restart_at=04:00' '$(E)/state/global.env'"
check "关闭" bash -c "bash dist/pbox.sh set restart off --yes && ! grep -q '^restart_at=.' '$(E)/state/global.env'"
check "立即重启" bash -c "bash dist/pbox.sh restart | grep -q 已重启"
check "菜单里可以设置" bash -c "printf '6\nt\n05:15\n\n0\n0\n' | bash dist/pbox.sh >/dev/null 2>&1; grep -qx 'restart_at=05:15' '$(E)/state/global.env'"

echo "调试日志"
new_root
PBOX_PROTOCOLS="reality-vision reality-xhttp" pbox install --yes >/dev/null 2>&1
dbg_level() { grep -h '"log"' "$(E)/generated/sing-box/00_base.json" "$(E)/generated/xray/00_base.json" | tr -d ' \n'; }
check "默认只记严重错误" test "$(dbg_level)" = '"log":{"level":"fatal","timestamp":true},"log":{"loglevel":"error","access":"none"},'
check "打开后两个内核都记详细日志" bash -c "bash dist/pbox.sh debug on 20 --yes 2>&1 | grep -q '20 分钟后自动关闭'"
check "打开后的日志级别" test "$(dbg_level)" = '"log":{"level":"debug","timestamp":true},"log":{"loglevel":"debug","access":""},'
check "查看状态和体检都提示剩余时间" bash -c "bash dist/pbox.sh debug | grep -q '还剩 20 分钟' && bash dist/pbox.sh doctor 2>&1 | grep -q '调试日志开着'"
check "没到期时检查不动它" bash -c "bash dist/pbox.sh debug check && grep -q '^debug_until=.' '$(E)/state/global.env'"
mkdir -p "$PBOX_ROOT/var/log/pbox" && echo 'from 198.51.100.7:5678' >"$PBOX_ROOT/var/log/pbox/pbox-singbox.log" && echo renewed >"$PBOX_ROOT/var/log/pbox/acme.log"
check "求助用的日志隐去客户端地址" bash -c "bash dist/pbox.sh log --report | grep -q 'from <IP>:5678'"
check "到期后检查会关掉并清空内核日志，证书日志留着" bash -c "PBOX_TEST_NOW=\$((\$(date +%s) + 1300)) bash dist/pbox.sh debug check | grep -q 已关闭 && ! grep -q '^debug_until=.' '$(E)/state/global.env' && test ! -s '$PBOX_ROOT/var/log/pbox/pbox-singbox.log' && grep -q renewed '$PBOX_ROOT/var/log/pbox/acme.log'"
check "关闭后恢复原来的级别" test "$(dbg_level)" = '"log":{"level":"fatal","timestamp":true},"log":{"loglevel":"error","access":"none"},'
check "到期后的任何改动也按平时的级别生成" bash -c "bash dist/pbox.sh debug on 1 --yes >/dev/null 2>&1 && PBOX_TEST_NOW=\$((\$(date +%s) + 120)) bash dist/pbox.sh set block-bt on --yes >/dev/null 2>&1 && grep -q '\"level\": \"fatal\"' '$(E)/generated/sing-box/00_base.json'"
bash dist/pbox.sh debug off >/dev/null 2>&1
check "分钟数超出范围时拒绝" bash -c "! bash dist/pbox.sh debug on 0 && ! bash dist/pbox.sh debug on 241 && ! bash dist/pbox.sh debug on abc && ! grep -q '^debug_until=.' '$(E)/state/global.env'"
check "平时查看日志提示先打开调试" bash -c "bash dist/pbox.sh log | grep -q 'pbox debug on'"
check "菜单里打开再关闭" bash -c "printf '9\n3\n15\n\n0\n0\n' | bash dist/pbox.sh >/dev/null 2>&1; grep -q '^debug_until=.' '$(E)/state/global.env' && printf '9\n3\n\n0\n0\n' | bash dist/pbox.sh >/dev/null 2>&1; ! grep -q '^debug_until=.' '$(E)/state/global.env'"
unset -f dbg_level

echo "自建订阅"
new_root
PBOX_PROTOCOLS="reality-vision hysteria2 anytls" pbox install --yes >/dev/null 2>&1
SV="$PBOX_ROOT/var/lib/pbox/sub"
ss_path() { sed -n 's/^sub_path=//p' "$(E)/state/users/$1.env"; }
ss_port() { sed -n 's/^selfsub_port=//p' "$(E)/state/global.env"; }
check "没有证书时拒绝，不提供明文订阅" bash -c "! bash dist/pbox.sh sub self on --yes && ! test -e '$SV'"
pbox domain set ip --yes >/dev/null 2>&1
check "IP 证书：单独开一个端口，地址用 IP" bash -c "bash dist/pbox.sh sub self on --yes >'$PBOX_ROOT/ss.txt' && grep -q \"https://203.0.113.10:\$(sed -n 's/^selfsub_port=//p' '$(E)/state/global.env')/[0-9a-f]\\{32\\}/clash\" '$PBOX_ROOT/ss.txt'"
check "提供的文件与本机生成的订阅一致" bash -c "for k in v2ray clash singbox; do cmp '$(E)/nodes/users/default/sub/'\$k '$SV/$(ss_path default)/'\$k || exit 1; done"
check "Nginx 只认订阅路径，配置里不含任何人的路径" bash -c "grep -q 'listen $(ss_port) ssl default_server' '$(E)/generated/nginx/nginx.conf' && grep -q 'return 404' '$(E)/generated/nginx/nginx.conf' && ! grep -q '$(ss_path default)' '$(E)/generated/nginx/nginx.conf'"
check "IP 证书时不拒绝不带域名的握手" bash -c "! grep -q ssl_reject_handshake '$(E)/generated/nginx/nginx.conf'"
check "单独的端口记入要放行的端口" bash -c ". dist/pbox.sh; ports_wanted | grep -qx '$(ss_port)/tcp'"
pbox user add bob --yes >/dev/null 2>&1
check "每人一条路径，各自的文件只含自己的节点" bash -c "test '$(ss_path default)' != \"\$(sed -n 's/^sub_path=//p' '$(E)/state/users/bob.env')\" && cmp '$(E)/nodes/users/bob/sub/clash' '$SV/'\$(sed -n 's/^sub_path=//p' '$(E)/state/users/bob.env')/clash"
old_bob=$(ss_path bob)
check "只给一个人换路径：旧路径立即失效，别人不变" bash -c "d=\$(sed -n 's/^sub_path=//p' '$(E)/state/users/default.env'); bash dist/pbox.sh sub self reset bob --yes >/dev/null && ! test -e '$SV/$old_bob' && test -e '$SV/'\$(sed -n 's/^sub_path=//p' '$(E)/state/users/bob.env')/clash && test -e '$SV/'\$d/clash"
check "删除用户后他的订阅目录消失" bash -c "bash dist/pbox.sh user del bob --yes >/dev/null && test \$(ls '$SV' | wc -l) = 1"
mkdir -p "$PBOX_ROOT/var/log/pbox" && echo "GET /$(ss_path default)/clash" >"$PBOX_ROOT/var/log/pbox/pbox-nginx.log"
check "求助用的日志隐去订阅路径" bash -c "bash dist/pbox.sh log --report | grep -q 'GET /<sub-path>/clash'"
check "指定端口与外网端口：地址里用外网端口" bash -c "bash dist/pbox.sh sub self port 31000 41000 --yes | grep -q 'https://203.0.113.10:41000/' && grep -q 'listen 31000 ssl' '$(E)/generated/nginx/nginx.conf'"
check "协议要占用正在提供订阅的端口时拒绝" bash -c "! bash dist/pbox.sh change anytls port 31000 --yes && test \$(sed -n 's/^selfsub_port=//p' '$(E)/state/global.env') = 31000"
check "端口写错时拒绝" bash -c "! bash dist/pbox.sh sub self port abc && ! bash dist/pbox.sh sub self port 70000 && ! bash dist/pbox.sh sub self port \$(sed -n 's/^port=//p' '$(E)/state/protocols/anytls.env')"
check "关闭后文件删除，Nginx 不再需要" bash -c "bash dist/pbox.sh sub self off --yes >/dev/null && ! test -e '$SV' && ! test -e '$(E)/generated/nginx'"
export PBOX_TEST_DNS_A=203.0.113.10
pbox domain set s.example.com --yes >/dev/null 2>&1
check "再开地址不变；域名证书时不带域名的握手直接拒绝" bash -c "p=\$(sed -n 's/^sub_path=//p' '$(E)/state/users/default.env'); bash dist/pbox.sh sub self on --yes | grep -q \"s.example.com:41000/\$p/clash\" && grep -q ssl_reject_handshake '$(E)/generated/nginx/nginx.conf' && grep -q 'server_name s.example.com;' '$(E)/generated/nginx/nginx.conf'"
pbox site on --yes >/dev/null 2>&1
check "开了伪装站就挂到 443 的网站上，不再单独开端口" bash -c "bash dist/pbox.sh sub | grep -q 'https://s.example.com/[0-9a-f]\\{32\\}/clash' && ! grep -q 'listen 31000' '$(E)/generated/nginx/nginx.conf' && grep -q 'try_files /\$1/\$2 =404' '$(E)/generated/nginx/nginx.conf'"
check "伪装站转发别的网站时，猜错的路径也交给那个网站" bash -c "bash dist/pbox.sh site source https://www.example.net --yes >/dev/null 2>&1; grep -q 'try_files /\$1/\$2 @pbox_site' '$(E)/generated/nginx/nginx.conf' && grep -q 'location @pbox_site' '$(E)/generated/nginx/nginx.conf'"
check "体检检查订阅" bash -c "bash dist/pbox.sh doctor 2>&1 | grep -q '自建订阅可以取到'"
check "说明只含本机节点，合并多台机器要用私有仓库" bash -c "bash dist/pbox.sh sub | grep -q '只能用 GitLab 私有仓库'"
check "只开了自建订阅时，合并机器的命令指向私有仓库" bash -c "! bash dist/pbox.sh sub machines >'$PBOX_ROOT/m.txt' 2>&1; grep -q '合并多台机器只能用 GitLab' '$PBOX_ROOT/m.txt' && ! bash dist/pbox.sh sub invite 2>/dev/null"
check "菜单里可以开关" bash -c "printf '5\n6\n\n0\n0\n' | bash dist/pbox.sh >/dev/null 2>&1; grep -qx 'selfsub=0' '$(E)/state/global.env'"
unset PBOX_TEST_DNS_A
unset -f ss_path ss_port

echo "下载镜像"
eval "$(sed -n '/^mirror_norm()/,/^}/p' src/cores/core.sh)"
check "镜像前缀末尾补上斜杠" test "$(mirror_norm https://m.example.com)" = 'https://m.example.com/'
check "已有斜杠时不重复" test "$(mirror_norm https://m.example.com/gh/)" = 'https://m.example.com/gh/'
mn_bad() { ! mirror_norm "$1"; }
check "不是 https 的拒绝" mn_bad http://m.example.com
check "空的拒绝" mn_bad ""

echo "连不上向导"
new_root
PBOX_PROTOCOLS="reality-vision hysteria2 anytls" pbox install --yes >/dev/null 2>&1
check "给出一条命令测完所有 TCP 端口，不含 UDP 协议" bash -c "bash dist/pbox.sh fix --yes | grep -q 'for p in 443 8443; do nc -vz -w 5 203.0.113.10 \\\$p; done'"
check "有端口不通：确认后把那个协议换到新端口，别的不动" bash -c "printf '2\n8443\ny\n' | bash dist/pbox.sh fix >/dev/null 2>&1; ! grep -qx port=8443 '$(E)/state/protocols/anytls.env' && grep -qx port=443 '$(E)/state/protocols/reality-vision.env'"
check "不确认就不改" bash -c "printf '2\n443\n\n' | bash dist/pbox.sh fix >/dev/null 2>&1; grep -qx port=443 '$(E)/state/protocols/reality-vision.env'"
check "全都不通：开 Argo 隧道节点" bash -c "printf '3\ny\n' | bash dist/pbox.sh fix >/dev/null 2>&1; test -f '$(E)/state/protocols/vless-ws.env' && grep -q Argo- '$(E)/nodes/links.txt'"
check "已有 Argo 时只指路，不重复开" bash -c "printf '3\n' | bash dist/pbox.sh fix 2>&1 | grep '名字里带 Argo' >/dev/null"
check "都通：给出客户端一侧的检查步骤，不改配置" bash -c "before=\$(cat '$(E)/nodes/links.txt'); printf '1\n' | bash dist/pbox.sh fix 2>&1 | grep '时间要准' >/dev/null && [ \"\$before\" = \"\$(cat '$(E)/nodes/links.txt')\" ]"

echo "Reality-gRPC"
new_root
check "装上 Reality-gRPC，不占 Reality 的 443" bash -c "PBOX_PROTOCOLS='reality-vision reality-grpc' bash dist/pbox.sh install --yes && grep -qx port=443 '$(E)/state/protocols/reality-vision.env' && grep -qx port=8443 '$(E)/state/protocols/reality-grpc.env'"
check "入站是 Reality 加 gRPC，不带 Vision 流控" bash -c "python3 -c 'import json,sys; i=json.load(open(sys.argv[1]))[\"inbounds\"][0]; sys.exit(not (i[\"tls\"][\"reality\"][\"enabled\"] and i[\"transport\"][\"type\"]==\"grpc\" and len(i[\"transport\"][\"service_name\"])>=8 and \"flow\" not in i[\"users\"][0]))' '$(E)/generated/sing-box/10_reality-grpc.json'"
check "与 Reality-Vision 各用各的密钥" bash -c "[ \"\$(sed -n 's/^private_key=//p' '$(E)/state/protocols/reality-grpc.env')\" != \"\$(sed -n 's/^private_key=//p' '$(E)/state/protocols/reality-vision.env')\" ]"
check "链接、sing-box、Clash 三种配置里都有" bash -c "svc=\$(sed -n 's/^service=//p' '$(E)/state/protocols/reality-grpc.env') && grep -q \"^vless://.*:8443?.*security=reality.*type=grpc&serviceName=\$svc&mode=gun#gRPC-IPv4\" '$(E)/nodes/links.txt' && ! grep '#gRPC-' '$(E)/nodes/links.txt' | grep -q flow= && python3 -m json.tool '$(E)/nodes/sing-box.json' >/dev/null && grep -q \"\\\"service_name\\\": \\\"\$svc\\\"\" '$(E)/nodes/sing-box.json' && grep -q \"grpc-service-name: \\\"\$svc\\\"\" '$(E)/nodes/mihomo.yaml'"
check "换伪装目标和握手特征" bash -c "bash dist/pbox.sh change reality-grpc sni www.example.net --yes && bash dist/pbox.sh change reality-grpc fp firefox --yes && grep 'sni=www.example.net.*fp=firefox' '$(E)/nodes/links.txt' | grep '#gRPC-IPv4' >/dev/null"

echo "SOCKS5"
new_root
check "装上 SOCKS5" bash -c "PBOX_PROTOCOLS='reality-vision socks' bash dist/pbox.sh install --yes"
check "SOCKS5 入站每个用户一组账号" bash -c "bash dist/pbox.sh user add bob --yes && python3 -c 'import json,sys; i=json.load(open(sys.argv[1]))[\"inbounds\"][0]; u=i[\"users\"]; sys.exit(not (i[\"type\"]==\"socks\" and sorted(x[\"username\"] for x in u)==[\"bob\",\"default\"] and u[0][\"password\"]!=u[1][\"password\"]))' '$(E)/generated/sing-box/10_socks.json'"
check "SOCKS5 的密码不是用户密码本身" bash -c "pw=\$(sed -n 's/^password=//p' '$(E)/state/users/default.env'); ! grep -q \"\$pw\" '$(E)/generated/sing-box/10_socks.json'"
check "SOCKS5 链接是 v2rayN 的写法" bash -c "python3 -c 'import base64,json,sys
l=[x for x in open(sys.argv[1]) if x.startswith(\"socks://\") and x.rstrip().endswith(\"#SOCKS5-IPv4-default\")][0]
u,pw=base64.b64decode(l[8:].split(\"@\")[0]).decode().split(\":\")
i=[x for x in json.load(open(sys.argv[2]))[\"inbounds\"][0][\"users\"] if x[\"username\"]==\"default\"][0]
sys.exit(not (u==\"default\" and pw==i[\"password\"]))' '$(E)/nodes/links.txt' '$(E)/generated/sing-box/10_socks.json'"
check "SOCKS5 在两种客户端配置里" bash -c "python3 -m json.tool '$(E)/nodes/sing-box.json' >/dev/null && grep -q '\"type\": \"socks\"' '$(E)/nodes/sing-box.json' && grep -q 'type: socks5' '$(E)/nodes/mihomo.yaml'"
check "SOCKS5 只放行 TCP" bash -c "p=\$(sed -n 's/^port=//p' '$(E)/state/protocols/socks.env'); bash dist/pbox.sh nodes | grep -q \"\$p/tcp\" && ! bash dist/pbox.sh nodes | grep -q \"\$p/udp\""
check "SOCKS5 默认不限来源" bash -c "! grep -q source_ip_cidr '$(E)/generated/sing-box/00_base.json'"
check "SOCKS5 只允许指定来源，只作用于它自己" bash -c "bash dist/pbox.sh change socks allow 198.51.100.20,2001:db8::/32 --yes && python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[\"route\"][\"rules\"][0]; a,b=r[\"rules\"]; sys.exit(not (r[\"mode\"]==\"and\" and r[\"action\"]==\"reject\" and a==dict(inbound=[\"socks\"]) and b[\"invert\"] and b[\"source_ip_cidr\"]==[\"198.51.100.20/32\",\"2001:db8::/32\",\"127.0.0.1/32\",\"::1/128\"]))' '$(E)/generated/sing-box/00_base.json'"
check "来源写错时拒绝，逗号后的空格不要紧" bash -c "! bash dist/pbox.sh change socks allow abc --yes && ! bash dist/pbox.sh change socks allow 1.2.3.4/33x --yes && bash dist/pbox.sh change socks allow '1.2.3.4, 5.6.7.8' --yes && grep -qx 'allow=1.2.3.4,5.6.7.8' '$(E)/state/protocols/socks.env'"
check "改回不限后规则去掉" bash -c "bash dist/pbox.sh change socks allow any --yes && ! grep -q source_ip_cidr '$(E)/generated/sing-box/00_base.json'"
check "停用 SOCKS5 后规则跟着去掉" bash -c "bash dist/pbox.sh change socks allow 1.2.3.4 --yes && bash dist/pbox.sh del socks --yes && ! grep -q source_ip_cidr '$(E)/generated/sing-box/00_base.json' && bash dist/pbox.sh add socks --yes"
socks_before=$(grep '^socks://.*-default$' "$(E)/nodes/links.txt")
check "重置用户后 SOCKS5 的密码跟着变" bash -c "bash dist/pbox.sh user reset default --yes && [ \"\$(grep '^socks://.*-default\$' '$(E)/nodes/links.txt')\" != '$socks_before' ]"

echo "启用前的风险确认"
new_root
pbox install --yes >/dev/null 2>&1
check "推荐配置的安装计划里没有风险提醒" bash -c "R=\$(mktemp -d); PBOX_ROOT=\$R bash dist/pbox.sh install --yes 2>&1 | grep -E '个端口|全随机' >/dev/null; [ \$? = 1 ]"
check "Shadowsocks 不确认就不启用" bash -c "printf '\n' | bash dist/pbox.sh add ss2022 2>&1 | grep '全随机字节' >/dev/null; test ! -e '$(E)/state/protocols/ss2022.env'"
check "输入 y 才启用" bash -c "printf 'y\n' | bash dist/pbox.sh add ss2022 >/dev/null 2>&1; test -e '$(E)/state/protocols/ss2022.env'"
check "SOCKS5 填了来源就不必再确认" bash -c "printf '198.51.100.7\n' | bash dist/pbox.sh add socks >/dev/null 2>&1; grep -qx 'allow=198.51.100.7' '$(E)/state/protocols/socks.env'"
check "不填来源又不确认就不启用" bash -c "bash dist/pbox.sh del socks --yes && printf '\n\n' | bash dist/pbox.sh add socks >/dev/null 2>&1; test ! -e '$(E)/state/protocols/socks.env'"
check "不填来源、确认后启用，来源不限" bash -c "printf '\ny\n' | bash dist/pbox.sh add socks >/dev/null 2>&1; test -e '$(E)/state/protocols/socks.env' && ! grep -q '^allow=' '$(E)/state/protocols/socks.env'"
check "来源写错时不启用" bash -c "bash dist/pbox.sh del socks --yes && printf 'abc\n' | bash dist/pbox.sh add socks >/dev/null 2>&1; test ! -e '$(E)/state/protocols/socks.env'"
check "--yes 不拦，装好后提醒" bash -c "bash dist/pbox.sh add socks --yes 2>&1 | grep '不加密' >/dev/null && test -e '$(E)/state/protocols/socks.env'"
check "对外端口到 6 个时要确认" bash -c "printf '\n' | bash dist/pbox.sh add tuic 2>&1 | grep '6 个端口' >/dev/null; test ! -e '$(E)/state/protocols/tuic.env'"
check "已经超过之后不再提醒" bash -c "bash dist/pbox.sh add tuic --yes >/dev/null && printf '\n' | bash dist/pbox.sh add anytls >/dev/null 2>&1; test -e '$(E)/state/protocols/anytls.env'"
check "只听本机的协议不算对外端口" bash -c "R=\$(mktemp -d); export PBOX_ROOT=\$R; PBOX_PROTOCOLS='reality-vision hysteria2 tuic anytls reality-grpc' bash dist/pbox.sh install --yes >/dev/null 2>&1 && printf '\n' | bash dist/pbox.sh add vless-ws >/dev/null 2>&1; test -e \$R/etc/pbox/state/protocols/vless-ws.env"
check "安装计划里列出风险与端口数，来源可由应答传入" bash -c "R=\$(mktemp -d); PBOX_ROOT=\$R PBOX_PROTOCOLS='reality-vision hysteria2 tuic anytls ss2022 socks' PBOX_SOCKS_ALLOW='198.51.100.7, 2001:db8::/32' bash dist/pbox.sh install --yes >\$R/out.txt 2>&1 && grep -q '全随机字节' \$R/out.txt && grep -q '7 个端口' \$R/out.txt && grep -qx 'allow=198.51.100.7,2001:db8::/32' \$R/etc/pbox/state/protocols/socks.env"
check "自选安装时 SOCKS5 顺带问来源" bash -c "R=\$(mktemp -d); { printf 'c\n\n\n\n\n'; printf '\n\n\n\n\n\n\n'; printf 'y\n\n198.51.100.9\n'; yes ''; } | head -60 | PBOX_ROOT=\$R bash dist/pbox.sh install >/dev/null 2>&1; grep -qx 'allow=198.51.100.9' \$R/etc/pbox/state/protocols/socks.env && test ! -e \$R/etc/pbox/state/protocols/ss2022.env"

echo "链式中转"
new_root
land="$PBOX_ROOT"
export PBOX_TEST_REGION=HK
pbox install --yes >/dev/null 2>&1
pbox change hysteria2 hop on --yes >/dev/null 2>&1
code=$(pbox relay invite 2>/dev/null | awk '/pbox relay forward/ {print $NF}')
check "中转码只有地址和端口" test "$(printf %s "$code" | openssl base64 -d -A)" = "fwd|HK|203.0.113.10|443/tcp+udp"
check "落地机上不能用自己的中转码" bash -c "! bash dist/pbox.sh relay forward '$code'"
new_root
relay="$PBOX_ROOT"
export PBOX_TEST_IP4=198.51.100.20 PBOX_TEST_REGION=JP
pbox install --yes >/dev/null 2>&1
check "无效的中转码被拒绝" bash -c "! bash dist/pbox.sh relay forward abc && ! test -e '$(E)/state/relay.env'"
code2=$(pbox relay forward "$code" 2>/dev/null | awk '/pbox relay via/ {print $NF}')
rj="$(E)/generated/sing-box/20_relay.json"
check "转发入站是合法 JSON" json_ok "$rj"
check "443 被本机节点占着，转发改用别的端口，TCP 和 UDP 都转" bash -c "python3 -c 'import json,sys; i=json.load(open(sys.argv[1]))[\"inbounds\"][0]; sys.exit(not (i[\"type\"]==\"direct\" and i[\"listen_port\"]!=443 and \"network\" not in i and i[\"override_address\"]==\"203.0.113.10\" and i[\"override_port\"]==443))' '$rj'"
check "转发的路由排在最前，不受私网拦截影响" bash -c "python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[\"route\"][\"rules\"][0]; sys.exit(not (r[\"inbound\"][0].startswith(\"relay-HK-\") and r[\"outbound\"]==\"direct\"))' '$(E)/generated/sing-box/00_base.json'"
lp=$(printf %s "$code2" | openssl base64 -d -A | sed 's/.*=//')
check "回传的中转码写着中转机的地址和端口" test "$(printf %s "$code2" | openssl base64 -d -A)" = "via|JP|198.51.100.20|443=$lp"
check "转发的端口已放行" bash -c "grep -qx '$lp/tcp' <(PBOX_ROOT='$relay' bash -c '. dist/pbox.sh; CUR=\$STATE; ports_wanted') && grep -qx '$lp/udp' <(PBOX_ROOT='$relay' bash -c '. dist/pbox.sh; CUR=\$STATE; ports_wanted')"
check "再运行一次沿用原来的端口" test "$(pbox relay forward "$code" 2>/dev/null | awk '/pbox relay via/ {print $NF}')" = "$code2"
check "同名但指向别的机器时拒绝" bash -c "! bash dist/pbox.sh relay forward '$(printf %s 'fwd|HK|203.0.113.99|443/tcp' | openssl base64 -A)'"
check "换个名字就可以" pbox relay forward "$(printf %s 'fwd|HK|203.0.113.99|443/tcp' | openssl base64 -A)" HK2
export PBOX_ROOT="$land" PBOX_TEST_IP4=203.0.113.10 PBOX_TEST_REGION=HK
check "落地机上不能用中转机给别人的码" bash -c "! bash dist/pbox.sh relay via '$code'"
check "落地机加上中转" pbox relay via "$code2"
check "经中转的节点用中转机的地址和端口" grep -q "@198.51.100.20:$lp?.*#HK-Reality-Via-JP" "$(E)/nodes/links.txt"
check "经中转的 Hysteria2 不带端口跳跃，直连的仍带" bash -c "grep '#HK-Hysteria2-Via-JP' '$(E)/nodes/links.txt' | grep -vq mport && grep '#HK-Hysteria2-IPv4' '$(E)/nodes/links.txt' | grep -q mport"
check "精简时经中转的节点优先" bash -c "bash dist/pbox.sh set compact-nodes on --yes && l='$(E)/nodes/links.txt' && [ \$(grep -c . \$l) = 2 ] && grep -q 'HK-Reality-Via-JP\$' \$l && grep -q 'HK-Hysteria2-Via-JP\$' \$l && bash dist/pbox.sh set compact-nodes off --yes"
check "两种客户端配置里都有" bash -c "json_ok() { python3 -m json.tool \"\$1\"; }; json_ok '$(E)/nodes/sing-box.json' >/dev/null && grep -q '\"server_port\": $lp' '$(E)/nodes/sing-box.json' && grep -q 'HK-Reality-Via-JP' '$(E)/nodes/mihomo.yaml'"
export PBOX_TEST_DNS_A=203.0.113.10
pbox domain set w.example.com --yes >/dev/null 2>&1
pbox site on --yes >/dev/null 2>&1
pbox add trojan --yes >/dev/null 2>&1
check "经中转的 Trojan 仍以自己的域名握手" grep -q "@198.51.100.20:$lp?security=tls&sni=w.example.com.*#HK-Trojan-Via-JP" "$(E)/nodes/links.txt"
check "建中转之后才开的协议，生效时提醒还没经中转" bash -c "bash dist/pbox.sh add tuic --yes 2>&1 | grep '还没有经 JP 中转' >/dev/null && ! grep -q 'TUIC-Via-JP' '$(E)/nodes/links.txt' && bash dist/pbox.sh relay 2>&1 | grep '还没有经 JP 中转' >/dev/null"
unset PBOX_TEST_DNS_A
check "删除中转后经它的节点消失" bash -c "bash dist/pbox.sh relay via off JP >/dev/null && ! grep -q Via-JP '$(E)/nodes/links.txt'"
export PBOX_ROOT="$relay" PBOX_TEST_IP4=198.51.100.20
check "新协议挑端口时避开转发占用的端口" bash -c "bash dist/pbox.sh relay forward '$(printf %s 'fwd|HK3|203.0.113.50|8443/tcp 2053/tcp 2083/udp' | openssl base64 -A)' >/dev/null && bash dist/pbox.sh add anytls --yes >/dev/null && grep -qx 'port=2083' '$(E)/state/protocols/anytls.env' && bash dist/pbox.sh relay forward off HK3 >/dev/null"
check "中转机删除转发" bash -c "bash dist/pbox.sh relay forward off HK >/dev/null && bash dist/pbox.sh relay forward off HK2 >/dev/null && ! test -e '$rj'"
export PBOX_TEST_IP4=203.0.113.10
unset PBOX_TEST_REGION

echo "VLESS 的自定义选项"
new_root
PBOX_PROTOCOLS="reality-vision vless-ws" pbox install --yes >/dev/null 2>&1
check "Reality 换握手特征" bash -c "bash dist/pbox.sh change reality-vision fp firefox --yes && grep -q '^vless://.*security=reality.*fp=firefox' '$(E)/nodes/links.txt' && grep -q 'client-fingerprint: firefox' '$(E)/nodes/mihomo.yaml' && python3 -m json.tool '$(E)/nodes/sing-box.json'"
check "不认识的握手特征被拒绝" bash -c "! bash dist/pbox.sh change reality-vision fp netscape --yes"
old_pbk=$(sed -n 's/^public_key=//p' "$(E)/state/protocols/reality-vision.env")
u_before=$(sed -n 's/^uuid=//p' "$(E)/state/users/default.env")
check "只换 Reality 的密钥，不动用户凭据" bash -c "bash dist/pbox.sh change reality-vision keys --yes && ! grep -qx 'public_key=$old_pbk' '$(E)/state/protocols/reality-vision.env' && grep -qx 'uuid=$u_before' '$(E)/state/users/default.env'"
check "精简时 Argo 有优选就只列优选" bash -c "bash dist/pbox.sh change vless-ws cdn www.visa.com.sg --yes && bash dist/pbox.sh set compact-nodes on --yes && grep -q 'Argo-Temp-Pref\$' '$(E)/nodes/links.txt' && ! grep -q 'Argo-Temp\$' '$(E)/nodes/links.txt' && bash dist/pbox.sh set compact-nodes off --yes && bash dist/pbox.sh change vless-ws cdn off --yes"
check "Argo 节点换连接端口" bash -c "bash dist/pbox.sh change vless-ws edge-port 2053 --yes && grep -q '^vless://.*:2053?.*type=ws' '$(E)/nodes/links.txt' && grep -q '\"server_port\": 2053' '$(E)/nodes/sing-box.json'"
check "Cloudflare 不支持的端口被拒绝" bash -c "! bash dist/pbox.sh change vless-ws edge-port 8080 --yes"
check "握手特征对不相关的协议不可用" bash -c "! bash dist/pbox.sh change hysteria2 fp firefox --yes"

echo "BBR"
new_root
pbox install --yes >/dev/null 2>&1
check "开启后写入自己的参数文件并登记到清单" bash -c "bash dist/pbox.sh bbr on && grep -q 'tcp_congestion_control=bbr' '$PBOX_ROOT/etc/sysctl.d/99-pbox-bbr.conf' && grep -q '99-pbox-bbr.conf' '$(E)/manifest'"
check "关闭后文件与清单记录都删除" bash -c "bash dist/pbox.sh bbr off && ! test -e '$PBOX_ROOT/etc/sysctl.d/99-pbox-bbr.conf' && ! grep -q '99-pbox-bbr.conf' '$(E)/manifest'"
check "内核不支持时拒绝且不留文件" bash -c "! PBOX_TEST_BBR=0 bash dist/pbox.sh bbr on && ! test -e '$PBOX_ROOT/etc/sysctl.d/99-pbox-bbr.conf'"
check "卸载时一并撤销" bash -c "bash dist/pbox.sh bbr on && bash dist/pbox.sh uninstall --yes && ! test -e '$PBOX_ROOT/etc/sysctl.d/99-pbox-bbr.conf'"

echo "卸载"
new_root
pbox install --yes >/dev/null 2>&1
check "卸载成功" pbox uninstall --yes
check "卸载后配置目录不存在" test ! -e "$(E)"

echo
echo "通过 $pass，失败 $fail"
[ "$fail" = 0 ]
