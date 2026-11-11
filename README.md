# 端口转发一键脚本（NAT 中转机 → 落地机）

在 **Alpine Linux** 上一条命令把「本机端口」转发到「落地机 IP:端口」，
TCP + UDP 全开，自动持久化，重启不丢。
（Debian/Ubuntu 也能跑，只是重启持久化需要额外装 `iptables-persistent`。）

> 适用场景：你有一台中转机（NAT 机）做入口，真正服务跑在另一台「落地机」上。

---

## 一键使用

```sh
wget -qO /tmp/portfwd.sh https://raw.githubusercontent.com/louwailou777/alpine-portfwd/main/portfwd.sh \
  && sh /tmp/portfwd.sh
```

> 仓库地址里的 `louwailou777` 要换成**你的 GitHub 用户名**（不是邮箱）。
> 登录后右上角头像 → 菜单里 `Signed in as xxx` 那个 `xxx` 才是用户名。

不想落地文件也可以（这条会把脚本当参数传给 sh，交互输入仍然正常）：

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/louwailou777/alpine-portfwd/main/portfwd.sh)"
```

跑起来是一个向导，跟着回车就行：

```
==============================================================
        端口转发一键配置  ·  转发机(NAT) → 落地机
==============================================================

[1/5] 落地机地址与端口
      落地机 IP，例：1.2.3.4
    落地机 IP: 1.2.3.4
      落地机上真正跑服务的端口（不是本机端口）
      常用：443 / 80 / 8443 / 8080
    落地机端口（必填，不能回车跳过）: 8443

[2/5] 线路质量检测
      先测本机到落地机的延迟和丢包，确认值得转发再往下走
    正在 ping 1.2.3.4 共 10 次（预计 10-20 秒）...
PING 1.2.3.4 (1.2.3.4): 56 data bytes
64 bytes from 1.2.3.4: seq=0 ttl=52 time=42.318 ms
...
--- 1.2.3.4 ping statistics ---
10 packets transmitted, 10 packets received, 0% packet loss
round-trip min/avg/max = 41.902/43.117/45.006 ms

    -------------------- 线路检测 --------------------
      落地机           : 1.2.3.4:8443
      ping             : 共 10 次，丢包 0%
      延迟 min/avg/max : 41.902/43.117/45.006 ms
      结论             : [优秀] 平均 43.117 ms，非常适合转发
    --------------------------------------------------
    是否继续配置转发？ [Y/n]:

[3/5] 环境与依赖检查
[OK] iptables 可用（iptables）
[OK] 基础命令齐全
[OK] 内核 IPv4 转发已开启并持久化

[4/5] 转发机端口（本机 NAT 端口）
      这是转发机上的端口，路由器/安全组会把外网端口指向它
      已生成随机可用端口：49372
    直接回车使用随机端口，或输入其他端口 [49372]:

[5/5] 确认并写入
      ------------------------------------------------
        转发机本地端口 : 49372   (TCP + UDP)
        落地机         : 1.2.3.4:8443
        线路质量       : 丢包 0%，平均 43.117 ms
        内核转发       : 已开启
        持久化         : 保存规则 + 开机自启
      ------------------------------------------------
    确认写入？ [Y/n]:
