#!/usr/bin/env bash

# Interactive implementation of the article's "BDP + iperf3 iteration" method.
# Run this script on the VPS being tuned. It supports manual clients and
# remotely reachable Linux test nodes accessed over SSH keys/ssh-agent or
# an explicitly selected temporary password mode.

CONF="/etc/sysctl.d/99-tcptune.conf"
STATE_DIR="/var/lib/tcptune"
BASELINE="$STATE_DIR/baseline.conf"
SESSION_LOG="$STATE_DIR/last-session.tsv"
REMOTE_SESSION_LOG="$STATE_DIR/last-remote-session.tsv"
MYSTERY_CONF="/etc/sysctl.d/99-zz-tcptune-mystery.conf"
MYSTERY_BASELINE="$STATE_DIR/mystery-baseline.conf"
MYSTERY_CANDIDATE="$STATE_DIR/mystery-candidate.conf"
MYSTERY_LOG="$STATE_DIR/last-mystery-tune.log"
XANMOD_SOURCE_LIST="/etc/apt/sources.list.d/xanmod-release.list"
XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
MIB=$((1024 * 1024))
MIN_WINDOW=87380
SSH_CONNECT_TIMEOUT=8
SCRIPT_VERSION="v1.1.0"
SCRIPT_DATE="2026-05-28"

green(){ printf '\033[32m%s\033[0m\n' "$*"; }
red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
pause(){ read -rp "按回车返回菜单..." _; }
has(){ command -v "$1" >/dev/null 2>&1; }
clear_screen(){ has clear && clear || printf '\n'; }

read_platform_info(){
  PLATFORM_ID="unknown"
  PLATFORM_NAME="未知系统"
  PLATFORM_VERSION=""
  PLATFORM_CODENAME=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    PLATFORM_ID="${ID:-unknown}"
    PLATFORM_NAME="${PRETTY_NAME:-${NAME:-未知系统}}"
    PLATFORM_VERSION="${VERSION_ID:-}"
    PLATFORM_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  fi
  if [ -z "$PLATFORM_CODENAME" ] && has lsb_release; then
    PLATFORM_CODENAME="$(lsb_release -sc 2>/dev/null)"
  fi
}

is_supported_tuning_platform(){
  read_platform_info
  case "$PLATFORM_ID" in
    debian|ubuntu|kali) return 0 ;;
    *) return 1 ;;
  esac
}

show_platform_support(){
  read_platform_info
  printf '目标发行版识别: %s' "$PLATFORM_NAME"
  [ -n "$PLATFORM_CODENAME" ] && printf ' (代号: %s)' "$PLATFORM_CODENAME"
  printf '\n'
  if is_supported_tuning_platform; then
    green "TCP 调优与基础依赖: 支持（Debian、Ubuntu、Kali 范围）。"
  else
    yellow "TCP 调优与依赖安装: 当前发行版不在声明支持范围内，需自行验证。"
  fi
  if has apt-get && has dpkg && [ "$(dpkg --print-architecture 2>/dev/null)" = "amd64" ]; then
    green "XanMod 自动安装: 可使用 XanMod 官方提供的 Debian-based 第三方内核仓库。"
    [ "$PLATFORM_ID" = "kali" ] &&
      yellow "Kali 提示: XanMod 不是 Kali 官方内核，安装后内核相关问题不属于 Kali 官方支持范围。"
  else
    yellow "XanMod 自动安装: 需要 amd64 架构以及 APT/dpkg 环境。"
  fi
}

require_root(){
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    red "此操作会修改系统网络参数，请使用 root 运行。"
    return 1
  fi
}

is_positive_number(){
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk "BEGIN{exit !($1 > 0)}"
}

read_positive(){
  local prompt="$1" default="${2:-}" value
  while true; do
    if [ -n "$default" ]; then
      read -rp "$prompt [$default]: " value
      value="${value:-$default}"
    else
      read -rp "$prompt: " value
    fi
    if is_positive_number "$value"; then
      REPLY="$value"
      return 0
    fi
    red "请输入大于 0 的数字。"
  done
}

read_nonnegative(){
  local prompt="$1" default="$2" value
  while true; do
    read -rp "$prompt [$default]: " value
    value="${value:-$default}"
    if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      REPLY="$value"
      return 0
    fi
    red "请输入不小于 0 的数字。"
  done
}

read_positive_integer(){
  local prompt="$1" default="${2:-}" value
  while true; do
    if [ -n "$default" ]; then
      read -rp "$prompt [$default]: " value
      value="${value:-$default}"
    else
      read -rp "$prompt: " value
    fi
    if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ]; then
      REPLY="$value"
      return 0
    fi
    red "请输入大于 0 的整数。"
  done
}

sysctl_value(){
  sysctl -n "$1" 2>/dev/null || printf '不可用'
}

show_status(){
  clear_screen
  green "系统与内核状态"
  show_platform_support
  printf '内核: %s\n' "$(uname -r 2>/dev/null || printf '不可用')"
  printf '架构: %s\n' "$(uname -m 2>/dev/null || printf '不可用')"
  echo
  green "脚本涉及的 TCP / 队列参数"
  printf 'net.ipv4.tcp_available_congestion_control = %s\n' "$(sysctl_value net.ipv4.tcp_available_congestion_control)"
  printf 'net.ipv4.tcp_congestion_control = %s\n' "$(sysctl_value net.ipv4.tcp_congestion_control)"
  printf 'net.core.default_qdisc = %s\n' "$(sysctl_value net.core.default_qdisc)"
  printf 'net.ipv4.tcp_wmem = %s\n' "$(sysctl_value net.ipv4.tcp_wmem)"
  printf 'net.ipv4.tcp_rmem = %s\n' "$(sysctl_value net.ipv4.tcp_rmem)"
  printf 'net.core.wmem_max = %s\n' "$(sysctl_value net.core.wmem_max)"
  printf 'net.core.rmem_max = %s\n' "$(sysctl_value net.core.rmem_max)"
  echo
  green "脚本配置与回滚基线"
  if [ -f "$CONF" ]; then
    printf '持久化调优配置: %s\n' "$CONF"
    sed 's/^/  /' "$CONF"
  else
    printf '持久化调优配置: 未创建 (%s)\n' "$CONF"
  fi
  if [ -f "$BASELINE" ]; then
    printf '调优前基线: %s\n' "$BASELINE"
    sed 's/^/  /' "$BASELINE"
  else
    printf '调优前基线: 未保存 (%s)\n' "$BASELINE"
  fi
  if [ -f "$MYSTERY_CONF" ]; then
    printf '迷之调参持久化配置: %s\n' "$MYSTERY_CONF"
    sed 's/^/  /' "$MYSTERY_CONF"
  else
    printf '迷之调参持久化配置: 未创建 (%s)\n' "$MYSTERY_CONF"
  fi
  [ -f "$MYSTERY_BASELINE" ] && printf '迷之调参应用前基线: %s\n' "$MYSTERY_BASELINE"
  [ -f "$MYSTERY_LOG" ] && printf '最近迷之调参记录: %s\n' "$MYSTERY_LOG"
  [ -f "$SESSION_LOG" ] && printf '最近手工测试记录: %s\n' "$SESSION_LOG"
  [ -f "$REMOTE_SESSION_LOG" ] && printf '最近远程测试记录: %s\n' "$REMOTE_SESSION_LOG"
  echo
  green "当前接口 qdisc"
  if has tc; then
    tc qdisc show 2>/dev/null || yellow "无法读取 qdisc。"
  else
    yellow "缺少 tc（通常由 iproute2 提供）。"
  fi
  echo
  green "附加组件与工具状态"
  show_xanmod_status
  for command in sysctl awk iperf3 tc ping jq ssh sshpass speedtest librespeed-cli; do
    if has "$command"; then
      green "[已安装] $command"
    else
      yellow "[未检测到] $command"
    fi
  done
  echo
  pause
}

xanmod_repository_codename(){
  local codename
  read_platform_info
  if [ "$PLATFORM_ID" = "kali" ]; then
    # XanMod lists Debian sid, but not kali-rolling; use its Debian-compatible rolling base.
    printf 'sid'
    return 0
  fi
  codename="$PLATFORM_CODENAME"
  case "$codename" in
    bookworm|trixie|forky|sid|noble|plucky|questing|resolute|faye|gigi|wilma|xia|zara|zena)
      printf '%s' "$codename"
      return 0
      ;;
  esac
  red "XanMod 官方仓库未声明支持当前发行版代号：${codename:-未知}。"
  return 1
}

repair_broken_xanmod_source(){
  local codename
  [ -f "$XANMOD_SOURCE_LIST" ] || return 0
  grep -q 'deb\.xanmod\.org' "$XANMOD_SOURCE_LIST" 2>/dev/null || return 0
  if ! grep -Eq 'deb\.xanmod\.org[[:space:]]+(releases|kali-rolling)[[:space:]]' "$XANMOD_SOURCE_LIST" 2>/dev/null; then
    return 0
  fi
  if [ -f "$XANMOD_KEYRING" ] && codename="$(xanmod_repository_codename)"; then
    printf 'deb [signed-by=%s] http://deb.xanmod.org %s main\n' "$XANMOD_KEYRING" "$codename" > "$XANMOD_SOURCE_LIST" || return 1
    yellow "检测到旧的无效 XanMod 软件源，已修正为仓库代号：$codename。"
  else
    rm -f "$XANMOD_SOURCE_LIST" || return 1
    yellow "检测到无效且无法修复的 XanMod 软件源，已移除以恢复 APT 可用性。"
  fi
}

apt_update_ready(){
  repair_broken_xanmod_source || return 1
  apt-get update
}

install_base(){
  require_root || return 1
  if has apt-get; then
    apt_update_ready &&
      DEBIAN_FRONTEND=noninteractive apt-get install -y iperf3 iproute2 iputils-ping gawk jq openssh-client ca-certificates procps coreutils kmod grep sed
  elif has apk; then
    apk add iperf3 iproute2 iputils gawk jq openssh-client ca-certificates procps coreutils grep sed
  elif has dnf; then
    dnf install -y iperf3 iproute iputils gawk jq openssh-clients ca-certificates procps-ng coreutils grep sed
  elif has yum; then
    yum install -y iperf3 iproute iputils gawk jq openssh-clients ca-certificates procps-ng coreutils grep sed
  else
    red "暂不支持当前包管理器，请手动安装 sysctl、cp、mkdir、cat、grep、sed、mktemp、iperf3、iproute2、ping、awk、jq、ssh；密码模式另需 sshpass。"
    return 1
  fi
}

install_sshpass(){
  require_root || return 1
  green "正在安装密码认证所需组件：sshpass"
  if has apt-get; then
    apt_update_ready && DEBIAN_FRONTEND=noninteractive apt-get install -y sshpass
  elif has apk; then
    apk add sshpass
  elif has dnf; then
    dnf install -y sshpass
  elif has yum; then
    yum install -y sshpass
  else
    red "暂不支持当前包管理器，请手动安装 sshpass 后继续。"
    return 1
  fi
}

check_env(){
  clear_screen
  green "环境检查 / 安装基础依赖"
  local missing=0 command package_manager="未识别"
  show_platform_support
  echo
  green "运行环境与调优能力"
  printf '当前用户: %s (UID=%s)\n' "$(id -un 2>/dev/null || printf '未知')" "${EUID:-$(id -u 2>/dev/null || printf '未知')}"
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    green "[可修改] 当前为 root，可执行安装和写入调优配置。"
  else
    yellow "[只读检查] 当前不是 root；安装、应用参数和恢复配置需要 root。"
  fi
  printf '当前内核: %s\n' "$(uname -r 2>/dev/null || printf '不可用')"
  printf '当前架构: %s\n' "$(uname -m 2>/dev/null || printf '不可用')"
  printf '当前拥塞控制: %s\n' "$(sysctl_value net.ipv4.tcp_congestion_control)"
  printf '当前默认 qdisc: %s\n' "$(sysctl_value net.core.default_qdisc)"
  if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    green "[可用] BBR 已在内核可用拥塞控制列表中。"
  else
    yellow "[未检测到] BBR 当前不在可用拥塞控制列表中；可检查内核或 XanMod。"
  fi
  has apt-get && package_manager="apt-get"
  has apk && package_manager="apk"
  has dnf && package_manager="dnf"
  has yum && package_manager="yum"
  printf '包管理器: %s\n' "$package_manager"
  if [ -d "$STATE_DIR" ]; then
    printf '脚本状态目录: %s\n' "$STATE_DIR"
    [ -w "$STATE_DIR" ] && green "[可写] 状态目录可写。" || yellow "[不可写] 状态目录当前不可写，调优记录可能无法保存。"
  else
    printf '脚本状态目录: 尚未创建 (%s，首次保存配置时创建)\n' "$STATE_DIR"
  fi
  echo
  green "必要命令"
  for command in sysctl awk iperf3 tc ping jq ssh grep sed mktemp; do
    if has "$command"; then
      green "[已安装] $command"
    else
      yellow "[缺少] $command"
      missing=1
    fi
  done
  if has sshpass; then
    green "[已安装] sshpass（远程密码认证使用）"
  else
    yellow "[可选缺少] sshpass（仅远程密码认证需要）"
  fi
  if has speedtest; then
    green "[已安装] speedtest（Ookla 公网测速使用）"
  else
    yellow "[可选缺少] speedtest（Ookla 公网测速使用）"
  fi
  if has librespeed-cli; then
    green "[已安装] librespeed-cli（LibreSpeed 公网测速使用）"
  else
    yellow "[可选缺少] librespeed-cli（LibreSpeed 公网测速使用）"
  fi
  echo
  green "已有配置 / 记录"
  [ -f "$CONF" ] && printf '[已存在] 交互调优配置: %s\n' "$CONF" || printf '[未创建] 交互调优配置: %s\n' "$CONF"
  [ -f "$BASELINE" ] && printf '[已存在] 交互调优基线: %s\n' "$BASELINE" || printf '[未创建] 交互调优基线: %s\n' "$BASELINE"
  [ -f "$MYSTERY_CONF" ] && printf '[已存在] 迷之调参配置: %s\n' "$MYSTERY_CONF" || printf '[未创建] 迷之调参配置: %s\n' "$MYSTERY_CONF"
  [ -f "$MYSTERY_LOG" ] && printf '[已存在] 迷之调参日志: %s\n' "$MYSTERY_LOG" || printf '[未生成] 迷之调参日志: %s\n' "$MYSTERY_LOG"
  if [ "$missing" -eq 1 ]; then
    echo
    read -rp "是否尝试安装缺失依赖？[y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] && install_base
  fi
  echo
  pause
}

