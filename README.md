# tcptune

面向代理 VPS 的保守 TCP 参数试验工具，v2.2。适用于实际使用 Linux TCP socket 的链路；VLESS 的名称本身不代表传输方式，用户态 QUIC 拥塞控制不属于本工具的调优范围。

在指定路径、速率、时间和流量预算内寻找**足够好的配置**。原配置始终参与对照，证据不足就 `no_change`，不宣称全局最优或保证提速。

## 当前自动调优范围

- 对本机作为发送端的路径，比较当前已加载的 `bbr` / `cubic`。
- 内核 socket 诊断显示发送缓冲受限时，有限地增加 `tcp_wmem` 上限，保留原 min/default。候选同时受可用内存、cgroup v2 余量、预计并发和单连接上限约束。
- 保持实际 qdisc 和默认 qdisc 原样。仅记录队列名称无法准确恢复选项、整棵队列或重启配置，因此本版停止自动替换队列。
- 接收方向保留测量，但没有对端证据时跳过接收缓冲扩容，也不比较不能作用于远端发送者的本机 CC。`no_change` 是合理结果。
- SSH 多节点自动提交暂时关闭，避免旧分支绕过统一验收。可以分别指定不同目标运行单节点流程。

原有环境检查、状态、内核安装等菜单仍保留；自动调优流程不安装内核。废弃的“迷之调参”不进入自动流程。

## 运行

Linux 上需要 Bash 4.3+、jq 1.6+、iperf3、iproute2、procps、GNU coreutils 和 util-linux。SOCKS5 探针还需要 curl；本地桥接/HTTP 测试端需要 Python 3。自动调优和恢复需要 root。

```bash
sudo apt-get update
sudo apt-get install -y iperf3 jq iproute2 procps coreutils util-linux curl

# 可选：若当前尚未加载 BBR，先加载发行版已有模块，再建立基线。
sudo modprobe tcp_bbr

# 首轮先临时测试，结束后验证恢复。
sudo bash tcptune.sh --auto-tune --target PEER_IP \
  --direction download --no-persist \
  --duration 10 --retest-rounds 5 --accept-rounds 3 \
  --rate-mbps 1000 --budget-gib 32 --max-seconds 1800

# 确认实测和回滚后，去掉 --no-persist 才会在验收通过时持久化。
```

`--direction download` 是兼容名称，明确表示 **VPS 发送到测试节点**；`upload` 表示节点发送到 VPS（iperf3 `-R`）。A→B 测试不能单独证明国内客户端→A 的体验。

没有指定 `--auto-tune` 时进入菜单。参数顺序无关，缺失值、未知参数和非法阈值快速失败。循环地址仅允许临时测试。

| 退出码 | RESULT | 含义 |
| --- | --- | --- |
| 0 | committed | 新数据验收通过，已应用并写入配置 |
| 1 | failed | 执行失败；以 `restore_verified` 判断是否确认恢复 |
| 2 | no_change | 无候选、收益不足、波动大或预算不足，已恢复 |
| 3 | validated | 临时模式确认候选，结束后已恢复，没有持久化 |

`RESULT`、`REASON` 和 `REPORT` 打印到终端。快照创建之前的失败可能只有 RESULT/REASON。恢复失败一律 `failed`，并阻止下一轮把未恢复状态作为新基线。

## 决策算法

1. 取得原始参数、实际路由接口、完整 qdisc JSON 和持久化文件快照。
2. 测量基线，生成有限候选；每个候选都从原始快照开始，应用并逐项读回后才允许测速。
3. 初筛先过全部硬门槛，再按吞吐比值排序，最多转交三个候选。
4. 默认五对复测，顺序交替 AB / BA，数量差不超过一。每一对计算相对变化，再汇总收益中位数。
5. 至少 80% 的有效配对收益方向一致；中位收益需达到 `max(最低收益, 2×基线相对 MAD)`。
6. 选择第一个满足要求的候选，再用全新的三对数据独立验收。独立验收失败就停止，不反复试到碰巧通过。
7. 最后重新应用、读回核对，然后临时恢复或原子写入配置。

