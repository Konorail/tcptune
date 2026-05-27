# tcptune

瞎写的 Linux TCP 调优脚本。

主要用于：

- BBR / fq 快速启用
- 常见 TCP 参数调优
- 查看当前网络参数
- 简单测速 / 网络排查

声明支持：

- Debian
- Ubuntu
- Kali Linux

说明：

- TCP 参数调优、状态检查和基础依赖安装适用于上述 APT 系发行版；环境安装会包含迷之调参依赖的 `sysctl`、`gawk` 与基础文件工具。
- XanMod 自动安装使用 XanMod 面向 64 位 Debian-based 系统提供的第三方内核仓库；Debian、Ubuntu、Kali 的 amd64 环境可尝试安装。
- Kali 上的 XanMod 不属于 Kali 官方内核或 Kali 官方支持范围，使用前应保留可启动的 Kali 原生内核。
- XanMod 软件源需要有效发行版代号；脚本会修复旧的无效 `releases` 源，Kali rolling 的 XanMod 安装使用 Debian `sid` 兼容源。
- 菜单提供 TCP 迷之调参：`Legacy` 与 `Arc` 按参考前端原公式生成完整参数；可选择 BBR/CUBIC 与 cake/fq/fq_pie，其中 `Arc` 保留原激进模式，`Legacy` 保留原延迟宽松模式。
- 该功能完整模式会输出并应用原算法涉及的 `kernel`、`vm`、ARP、路由和转发相关策略，使用前必须核对配置预览并确认其符合服务器用途。
- TCP 迷之调参每次运行都会覆盖写入 `/var/lib/tcptune/last-mystery-tune.log`，记录原算法完整输出、当前内核可应用的过滤结果和最终应用状态。

没写好 / 不保证可用

---

## 一键运行

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Konorail/tcptune/main/tcptune.sh)
```
或

```bash
wget -O tcptune.sh https://raw.githubusercontent.com/Konorail/tcptune/main/tcptune.sh && bash tcptune.sh
```