xanmod_installed_packages(){
  has dpkg-query || return 1
  dpkg-query -W -f='${db:Status-Status}\t${binary:Package}\t${Version}\n' '*xanmod*' 2>/dev/null |
    awk -F '\t' '$1 == "installed" { printf "%s %s\n", $2, $3; found=1 } END { exit !found }'
}

xanmod_installed_package_names(){
  has dpkg-query || return 1
  dpkg-query -W -f='${db:Status-Status}\t${binary:Package}\n' '*xanmod*' 2>/dev/null |
    awk -F '\t' '$1 == "installed" { print $2; found=1 } END { exit !found }'
}

xanmod_is_running(){
  local release
  release="$(uname -r 2>/dev/null)" || return 1
  [[ "${release,,}" == *xanmod* ]]
}

xanmod_is_installed(){
  xanmod_is_running || xanmod_installed_packages >/dev/null 2>&1
}

native_kernel_package_installed(){
  has dpkg-query || return 1
  dpkg-query -W -f='${db:Status-Status}\t${binary:Package}\n' 'linux-image-*' 2>/dev/null |
    awk -F '\t' '$1 == "installed" && tolower($2) !~ /xanmod/ { found=1 } END { exit !found }'
}

show_xanmod_status(){
  local release packages
  release="$(uname -r 2>/dev/null || printf '无法读取')"
  printf '当前运行内核: %s\n' "$release"
  if xanmod_is_running; then
    green "运行状态: 当前正在运行 XanMod 内核。"
  else
    yellow "运行状态: 当前未运行 XanMod 内核。"
  fi
  if packages="$(xanmod_installed_packages)"; then
    echo "已安装 XanMod 软件包:"
    printf '%s\n' "$packages"
  else
    yellow "软件包状态: 未检测到已安装的 XanMod 内核包。"
  fi
}

offer_xanmod_reboot(){
  local yn
  xanmod_is_running && return 0
  echo
  yellow "XanMod 已安装但尚未运行：Linux 内核不能在当前会话中热切换。"
  yellow "通常重启后引导程序会选用新安装的 XanMod 内核；自定义引导配置请自行确认默认启动项。"
  read -rp "是否立即重启以尝试启用 XanMod？SSH 连接将断开。[y/N]: " yn
  [[ "$yn" =~ ^[Yy]$ ]] || { yellow "暂不重启；稍后重启后可再次进入本项核对运行状态。"; return 0; }
  require_root || return 1
  green "正在重启系统；重新连接后请再次查看 XanMod 运行状态。"
  reboot || {
    red "重启命令执行失败，请手动执行 reboot 后重新检查内核状态。"
    return 1
  }
}

install_xanmod_kernel(){
  local architecture repository_codename
  clear_screen
  green "XanMod 内核安装 / 状态 / 启用"
  echo
  if xanmod_is_installed; then
    green "已安装 XanMod 内核，无需重复安装。"
    show_xanmod_status
    offer_xanmod_reboot
    pause
    return
  fi

  show_xanmod_status
  echo
  require_root || { pause; return; }
  if ! has apt-get || ! has dpkg-query || ! has dpkg; then
    red "自动安装 XanMod 目前仅支持使用 APT/dpkg 的 Debian、Ubuntu、Kali 等 64 位 Debian 系系统。"
    pause
    return
  fi
  architecture="$(dpkg --print-architecture 2>/dev/null)"
  if [ "$architecture" != "amd64" ]; then
    red "XanMod 官方 APT 内核安装流程需要 amd64 架构；当前架构为 ${architecture:-未知}。"
    pause
    return
  fi
  read_platform_info
  if [ "$PLATFORM_ID" = "kali" ]; then
    yellow "注意：即将在 Kali 上安装 XanMod 第三方内核，它不由 Kali 官方维护。"
    yellow "Kali rolling 将使用 XanMod 列出的 Debian sid 兼容仓库。"
  fi
  repository_codename="$(xanmod_repository_codename)" || { pause; return; }
  green "正在添加 XanMod 官方软件源并安装 linux-xanmod-lts-x64v1..."
  if ! apt_update_ready ||
     ! DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates wget gnupg ||
     ! install -d -m 0755 /etc/apt/keyrings ||
     ! wget -qO /etc/apt/keyrings/xanmod-archive.key https://dl.xanmod.org/archive.key ||
     ! gpg --batch --yes --dearmor -o "$XANMOD_KEYRING" /etc/apt/keyrings/xanmod-archive.key; then
    rm -f /etc/apt/keyrings/xanmod-archive.key
    red "准备 XanMod 官方软件源失败，未继续安装内核。"
    pause
    return
  fi
  rm -f /etc/apt/keyrings/xanmod-archive.key
  printf 'deb [signed-by=%s] http://deb.xanmod.org %s main\n' "$XANMOD_KEYRING" "$repository_codename" \
    > "$XANMOD_SOURCE_LIST" || {
      red "写入 XanMod 软件源失败。"
      pause
      return
    }
  if apt_update_ready &&
     DEBIAN_FRONTEND=noninteractive apt-get install -y linux-xanmod-lts-x64v1; then
    echo
    green "XanMod 内核安装完成。重启系统后才会切换并启用新内核。"
    show_xanmod_status
    offer_xanmod_reboot
  else
    red "XanMod 内核安装失败，请检查上方 APT 输出和系统发行版支持情况。"
  fi
  pause
}

remove_sshpass_component(){
  if ! has sshpass; then
    green "sshpass: 未检测到，无需卸载。"
    return 0
  fi
  green "正在卸载附加组件 sshpass..."
  if has apt-get && has dpkg-query &&
     dpkg-query -W -f='${db:Status-Status}\n' sshpass 2>/dev/null | grep -qx installed; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y sshpass
  elif has apk && apk info -e sshpass >/dev/null 2>&1; then
    apk del sshpass
  elif has dnf && has rpm && rpm -q sshpass >/dev/null 2>&1; then
    dnf remove -y sshpass
  elif has yum && has rpm && rpm -q sshpass >/dev/null 2>&1; then
    yum remove -y sshpass
  else
    yellow "检测到 sshpass 命令，但无法确认其包管理来源，未自动移除。"
    return 1
  fi
}

remove_xanmod_component(){
  local packages removed_repo=0
  if xanmod_is_running; then
    yellow "当前正在运行 XanMod 内核，本次不卸载正在使用的内核包。"
    yellow "请先重启并选择发行版原生内核启动，再次执行初始化清理以卸载 XanMod。"
    return 1
  fi
  if packages="$(xanmod_installed_package_names)"; then
    if ! has apt-get; then
      red "检测到 XanMod 软件包，但系统没有 apt-get，无法自动卸载。"
      return 1
    fi
    if ! native_kernel_package_installed; then
      yellow "未检测到已安装的非 XanMod linux-image 内核包，为避免系统失去可启动内核，本次保留 XanMod。"
      yellow "请先安装/确认发行版原生内核后再次执行初始化清理。"
      return 1
    fi
    green "正在卸载 XanMod 内核包..."
    # Package names originate from dpkg-query; split them as APT package arguments.
    if ! DEBIAN_FRONTEND=noninteractive apt-get purge -y $packages; then
      red "XanMod 内核包卸载失败，保留软件源配置供后续处理。"
      return 1
    fi
  else
    green "XanMod: 未检测到已安装内核包。"
  fi
  if [ -f "$XANMOD_SOURCE_LIST" ]; then
    rm -f "$XANMOD_SOURCE_LIST"
    removed_repo=1
  fi
  if [ -f "$XANMOD_KEYRING" ]; then
    rm -f "$XANMOD_KEYRING"
    removed_repo=1
  fi
  rm -f /etc/apt/keyrings/xanmod-archive.key
  if [ "$removed_repo" -eq 1 ]; then
    green "已移除 XanMod 软件源及签名密钥。"
    has apt-get && apt_update_ready || true
  fi
}

reset_to_initial_state(){
  local yn reset_ok=1
  clear_screen
  green "一键卸载附加组件并恢复初始化状态"
  echo "将执行以下操作："
  echo "- 使用已保存的调优前基线恢复 TCP / qdisc 参数（若存在）"
  echo "- 删除本脚本写入的交互调优 / 迷之调参持久化配置和测试记录"
  echo "- 卸载 sshpass（不卸载 iperf3、speedtest、LibreSpeed 等基础/测速工具）"
  echo "- 卸载未在运行中的 XanMod 内核包，并移除 XanMod 软件源"
  echo
  yellow "如果当前正在运行 XanMod，本次会保留其内核包，待以原生内核启动后再清理。"
  read -rp "确认执行初始化清理？[y/N]: " yn
  [[ "$yn" =~ ^[Yy]$ ]] || { yellow "已取消。"; pause; return; }
  require_root || { pause; return; }
  echo

  if [ -f "$MYSTERY_BASELINE" ]; then
    green "正在恢复迷之调参应用前保存的网络参数基线..."
    if sysctl -p "$MYSTERY_BASELINE"; then
      green "运行参数已恢复为迷之调参应用前基线。"
    else
      red "应用迷之调参基线失败，保留配置以便重试。"
      reset_ok=0
    fi
    if [ "$reset_ok" -eq 1 ] && [ -f "$BASELINE" ] && [ "$BASELINE" -ot "$MYSTERY_BASELINE" ]; then
      green "检测到更早的交互调优基线，正在恢复其原始 TCP / qdisc 参数..."
      if sysctl -p "$BASELINE"; then
        green "运行参数已恢复为最初保存的交互调优基线。"
      else
        red "应用交互调优基线失败，保留配置以便重试。"
        reset_ok=0
      fi
    fi
  elif [ -f "$BASELINE" ]; then
    green "正在恢复调优前保存的 TCP / qdisc 基线..."
    if sysctl -p "$BASELINE"; then
      green "运行参数已恢复为调优前基线。"
    else
      red "应用调优前基线失败，保留基线与脚本配置以便重试。"
      reset_ok=0
    fi
  elif [ -f "$CONF" ] || [ -f "$MYSTERY_CONF" ]; then
    yellow "未发现调优前基线，无法可靠还原当前运行中的 TCP 参数。"
    yellow "将移除持久化脚本配置；下次重启后不会继续由该配置启用调优参数。"
  else
    green "未发现脚本持久化调优配置或回滚基线。"
  fi

  if [ "$reset_ok" -eq 1 ]; then
    rm -f "$CONF" "$BASELINE" "$MYSTERY_CONF" "$MYSTERY_BASELINE" "$MYSTERY_CANDIDATE" "$MYSTERY_LOG" "$SESSION_LOG" "$REMOTE_SESSION_LOG"
    green "已移除脚本调优配置、回滚基线和测试记录。"
  fi
  remove_sshpass_component || reset_ok=0
  remove_xanmod_component || reset_ok=0
  echo
  if [ "$reset_ok" -eq 1 ]; then
    green "初始化清理已完成。"
  else
    yellow "初始化清理部分完成，请根据上方提示处理保留项目。"
  fi
  pause
}

install_optional_speed_tool(){
  local tool="$1"
  require_root || return 1
  green "正在尝试安装可选测速组件：$tool"
  if has apt-get; then
    apt_update_ready && DEBIAN_FRONTEND=noninteractive apt-get install -y "$tool"
  elif has apk; then
    apk add "$tool"
  elif has dnf; then
    dnf install -y "$tool"
  elif has yum; then
    yum install -y "$tool"
  else
    red "暂不支持当前包管理器，请手动安装 $tool。"
    return 1
  fi
}