```

> **落地机端口没有默认值**，必须自己输入，避免所有落地机都被写成 443。
> 只有本机那个 NAT 端口会给你随机默认值（回车即用）。

写入完成后会打印**你还需要手动做的 3 件事**（路由器映射 / 防火墙放行 / 客户端参数），
并自动探测本机公网 IP 填进去。

---

## 线路质量预检（判定标准）

脚本会 ping 10 次，按**平均延迟 + 丢包率**给结论，不好的线路默认让你别继续：

| 结论 | 条件 | 默认选项 |
|---|---|---|
| `[优秀]` | 平均 < 60 ms，丢包 ≤ 2% | `[Y/n]` |
| `[良好]` | 平均 < 120 ms，丢包 ≤ 2% | `[Y/n]` |
| `[一般]` | 平均 < 200 ms，或丢包 ≤ 10% | `[y/N]` |
| `[偏高]` | 平均 ≥ 200 ms，或丢包 > 10% | `[y/N]`，额外跑 `mtr` 看逐跳丢包 |
| `[严重]` | 丢包 ≥ 50% | `[y/N]`，强烈建议换落地机 |
| `[未知]` | 没有 `ping` 或执行失败 | `[Y/n]`，不拦你 |

阈值都写在脚本顶部，觉得太松/太严直接改：

```sh
P_GOOD_MS=60      # 优秀线
P_OK_MS=120       # 良好线
P_BAD_MS=200      # 超过就当“偏高”
P_LOSS_OK=2       # 可接受丢包 %
P_LOSS_BAD=10     # 超过就当“偏高”
```

**注意**：100% 丢包常常是落地机屏蔽了 ICMP，不代表 TCP 不通。脚本会提示你，
并且不阻止继续（可以用 `portfwd.sh test` 复核 TCP）。

只想测线路、不写任何规则：

```sh
portfwd.sh probe 1.2.3.4
portfwd.sh probe 1.2.3.4 --probe-count 20
```

不想测就跳过：

```sh
portfwd.sh --no-probe
```

---

## 精简系统适配（依赖提前装好）

脚本第一步就是「依赖自检 + 自动补装」，不会写了一半才报错：

| 场景 | 脚本动作 |
|---|---|
| 没有 `iptables` | 按包管理器自动装：`apk` / `apt` / `dnf` / `yum` / `microdnf` / `opkg` |
| 内核模块没加载 | 显式 `modprobe ip_tables iptable_filter iptable_nat nf_nat nf_conntrack xt_MASQUERADE xt_comment xt_conntrack` |
| `iptables` 后端不对 | nat 表不可用时自动切 `iptables-legacy` / `iptables-nft` |
| busybox 裁掉了 applet | 检测 `awk/sed/grep/head/cut/sort/tr/mktemp`，缺了就补 `busybox`/`coreutils`/`gawk` |
| 没有 `sysctl` | 直接写 `/proc/sys/net/ipv4/ip_forward` |
| 没有 `iptables-save` | 改用开机钩子按 `/etc/portfwd.conf` 重放规则 |
| 没有 `nc` / `curl` / `wget` | 只是跳过「连通性测试 / 公网 IP 探测」，不影响转发 |
| 完全装不上 | 直接报错并告诉你缺什么、该装哪个包，不会留半套规则 |

脚本本身只用 POSIX sh（busybox ash 兼容），不用 bash 数组、不用 `local`，
删规则按**规则序号**走，不依赖 `xargs`/`sed` 这些可能被裁掉的小工具。

容器里跑的话仍需：

```sh
docker run ... --cap-add NET_ADMIN --cap-add NET_RAW --sysctl net.ipv4.ip_forward=1
```

---

## 它替你做了什么

| 手工步骤 | 脚本动作 |
|---|---|
| `apk add iptables` | 检测不到就自动装（apk / apt / dnf / yum / opkg） |
| `sysctl -w net.ipv4.ip_forward=1` + 写 `sysctl.conf` | 自动执行，已存在则改为 1，不重复追加 |
| `iptables -t nat -A PREROUTING ... DNAT` | `-C` 查重后再加，**重复执行不会叠加** |
| `iptables -t nat -A POSTROUTING ... MASQUERADE` | 同上 |
| `/etc/init.d/iptables save` + `rc-update add iptables default` | 自动执行，并额外装 `/etc/local.d/portfwd.start` 开机钩子 |
| 手工改端口要重敲一遍命令 | 映射存在 `/etc/portfwd.conf`，改文件后 `portfwd.sh apply` |

---

## 命令一览

```sh
portfwd.sh                       # 向导模式（推荐）
portfwd.sh probe 1.2.3.4   # 只测线路质量，不写任何规则
portfwd.sh list                  # 看映射、公网 IP、当前 NAT 规则
portfwd.sh test                  # 自检：规则是否完整 + 落地机 ping/TCP
portfwd.sh rm 10888              # 删除某条映射（连带清规则）
portfwd.sh apply                 # 按 /etc/portfwd.conf 全量重放（幂等）
portfwd.sh open-port 10888       # 本机 iptables 放行该端口
portfwd.sh uninstall             # 彻底卸载（规则 + 配置 + 开机钩子）
portfwd.sh help                  # 帮助
```

## 无人值守 / 批量

```sh
# 全参数，不交互（-y 跳过确认；线路检测仍会跑并打印结论）
portfwd.sh add -l 10888 -r 1.2.3.4 -p 443 -y

