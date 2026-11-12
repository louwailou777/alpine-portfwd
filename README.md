# portfwd

基于 iptables NAT 的端口转发脚本，把中转机（NAT）上的端口转发到落地机，支持 TCP/UDP、幂等执行与开机持久化。

> **适用范围**：本项目只负责中转机（线路机）侧的端口转发。落地机需提前部署并运行节点服务，
> 不涉及节点搭建、协议配置与落地机运维。

## 特性

- **幂等**：写入前经 `iptables -C` 校验，重复执行不产生重复规则
- **可回收**：规则携带 `portfwd:` 标记，重放前清除历史规则，切换落地机无残留
- **自动放行 FORWARD**：同时写入转发放行规则，ufw 默认 `routed: deny` 时也能正常转发
- **线路预检**：配置前统计延迟与丢包，按阈值输出可用性结论
- **持久化**：systemd 服务或 OpenRC 钩子，重启自动恢复
- **多发行版**：Alpine、Debian、Ubuntu 及同类系统
- **精简系统适配**：自动补齐依赖、加载内核模块、回退 iptables 后端
- **纯 POSIX sh**：兼容 dash 与 busybox ash，不依赖 bash 扩展

## 环境要求

- Linux 主机，root 权限（普通用户可用 `sudo`，脚本会自动提权重跑）
- Alpine（OpenRC）、Debian 12+、Ubuntu 22.04+（systemd）
- iptables：缺失时按 `apk` / `apt` / `dnf` / `yum` / `microdnf` / `opkg` 自动安装
- 内核需支持 nat 表；容器另需 `NET_ADMIN` / `NET_RAW` 能力

## 快速开始

```sh
curl -fsSL -o /tmp/portfwd.sh https://raw.githubusercontent.com/louwailou777/alpine-portfwd/main/portfwd.sh
head -n 1 /tmp/portfwd.sh
sudo sh /tmp/portfwd.sh
```

Alpine 无 `curl` 时改用 `wget -qO /tmp/portfwd.sh <同一地址>`。

网络无法访问 `raw.githubusercontent.com` 时，在原始地址前拼接镜像前缀：

```sh
curl -fsSL -o /tmp/portfwd.sh https://ghproxy.net/https://raw.githubusercontent.com/louwailou777/alpine-portfwd/main/portfwd.sh
```

可用前缀：`https://ghproxy.net/`、`https://gh-proxy.com/`。

执行后进入配置流程：

1. 落地机 IP 与端口
2. 线路质量检测（ping ×10）与继续确认
3. 环境与依赖检查
4. 本机 NAT 端口（默认随机 5 位，回车即用）
5. 确认写入并持久化

## 客户端配置

| 项目 | 修改为 |
| --- | --- |
| 地址（URL / Host） | 中转机公网 IP 或域名 |
| 端口（Port） | 中转机的外部映射端口 |

其余参数（协议、UUID、密码、路径、TLS）保持不变。
端口填外部映射端口，而非脚本生成的本机 NAT 端口：外部 `443` 映射到本机 `49372` 时，客户端填 `443`。

## 命令

| 命令 | 说明 |
| --- | --- |
| `portfwd.sh` | 交互式配置 |
| `portfwd.sh probe <IP>` | 仅检测线路质量，不写入规则 |
| `portfwd.sh list` | 查看映射、公网 IP 与当前 NAT 规则 |
| `portfwd.sh test` | 校验规则完整性、ping 与 TCP 连通性 |
| `portfwd.sh rm <端口>` | 删除指定映射 |
| `portfwd.sh apply` | 按配置文件全量重放规则 |
| `portfwd.sh open-port <端口>` | 放行本机 INPUT 端口 |
| `portfwd.sh uninstall` | 卸载并清理规则、配置与开机项 |
| `portfwd.sh help` | 显示帮助 |

## 参数

| 参数 | 说明 |
| --- | --- |
| `-l, --local-port` | 本机 NAT 端口 |
| `-r, --remote-ip` | 落地机 IP |
| `-p, --remote-port` | 落地机端口（无默认值，无人值守时必须指定） |
| `-y, --yes` | 跳过确认 |
| `-q, --quiet` | 静默模式 |
| `--no-probe` | 跳过线路质量检测 |
| `--probe-count N` | ping 次数，默认 10 |

无人值守示例：

```sh
portfwd.sh -y -l 10888 -r 1.2.3.4 -p 8443
portfwd.sh 10888 1.2.3.4 8443
portfwd.sh 10888 1.2.3.4 8443 10889 1.2.3.4 8080
```

## 配置与持久化

映射保存在 `/etc/portfwd.conf`，每行一条，格式为 `<本地端口> <落地IP> <落地端口>`：