ensure_optional_speed_tool(){
  local tool="$1" label="$2" yn
  has "$tool" && return 0
  yellow "当前未检测到 $label（命令：$tool）。"
  read -rp "是否现在尝试安装？[y/N]: " yn
  [[ "$yn" =~ ^[Yy]$ ]] && install_optional_speed_tool "$tool" && has "$tool"
}

ookla_test_menu(){
  local choice server_id retry
  ensure_optional_speed_tool speedtest "Ookla Speedtest CLI" || {
    yellow "未安装 Ookla Speedtest CLI，返回测速菜单。"
    pause
    return
  }
  while true; do
    clear_screen
    green "Ookla Speedtest 公网测速"
    echo "1. 自动选择测速服务器并测试"
    echo "2. 列出附近可用测速服务器"
    echo "3. 指定服务器 ID 进行测试"
    echo "0. 返回"
    echo
    read -rp "请选择 [0-3]: " choice
    case "$choice" in
      1)
        echo
        green "正在执行 Ookla 自动选点测速..."
        if speedtest --accept-license --accept-gdpr; then
          pause
        else
          red "Ookla 测速失败。"
          read -rp "是否重新测试？[y/N]: " retry
          [[ "$retry" =~ ^[Yy]$ ]] || return
        fi
        ;;
      2)
        echo
        green "正在获取 Ookla 附近服务器列表..."
        speedtest --accept-license --accept-gdpr --servers || red "获取服务器列表失败。"
        pause
        ;;
      3)
        while true; do
          read -rp "输入 Ookla 服务器 ID: " server_id
          [[ "$server_id" =~ ^[0-9]+$ ]] && break
          red "服务器 ID 应为整数。"
        done
        echo
        green "正在使用 Ookla 服务器 ID $server_id 测速..."
        if speedtest --accept-license --accept-gdpr --server-id="$server_id"; then
          pause
        else
          red "Ookla 指定节点测速失败。"
          read -rp "是否重新选择并测试？[y/N]: " retry
          [[ "$retry" =~ ^[Yy]$ ]] || return
        fi
        ;;
      0) return ;;
      *) red "无效输入" ;;
    esac
  done
}

librespeed_test_menu(){
  local retry
  ensure_optional_speed_tool librespeed-cli "LibreSpeed CLI" || {
    yellow "未安装 LibreSpeed CLI，返回测速菜单。"
    pause
    return
  }
  while true; do
    clear_screen
    green "LibreSpeed 公网测速"
    echo "正在执行 librespeed-cli 并显示详细结果..."
    echo
    if librespeed-cli; then
      pause
      return
    fi
    red "LibreSpeed 测速失败。"
    read -rp "是否重新测试？[y/N]: " retry
    [[ "$retry" =~ ^[Yy]$ ]] || return
  done
}

public_speedtest_menu(){
  local choice
  while true; do
    clear_screen
    green "独立公网测速"
    yellow "公网测速适合了解本机出口能力，不等同于远程节点到本 VPS 的目标链路测速。"
    echo "1. Ookla Speedtest（支持自动选点 / 查看服务器 / 指定服务器 ID）"
    echo "2. LibreSpeed"
    echo "0. 返回"
    echo
    read -rp "请选择 [0-2]: " choice
    case "$choice" in
      1) ookla_test_menu ;;
      2) librespeed_test_menu ;;
      0) return ;;
      *) red "无效输入" ;;
    esac
  done
}

check_remote_local_env(){
  local missing=0 command yn
  echo
  green "远程自动模式本机依赖检查"
  for command in sysctl awk iperf3 jq ssh; do
    if has "$command"; then
      green "[已安装] $command"
    else
      yellow "[缺少] $command"
      missing=1
    fi
  done
  if has sshpass; then
    green "[已安装] sshpass（可使用密码认证）"
  else
    yellow "[可选缺少] sshpass（选择密码认证时将提示安装）"
  fi
  if [ "$missing" -eq 1 ]; then
    echo
    read -rp "远程模式必要依赖缺失，是否现在尝试安装？[y/N]: " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      install_base || return 1
    else
      return 1
    fi
    for command in sysctl awk iperf3 jq ssh; do
      has "$command" || { red "安装后仍缺少必要命令：$command"; return 1; }
    done
  fi
}

save_baseline_once(){
  require_root || return 1
  mkdir -p "$STATE_DIR" || return 1
  if [ -f "$BASELINE" ]; then
    yellow "已存在回滚基线：$BASELINE（不会覆盖）。"
    return 0
  fi
  {
    printf '# tcptune baseline captured before tuning\n'
    printf 'net.core.default_qdisc = %s\n' "$(sysctl_value net.core.default_qdisc)"
    printf 'net.ipv4.tcp_congestion_control = %s\n' "$(sysctl_value net.ipv4.tcp_congestion_control)"
    printf 'net.ipv4.tcp_wmem = %s\n' "$(sysctl_value net.ipv4.tcp_wmem)"
    printf 'net.ipv4.tcp_rmem = %s\n' "$(sysctl_value net.ipv4.tcp_rmem)"
  } > "$BASELINE" || return 1
  green "已保存回滚基线：$BASELINE"
}

restore_baseline(){
  clear_screen
  require_root || { pause; return; }
  if [ -f "$MYSTERY_CONF" ]; then
    red "当前存在迷之调参持久化配置：$MYSTERY_CONF"
    yellow "迷之调参配置会覆盖部分基线参数，请使用“一键卸载附加组件并恢复初始化状态”完整回滚。"
    pause
    return
  fi
  if [ ! -f "$BASELINE" ]; then
    red "未找到回滚基线：$BASELINE"
    pause
    return
  fi
  yellow "将用已保存的基线替换 $CONF 并应用。"
  read -rp "确认恢复？[y/N]: " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    cp "$BASELINE" "$CONF" && sysctl --system &&
      green "已恢复基线配置。" || red "恢复失败，请检查系统输出。"
  fi
  pause
}

prepare_bbr_fq(){
  local available cc qdisc yn
  available="$(sysctl_value net.ipv4.tcp_available_congestion_control)"
  cc="$(sysctl_value net.ipv4.tcp_congestion_control)"
  qdisc="$(sysctl_value net.core.default_qdisc)"
  echo
  green "拥塞控制与默认队列检查"
  printf '可用拥塞控制算法: %s\n当前拥塞控制算法: %s\n当前默认 qdisc: %s\n' "$available" "$cc" "$qdisc"
  if [[ " $available " != *" bbr "* ]]; then
    red "当前内核未报告 bbr 可用，无法按文章的 bbr + fq 前提继续。"
    return 1
  fi
  if [ "$cc" = "bbr" ] && [ "$qdisc" = "fq" ]; then
    green "已启用 bbr + fq。"
    return 0
  fi
  read -rp "是否临时启用 bbr + fq 进行本次测试？[Y/n]: " yn
  if [[ "$yn" =~ ^[Nn]$ ]]; then
    red "未启用 bbr + fq，已取消文章方案一调优流程。"
    return 1
  fi
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null &&
    sysctl -w net.core.default_qdisc=fq >/dev/null || {
      red "设置 bbr + fq 失败。"
      return 1
    }
  yellow "已设置默认 qdisc=fq；既有接口的当前 qdisc 请通过状态菜单核对。"
}

show_client_command(){
  local host="$1" direction="$2" duration="$3"
  if [ "$direction" = "download" ]; then
    printf 'iperf3 -c %s -R -t %s\n' "$host" "$duration"
  else
    printf 'iperf3 -c %s -t %s\n' "$host" "$duration"
  fi
}

apply_window(){
  local value="$1"
  sysctl -w net.ipv4.tcp_wmem="4096 16384 $value" >/dev/null &&
    sysctl -w net.ipv4.tcp_rmem="4096 87380 $value" >/dev/null
}

collect_test_result(){
  local candidate="$1" command="$2" throughput retr shake
  echo
  green "请在客户端执行本轮测试"
  printf '%s\n' "$command"
  read_positive "输入本轮平均吞吐 Mbps" ""
  throughput="$REPLY"
  while true; do
    read -rp "输入本轮 Retr 重传数: " retr
    [[ "$retr" =~ ^[0-9]+$ ]] && break
    red "请输入非负整数。"
  done
  read -rp "本轮是否出现明显速度抖动或断流？[y/N]: " shake
  [[ "$shake" =~ ^[Yy]$ ]] && shake="yes" || shake="no"
  printf '%s\t%s\t%s\t%s\n' "$candidate" "$throughput" "$retr" "$shake" >> "$SESSION_LOG"
  RESULT_THROUGHPUT="$throughput"
  RESULT_RETR="$retr"
  RESULT_SHAKE="$shake"
}

persist_final(){
  local value="$1"
  {
    printf '# Managed by tcptune. Validated through the interactive iperf3 workflow.\n'
    printf 'net.core.default_qdisc = fq\n'
    printf 'net.ipv4.tcp_congestion_control = bbr\n'
    printf 'net.ipv4.tcp_wmem = 4096 16384 %s\n' "$value"
    printf 'net.ipv4.tcp_rmem = 4096 87380 %s\n' "$value"
  } > "$CONF" &&
    sysctl --system
}

mystery_read_decimal(){
  local prompt="$1" default="$2" min="$3" max="$4" value
  while true; do
    read -rp "$prompt [$default]: " value
    value="${value:-$default}"
    if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
       awk "BEGIN{exit !($value >= $min && $value <= $max)}"; then
      REPLY="$value"
      return 0
    fi
    red "请输入 $min 到 $max 范围内的数字。"
  done
}

mystery_check_environment(){
  local missing=0 command yn
  green "TCP 迷之调参环境检查"
  for command in sysctl gawk modprobe cp mkdir cat; do
    if has "$command"; then
      green "[已安装] $command"
    else
      red "[缺少] $command"
      missing=1
    fi
  done
  if [ "$missing" -eq 1 ]; then
    read -rp "必要依赖缺失，是否尝试安装基础依赖？[y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] && install_base
    for command in sysctl gawk modprobe cp mkdir cat; do
      has "$command" || return 1
    done
  fi
  printf '当前可用拥塞控制算法: %s\n' "$(sysctl_value net.ipv4.tcp_available_congestion_control)"
  printf '当前默认 qdisc: %s\n' "$(sysctl_value net.core.default_qdisc)"
}

mystery_choose_transport(){
  local available choice
  available="$(sysctl_value net.ipv4.tcp_available_congestion_control)"
  echo
  echo "选择拥塞控制算法（原默认值为 bbr）："
  echo "1. bbr"
  echo "2. cubic"
  while true; do
    read -rp "请选择 [1-2，默认 1]: " choice
    choice="${choice:-1}"
    case "$choice" in
      1) MYSTERY_CC="bbr" ;;
      2) MYSTERY_CC="cubic" ;;
      *) red "请选择 1 或 2。"; continue ;;
    esac
    [[ " $available " == *" $MYSTERY_CC "* ]] && break
    red "当前内核未报告 $MYSTERY_CC 可用，不能应用该配置。"
  done
  echo
  echo "选择队列算法（原默认值为 cake）："
  echo "1. cake"
  echo "2. fq"
  echo "3. fq_pie"
  while true; do
    read -rp "请选择 [1-3，默认 1]: " choice
    choice="${choice:-1}"
    case "$choice" in
      1) MYSTERY_QDISC="cake"; break ;;
      2) MYSTERY_QDISC="fq"; break ;;
      3) MYSTERY_QDISC="fq_pie"; break ;;
      *) red "请选择 1、2 或 3。" ;;
    esac
  done
  if [ "$MYSTERY_QDISC" != "fq" ]; then
    if has modprobe; then
      modprobe "sch_$MYSTERY_QDISC" >/dev/null 2>&1 ||
        yellow "无法预加载 sch_$MYSTERY_QDISC；配置应用时将由当前内核最终验证。"
    else
      yellow "$MYSTERY_QDISC 需要当前内核支持；未检测到 modprobe，配置应用时将最终验证。"
    fi
  fi
}

