# tcptune

面向 VLESS/Xray 等代理 VPS 的 Linux TCP 自动调优脚本（v2.0）。

## 功能

- **完全非交互式**自动调优：一条命令完成全流程
- 自动生成候选配置（CC 算法 / qdisc / 缓冲），自动测试并选出最佳方案
- **交错复测**（≥3 轮基线/候选交替测量），用中位数判断，避免单次网络抖动左右结果
- 可靠改善判定：吞吐提升 ≥5%，或负载下 RTT 降低 ≥20%（吞吐保持 ≥95%）
- 每次运行创建独立会话快照，支持精确回滚
- 进程锁 + watchdog 守护进程，中断/被杀时自动恢复原状态
- 原子持久化：写入临时文件 → mv 替换 → sysctl --system → 逐项读回核对
- 诊断性缓冲测试（单流 vs 并发），有瓶颈证据时才生成缓冲候选
- 可选 SOCKS5 代理验收测试（持久化前执行）
- 明确的退出码：0=committed，1=failed，2=no_change
- 保留 BBR / XanMod 安装、状态检查等原有功能；迷之调参（已废弃）

已知支持：Debian、Ubuntu、Kali Linux

---

## 快速开始

```bash
# 下载脚本
curl -LO https://raw.githubusercontent.com/Konorail/tcptune/main/tcptune.sh

# 非交互式自动调优（需要 root）
sudo bash tcptune.sh --auto-tune --target <iperf3测试节点IP> --direction download
```

退出码含义：
| 退出码 | 含义 |
|--------|------|
| `0` | `committed` — 检测到可靠改善，已验证并持久化 |
| `1` | `failed` — 执行失败（已恢复原状态） |
| `2` | `no_change` — 原配置最好或收益不足，保持不变 |

---

## CLI 参数

```
bash tcptune.sh [选项]

  --auto-tune          非交互式自动调优（必须配合 --target）
  --target <host>      iperf3 测试目标 IP/域名（自动模式必须）
  --direction <d>      测试方向：download（默认，VPS 发送）或 upload（VPS 接收）
  --max-candidates N   最大候选数（默认 8）
  --duration N         每轮测试时长秒（默认 20）
  --budget-gib N       总流量预算 GiB（默认 20）
  --retest-rounds N    交错复测轮数（默认 3）
  --help               显示帮助
```

---

## 完整自动运行示例

```bash
# 基础用法：指定 iperf3 测试节点
sudo bash tcptune.sh \
  --auto-tune \
  --target 203.0.113.10 \
  --direction download \
  --duration 20 \
  --budget-gib 20
```

```bash
# 带代理验收（通过 SOCKS5 代理下载测试文件，在持久化前执行）
PROXY_HOST=127.0.0.1 \
PROXY_PORT=1080 \
PROXY_TEST_URL=https://example.com/100mb.bin \
sudo -E bash tcptune.sh \
  --auto-tune \
  --target 203.0.113.10 \
  --direction download
```

> **注意**：代理验收通过 VPS 本机 curl 验证，目前不从远端客户端测量。
> 未配置时，报告会注明"真实代理体验未验证"。

---

## 调优流程

```
环境检查 → 创建会话快照 → 获取进程锁 → 启动 watchdog
→ 基线 iperf3 测试（单流）→ 诊断缓冲瓶颈（单流 vs 并发）
→ 生成候选（CC / qdisc / 缓冲，≤8 个）
→ 逐一临时应用候选 → 单流测试 → 评分筛选（60% 预算）
→ 交错复测胜者（≥3 轮，比较中位数）
→ is_reliable_improvement 判定（吞吐+RTT 双维度）
→ 重新应用胜者 → 可选代理验收
→ 原子持久化 + 读回核对
→ 输出前后对比 + 回滚命令
→ 打印 RESULT=committed|no_change|failed
```

选优策略（可通过环境变量调整）：

| 策略参数 | 默认值 | 说明 |
|----------|--------|------|
| `AT_MIN_TP_GAIN` | `5` | 吞吐提升阈值（%） |
| `AT_MIN_RTT_GAIN` | `20` | RTT 改善阈值（%，当吞吐≥95%时） |
| `AT_MAX_RTT_FACTOR` | `200` | RTT 退化上限（%） |
| `AT_MAX_RETR_FACTOR` | `300` | 归一化重传率退化上限（%） |

---

## 回滚

每次调优后会话目录保存在 `/var/lib/tcptune/sessions/`，最新会话通过 symlink `latest` 指向：

```bash
# 查看最新会话
ls -la /var/lib/tcptune/sessions/latest/

# 立即回滚到本次调优前状态
bash /var/lib/tcptune/sessions/latest/restore.sh

# 查看测试记录
cat /var/lib/tcptune/sessions/latest/results.tsv
```

回滚脚本会：
1. 逐行恢复所有受管 sysctl 参数
2. 恢复出口接口实际 qdisc（若本次修改过）
3. 删除持久化配置文件（若原先不存在）或恢复原内容

---

## 依赖

- `bash` ≥ 4.3
- `sysctl`, `awk`, `iperf3`, `tc`, `ip`, `jq`, `curl`（代理验收可选）
- root 权限

安装依赖（Debian/Ubuntu）：
```bash
apt-get install -y iproute2 iperf3 jq
```

---

## 回归测试

```bash
bash tests/regression.sh
```

覆盖 13 个场景（18 个断言），包括：评分公式正确性、改善阈值、持久化文件内容、CLI 参数解析等。
不需要 root 或网络连接。

---

## 注意

- 需要 root 权限
- 迷之调参（菜单 8）已废弃，不再是推荐的调优入口
- qdisc 候选仅在能完整恢复的场景下生成（pfifo_fast/pfifo/fq/fq_codel/bfifo/cake/sfq）
- 真实公网和代理体验改善需在实际 VPS 上验证；回环测试结果仅作内核参数对比参考