```
# 本地端口  落地IP  落地端口
10888 1.2.3.4 8443
```

修改后执行 `portfwd.sh apply` 生效。`portfwd.sh open-port` 放行的端口记录在 `/etc/portfwd.open`，
开机时一并重放。

开机自启按 init 系统分别处理：

**systemd（Debian / Ubuntu）**

- 安装 `/etc/systemd/system/portfwd.service` 并 `systemctl enable portfwd.service`
- 服务在 `network-pre.target` 之前执行 `/usr/local/sbin/portfwd boot`，
  按 `/etc/portfwd.conf` 与 `/etc/portfwd.open` 重放规则
- 手动重放：`systemctl reload portfwd.service` 或 `portfwd.sh apply`

**OpenRC（Alpine）**

- 规则快照保存至 `/etc/iptables/rules-save`，`rc-update add iptables default` 开机恢复
- `/etc/local.d/portfwd.start` 重放配置，保证 `ip_forward` 与映射一致

两种方式都只重建带 `portfwd:` 标记的规则，不还原整份 iptables 快照，
避免覆盖 ufw、docker、fail2ban 等自行维护的链。

> `ufw reload` / `ufw enable` 会重建整张 iptables 表，本项目的规则会被清掉，
> 之后执行一次 `portfwd.sh apply` 即可恢复。

## 线路质量判定

| 等级 | 条件 |
| --- | --- |
| 优秀 | 平均延迟 < 60 ms，丢包 ≤ 2% |
| 良好 | 平均延迟 < 120 ms，丢包 ≤ 2% |
| 一般 | 平均延迟 < 200 ms，或丢包 ≤ 10% |
| 偏高 | 平均延迟 ≥ 200 ms，或丢包 > 10% |
| 严重 | 丢包 ≥ 50% |

阈值定义在脚本首部常量 `P_GOOD_MS`、`P_OK_MS`、`P_BAD_MS`、`P_LOSS_OK`、`P_LOSS_BAD`。
等级为「一般」及以下时，确认提示的默认选项为不继续。

## 工作原理

```
客户端 → 中转机:外网端口 --DNAT--> 落地机:服务端口
              ↑                        |
              └────── MASQUERADE ──────┘
```

对应规则（TCP，UDP 同理）：

```sh
iptables -t nat -A PREROUTING  -p tcp --dport <本机端口> -j DNAT --to-destination <落地IP>:<落地端口>
iptables -t nat -A POSTROUTING -p tcp -d <落地IP> --dport <落地端口> -j MASQUERADE
sysctl -w net.ipv4.ip_forward=1
```

## 故障排查

| 现象 | 排查方向 |
| --- | --- |
| 执行后无任何输出 | 文件未下载完整，`ls -l /tmp/portfwd.sh` 确认大小后重新下载 |
| 规则写入失败 | `iptables -t nat -L -n` 是否可用；容器需 `NET_ADMIN` |
| DNAT 计数在涨但 MASQUERADE 为 0 | 包被 `FORWARD` 链拦下（ufw 默认 `routed: deny`）。确认 `iptables -S FORWARD \| grep portfwd` 有规则；修改 ufw 后需重新 `portfwd.sh apply` |
| 客户端连不上 | `portfwd.sh test`；确认路由或安全组已映射到本机 NAT 端口 |
| 落地机端口不通 | 落地机服务是否监听、防火墙是否放行 |
| 能 ping 通但转发失败 | `net.ipv4.ip_forward` 是否为 1；转发流量是否被 `FORWARD` 链丢弃 |
| ping 100% 丢包 | 落地机可能屏蔽 ICMP，不代表 TCP 不通 |
| Ubuntu/Debian 上端口放行无效 | 启用 ufw 时用 `ufw allow <端口>/tcp` 与 `/udp`，ufw 会覆盖手工 INPUT 规则 |
| 重启后规则消失 | `systemctl status portfwd.service`；确认 `/etc/portfwd.conf` 存在 |
| 容器内运行 | 需 `--cap-add NET_ADMIN --cap-add NET_RAW`，容器无 init，不启用开机自启 |
| Alpine diskless 模式 | 执行 `lbu commit` 保存 `/etc` 与 `/usr/local` 变更 |
| raw 地址无法访问 | 使用「快速开始」中的镜像前缀 |

## 卸载

```sh
portfwd.sh uninstall
```

删除所有带 `portfwd:` 标记的规则、`/etc/portfwd.conf`、`/etc/portfwd.open`、
systemd 服务或 OpenRC 钩子，以及 `/usr/local/sbin/portfwd`。
`net.ipv4.ip_forward` 保持开启，如需关闭：`sysctl -w net.ipv4.ip_forward=0`。

## License

MIT