mystery_generate_tcp_config(){
  local algorithm="$1" local_bw="$2" vps_bw="$3" rtt="$4" memory="$5" ramp="$6" cc="$7" qdisc="$8" aggressive="$9"
  gawk -v local_bw="$local_bw" -v vps_bw="$vps_bw" -v rtt="$rtt" -v mem="$memory" \
      -v ramp="$ramp" -v cc="$cc" -v qdisc="$qdisc" -v aggressive="$aggressive" -v algorithm="$algorithm" '
    function min(a,b){ return a < b ? a : b }
    function max(a,b){ return a > b ? a : b }
    function clamp(x,a,b){ return min(max(x,a),b) }
    function ceil(x){ return int(x) == x ? x : int(x) + 1 }
    function log2(x){ return log(x)/log(2) }
    function integer(x){ return sprintf("%.0f", int(x)) }
    function piece(x) {
      if (x <= 0) return 1
      if (x <= .3) return 1 + x/.3*.5
      if (x <= .6) return 1.5 + (x-.3)/.3
      if (x <= 1) return 2.5 + (x-.6)/.4*1.5
      return 4
    }
    function out(k,v){
      if (v ~ /^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$/) v=integer(v)
      printf "%s = %s\n", k, v
    }
    function common_policy(ipforward, redirects, neigh1, neigh2, neigh3) {
      if (ipforward >= 0) out("net.ipv4.ip_forward",ipforward)
      out("net.ipv4.ip_local_port_range","1024 65535")
      out("net.ipv4.ip_no_pmtu_disc",0)
      out("net.ipv4.route.gc_timeout",100)
      out("net.ipv4.neigh.default.gc_stale_time",120)
      out("net.ipv4.neigh.default.gc_thresh3",neigh3)
      out("net.ipv4.neigh.default.gc_thresh2",neigh2)
      out("net.ipv4.neigh.default.gc_thresh1",neigh1)
      if (redirects) {
        out("net.ipv4.conf.all.accept_redirects",0)
        out("net.ipv4.conf.default.accept_redirects",0)
        out("net.ipv4.conf.all.secure_redirects",0)
        out("net.ipv4.conf.default.secure_redirects",0)
        out("net.ipv4.conf.all.accept_source_route",0)
        out("net.ipv4.conf.default.accept_source_route",0)
        out("net.ipv4.conf.all.forwarding",0)
        out("net.ipv4.conf.default.forwarding",0)
      }
      out("net.ipv4.icmp_echo_ignore_broadcasts",1)
      out("net.ipv4.icmp_ignore_bogus_error_responses",1)
      out("net.ipv4.conf.all.rp_filter",1)
      out("net.ipv4.conf.default.rp_filter",1)
      out("net.ipv4.conf.all.arp_announce",2)
      out("net.ipv4.conf.default.arp_announce",2)
      out("net.ipv4.conf.all.arp_ignore",1)
      out("net.ipv4.conf.default.arp_ignore",1)
    }
    function system_base(swappiness, dirty, dirty_bg, minfree) {
      out("kernel.pid_max",65535)
      out("kernel.panic",1)
      out("kernel.sysrq",1)
      out("kernel.core_pattern","core_%e")
      out("kernel.printk","3 4 1 3")
      out("kernel.numa_balancing",0)
      out("kernel.sched_autogroup_enabled",0)
      out("vm.swappiness",swappiness)
      out("vm.dirty_ratio",dirty)
      out("vm.dirty_background_ratio",dirty_bg)
      out("vm.panic_on_oom",1)
      out("vm.overcommit_memory",1)
      out("vm.min_free_kbytes",minfree)
    }
    function tcp_base(q, backlog, rmax, wmax, rdefault, wdefault, somax, optmem,
                      timestamps, fin, fack, rmin, rmid, wmin, wmid, mtu, notsent,
                      adv, moderate, metrics, synbacklog, orphans, synack, synretry) {
      out("net.core.default_qdisc",q)
      out("net.core.netdev_max_backlog",backlog)
      out("net.core.rmem_max",rmax)
      out("net.core.wmem_max",wmax)
      out("net.core.rmem_default",rdefault)
      out("net.core.wmem_default",wdefault)
      out("net.core.somaxconn",somax)
      out("net.core.optmem_max",optmem)
      out("net.ipv4.tcp_fastopen",3)
      out("net.ipv4.tcp_timestamps",timestamps)
      out("net.ipv4.tcp_tw_reuse",1)
      out("net.ipv4.tcp_fin_timeout",fin)
      out("net.ipv4.tcp_slow_start_after_idle",0)
      out("net.ipv4.tcp_max_tw_buckets",32768)
      out("net.ipv4.tcp_sack",1)
      out("net.ipv4.tcp_fack",fack)
      out("net.ipv4.tcp_rmem",integer(rmin) " " integer(rmid) " " integer(rmax))
      out("net.ipv4.tcp_wmem",integer(wmin) " " integer(wmid) " " integer(wmax))
      out("net.ipv4.tcp_mtu_probing",mtu)
      out("net.ipv4.tcp_congestion_control",cc)
      out("net.ipv4.tcp_notsent_lowat",notsent)
      out("net.ipv4.tcp_window_scaling",1)
      out("net.ipv4.tcp_adv_win_scale",adv)
      out("net.ipv4.tcp_moderate_rcvbuf",moderate)
      out("net.ipv4.tcp_no_metrics_save",metrics)
      out("net.ipv4.tcp_max_syn_backlog",synbacklog)
      out("net.ipv4.tcp_max_orphans",orphans)
      out("net.ipv4.tcp_synack_retries",synack)
      out("net.ipv4.tcp_syn_retries",synretry)
      out("net.ipv4.tcp_abort_on_overflow",0)
      out("net.ipv4.tcp_stdurg",0)
      out("net.ipv4.tcp_rfc1337",0)
      out("net.ipv4.tcp_syncookies",1)
    }
    function legacy() {
      if (rtt > 120) {
        lf=min(4,max(1,rtt/40))
        amp=min(4,max(1.5,2*sqrt(local_bw/vps_bw)*lf))
        rate=int(mib*min(local_bw*amp,1.8*vps_bw)/8)
        base=max(max(ceil(rate*rtt/1000),131072),rate*rtt/1200)
        rmax=int(base*min(12,max(6,2*lf)))
        wmax=int(base*min(8,max(4,1.5*lf)))
        scale=min(4,max(2,lf))
        somax=int(min(max(1024,ceil(rate/32768*scale)),16384))
        backlog=int(min(max(16000,ceil(rate/8192*scale)),32000))
        syn=int(min(max(4096,ceil(rate/4096*scale)),131072))
        minfree=min(max(65536,rate/1024*.8),524288)
        system_base(5,5,2,minfree)
        tcp_base(qdisc,backlog,rmax,wmax,262144,131072,somax,min(131072,base/4),
          1,10,1,32768,262144,16384,131072,1,min(base/4,524288),
          min(6,ceil(1.2*lf)),0,1,syn,32768,2,2)
        common_policy(-1,0,512,2048,4096)
      } else {
        amp=min(2,max(1,1.5*sqrt(local_bw/vps_bw)))
        rate=mib*min(local_bw*amp,vps_bw)/8
        base=max(ceil(rate*rtt/1000),24576)
        rmax=int(3*base); wmax=int(1.5*base)
        somax=int(min(max(256,ceil(rate/262144)),2048))
        backlog=int(min(max(2000,ceil(rate/131072)),4000))
        syn=int(min(max(2048,ceil(rate/65536)),16384))
        minfree=min(max(65536,rate/1024),1048576)
        system_base(10,10,5,minfree)
        tcp_base(qdisc,backlog,rmax,wmax,87380,65536,somax,min(65536,base/4),
          1,10,0,8192,87380,8192,65536,1,8192,2,1,0,syn,65536,2,3)
        common_policy(-1,0,1024,4096,8192)
      }
    }
    function arc_high(    lf,amp,rate,ratio,reduce,tp,stable,ba,qd,cs,mu,wsbase,wstol,wsmax,
                         curve,latfac,buffac,qfac,advfac,bdp,base,cap,rcoef,wcoef,rmax,wmax,
                         qraw,z,somax,backlog,syn,minfree,x,k,maxq) {
      mem=max(mem,256)
      lf=min(5,max(1,rtt/40))
      amp=min(5,max(1.5,2*sqrt(local_bw/vps_bw)*lf))
      rate=int(mib*min(local_bw*amp,2*vps_bw)/8)
      ratio=local_bw/vps_bw; reduce=1
      if (ratio>100) reduce=.06; else if (ratio>50) reduce=.12; else if (ratio>20) reduce=.2
      else if (ratio>10) reduce=.3; else if (ratio>5) reduce=.5; else if (ratio>2) reduce=.7
      tp=2; stable=1.5; ba=2; qd=2.5; cs=2; mu=1.5; wsbase=2; wstol=2; wsmax=8
      if (mem<=512) { tp=1.8; stable=1.8; ba=1.5; qd=2; cs=1.5; mu=1.2; wsbase=1.5; wsmax=6 }
      else if (mem<=2048 && mem>1024) { tp=2.2; ba=2.3; qd=3; cs=2.5; mu=1.8; wsbase=2.5; wsmax=12 }
      else if (mem>2048) { tp=2.5; ba=2.5; qd=3.5; cs=3; mu=2; wsbase=3; wsmax=16 }
      curve=clamp((tp/2)*log(ramp*(exp(1)-1)+1)*stable*(ba/2),.5,3)
      latfac=clamp((log(min(1,(rtt-120)/1880)*(.5)+1)/log(1.5))*wstol*curve,1,8)
      buffac=clamp(latfac*(10+.1*curve)*tp*ba*mu*piece(curve),1,8)
      qfac=clamp(latfac/3*(log((rtt/1000*3)/(1-min(.9,.85*curve))*rate/131072*cs+1)/log(10000)*qd),.8,4)
      advfac=clamp(latfac/wstol*(max(0,ceil(log2(4*ceil(rate*rtt/1000)/65535)))*wsbase)*(2*curve+1),2,wsmax)
      bdp=ceil(rate*rtt/1000); base=max(bdp,262144)
      if (mem<=512) base=max(max(bdp,131072),rate*rtt/1200)
      else if (mem<=1024) base=max(max(bdp,262144),rate*rtt/1000)
      else base=max(max(bdp,524288),rate*rtt/800)
      cap=min(ceil(2*ramp*reduce*bdp),mem*mib*.125); if (rtt>500) cap=max(cap,ceil(.5*bdp))
      rcoef=mem<=512?min(6,max(3,1.5*lf)):(mem<=1024?min(8,max(4,1.8*lf)):min(10,max(5,2*lf)))
      wcoef=rcoef*buffac
      rmax=min(int(base*rcoef),cap); wmax=min(int(base*wcoef),cap)
      qraw=ceil(min(3*max(50,rate/131072),20000)*qfac)
      z=mem<=512?.8:(mem<=1024?1:(mem<=2048?1.3:1.5))
      maxq=mem<=512?8192:16384
      somax=clamp(int(.15*qraw*z),2560,maxq)
      backlog=clamp(int(.3*qraw*z),8192,mem<=512?16384:32768)
      syn=clamp(int(.6*qraw*z),8192,mem<=512?32768:65536)
      minfree=clamp(int(1024*mem*(mem<=512?.02:(mem<=1024?.025:(mem<=2048?.03:.035))))+int(.6*ceil(rate/1024)),65536,1048576)
      system_base(5,5,2,minfree)
      out("vm.vfs_cache_pressure",100); out("vm.dirty_expire_centisecs",3000); out("vm.dirty_writeback_centisecs",500)
      tcp_base(qdisc,backlog,cap,cap,262144,262144,somax,int(min(262144,base/2)),
        1,10,1,32768,262144,32768,262144,1,int(min(base/2,524288)),
        max(2,ceil(lf*advfac)),1,1,syn,mem<=256?16384:32768,2,2)
      out("net.ipv4.tcp_rmem","32768 262144 " integer(rmax))
      out("net.ipv4.tcp_wmem","32768 262144 " integer(wmax))
      common_policy(0,1,mem<=512?256:512,mem<=512?1024:2048,mem<=512?2048:4096)
      if (aggressive == "yes") {
        x=max(min(rate*rtt/1000*min(12,6+mem/1024),mib*mem*.15),4194304)
        k=min(rtt/100,5); maxq=min(6*mem,24576)
        backlog=min(maxq,6000+min(rate/1048576,15000)*k); syn=min(maxq/2,3000+min(rate/1048576,15000)*k/2)
        out("net.core.rmem_max",2*x); out("net.core.wmem_max",x)
        out("net.core.rmem_default",524288); out("net.core.wmem_default",524288)
        out("net.ipv4.tcp_rmem","65536 524288 " integer(2*x)); out("net.ipv4.tcp_wmem","65536 524288 " integer(x))
        out("net.core.netdev_max_backlog",backlog); out("net.core.somaxconn",32768)
        out("net.ipv4.tcp_max_syn_backlog",syn); out("net.ipv4.tcp_mtu_probing",2)
        out("net.ipv4.tcp_fack",1); out("net.ipv4.tcp_notsent_lowat",32768); out("net.core.default_qdisc","fq")
        out("vm.min_free_kbytes",max(262144,64*mem)); out("vm.swappiness",1)
        out("net.ipv4.tcp_mem",integer(512*mem) " " integer(768*mem) " " integer(1024*mem))
        out("net.ipv4.tcp_keepalive_time",1200); out("net.ipv4.tcp_keepalive_intvl",60)
        out("net.ipv4.tcp_fin_timeout",30); out("net.core.busy_read",0); out("net.core.busy_poll",0)
        out("net.core.optmem_max",min(163840,160*mem))
      }
    }
    function arc_low(    resp,jitter,burst,me,ba,qpref,conn,wsbase,wssens,wsmax,amp,rate,ratio,reduce,
                        bdp,base,pct,floorbuf,cap,curve,latfac,buffac,qfac,advfac,rmult,wmult,
                        rmax,wmax,qraw,z,somax,backlog,syn,minfree,x,maxq) {
      resp=2; jitter=.3; burst=.7; me=1; ba=.8; qpref=.8; conn=1.2; wsbase=1.2; wssens=1.5; wsmax=4
      if (mem<=256) {resp=2.5;jitter=.2;burst=.5;me=.8;ba=.6;qpref=.6;conn=1;wsbase=1;wsmax=3}
      else if (mem<=512) {resp=2.2;jitter=.25;burst=.6;me=.9;ba=.7}
      else if (mem>1024) {resp=1.8;jitter=.4;burst=.9;me=1.2;ba=1;qpref=1;conn=1.5;wsbase=1.4;wsmax=6}
      amp=min(2,max(1,1.5*sqrt(local_bw/vps_bw))); rate=mib*min(local_bw*amp,vps_bw)/8
      ratio=local_bw/vps_bw; reduce=ratio>1?max(.3,1/sqrt(min(ratio,100))):1
      bdp=ceil(rate*rtt/1000); base=max(bdp,24576); pct=mem<=256?.10:.125; floorbuf=mem<=256?4194304:8388608
      cap=max(min(ceil(1.5*ramp*reduce*bdp),mem*mib*pct),floorbuf)
      curve=clamp((1/(1+exp(-4*(ramp-.3))))*(resp/2),.3,2)
      latfac=clamp(exp(log(2)*(rtt/120-1))*curve*resp,.8,5)
      buffac=clamp(latfac*(1+.5*curve)*me*ba*burst,.5,3)
      qfac=clamp(log((rtt/1000*2)/(1-min(.8*curve,.95))*rate/65536*conn+1)/log(1000)*qpref*(1+jitter),.3,2)
      advfac=clamp(latfac/wssens*(max(0,ceil(log2(2*bdp/65535)))*wsbase)*curve,1,wsmax)
      rmult=mem<=256?2.5:(mem<=512?3:4); wmult=mem<=256?1.2:(mem<=512?1.5:2)
      rmax=min(int(base*rmult*buffac),cap); wmax=min(int(base*wmult*buffac),cap)
      qraw=ceil(min(2*max(100,rate/65536),10000)*qfac); z=mem<=256?.6:(mem<=512?.8:(mem<=1024?1:1.2))
      somax=clamp(int(.2*qraw*z),256,2048); backlog=clamp(int(.4*qraw*z),2000,4000); syn=clamp(int(.8*qraw*z),2048,16384)
      minfree=clamp(int(1024*mem*(mem<=256?.015:(mem<=512?.02:(mem<=1024?.025:.03))))+int(.5*ceil(rate/1024)),32768,1048576)
      system_base(10,10,5,minfree)
      out("vm.vfs_cache_pressure",100); out("vm.dirty_expire_centisecs",3000); out("vm.dirty_writeback_centisecs",500)
      tcp_base(qdisc,backlog,cap,cap,87380,65536,somax,int(min(65536,base/4)),
        1,10,0,8192,87380,8192,65536,1,4096,max(2,ceil(advfac)),1,0,syn,65536,2,3)
      out("net.ipv4.tcp_rmem","8192 87380 " integer(rmax)); out("net.ipv4.tcp_wmem","8192 65536 " integer(wmax))
      common_policy(0,1,1024,4096,8192)
      if (aggressive == "yes") {
        x=max(min(rate*rtt/1000*min(8,4+mem/2048),mib*mem*.12),2097152)
        maxq=min(4*mem,16384); backlog=min(maxq,4000+min(rate/1048576,10000)); syn=min(maxq/2,2048+min(rate/1048576,10000)/2)
        out("net.core.rmem_max",2*x); out("net.core.wmem_max",x)
        out("net.core.rmem_default",262144); out("net.core.wmem_default",262144)
        out("net.ipv4.tcp_rmem","32768 262144 " integer(2*x)); out("net.ipv4.tcp_wmem","32768 262144 " integer(x))
        out("net.core.netdev_max_backlog",backlog); out("net.core.somaxconn",16384)
        out("net.ipv4.tcp_max_syn_backlog",syn); out("net.ipv4.tcp_mtu_probing",2)
        out("net.ipv4.tcp_timestamps",0); out("net.ipv4.tcp_fack",1); out("net.ipv4.tcp_notsent_lowat",16384)
        out("net.core.default_qdisc","fq"); out("net.core.busy_read",50); out("net.core.busy_poll",50)
        out("kernel.sched_min_granularity_ns",3000000); out("vm.min_free_kbytes",max(131072,32*mem)); out("vm.swappiness",1)
        out("net.ipv4.tcp_mem",integer(384*mem) " " integer(512*mem) " " integer(768*mem))
        out("net.ipv4.tcp_keepalive_time",600); out("net.ipv4.tcp_keepalive_intvl",30); out("net.ipv4.tcp_keepalive_probes",3)
        out("net.ipv4.tcp_fin_timeout",15); out("net.ipv4.tcp_moderate_rcvbuf",0); out("net.core.optmem_max",min(81920,80*mem))
      }
    }
    BEGIN {
      mib=1048576
      printf "# Managed by tcptune TCP Mystery Tuning (algorithm=%s, aggressive=%s)\n", algorithm, aggressive
      printf "# Input: local=%s Mbps server=%s Mbps rtt=%s ms memory=%s MB curvature=%s\n", local_bw,vps_bw,rtt,mem,ramp
      printf "# Integer-valued sysctl output is rendered as decimal integers for Linux application.\n"
      if (algorithm == "Legacy") {
        printf "# Legacy keeps its original inputs: memory, curvature and aggressive mode do not change its output.\n"
        legacy()
      } else if (rtt > 120) arc_high()
      else arc_low()
    }' > "$MYSTERY_CANDIDATE"
}