配对的任何硬门槛失败都会否决该候选，不能用总体平均值覆盖。测量失败的配对保留记录；本阶段需要完整取得请求的有效配对，至少三对。默认不增加补测轮数，以免选择性丢弃失败样本。

MAD 和 80% 一致性规则都是保守的**启发式策略**，小样本、MAD=0 均不构成统计显著性证明；默认值需要通过实际线路校准。

配置了探针时，收益优先比较**真实代理下载吞吐和负载小请求 P95**；否则比较 iperf 吞吐和发送者平均 TCP RTT，并标明代理体验未验证。iperf 和代理链路均受退化保护，未知指标保留 `null`，不以 0 代替。

| 策略环境变量 | 默认值 | 含义 |
| --- | --- | --- |
| `AT_MIN_TP_GAIN` | 5 | 最低吞吐收益百分比 |
| `AT_MIN_RTT_GAIN` | 20 | 最低延迟改善百分比 |
| `AT_MAX_RTT_FACTOR` | 115 | 相对延迟保护线，百分比 |
| `AT_RTT_TOLERANCE_MS` | 5 | 绝对延迟容差，毫秒 |
| `AT_MAX_RETR_FACTOR` | 300 | 每 GiB 重传相对保护线，百分比 |
| `AT_RETR_FLOOR` | 100 | 零/小基线的绝对容差，次/GiB |

延迟上限是 `max(基线×1.15, 基线+5ms)`，TCP RTT 和代理 P95 都检查。任一配对吞吐低于基线 95%、重传明显超过容差或代理出现错误时拒绝；这些保护线先于收益判断。

缓冲证据来自测试连接 `ss -tinm` 的 `sndbuf_limited`：样本至少已发送 1 MiB，且显示受限时间不低于 5%。无法取得该信息时跳过。多流比单流快、BDP 大、接收窗口受限，都不能单独证明本机缓冲不足。

## 参数与预算

`bash tcptune.sh --help` 显示完整参数。

| 参数 | 默认值 |
| --- | --- |
| `--duration` | 默认 10 秒，允许 2..120；不限速时为最短有效样本时长 |
| `--retest-rounds` | 5 对，允许 3..15 |
| `--accept-rounds` | 新数据 3 对，允许 3..15 |
| `--max-candidates` | 4，最多 16 |
| `--rate-mbps` | 每流 1000 Mbps 的测试速率上限；0 表示不限速 |
| `--sample-mib` | 默认 0；不限速模式必须显式指定每轮 1..4096 MiB 载荷 |
| `--budget-gib` | 32 GiB 应用层载荷预算 |
| `--max-seconds` | 1800 秒会话预算 |
| `--expected-connections` | 64 个并发连接用于缓冲内存预算 |
| `--buffer-max-mib` | 16 MiB 单连接发送缓冲候选上限 |

一条成功候选在默认设置下至少需 18 次 iperf 测量：基线、初筛、十次复测、六次独立验收。1 Gbps 持续传输约需 21 GiB，再加其他候选和代理流量。因此默认预算从旧版 20 调整为 32 GiB；运行开始会打印预算。可显式降低预算或速率进行流程验证，之后再按实际带宽提高速率。

所有测试共用时间和载荷账本。限速模式按时长、速率上限和 10% 余量预留；不限速模式按每轮字节额度加 128 KiB 写块余量预留。成功解析后按发送/接收两端较大的载荷量记账，失败保留预留值。探针也预留并记账。预算不足不开始下一次测量，测试进程受 timeout 限制。

不限速模式使用 iperf3 `-b 0 -n 字节数`，只支持单流。每轮截止时间为 `--duration + 5` 秒；字节额度过小、实际发送时长不足 `--duration` 时返回 `sample_too_short`，异常超出额度和写块余量时返回 `sample_byte_limit_exceeded`。这些数据仍保留并计费到测试账本，但不能进入收益验收。需要按实际带宽选择字节额度，避免用短突发代替稳定样本；原收益、重传保护和独立验收规则不变。

```bash
# 约 1 Gbps 路径的示例；每轮 1.5 GiB，默认 18 轮约需 27 GiB 载荷。
sudo bash tcptune.sh --auto-tune --target PEER_IP --no-persist \
  --rate-mbps 0 --sample-mib 1536 --duration 10 --budget-gib 32
```

