# tcptune

瞎写的 Linux TCP 调优脚本。

主要用于：

- BBR / fq 快速启用
- 常见 TCP 参数调优
- 查看当前网络参数
- 简单测速 / 网络排查

已知支持：

- Debian
- Ubuntu
- Kali Linux

说明：

- TCP 参数调优、状态检查
- 安装XanMod

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