mystery_collapse_overrides(){
  local collapsed="${MYSTERY_CANDIDATE}.collapsed"
  awk '
    /^#/ { comments[++comment_count]=$0; next }
    /^[^[:space:]]+[[:space:]]*=/ {
      key=$1
      if (!(key in seen)) { order[++key_count]=key; seen[key]=1 }
      last[key]=$0
      next
    }
    { trailing[++trailing_count]=$0 }
    END {
      for (i=1; i<=comment_count; i++) print comments[i]
      for (i=1; i<=key_count; i++) print last[order[i]]
      for (i=1; i<=trailing_count; i++) print trailing[i]
    }
  ' "$MYSTERY_CANDIDATE" > "$collapsed" && mv "$collapsed" "$MYSTERY_CANDIDATE"
}

mystery_filter_supported_candidate(){
  local line key filtered="${MYSTERY_CANDIDATE}.supported"
  : > "$filtered" || return 1
  while IFS= read -r line; do
    case "$line" in
      ""|\#*) printf '%s\n' "$line" >> "$filtered"; continue ;;
    esac
    key="${line%%[[:space:]]*}"
    if sysctl -n "$key" >/dev/null 2>&1; then
      printf '%s\n' "$line" >> "$filtered"
    else
      yellow "当前内核不存在参数 $key，已从迷之调参配置中跳过。"
    fi
  done < "$MYSTERY_CANDIDATE"
  mv "$filtered" "$MYSTERY_CANDIDATE"
}

mystery_save_baseline_once(){
  local key value
  require_root || return 1
  mkdir -p "$STATE_DIR" || return 1
  [ -f "$MYSTERY_BASELINE" ] && { yellow "已存在迷之调参回滚基线：$MYSTERY_BASELINE（不会覆盖）。"; return 0; }
  printf '# tcptune TCP Mystery Tuning baseline captured before generated configuration\n' > "$MYSTERY_BASELINE" || return 1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    value="$(sysctl_value "$key")"
    [ "$value" = "不可用" ] || printf '%s = %s\n' "$key" "$value" >> "$MYSTERY_BASELINE"
  done < <(awk -F '[[:space:]]*=[[:space:]]*' '!/^#/ && NF >= 2 {print $1}' "$MYSTERY_CANDIDATE")
}

mystery_apply_candidate(){
  cp "$MYSTERY_CANDIDATE" "$MYSTERY_CONF" || return 1
  if sysctl -p "$MYSTERY_CONF"; then
    green "迷之调参 TCP 配置已应用并持久化到 $MYSTERY_CONF"
    return 0
  fi
  red "配置未能完整应用，正在尝试恢复迷之调参应用前基线。"
  sysctl -p "$MYSTERY_BASELINE" >/dev/null 2>&1 || red "自动恢复失败，请手动检查 $MYSTERY_BASELINE。"
  rm -f "$MYSTERY_CONF"
  return 1
}

mystery_choose_algorithm(){
  local choice
  echo
  echo "选择参数生成算法："
  echo "1. Legacy（原低/高延迟公式，支持 RTT 宽松模式）"
  echo "2. Arc（曲率自适应；按低/高延迟场景调整缓冲与队列）"
  while true; do
    read -rp "请选择 [1-2]: " choice
    case "$choice" in
      1) MYSTERY_ALGORITHM="Legacy"; return 0 ;;
      2) MYSTERY_ALGORITHM="Arc"; return 0 ;;
      *) red "请选择 1 或 2。" ;;
    esac
  done
}

mystery_log(){
  printf '%s\n' "$*" >> "$MYSTERY_LOG"
}

view_mystery_log(){
  clear_screen
  green "TCP 迷之调参 - 最近一次运行日志"
  echo
  if [ -f "$MYSTERY_LOG" ]; then
    printf '日志路径: %s\n\n' "$MYSTERY_LOG"
    cat "$MYSTERY_LOG"
  else
    yellow "尚未生成迷之调参日志。执行一次调参预览或应用后即可在此查看。"
    printf '预期日志路径: %s\n' "$MYSTERY_LOG"
  fi
  echo
  pause
}

