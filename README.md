# tcptune

面向 VLESS/Xray 等代理 VPS 的 Linux TCP 自动调优脚本（v2.0）。

## 功能

- 自动生成候选配置（CC 算法 / qdisc / 缓冲），自动测试并选出最佳方案
- 每次运行创建独立会话快照，支持精确回滚
- 进程锁 + watchdog 守护进程，中断时自动恢复原状态
- 原子持久化：写入临时文件 → mv 替换 → sysctl --system → 逐项读回核对
- 诊断性缓冲测试（单流 vs 并发），有瓶颈证据时才生成缓冲候选
- 评分公式：`score = throughput×0.7 + (1/norm_retr)×0.3`，吞吐量是主要指标
- 可选 SOCKS5 代理验收测试
- 保留 BBR / XanMod 安装、状态检查、迷之调参（已废弃）等原有功能

已知支持：Debian、Ubuntu、Kali Linux

---

## 一键运行

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Konorail/tcptune/main/tcptune.sh)
```

或：

```bash
wget -O tcptune.sh https://raw.githubusercontent.com/Konorail/tcptune/main/tcptune.sh && bash tcptune.sh
```

---

## CLI 参数

```
bash tcptune.sh [选项]

  --max-candidates N   最大候选数（默认 8）
  --duration N         每轮测试时长秒（默认 20）
  --budget-gib N       总流量预算 GiB（默认 2）
  --auto-tune          直接运行自动调优（非交互式）
  --help               显示帮助
```

## 可选代理验收（环境变量）

```bash
PROXY_HOST=127.0.0.1 PROXY_PORT=1080 PROXY_TEST_URL=https://example.com/test.bin \
  bash tcptune.sh --auto-tune
```

---

## 调优流程说明

```
环境检查 → 创建会话快照 → 获取进程锁 → 启动 watchdog
→ 基线 iperf3 测试 → 诊断缓冲瓶颈
→ 生成候选（CC/qdisc/缓冲，≤8 个）
→ 逐一测试候选（筛选预算 60%）
→ 选出最佳候选（评分公式）
→ 最终验收测试（-P 4，时长 2×，预算 40%）
→ 原子持久化 + 读回核对
→ 输出前后对比 + 回滚命令
→ 可选 SOCKS5 代理验收
```

## 回滚

每次调优后会话目录保存在 `/var/lib/tcptune/sessions/`，最新会话通过 symlink `latest` 指向：

```bash
# 查看最新会话
ls -la /var/lib/tcptune/sessions/latest/

# 回滚
bash /var/lib/tcptune/sessions/latest/restore.sh
```

---

## 注意

- 需要 root 权限
- 依赖：`sysctl`, `awk`, `iperf3`, `tc`, `ip`, `jq`
- 迷之调参（菜单 8）已废弃，不再是推荐的调优入口