不同 iperf3 版本的字节终止行为可能存在差异；报告记录实际字节和时长，超量或超时必须拒绝。这仍不是运营商流量硬上限。小预算先验证流程，预算不足时保留原配置。

这是保守的**应用层载荷记账**，不包含所有 TCP/IP 包头、ACK、SSH 控制流量，不能当作运营商计费流量或严格线速硬上限。外部探针必须遵守自己的响应大小、请求数和超时约定；脚本无法强制约束任意外部程序的实际网络行为。

## 真实代理探针

可用内置 SOCKS5 探针，或 `--probe-command /absolute/path/to/executable` 接入实际客户端。每次 iperf 测量期间执行探针，同时大文件传输与小请求，并取得至少十个有负载的小请求样本。传输过快、样本不足时失败，增大受控文件/允许传输量后重新运行，不能将空数据当成功。

```bash
sudo env PROXY_HOST=127.0.0.1 PROXY_PORT=1080 \
  PROXY_TEST_URL=http://ORIGIN_IP:8080/bulk \
  PROXY_SMALL_URL=http://ORIGIN_IP:8080/small \
  PROXY_MAX_BYTES=268435456 \
  bash tcptune.sh --auto-tune --target PEER_IP --no-persist
```

以上探针在运行脚本的机器上测量，**不能冒充国内客户端体验**。真实客户端应通过以下桥接或远程回调执行探针。

`--probe-command` 只接受可执行文件路径，不使用 eval。程序标准输出须是单个 JSON：

```json
{"status":"ok","requests":20,"errors":0,"p50_ms":80,"p95_ms":120,"download_mbps":90,"bytes":33554432}
```

`bytes` 包括大传输及所有小请求收到的字节，须为正整数，且不能超过声明的探针预算。缺失、非零退出码、超时、非法 JSON 均失败。

代理服务的监听 socket 可能保留原 CC，应用自身也可能设置 socket 级 CC。需要重建监听 socket 时，显式使用 `--proxy-service xray.service`：允许工具在应用及恢复参数时重启该服务，**会中断代理连接**。未指定时不会重启服务，报告 `listener_refresh=not_managed`。应用自身设置的 CC 仍可能覆盖系统默认，应结合实际连接诊断确认。

## 两台 VPS + 真实客户端

```text
国内电脑/手机（平时线路与代理客户端） ⇄ A（境外代理/被调） ⇄ B（境外受控目标）
```

A 选实际打算使用的代理 VPS，B 具备稳定带宽和 CPU 余量。两台境外 VPS 即可；国内电脑/手机承担真实接入测试，不需要另购国内 VPS。先验证一个代表性场景，再对不同时段或路径复核。

在 B 启动测试端，端口只按你的测试来源开放：

```bash
iperf3 -s
python3 tools/lab_origin.py --bind 0.0.0.0 --port 8080 --size-mib 256
```

两条命令分别在终端运行。HTTP 端按需生成有界数据，支持 Range，没有磁盘大文件和压缩优化。

真实客户端运行 `tools/client_probe.sh`，它只加载测量函数，不改客户端 sysctl。本地需要 Bash、curl、jq。

Windows/家庭网络无需开放入站 SSH：`tools/probe_bridge.py` 在客户端监听 127.0.0.1，通过客户端主动建立的 SSH 反向转发，让 A 同步请求客户端测量。

```bash
# 客户端终端 1；Windows 可给 --bash 指定 Git Bash 的完整路径。
export PROXY_HOST=127.0.0.1 PROXY_PORT=1080
export PROXY_TEST_URL=http://B_IP:8080/bulk
export PROXY_SMALL_URL=http://B_IP:8080/small
export PROXY_MAX_BYTES=268435456 PROXY_REQUESTS=20 PROXY_DURATION=10
python3 tools/probe_bridge.py --token-file probe.token --port 19090 --timeout 15

# 客户端终端 2；使用已配置的 SSH 别名/密钥。
scp probe.token vps-a:/root/tcptune/probe.token
ssh -N -o ExitOnForwardFailure=yes -R 127.0.0.1:19090:127.0.0.1:19090 vps-a
```