mystery_tune_flow(){
  local local_bw vps_bw rtt memory ramp aggressive relaxed yn
  clear_screen
  green "TCP 迷之调参"
  echo "依据原算法公式生成完整 sysctl 配置。"
  yellow "注意：完整复现会写入 kernel、vm、ARP、路由与转发相关策略；应用前请检查预览。"
  echo
  mystery_choose_algorithm
  require_root || { pause; return; }
  mkdir -p "$STATE_DIR" || { red "无法创建状态目录。"; pause; return; }
  {
    printf 'TCP 迷之调参运行日志（每次运行覆盖）\n'
    printf 'time=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf unknown)"
    printf 'algorithm=%s\n' "$MYSTERY_ALGORITHM"
  } > "$MYSTERY_LOG" || { red "无法写入运行日志：$MYSTERY_LOG"; pause; return; }
  mystery_check_environment || { mystery_log "result=environment-check-failed"; red "迷之调参必要环境未满足。"; pause; return; }
  mystery_choose_transport || { mystery_log "result=transport-selection-failed"; pause; return; }
  mystery_read_decimal "输入本地下载带宽 Mbps" "1000" "1" "100000"; local_bw="$REPLY"
  mystery_read_decimal "输入服务器出口带宽 Mbps" "1000" "1" "100000"; vps_bw="$REPLY"
  mystery_read_decimal "输入本地到服务器 RTT ms" "50" "1" "2000"; rtt="$REPLY"
  mystery_read_decimal "输入服务器可用内存 MB" "1024" "64" "32768"; memory="$REPLY"
  mystery_read_decimal "输入曲率" "0.7" "0.1" "1"; ramp="$REPLY"
  if [ "$MYSTERY_ALGORITHM" = "Arc" ]; then
    read -rp "是否启用激进模式？激进模式会按原逻辑覆盖更多系统参数并强制使用 fq。[y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] && aggressive="yes" || aggressive="no"
    relaxed="not-supported"
    if awk "BEGIN{exit !($local_bw > 10 * $vps_bw)}"; then
      yellow "提示：本地带宽显著高于服务器带宽，原算法提示可能导致性能问题。"
      mystery_log "warning=local-bandwidth-significantly-exceeds-server"
    fi
    if awk "BEGIN{exit !($rtt > 500 && $memory < 512)}"; then
      yellow "提示：高延迟且内存较小，原算法提示可能影响性能。"
      mystery_log "warning=high-latency-low-memory"
    fi
    if awk "BEGIN{exit !($rtt > 120 && $local_bw > 5 * $vps_bw)}"; then
      yellow "提示：高延迟场景下本地带宽过高，原算法提示可能导致缓冲区膨胀。"
      mystery_log "warning=high-latency-buffer-bloat-risk"
    fi
    if awk "BEGIN{exit !($rtt > 120 && $ramp < .3)}"; then
      yellow "提示：高延迟场景下，原算法建议使用较高曲率值以改善吞吐量。"
      mystery_log "warning=high-latency-low-curvature"
    fi
    if [ "$aggressive" = "yes" ] && awk "BEGIN{exit !($memory < 512)}"; then
      yellow "提示：内存不足 512 MB 时启用激进模式，原算法提示可能影响系统稳定性。"
      mystery_log "warning=aggressive-low-memory"
    fi
  else
    aggressive="not-supported"
    read -rp "是否启用 Legacy 延迟宽松模式？原逻辑会将 RTT 增加 20%。[y/N]: " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      relaxed="yes"
      rtt="$(awk -v n="$rtt" 'BEGIN { print int(n*1.2 == int(n*1.2) ? n*1.2 : int(n*1.2)+1) }')"
      yellow "Legacy 计算使用的 RTT 已调整为 $rtt ms。"
    else
      relaxed="no"
    fi
    yellow "Legacy 原逻辑不使用内存、曲率或激进模式输入；这些值仅记录在日志中。"
  fi
  mystery_log "cc=$MYSTERY_CC qdisc=$MYSTERY_QDISC local_mbps=$local_bw server_mbps=$vps_bw rtt_ms=$rtt memory_mb=$memory curvature=$ramp aggressive=$aggressive relaxed=$relaxed"
  mystery_generate_tcp_config "$MYSTERY_ALGORITHM" "$local_bw" "$vps_bw" "$rtt" "$memory" "$ramp" "$MYSTERY_CC" "$MYSTERY_QDISC" "$aggressive" || {
    mystery_log "result=generation-failed"
    red "生成迷之调参配置失败。"
    pause
    return
  }
  mystery_collapse_overrides || { mystery_log "result=override-collapse-failed"; red "整理原算法覆盖参数失败。"; pause; return; }
  {
    printf '\n[generated-original]\n'
    cat "$MYSTERY_CANDIDATE"
  } >> "$MYSTERY_LOG"
  echo
  green "原算法完整生成结果"
  cat "$MYSTERY_CANDIDATE"
  mystery_filter_supported_candidate || { mystery_log "result=filter-failed"; red "过滤当前内核不支持参数时失败。"; pause; return; }
  {
    printf '\n[applicable-after-kernel-check]\n'
    cat "$MYSTERY_CANDIDATE"
  } >> "$MYSTERY_LOG"
  echo
  green "当前内核待应用配置预览"
  cat "$MYSTERY_CANDIDATE"
  echo
  yellow "该预览为原算法完整配置，会影响内核/内存/ARP/转发等系统策略；如应用失败，将自动尝试恢复应用前基线。"
  read -rp "确认应用以上配置并持久化？[y/N]: " yn
  [[ "$yn" =~ ^[Yy]$ ]] || { mystery_log "result=previewed-not-applied"; yellow "未应用配置；本次计算记录已写入 $MYSTERY_LOG。"; pause; return; }
  if mystery_save_baseline_once && mystery_apply_candidate; then
    mystery_log "result=applied persisted=$MYSTERY_CONF"
    green "本次运行日志已写入 $MYSTERY_LOG"
    yellow "公式生成配置尚未证明是本链路最优值；建议随后使用 iperf3 验证吞吐、重传和抖动。"
  else
    mystery_log "result=apply-failed"
    red "迷之调参配置应用失败；检查日志 $MYSTERY_LOG。"
  fi
  pause
}

mystery_tune_menu(){
  local choice
  while true; do
    clear_screen
    green "调试区 - TCP 迷之调参"
    echo "--------------------------------"
    echo "1. 开始一次迷之调参配置生成 / 应用"
    echo "2. 查看最近一次迷之调参运行日志"
    echo "0. 返回主菜单"
    echo
    read -rp "请选择 [0-2]: " choice
    case "$choice" in
      1) mystery_tune_flow ;;
      2) view_mystery_log ;;
      0) return ;;
      *) red "无效输入"; sleep 1 ;;
    esac
  done
}

tune_flow(){
  local host direction duration client_bw vps_bw rtt bottleneck bdp candidate
  local mib_value choice applied last_good="" next_step margin final_candidate command
  clear_screen
  green "文章方案一：BDP 起点 + iperf3 交互调优"
  echo "说明：脚本运行在 VPS；带宽与 RTT 必须对应客户端和该 VPS 的目标链路。"
  echo "公网 speedtest 的结果不会作为 BDP 输入。"
  echo
  if [ -f "$MYSTERY_CONF" ]; then
    red "检测到已启用的迷之调参持久化配置：$MYSTERY_CONF"
    yellow "请先执行初始化恢复移除迷之调参配置，再使用交互实测调优流程。"
    pause
    return
  fi
  require_root || { pause; return; }
  has sysctl && has awk && has iperf3 || {
    red "缺少必要命令，请先运行“环境检查 / 安装依赖”。"
    pause
    return
  }
  save_baseline_once || { red "保存基线失败，取消调优。"; pause; return; }
  prepare_bbr_fq || { pause; return; }

  echo
  read -rp "输入 VPS 公网 IP 或域名（用于生成客户端命令）: " host
  if [ -z "$host" ]; then
    red "VPS 地址不能为空。"
    pause
    return
  fi
  echo "选择本次优化方向："
  echo "1. VPS -> 客户端（下载，文章主要场景）"
  echo "2. 客户端 -> VPS（上传）"
  while true; do
    read -rp "请选择 [1-2]: " choice
    case "$choice" in
      1) direction="download"; break ;;
      2) direction="upload"; break ;;
      *) red "请选择 1 或 2。" ;;
    esac
  done
  read_positive_integer "输入每轮 iperf3 测试时长（秒）" "30"
  duration="$REPLY"
  command="$(show_client_command "$host" "$direction" "$duration")"

  echo
  green "在客户端准备好 iperf3 后，将使用以下命令测试："
  printf '%s\n' "$command"
  echo "VPS 端需保持运行：iperf3 -s"
  echo
  read_positive "输入客户端在本方向的有效带宽 Mbps" ""
  client_bw="$REPLY"
  read_positive "输入 VPS 在本方向的端口/有效带宽 Mbps" ""
  vps_bw="$REPLY"
  echo "请从客户端 ping 本 VPS；ping 输出已经是往返时延，无需乘 2。"
  read_positive "输入客户端到 VPS 的平均 RTT ms" ""
  rtt="$REPLY"

  bottleneck="$(awk "BEGIN{print ($client_bw < $vps_bw) ? $client_bw : $vps_bw}")"
  bdp="$(awk "BEGIN{printf \"%.0f\", $bottleneck * 1000000 * ($rtt / 1000) / 8}")"
  [ "$bdp" -lt "$MIN_WINDOW" ] && bdp="$MIN_WINDOW"
  mib_value="$(awk "BEGIN{printf \"%.2f\", $bdp / $MIB}")"
  echo
  green "BDP 理论起点"
  printf '客户端有效带宽: %s Mbps\nVPS 有效带宽: %s Mbps\n采用瓶颈带宽: %s Mbps\nRTT: %s ms\n' \
    "$client_bw" "$vps_bw" "$bottleneck" "$rtt"
  printf 'BDP = %s Byte (约 %s MiB)\n' "$bdp" "$mib_value"
  yellow "BDP 仅为测试起点，最终参数必须经过 iperf3 验证。"
  echo
  echo "1. 使用 BDP 理论值作为初始候选"
  echo "2. 手动输入初始最大缓冲区字节数"
  echo "0. 取消"
  read -rp "请选择 [0-2]: " choice
  case "$choice" in
    1) candidate="$bdp" ;;
    2)
      read_positive_integer "输入初始最大缓冲区 Byte" ""
      candidate="$REPLY"
      [ "$candidate" -lt "$MIN_WINDOW" ] && candidate="$MIN_WINDOW"
      ;;
    *) pause; return ;;
  esac

  mkdir -p "$STATE_DIR" || { red "无法创建状态目录。"; pause; return; }
  printf 'window_bytes\tthroughput_mbps\tretr\tshake_or_disconnect\n' > "$SESSION_LOG"
  while true; do
    mib_value="$(awk "BEGIN{printf \"%.2f\", $candidate / $MIB}")"
    echo
    yellow "候选最大缓冲区：$candidate Byte（约 $mib_value MiB）"
    read -rp "是否临时应用该候选值并测试？[Y/n/q]: " applied
    [[ "$applied" =~ ^[Qq]$ ]] && break
    [[ "$applied" =~ ^[Nn]$ ]] && continue
    if ! apply_window "$candidate"; then
      red "临时设置失败，取消本轮。"
      break
    fi
    collect_test_result "$candidate" "$command"
    if [ "$RESULT_SHAKE" = "no" ] && [ "$RESULT_RETR" -lt 100 ]; then
      last_good="$candidate"
      green "本轮属于低重传且无明显抖动，可作为已验证候选。"
      echo "1. 上调窗口继续探索"
      echo "2. 基于本轮结果进入稳定余量验证"
      echo "0. 结束而不保存"
      read -rp "请选择 [0-2]: " choice
      case "$choice" in
        1)
          if [ "$RESULT_RETR" -le 9 ]; then
            read_positive "上调多少 MiB" "2"
          else
            read_positive "上调多少 MiB" "0.5"
          fi
          next_step="$(awk "BEGIN{printf \"%.0f\", $REPLY * $MIB}")"
          candidate=$((last_good + next_step))
          ;;
        2)
          read_nonnegative "为晚高峰稳定性回退多少 MiB（文章建议 0.5 或 1）" "1"
          margin="$(awk "BEGIN{printf \"%.0f\", $REPLY * $MIB}")"
          final_candidate=$((last_good - margin))
          [ "$final_candidate" -lt "$MIN_WINDOW" ] && final_candidate="$MIN_WINDOW"
          candidate="$final_candidate"
          yellow "稳定余量值也必须完成一轮测试后才可写入配置。"
          if apply_window "$candidate"; then
            collect_test_result "$candidate" "$command"
            if [ "$RESULT_SHAKE" = "no" ] && [ "$RESULT_RETR" -lt 100 ]; then
              green "最终候选已通过测试：$candidate Byte"
              read -rp "是否写入 $CONF 并应用？[y/N]: " applied
              if [[ "$applied" =~ ^[Yy]$ ]]; then
                persist_final "$candidate" && green "已保存并应用最终配置。" ||
                  red "写入或应用配置失败。"
              fi
              break
            fi
            yellow "稳定余量值未通过验证，请继续降低候选值后测试。"
          fi
          ;;
        *) break ;;
      esac
    else
      yellow "本轮重传较高或存在抖动/断流，应降低缓冲区后重测。"
      read_positive "下调多少 MiB" "1"
      next_step="$(awk "BEGIN{printf \"%.0f\", $REPLY * $MIB}")"
      candidate=$((candidate - next_step))
      [ "$candidate" -lt "$MIN_WINDOW" ] && candidate="$MIN_WINDOW"
    fi
  done
  echo
  printf '测试记录保存在：%s\n' "$SESSION_LOG"
  [ -n "$last_good" ] && printf '最后一次通过测试的候选值：%s Byte\n' "$last_good"
  pause
}

valid_target_host(){
  [[ "$1" =~ ^[a-zA-Z0-9._:-]+$ ]]
}

ssh_args_for_node(){
  local index="$1"
  SSH_ARGS=(-o "ConnectTimeout=$SSH_CONNECT_TIMEOUT" -p "${NODE_PORT[$index]}")
  if [ "${NODE_ACCEPT_NEW[$index]:-no}" = "yes" ]; then
    SSH_ARGS+=(-o "StrictHostKeyChecking=accept-new")
  fi
  if [ "${NODE_AUTH[$index]}" = "password" ]; then
    SSH_ARGS+=(-o "BatchMode=no" -o "PreferredAuthentications=password" -o "PubkeyAuthentication=no" -o "NumberOfPasswordPrompts=1")
  else
    SSH_ARGS+=(-o "BatchMode=yes")
  fi
  if [ "${NODE_AUTH[$index]}" = "key" ] && [ -n "${NODE_KEY[$index]}" ]; then
    SSH_ARGS+=(-i "${NODE_KEY[$index]}")
  fi
  SSH_ARGS+=("${NODE_USER[$index]}@${NODE_HOST[$index]}")
}

ssh_node(){
  local index="$1"
  shift
  ssh_args_for_node "$index"
  if [ "${NODE_AUTH[$index]}" = "password" ]; then
    SSHPASS="${NODE_PASSWORD[$index]}" sshpass -e ssh "${SSH_ARGS[@]}" "$@"
  else
    ssh "${SSH_ARGS[@]}" "$@"
  fi
}

ssh_node_verbose(){
  local index="$1"
  shift
  ssh_args_for_node "$index"
  if [ "${NODE_AUTH[$index]}" = "password" ]; then
    SSHPASS="${NODE_PASSWORD[$index]}" sshpass -e ssh -v "${SSH_ARGS[@]}" "$@"
  else
    ssh -v "${SSH_ARGS[@]}" "$@"
  fi
}