# 位置参数写法
portfwd.sh 10888 1.2.3.4 443

# 一次加多条
portfwd.sh 10888 1.2.3.4 443 10889 1.2.3.4 8443

# 完全不想 ping（比如落地机封 ICMP）
portfwd.sh -y --no-probe 10888 1.2.3.4 443

# 只测 5 次
portfwd.sh probe 1.2.3.4 --probe-count 5
```

也可以只给一部分参数，缺的项会自动进入提问：

```sh
portfwd.sh add -r 1.2.3.4 -p 443     # 只问本地端口
```

> ⚠️ 落地机端口 `-p` **没有默认值**：无人值守（`-y`）运行时必须显式给出，
> 否则脚本会因为没有终端输入而报错退出——这是故意的，避免所有落地机都被写成 443。

---

## 持久化是怎么做的

1. `iptables-save > /etc/iptables/rules-save`（同时调用 `/etc/init.d/iptables save`）
2. `rc-update add iptables default` —— 开机由 iptables 服务恢复规则
3. 安装 `/usr/local/sbin/portfwd` + `/etc/local.d/portfwd.start` —— 开机再按
   `/etc/portfwd.conf` 重放一遍，保证 `ip_forward` 和映射最终一致

三者叠加，正常重启、`rc-service iptables restart` 都不会丢。

---

## 常见问题

**Q：客户端连不上？**
按顺序查：
1. 转发机上 `portfwd.sh test` —— 规则全不全、落地机通不通；
2. 路由器/安全组有没有把**外网端口**指向**本机 NAT 端口**；
3. 落地机自己的防火墙有没有放行它的服务端口；
4. 落地机回程路由是否正常（本脚本已用 MASQUERADE，回包会先回到转发机）。

**Q：家用路由器怎么配？**
在「端口转发 / 虚拟服务器 / NAT」里加一条：
`外部端口` 任选（比如 443） → `内部 IP` 填转发机内网 IP → `内部端口` 填脚本给的 NAT 端口，
协议选 TCP+UDP（或各建一条）。

**Q：云服务器呢？**
在安全组/防火墙里放行「外网端口」（或直接放行 NAT 端口）TCP+UDP 入方向。

**Q：反复执行会不会加重复规则？**
不会。脚本加规则前用 `iptables -C` 查重，并给自己加的规则打 `portfwd:` 标记，
每次重放前先清掉旧的再写，所以换落地机 IP 也不会留残留。

**Q：跑在 Docker 容器里？**
容器需要 `--cap-add NET_ADMIN --cap-add NET_RAW --sysctl net.ipv4.ip_forward=1`，
并且 OpenRC 不生效，开机自启会被跳过（启动命令里执行一次脚本即可）。

**Q：Alpine 内存运行（diskless）重启配置就没了？**
执行一次 `lbu commit` 把 `/etc` 和 `/usr/local` 存盘。

**Q：想换落地机？**
`rm 端口` 再重加，或者直接 `add` 同端口覆盖，然后 `apply`。

---

## 原理

```
客户端 ──► 转发机:外网端口 ──(DNAT)──► 落地机:服务端口
                 │                        │
                 └──(MASQUERADE 源地址伪装)──┘   ← 回包先回转发机，再由它转回客户端
```

iptables 侧就 4 条（TCP/UDP 各 2 条）：

```sh
iptables -t nat -A PREROUTING  -p tcp --dport 49372 -j DNAT --to-destination 1.2.3.4:443
iptables -t nat -A PREROUTING  -p udp --dport 49372 -j DNAT --to-destination 1.2.3.4:443
iptables -t nat -A POSTROUTING -p tcp -d 1.2.3.4 --dport 443 -j MASQUERADE
iptables -t nat -A POSTROUTING -p udp -d 1.2.3.4 --dport 443 -j MASQUERADE
```

配合 `net.ipv4.ip_forward = 1`。

---

## License

MIT