在 A 创建回调：

```bash
cd /root/tcptune
read -r token < probe.token
printf 'Authorization: Bearer %s\n' "$token" > probe.header
chmod 600 probe.header probe.token
cat > client-hook.sh <<'HOOK'
#!/usr/bin/env bash
exec curl -fsS --max-time 15 -X POST --header @/root/tcptune/probe.header \
  http://127.0.0.1:19090/probe
HOOK
chmod 700 client-hook.sh

# 两边的 PROXY_MAX_BYTES / PROXY_REQUESTS 须一致。
sudo env PROXY_MAX_BYTES=268435456 PROXY_REQUESTS=20 \
  bash tcptune.sh --auto-tune --target B_IP --no-persist \
  --probe-command /root/tcptune/client-hook.sh \
  --proxy-service xray.service --duration 10 --budget-gib 32
```

代理路径必须实际经过 A；桥接脚本本身不创建代理或修改路由。先确认客户端探针能独立返回有效数据，再开始调优。桥接默认仅监听回环地址、校验 token，只能执行预配置探针，不能通过 HTTP 提交任意命令。

第一轮验证应用、报告与恢复；第二轮按带宽预算运行完整 A/B 与代理验收；最后在另一时段复核，才测试持久化。

## 会话、持久化和恢复

`/var/lib/tcptune/sessions/<UTC时间.随机后缀>/` 保存：

- 原始 sysctl、qdisc JSON、原配置及独立 `restore.sh`；
- 每次原始 iperf JSON/stderr、可用的 socket 诊断和探针输出；
- 参数计划、逐轮数据、配对结果、策略阈值和拒绝原因；
- `report.json`：版本/commit、方向、原始/请求/最终配置、预算、选择/应用/恢复状态。CPU jiffies 和内存数据是诊断快照，未伪装成应用进程占用百分比。

`flock` 保持整个会话和守护恢复的互斥；watchdog 检查父进程消失及截止时间。正常退出/中断通过统一清理路径恢复。独立恢复脚本冻结恢复代码，不依赖以后修改的 tcptune.sh。

```bash
sudo bash /var/lib/tcptune/sessions/latest/restore.sh
```

持久化只更新本轮选中的 CC/缓冲项，保留原文件其他条目和注释，临时文件原子替换并逐项验证。不执行全局 `sysctl --system`，避免载入与测量无关的配置。恢复先恢复原配置文件，再还原实际运行值，不全局重载。

`reboot_verified=false` 表示没有验证重启：其他 sysctl 文件、服务配置和应用的 socket 设置仍可能影响重启后的有效状态。旧会话不能覆盖更新的会话；恢复失败时检查报告和会话目录后先处理恢复，再开始新调优。

## 测试与验证边界

```bash
bash -n tcptune.sh
bash tests/regression.sh
bash tests/measurement.sh
bash tests/integration.sh
bash tests/linux-process.sh
python3 -m unittest discover -s tests -p 'test_*.py'

# 负对照应返回非零，并显示 FAIL=1。
TCPTUNE_TEST_NEGATIVE_CONTROL=1 bash tests/regression.sh
```

Bash 回归/流程测试均使用 fake sysctl/tc/iperf，不修改宿主参数、不访问公网；Linux 进程测试用真实 flock、真实进程和 SIGKILL 验证 watchdog，仍只写假内核状态。缺少 flock 的 Windows 明确 SKIP。Python 测试仅使用本机回环 HTTP。

测试断言在子进程内计数并回传父进程，任意断言失败或场景异常会使整套测试非零退出。覆盖配对噪声、吞吐/延迟分支、独立验收、应用/读回/保存/报告失败、中断与独立恢复等。

这些测试不证明公网收益、真实内核写入或运营商计费流量控制。需要真实 Linux VPS 和客户端验证；最终阈值与候选范围依实测收敛。

参考：[Linux TCP sysctl 文档](https://docs.kernel.org/networking/ip-sysctl.html)、[iperf3 官方说明](https://software.es.net/iperf/invoking.html)。