remote_add_nodes(){
  local label host port user auth key password bw_source more index
  NODE_COUNT=0
  NODE_LABEL=()
  NODE_HOST=()
  NODE_PORT=()
  NODE_USER=()
  NODE_AUTH=()
  NODE_KEY=()
  NODE_PASSWORD=()
  NODE_BW=()
  NODE_BW_SOURCE=()
  NODE_ACCEPT_NEW=()
  while true; do
    echo
    green "添加测试节点 $((NODE_COUNT + 1))"
    read -rp "节点标签（例如联通家宽/上海测试机）: " label
    label="${label:-node-$((NODE_COUNT + 1))}"
    while true; do
      read -rp "SSH 主机 IP/域名: " host
      valid_target_host "$host" && break
      red "主机只允许域名、IP 地址使用的字符。"
    done
    read_positive_integer "SSH 端口" "22"
    port="$REPLY"
    while true; do
      read -rp "SSH 用户名: " user
      [[ "$user" =~ ^[a-zA-Z0-9._-]+$ ]] && break
      red "用户名格式不合法。"
    done
    echo "选择 SSH 认证方式："
    echo "1. 私钥 / ssh-agent / 默认密钥（推荐）"
    echo "2. 密码登录（密码仅保留于本次进程内）"
    while true; do
      read -rp "请选择 [1-2]: " auth
      case "$auth" in
        1)
          auth="key"
          read -rp "私钥文件路径（留空则使用 ssh-agent/默认密钥）: " key
          if [ -n "$key" ] && [ ! -r "$key" ]; then
            red "私钥文件不可读：$key"
            continue
          fi
          password=""
          break
          ;;
        2)
          auth="password"
          if ! has sshpass; then
            yellow "密码自动登录需要本机安装 sshpass，当前未检测到。"
            read -rp "是否现在安装 sshpass？[Y/n]: " more
            if [[ "$more" =~ ^[Nn]$ ]] || ! install_sshpass || ! has sshpass; then
              red "无法使用密码认证，请选择私钥认证或安装 sshpass 后重试。"
              continue
            fi
            green "sshpass 已安装，可以继续使用密码认证。"
          fi
          yellow "风险提示：密码不会写入文件或日志，但同机特权用户仍可能观察到临时进程环境。"
          while true; do
            read -rsp "SSH 密码（输入不显示）: " password
            echo
            [ -n "$password" ] && break
            red "密码不能为空。"
          done
          key=""
          break
          ;;
        *) red "请选择 1 或 2。" ;;
      esac
    done
    echo "选择该节点有效带宽的获取方式："
    echo "1. 在节点上运行公网测速，作为参考值"
    echo "2. 由节点直接对本 VPS 运行 iperf3 下载基线测速（推荐）"
    echo "3. 手动填写"
    while true; do
      read -rp "请选择 [1-3]: " bw_source
      case "$bw_source" in
        1)
          bw_source="speedtest"
          bw=""
          break
          ;;
        2)
          bw_source="iperf"
          bw=""
          break
          ;;
        3)
          bw_source="manual"
          read_positive "该节点接收方向的有效带宽上限 Mbps" ""
          bw="$REPLY"
          break
          ;;
        *) red "请选择 1、2 或 3。" ;;
      esac
    done
    index="$NODE_COUNT"
    NODE_LABEL[$index]="$label"
    NODE_HOST[$index]="$host"
    NODE_PORT[$index]="$port"
    NODE_USER[$index]="$user"
    NODE_AUTH[$index]="$auth"
    NODE_KEY[$index]="$key"
    NODE_PASSWORD[$index]="$password"
    NODE_BW[$index]="$bw"
    NODE_BW_SOURCE[$index]="$bw_source"
    NODE_ACCEPT_NEW[$index]="no"
    NODE_COUNT=$((NODE_COUNT + 1))
    read -rp "继续添加测试节点？[y/N]: " more
    [[ "$more" =~ ^[Yy]$ ]] || break
  done
}

clear_remote_credentials(){
  local index
  for ((index=0; index<${NODE_COUNT:-0}; index++)); do
    NODE_PASSWORD[$index]=""
  done
  unset NODE_PASSWORD
}

remote_verify_nodes(){
  local index missing output status_lines trust
  for ((index=0; index<NODE_COUNT; index++)); do
    echo
    green "检查远程节点：${NODE_LABEL[$index]}"
    if ! output="$(ssh_node_verbose "$index" "if command -v iperf3 >/dev/null 2>&1; then echo '[已安装] iperf3'; else echo '[缺少] iperf3'; fi; if command -v ping >/dev/null 2>&1; then echo '[已安装] ping'; else echo '[缺少] ping'; fi" 2>&1)"; then
      red "SSH 连接失败：${NODE_LABEL[$index]}"
      yellow "SSH 诊断输出："
      printf '%s\n' "$output"
      if [[ "$output" == *"Server host key:"* ]] && [[ "$output" == *"known_hosts"* ]]; then
        echo
        yellow "该节点可能是首次连接，控制端尚未保存其 SSH 主机指纹。"
        read -rp "请核对上方 Server host key 指纹；确认可信并写入 known_hosts 后重试？[y/N]: " trust
        if [[ "$trust" =~ ^[Yy]$ ]]; then
          NODE_ACCEPT_NEW[$index]="yes"
          if ! output="$(ssh_node "$index" "if command -v iperf3 >/dev/null 2>&1; then echo '[已安装] iperf3'; else echo '[缺少] iperf3'; fi; if command -v ping >/dev/null 2>&1; then echo '[已安装] ping'; else echo '[缺少] ping'; fi" 2>&1)"; then
            red "写入新指纹后仍无法登录：${NODE_LABEL[$index]}"
            printf '%s\n' "$output"
            return 1
          fi
          green "主机指纹已接受，SSH 登录成功。"
        else
          return 1
        fi
      else
        return 1
      fi
    fi
    status_lines="$(printf '%s\n' "$output" | grep -E '^\[(已安装|缺少)\]' || true)"
    printf '%s\n' "$status_lines"
    if [[ "$status_lines" == *"[缺少]"* ]]; then
      missing=1
      red "节点缺少测试依赖：${NODE_LABEL[$index]}"
      echo "当前版本不自动修改远程节点，请在该节点安装后重新开始。"
    else
      green "SSH 与测试依赖正常。"
    fi
  done
  [ "${missing:-0}" -eq 0 ] || return 1
}

remote_iperf_bandwidth_reference(){
  local index="$1" target="$2" duration="$3"
  local json bps throughput retr server_log server_pid ssh_error ssh_status
  server_log="$(mktemp)"
  ssh_error="$(mktemp)"
  green "启动本机一次性 iperf3 服务，并由 ${NODE_LABEL[$index]} 执行下载基线测速..."
  iperf3 -s -1 >"$server_log" 2>&1 &
  server_pid=$!
  sleep 1
  json="$(ssh_node "$index" "iperf3 -c '$target' -R -J --get-server-output -t '$duration'" 2>"$ssh_error")"
  ssh_status=$?
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  if [ "$ssh_status" -ne 0 ] || ! printf '%s\n' "$json" | jq -e . >/dev/null 2>&1; then
    red "节点 ${NODE_LABEL[$index]} 的 iperf3 基线测速失败。"
    [ -s "$ssh_error" ] && { yellow "SSH/远程错误输出："; cat "$ssh_error"; }
    [ -s "$server_log" ] && { yellow "本机 iperf3 服务端输出："; cat "$server_log"; }
    [ -n "$json" ] && { yellow "远程返回内容："; printf '%s\n' "$json"; }
    rm -f "$server_log" "$ssh_error"
    return 1
  fi
  rm -f "$server_log" "$ssh_error"
  bps="$(printf '%s\n' "$json" | jq -r '.end.sum_received.bits_per_second // .end.sum.bits_per_second // empty' 2>/dev/null)"
  throughput="$(awk "BEGIN{if (\"$bps\" == \"\") exit 1; printf \"%.2f\", $bps / 1000000}")" || return 1
  retr="$(printf '%s\n' "$json" | jq -r '.server_output_json.end.sum_sent.retransmits // .end.sum_sent.retransmits // \"未知\"' 2>/dev/null)"
  printf '目标链路 iperf3 基线：平均吞吐 %s Mbps，Retr=%s\n' "$throughput" "$retr"
  IPERF_REFERENCE_BW="$throughput"
}

remote_choose_bandwidth(){
  local target="$1" duration="$2" index output down up choice
  for ((index=0; index<NODE_COUNT; index++)); do
    [ "${NODE_BW_SOURCE[$index]}" = "manual" ] && continue
    echo
    if [ "${NODE_BW_SOURCE[$index]}" = "iperf" ]; then
      green "由远程节点 ${NODE_LABEL[$index]} 测量到本 VPS 的目标链路基线"
      if ! remote_iperf_bandwidth_reference "$index" "$target" "$duration"; then
        read_positive "请手动输入该节点接收方向有效带宽 Mbps" ""
        NODE_BW[$index]="$REPLY"
        continue
      fi
      yellow "iperf3 更贴近目标链路，但默认 TCP 参数可能使基线值偏低；最终仍需逐轮上调验证。"
      echo "1. 采用 iperf3 平均吞吐 ${IPERF_REFERENCE_BW} Mbps"
      echo "2. 手动填写有效带宽"
      read -rp "请选择 [1-2]: " choice
      case "$choice" in
        1) NODE_BW[$index]="$IPERF_REFERENCE_BW" ;;
        *)
          read_positive "请输入该节点接收方向有效带宽 Mbps" ""
          NODE_BW[$index]="$REPLY"
          ;;
      esac
    else
      green "在远程节点 ${NODE_LABEL[$index]} 上获取公网测速参考值"
      output="$(ssh_node "$index" '
        if command -v speedtest >/dev/null 2>&1; then
          echo __TOOL__:speedtest
          speedtest --accept-license --accept-gdpr --progress=no --format=json
        elif command -v librespeed-cli >/dev/null 2>&1; then
          echo __TOOL__:librespeed-cli
          librespeed-cli --json
        else
          echo __TOOL__:missing
        fi
      ' 2>&1)" || {
        red "远程公网测速执行失败：${NODE_LABEL[$index]}"
        printf '%s\n' "$output"
        read_positive "请手动输入该节点接收方向有效带宽 Mbps" ""
        NODE_BW[$index]="$REPLY"
        continue
      }
      case "$output" in
        *__TOOL__:speedtest*)
          down="$(printf '%s\n' "$output" | sed '1,/__TOOL__:speedtest/d' | jq -r '(.download.bandwidth * 8 / 1000000) | floor' 2>/dev/null)"
          up="$(printf '%s\n' "$output" | sed '1,/__TOOL__:speedtest/d' | jq -r '(.upload.bandwidth * 8 / 1000000) | floor' 2>/dev/null)"
          ;;
        *__TOOL__:librespeed-cli*)
          down="$(printf '%s\n' "$output" | sed '1,/__TOOL__:librespeed-cli/d' | jq -r 'if type=="array" then .[0].download else (.downloadMbit // .download) end // empty' 2>/dev/null)"
          up="$(printf '%s\n' "$output" | sed '1,/__TOOL__:librespeed-cli/d' | jq -r 'if type=="array" then .[0].upload else (.uploadMbit // .upload) end // empty' 2>/dev/null)"
          ;;
        *)
          yellow "远程节点未安装 speedtest 或 librespeed-cli，无法自动取得公网测速值。"
          read_positive "请手动输入该节点接收方向有效带宽 Mbps" ""
          NODE_BW[$index]="$REPLY"
          continue
          ;;
      esac
      if ! is_positive_number "$down"; then
        yellow "无法解析下载测速结果，将改为手动输入。"
        read_positive "请手动输入该节点接收方向有效带宽 Mbps" ""
        NODE_BW[$index]="$REPLY"
        continue
      fi
      printf '公网测速参考：下载 %s Mbps，上传 %s Mbps\n' "$down" "${up:-未知}"
      yellow "公网测速只用于 BDP 起始估计，最终仍以本 VPS 的 iperf3 迭代结果为准。"
      echo "1. 采用下载测速值 $down Mbps"
      echo "2. 手动填写有效带宽"
      read -rp "请选择 [1-2]: " choice
      case "$choice" in
        1) NODE_BW[$index]="$down" ;;
        *)
          read_positive "请输入该节点接收方向有效带宽 Mbps" ""
          NODE_BW[$index]="$REPLY"
          ;;
      esac
    fi
  done
}

remote_measure_rtt(){
  local target="$1" index output rtt worst=0
  for ((index=0; index<NODE_COUNT; index++)); do
    green "从 ${NODE_LABEL[$index]} 测量到本 VPS 的 RTT..."
    output="$(ssh_node "$index" "ping -c 5 '$target'" 2>&1)" || {
      red "无法从 ${NODE_LABEL[$index]} ping $target。"
      printf '%s\n' "$output"
      return 1
    }
    rtt="$(printf '%s\n' "$output" | awk -F'/' '/rtt|round-trip/ {printf "%.0f", $5}')"
    if ! [[ "$rtt" =~ ^[0-9]+$ ]] || [ "$rtt" -le 0 ]; then
      red "无法解析节点 ${NODE_LABEL[$index]} 的 RTT。"
      return 1
    fi
    NODE_RTT[$index]="$rtt"
    printf '%s RTT: %s ms\n' "${NODE_LABEL[$index]}" "$rtt"
    [ "$rtt" -gt "$worst" ] && worst="$rtt"
  done
  WORST_RTT="$worst"
}

run_one_remote_test(){
  local index="$1" target="$2" duration="$3" candidate="$4"
  local json throughput bps retr server_log server_pid ssh_status ssh_error
  server_log="$(mktemp)"
  ssh_error="$(mktemp)"
  green "启动本机一次性 iperf3 服务，并由 ${NODE_LABEL[$index]} 发起下载测试..."
  iperf3 -s -1 >"$server_log" 2>&1 &
  server_pid=$!
  sleep 1
  json="$(ssh_node "$index" "iperf3 -c '$target' -R -J --get-server-output -t '$duration'" 2>"$ssh_error")"
  ssh_status=$?
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  if [ "$ssh_status" -ne 0 ]; then
    red "节点 ${NODE_LABEL[$index]} 执行 iperf3 失败。"
    [ -s "$ssh_error" ] && { yellow "SSH/远程错误输出："; cat "$ssh_error"; }
    [ -s "$server_log" ] && { yellow "本机 iperf3 服务端输出："; cat "$server_log"; }
    rm -f "$server_log" "$ssh_error"
    return 1
  fi
  rm -f "$server_log" "$ssh_error"
  if ! printf '%s\n' "$json" | jq -e . >/dev/null 2>&1; then
    red "节点 ${NODE_LABEL[$index]} 的 iperf3 测试失败或未返回 JSON。"
    [ -n "$json" ] && { yellow "远程返回内容："; printf '%s\n' "$json"; }
    return 1
  fi
  bps="$(printf '%s\n' "$json" | jq -r '.end.sum_received.bits_per_second // .end.sum.bits_per_second // empty' 2>/dev/null)"
  throughput="$(awk "BEGIN{if (\"$bps\" == \"\") exit 1; printf \"%.2f\", $bps / 1000000}")"
  retr="$(printf '%s\n' "$json" | jq -r '.server_output_json.end.sum_sent.retransmits // .end.sum_sent.retransmits // empty' 2>/dev/null)"
  if [ -z "$throughput" ] || ! [[ "$retr" =~ ^[0-9]+$ ]]; then
    red "节点 ${NODE_LABEL[$index]} 的输出缺少吞吐或发送端 Retr，无法自动判定。"
    return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$candidate" "${NODE_LABEL[$index]}" "${NODE_RTT[$index]}" "$throughput" "$retr" >> "$REMOTE_SESSION_LOG"
  printf '%s: %s Mbps, Retr=%s\n' "${NODE_LABEL[$index]}" "$throughput" "$retr"
  TEST_THROUGHPUT="$throughput"
  TEST_RETR="$retr"
}

run_remote_round(){
  local target="$1" duration="$2" candidate="$3" index round_ok=1 worst_retr=0
  echo
  green "执行远程 iperf3 轮次：候选窗口 $candidate Byte"
  for ((index=0; index<NODE_COUNT; index++)); do
    if ! run_one_remote_test "$index" "$target" "$duration" "$candidate"; then
      round_ok=0
      continue
    fi
    [ "$TEST_RETR" -gt "$worst_retr" ] && worst_retr="$TEST_RETR"
    [ "$TEST_RETR" -ge 100 ] && round_ok=0
  done
  ROUND_RETR="$worst_retr"
  ROUND_OK="$round_ok"
}

remote_tune_flow(){
  local target duration vps_bw bottleneck bdp candidate mib_value primary
  local index choice step last_good="" margin final_candidate yn
  clear_screen
  green "远程节点自动调优：VPS -> 测试节点下载方向"
  echo "说明：被调 VPS 作为控制端和发送端，通过 SSH 登录远程测试节点。"
  echo "默认推荐密钥认证；密码模式需 sshpass，密码仅在本次运行期间驻留内存。"
  echo
  if [ -f "$MYSTERY_CONF" ]; then
    red "检测到已启用的迷之调参持久化配置：$MYSTERY_CONF"
    yellow "请先执行初始化恢复移除迷之调参配置，再使用远程实测调优流程。"
    pause
    return
  fi
  require_root || { pause; return; }
  check_remote_local_env || { red "远程模式本机依赖未满足。"; pause; return; }
  while true; do
    read -rp "输入本 VPS 供测试节点访问的公网 IP/域名: " target
    valid_target_host "$target" && break
    red "地址格式不合法。"
  done
  read_positive_integer "输入每轮 iperf3 测试时长（秒）" "30"
  duration="$REPLY"
  read_positive "输入本 VPS 发送方向有效带宽/端口上限 Mbps" ""
  vps_bw="$REPLY"
  remote_add_nodes
  remote_verify_nodes || { yellow "远程节点准备未通过，未进行参数测试。"; clear_remote_credentials; pause; return; }
  remote_choose_bandwidth "$target" "$duration"
  NODE_RTT=()
  remote_measure_rtt "$target" || { clear_remote_credentials; pause; return; }
  echo
  green "已添加测试节点"
  for ((index=0; index<NODE_COUNT; index++)); do
    printf '%s. %s - 有效带宽 %s Mbps, RTT %s ms\n' \
      "$((index + 1))" "${NODE_LABEL[$index]}" "${NODE_BW[$index]}" "${NODE_RTT[$index]}"
  done
  while true; do
    read_positive_integer "选择作为 BDP 初始计算基准的节点序号" "1"
    primary=$((REPLY - 1))
    [ "$primary" -ge 0 ] && [ "$primary" -lt "$NODE_COUNT" ] && break
    red "节点序号超出范围。"
  done
  bottleneck="$(awk "BEGIN{print (${NODE_BW[$primary]} < $vps_bw) ? ${NODE_BW[$primary]} : $vps_bw}")"
  bdp="$(awk "BEGIN{printf \"%.0f\", $bottleneck * 1000000 * (${NODE_RTT[$primary]} / 1000) / 8}")"
  [ "$bdp" -lt "$MIN_WINDOW" ] && bdp="$MIN_WINDOW"
  mib_value="$(awk "BEGIN{printf \"%.2f\", $bdp / $MIB}")"
  echo
  green "BDP 起点"
  printf '基准节点: %s\n基准节点有效带宽: %s Mbps\nVPS 发送上限: %s Mbps\n采用瓶颈带宽: %s Mbps\n基准节点 RTT: %s ms\n' \
    "${NODE_LABEL[$primary]}" "${NODE_BW[$primary]}" "$vps_bw" "$bottleneck" "${NODE_RTT[$primary]}"
  printf 'BDP = %s Byte（约 %s MiB）\n' "$bdp" "$mib_value"
  yellow "多节点模式以全部节点均低重传为通过标准；自动化无法识别主观画面卡顿。"
  echo "1. 使用 BDP 理论值作为初始候选"
  echo "2. 手动输入初始最大缓冲区字节数"
  echo "0. 取消"
  read -rp "请选择 [0-2]: " choice
  case "$choice" in
    1) candidate="$bdp" ;;
    2)
      read_positive_integer "输入初始最大缓冲区 Byte" ""
      candidate="$REPLY"
      [ "$candidate" -lt "$MIN_WINDOW" ] && candidate="$MIN_WINDOW"
      ;;
    *) clear_remote_credentials; pause; return ;;
  esac
  save_baseline_once || { red "保存基线失败，取消调优。"; clear_remote_credentials; pause; return; }
  prepare_bbr_fq || { clear_remote_credentials; pause; return; }
  mkdir -p "$STATE_DIR" || { red "无法创建状态目录。"; clear_remote_credentials; pause; return; }
  printf 'window_bytes\tnode\trtt_ms\tthroughput_mbps\tretr\n' > "$REMOTE_SESSION_LOG"
  while true; do
    mib_value="$(awk "BEGIN{printf \"%.2f\", $candidate / $MIB}")"
    yellow "候选最大缓冲区：$candidate Byte（约 $mib_value MiB）"
    read -rp "是否临时应用并自动测试全部远程节点？[Y/n/q]: " yn
    [[ "$yn" =~ ^[Qq]$ ]] && break
    [[ "$yn" =~ ^[Nn]$ ]] && continue
    apply_window "$candidate" || { red "临时设置失败。"; break; }
    run_remote_round "$target" "$duration" "$candidate"
    if [ "$ROUND_OK" -eq 1 ]; then
      last_good="$candidate"
      green "全部节点 Retr < 100，本候选已通过自动判定。"
      echo "1. 上调窗口继续探索"
      echo "2. 回退余量并执行最终验证"
      echo "0. 结束而不保存"
      read -rp "请选择 [0-2]: " choice
      case "$choice" in
        1)
          if [ "$ROUND_RETR" -le 9 ]; then
            read_positive "上调多少 MiB" "2"
          else
            read_positive "上调多少 MiB" "0.5"
          fi
          step="$(awk "BEGIN{printf \"%.0f\", $REPLY * $MIB}")"
          candidate=$((last_good + step))
          ;;
        2)
          read_nonnegative "稳定性回退多少 MiB（文章建议 0.5 或 1）" "1"
          margin="$(awk "BEGIN{printf \"%.0f\", $REPLY * $MIB}")"
          final_candidate=$((last_good - margin))
          [ "$final_candidate" -lt "$MIN_WINDOW" ] && final_candidate="$MIN_WINDOW"
          apply_window "$final_candidate" || { red "临时设置失败。"; break; }
          run_remote_round "$target" "$duration" "$final_candidate"
          if [ "$ROUND_OK" -eq 1 ]; then
            green "最终余量值已通过全部节点验证：$final_candidate Byte"
            read -rp "是否写入 $CONF 并应用？[y/N]: " yn
            [[ "$yn" =~ ^[Yy]$ ]] && {
              persist_final "$final_candidate" && green "已保存并应用最终配置。" ||
                red "写入或应用配置失败。"
            }
            break
          fi
          yellow "最终余量验证未通过，请继续降低候选值测试。"
          candidate="$final_candidate"
          ;;
        *) break ;;
      esac
    else
      yellow "至少一个节点 Retr >= 100 或测试失败，应下调候选值重测。"
      read_positive "下调多少 MiB" "1"
      step="$(awk "BEGIN{printf \"%.0f\", $REPLY * $MIB}")"
      candidate=$((candidate - step))
      [ "$candidate" -lt "$MIN_WINDOW" ] && candidate="$MIN_WINDOW"
    fi
  done
  echo
  printf '远程测试记录保存在：%s\n' "$REMOTE_SESSION_LOG"
  [ -n "$last_good" ] && printf '最后一次通过全部节点的候选值：%s Byte\n' "$last_good"
  clear_remote_credentials
  pause
}

start_iperf_server(){
  clear_screen
  if ! has iperf3; then
    red "未安装 iperf3，请先执行环境检查。"
    pause
    return
  fi
  green "正在前台启动 iperf3 服务端（Ctrl+C 可停止并返回菜单）"
  echo
  iperf3 -s
  pause
}

menu(){
  while true; do
    clear_screen
    green "TCP 调优管理脚本 ${SCRIPT_VERSION} - ${SCRIPT_DATE}"
    echo "=================================================="
    green "[ 状态检查 / 基础工具 ]"
    echo "1. 检查并输出当前参数 / 完整状态"
    echo "2. 环境检查 / 安装基础依赖"
    echo "3. 安装 / 查看 / 启用 XanMod 内核状态"
    echo "4. 独立公网测速（Ookla / LibreSpeed）"
    echo "5. 启动 iperf3 服务端（手工模式使用）"
    echo
    green "[ 调试区 ]"
    echo "6. 手工客户端：BDP 与 iperf3 交互调优"
    echo "7. SSH 远程节点：下载方向自动测试调优"
    echo "8. TCP 迷之调参 / 查看最近运行日志"
    echo
    green "[ 恢复 / 退出 ]"
    echo "9. 仅恢复调优前基线配置"
    echo "10. 一键卸载附加组件并恢复初始化状态"
    echo "0. 退出"
    echo
    read -rp "请输入选择 [0-10]: " num
    case "$num" in
      1) show_status ;;
      2) check_env ;;
      3) install_xanmod_kernel ;;
      4) public_speedtest_menu ;;
      5) start_iperf_server ;;
      6) tune_flow ;;
      7) remote_tune_flow ;;
      8) mystery_tune_menu ;;
      9) restore_baseline ;;
      10) reset_to_initial_state ;;
      0) exit 0 ;;
      *) red "无效输入"; sleep 1 ;;
    esac
  done
}

menu
