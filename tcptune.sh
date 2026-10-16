#!/usr/bin/env bash

# Conservative, paired TCP experiments on the VPS being tuned. Automatic
# decisions are path/budget specific; keep the baseline without reliable gains.
# Legacy administrative menus remain separate from the automatic experiment.

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
SCRIPT_VERSION="v2.3.0"
SCRIPT_DATE="2026-10-16"

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

restore_baseline(){
  local previous rc=0
  clear_screen
  require_root || { pause; return 1; }
  previous="$(cat "$STATE_DIR/active-session" 2>/dev/null)" || previous=""
  case "$previous" in
    "$SESSIONS_BASE"/*)
      if [ -f "$previous/restore.sh" ]; then
        # The frozen script takes the same lock and rejects obsolete sessions.
        bash "$previous/restore.sh" || rc=$?
      else red "最近会话缺少恢复脚本：$previous"; rc=1; fi ;;
    *) red '没有可恢复的自动调优会话。'; rc=1 ;;
  esac
  pause
  return "$rc"
}

reset_to_initial_state() (
  local yn reset_ok=1
  LOCK_HELD=0
  trap 'lock_release' EXIT
  clear_screen
  green "一键卸载附加组件并恢复初始化状态"
  echo "将执行以下操作："
  echo "- 恢复最近自动调优会话，以及已保存的旧版参数基线（若存在）"
  echo "- 删除本脚本写入的交互调优 / 迷之调参持久化配置和测试记录"
  echo "- 卸载 sshpass（不卸载 iperf3、speedtest、LibreSpeed 等基础/测速工具）"
  echo "- 卸载未在运行中的 XanMod 内核包，并移除 XanMod 软件源"
  echo
  yellow "如果当前正在运行 XanMod，本次会保留其内核包，待以原生内核启动后再清理。"
  read -rp "确认执行初始化清理？[y/N]: " yn
  [[ "$yn" =~ ^[Yy]$ ]] || { yellow "已取消。"; pause; return; }
  require_root || { pause; return; }
  has flock || { red '缺少 flock，无法安全执行恢复和清理。'; pause; return 1; }
  lock_acquire || { pause; return 1; }
  echo

  if [ -s "$STATE_DIR/active-session" ]; then
    local previous
    previous="$(cat "$STATE_DIR/active-session")" || return 1
    case "$previous" in
      "$SESSIONS_BASE"/*)
        [ -f "$previous/restore.sh" ] || { red '缺少最近会话恢复脚本，已停止清理。'; pause; return 1; }
        # We already own FD 9 and checked the current session while acquiring it.
        bash "$previous/restore.sh" --watchdog || { red '最近会话恢复失败，已停止清理。'; pause; return 1; } ;;
      *) red '最近会话路径无效，已停止清理。'; pause; return 1 ;;
    esac
  fi

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
)

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


##############################################################################
# 会话快照系统（每次运行创建独立快照，不复用旧快照）
##############################################################################

# Automatic tuning policy. All numeric CLI/env values are validated before use.
SESSION_DIR=""
SESSIONS_BASE="$STATE_DIR/sessions"
LOCK_HELD=0
WATCHDOG_PID=""
AT_AUTO=0
AT_TARGET="${AT_TARGET:-}"
AT_DIRECTION="${AT_DIRECTION:-download}" # compatibility: download=VPS sends
AT_MAX_CANDIDATES="${AT_MAX_CANDIDATES:-4}"
AT_DURATION="${AT_DURATION:-10}"
AT_BUDGET_GIB="${AT_BUDGET_GIB:-32}"
AT_MAX_SECONDS="${AT_MAX_SECONDS:-1800}"
AT_RATE_MBPS="${AT_RATE_MBPS:-1000}" # explicit per-test TCP rate ceiling
AT_SAMPLE_MIB="${AT_SAMPLE_MIB:-0}" # required byte quota when rate=0
AT_RETEST_ROUNDS="${AT_RETEST_ROUNDS:-5}"
AT_ACCEPT_ROUNDS="${AT_ACCEPT_ROUNDS:-3}"
AT_MAX_SHORTLIST="${AT_MAX_SHORTLIST:-3}"
AT_MIN_TP_GAIN="${AT_MIN_TP_GAIN:-5}"
AT_MIN_RTT_GAIN="${AT_MIN_RTT_GAIN:-20}"
AT_MAX_RTT_FACTOR="${AT_MAX_RTT_FACTOR:-115}"
AT_RTT_TOLERANCE_MS="${AT_RTT_TOLERANCE_MS:-5}"
AT_MAX_RETR_FACTOR="${AT_MAX_RETR_FACTOR:-300}"
AT_RETR_FLOOR="${AT_RETR_FLOOR:-100}" # retransmits/GiB; small baseline tolerance
AT_EXPECTED_CONNECTIONS="${AT_EXPECTED_CONNECTIONS:-64}"
AT_BUFFER_MAX_MIB="${AT_BUFFER_MAX_MIB:-16}"
AT_NO_PERSIST=0
AT_PROBE_COMMAND="${AT_PROBE_COMMAND:-}"
AT_PROXY_SERVICE="${AT_PROXY_SERVICE:-}"
AT_PRIMARY_NODE=0
AT_EXIT_COMMITTED=0
AT_EXIT_FAILED=1
AT_EXIT_NO_CHANGE=2
AT_EXIT_VALIDATED=3
BUDGET_USED_BYTES=0
MEASURE_SEQ=0
ACTUAL_IFACE=""
ACTUAL_QDISC=""
BASELINE_THROUGHPUT=0
BASELINE_RETR=null
BASELINE_RTT=null
BASELINE_BYTES=0
BUFFER_LIMITED=0
IPERF_THROUGHPUT=0
IPERF_RETR=null
IPERF_RTT=null
IPERF_BYTES=0
IPERF_SNDBUF_LIMITED=0
IPERF_SNDBUF_EVIDENCE=0
IPERF_RWND_LIMITED=0
IPERF_PROXY='{"status":"not_configured"}'
CANDIDATE_SCORE=-1
SCORE_REJECT_REASON=""
IMPROVEMENT_REASON=""
MEASURE_REASON=""
RUN_RESULT=failed
RUN_REASON=not_started
RUN_SELECTED=false
RUN_COMMITTED=0
RUN_RESTORE_VERIFIED=false
RUN_PERSIST_TOUCHED=0
RUN_START=0
RUN_FINISHED=0
RETEST_STATS='{}'
RETEST_RESULTS='[]'
ACCEPTANCE_STATS=null
ACCEPTANCE_ATTEMPTED=false
ACCEPTANCE_COMPLETED=false
ACCEPTANCE_PASSED=false
RETEST_STAGE=retest
RETEST_GATE_FAILED=0
RETEST_VALID_PAIRS=0
RETEST_CAND_TP_MEDIAN=0
RETEST_BASE_TP_MEDIAN=0
RETEST_CAND_RTT_MEDIAN=null
RETEST_BASE_RTT_MEDIAN=null

normalize_value(){ local IFS=$' \t\n'; local -a parts=(); read -ra parts <<< "$1"; printf '%s\n' "${parts[*]}"; }
numeric(){ [[ "${1:-}" =~ ^(0|[1-9][0-9]*)([.][0-9]+)?$ ]]; }
known_positive(){ numeric "${1:-}" && awk -v n="$1" 'BEGIN{exit !(n>0)}'; }
session_log(){ [ -z "$SESSION_DIR" ] || printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$SESSION_DIR/session.log"; }

check_actual_qdisc(){
  # Resolve the tested path, including policy routing; never guess first default.
  local route queues
  local route_target="${AT_TARGET:-1.1.1.1}"
  if [[ ! "$route_target" =~ ^[0-9.:]+$ ]]; then
    route_target="$(getent ahosts "$route_target" 2>/dev/null | awk 'NR==1{print $1}')"
    [ -n "$route_target" ] || return 1
  fi
  route="$(ip route get "$route_target" 2>/dev/null)" || return 1
  ACTUAL_IFACE="$(awk '{for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}' <<< "$route")"
  [ -n "$ACTUAL_IFACE" ] || return 1
  queues="$(tc -j qdisc show dev "$ACTUAL_IFACE" 2>/dev/null)" || return 1
  ACTUAL_QDISC="$(jq -ser '
    select(length==1) | .[0] |
    select(type=="array" and length>0 and all(.[];type=="object")) |
    [.[]|select(.root==true)|.kind] |
    select(length==1 and (.[0]|type)=="string" and (.[0]|length)>0) | .[0]
  ' <<< "$queues")" || return 1
}

_runtime_json(){
  local key value
  {
    for key in net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_wmem net.ipv4.tcp_rmem net.core.wmem_max net.core.rmem_max; do
      value="$(normalize_value "$(sysctl_value "$key")")"
      printf '%s\t%s\n' "$key" "$value"
    done
  } | jq -Rnc '[inputs|split("\t")|{key:.[0],value:.[1]}]|from_entries'
}

lock_acquire(){
  mkdir -p "$STATE_DIR" || return 1
  exec 9>"$STATE_DIR/tuning.lock" || return 1
  if ! flock -n 9; then red '已有调优/恢复进程持有锁。'; exec 9>&-; return 1; fi
  LOCK_HELD=1
  # A failed restore must be repaired before taking a new baseline.
  if [ -s "$STATE_DIR/active-session" ]; then
    local previous
    previous="$(cat "$STATE_DIR/active-session")"
    if [ ! -f "$previous/complete" ]; then
      red "上次会话未确认恢复：bash $previous/restore.sh"
      lock_release; return 1
    fi
  fi
}
lock_release(){
  [ "$LOCK_HELD" -eq 1 ] || return 0
  exec 9>&-
  LOCK_HELD=0
}

_restore_orig_persistent(){
  local status tmp
  status="$(cat "$SESSION_DIR/orig_persistent.status" 2>/dev/null)" || return 1
  case "$status" in
    exists)
      tmp="$(mktemp "${CONF}.restore.XXXXXX")" || return 1
      cp -p "$SESSION_DIR/orig_persistent.conf" "$tmp" && mv -f "$tmp" "$CONF" || { rm -f "$tmp"; return 1; }
      cmp -s "$SESSION_DIR/orig_persistent.conf" "$CONF" || return 1 ;;
    absent) rm -f "$CONF" || return 1; [ ! -e "$CONF" ] || return 1 ;;
    *) return 1 ;;
  esac
}

session_restore_runtime(){
  local line key val actual ok=0 cc_changed=0 snap="$SESSION_DIR/snapshot.conf"
  [ -s "$snap" ] || return 1
  while IFS= read -r line; do
    [[ "$line" == \#* || -z "$line" ]] && continue
    key="${line%% = *}"; val="${line#* = }"
    actual="$(normalize_value "$(sysctl_value "$key")")"
    # Restore only values that differ; no tc reconstruction, no global reload.
    if [ "$actual" != "$(normalize_value "$val")" ]; then
      [ "$key" != net.ipv4.tcp_congestion_control ] || cc_changed=1
      if [ "$key" = net.ipv4.tcp_congestion_control ] && [ -n "${AT_PROXY_SERVICE:-}" ]; then
        touch "$SESSION_DIR/service-dirty" || return 1
      fi
      sysctl -w "$key=$val" >/dev/null 2>&1 || ok=1
    fi
    [ "$(normalize_value "$(sysctl_value "$key")")" = "$(normalize_value "$val")" ] || ok=1
  done < "$snap"
  # Automatic mode never mutates tc. Verify original queue configuration survived.
  local current original
  # Capture tc's own status; neither caller pipefail nor jq's empty-input status
  # can turn a failed/missing queue read into verified restoration.
  if current="$(tc -j qdisc show dev "$ACTUAL_IFACE" 2>/dev/null)" &&
    current="$(jq -Sce -s 'select(length==1)|.[0]|select(type=="array" and length>0 and all(.[];type=="object"))' <<< "$current")" &&
    original="$(jq -Sce -s 'select(length==1)|.[0]|select(type=="array" and length>0 and all(.[];type=="object"))' "$SESSION_DIR/qdisc.json")"; then
    [ "$current" = "$original" ] || ok=1
  else ok=1; fi
  if [ -n "${AT_PROXY_SERVICE:-}" ] && { [ "$cc_changed" -eq 1 ] || [ -f "$SESSION_DIR/service-dirty" ]; }; then
    _restart_proxy_service || ok=1
  fi
  return "$ok"
}

_restart_proxy_service(){
  [ -n "${AT_PROXY_SERVICE:-}" ] || return 0
  touch "$SESSION_DIR/service-dirty" || return 1
  timeout --signal=TERM --kill-after=3 20 systemctl restart "$AT_PROXY_SERVICE" >/dev/null 2>&1 || return 1
  systemctl is-active --quiet "$AT_PROXY_SERVICE" || return 1
  rm -f "$SESSION_DIR/service-dirty"
}

session_create(){
  local key value queues
  mkdir -p "$SESSIONS_BASE" || return 1
  SESSION_DIR="$(mktemp -d "$SESSIONS_BASE/$(date -u +%Y%m%d-%H%M%S).XXXXXX")" || return 1
  : > "$SESSION_DIR/snapshot.conf"
  for key in net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_wmem net.ipv4.tcp_rmem net.core.wmem_max net.core.rmem_max; do
    value="$(normalize_value "$(sysctl_value "$key")")"
    case "$key" in
      *mem) [[ "$value" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]] || return 1 ;;
      *max) [[ "$value" =~ ^[0-9]+$ ]] || return 1 ;;
      *) [[ "$value" =~ ^[a-zA-Z0-9_]+$ ]] || return 1 ;;
    esac
    printf '%s = %s\n' "$key" "$value" >> "$SESSION_DIR/snapshot.conf" || return 1
  done
  _runtime_json > "$SESSION_DIR/original.json" || return 1
  queues="$(tc -j qdisc show dev "$ACTUAL_IFACE" 2>/dev/null)" || return 1
  jq -Sce -s 'select(length==1)|.[0]|select(type=="array" and length>0 and all(.[];type=="object"))' \
    <<< "$queues" > "$SESSION_DIR/qdisc.json" || return 1
  if [ -f "$CONF" ]; then
    cp -p "$CONF" "$SESSION_DIR/orig_persistent.conf" || return 1
    printf 'exists\n' > "$SESSION_DIR/orig_persistent.status"
  else printf 'absent\n' > "$SESSION_DIR/orig_persistent.status"; fi
  : > "$SESSION_DIR/measurements.jsonl"; : > "$SESSION_DIR/pairs.jsonl"; : > "$SESSION_DIR/session.log"
  : > "$SESSION_DIR/candidates.jsonl"; : > "$SESSION_DIR/decisions.jsonl"
  {
    printf '#!/usr/bin/env bash\nset -uo pipefail\n'
    printf 'SESSION_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"\n'
    printf 'CONF=%q\nSTATE_DIR=%q\nACTUAL_IFACE=%q\nAT_PROXY_SERVICE=%q\n' "$CONF" "$STATE_DIR" "$ACTUAL_IFACE" "$AT_PROXY_SERVICE"
    declare -f normalize_value sysctl_value _restore_orig_persistent session_restore_runtime _restart_proxy_service
    cat <<'RESTORE'
if [ "${1:-}" != --watchdog ]; then
  exec 9>"$STATE_DIR/tuning.lock" || exit 1
  flock -n 9 || { echo 'Another tuner/restore holds the lock.' >&2; exit 1; }
  active="$(cat "$STATE_DIR/active-session" 2>/dev/null || true)"
  if [ -n "$active" ] && [ "$active" != "$SESSION_DIR" ]; then
    echo 'A newer session owns this machine; use its restore script.' >&2; exit 1
  fi
fi
# A previously completed commit is no longer verified once recovery starts.
# Invalidate its marker before writes so a failed retry blocks new tuning.
if ! rm -f "$SESSION_DIR/complete" || [ -e "$SESSION_DIR/complete" ] || [ -L "$SESSION_DIR/complete" ]; then
  echo 'restore_attempted=false; reason=completion_marker_remove_failed; recovery not started' >&2
  exit 1
fi
rc=0
_restore_orig_persistent || rc=1
session_restore_runtime || rc=1
if [ "$rc" -eq 0 ]; then
  echo 'restore_verified=true'
  if ! touch "$SESSION_DIR/complete"; then
    echo 'session_complete=false; reason=completion_marker_failed; parameters restored, retry recovery after fixing session storage' >&2
    rc=1
  fi
else echo 'restore_verified=false; manual recovery required' >&2; fi
exit "$rc"
RESTORE
  } > "$SESSION_DIR/restore.sh" || return 1
  chmod 700 "$SESSION_DIR/restore.sh" || return 1
  printf '%s\n' "$SESSION_DIR" > "$STATE_DIR/active-session" || return 1
  local latest_tmp="$SESSIONS_BASE/.latest-${SESSION_DIR##*/}"
  if [ -e "$SESSIONS_BASE/latest" ] && [ ! -L "$SESSIONS_BASE/latest" ]; then return 1; fi
  ln -s "$SESSION_DIR" "$latest_tmp" && mv -Tf "$latest_tmp" "$SESSIONS_BASE/latest" || return 1
}

watchdog_start(){
  local restore_script="$1" parent_pid="$BASHPID" deadline=$(( RUN_START + AT_MAX_SECONDS + 30 ))
  (
    trap - EXIT INT TERM
    while kill -0 "$parent_pid" 2>/dev/null; do
      [ -f "$SESSION_DIR/complete" ] && exit 0
      if [ "$(date +%s)" -ge "$deadline" ]; then
        kill -TERM "$parent_pid" 2>/dev/null || true
        sleep 5 9>&-
        kill -KILL "$parent_pid" 2>/dev/null || true
        break
      fi
      # Keep the inherited lock in the watchdog, not its sleeper: the latter
      # can outlive watchdog_stop and delay the next session.
      sleep 2 9>&-
    done
    if [ ! -f "$SESSION_DIR/complete" ] && [ "$(cat "$STATE_DIR/active-session" 2>/dev/null)" = "$SESSION_DIR" ]; then
      bash "$restore_script" --watchdog >> "$SESSION_DIR/watchdog.log" 2>&1
    fi
  ) &
  WATCHDOG_PID=$!
}
watchdog_stop(){
  if [ -n "$WATCHDOG_PID" ]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
    WATCHDOG_PID=""
  fi
}

apply_cc(){ sysctl -w "net.ipv4.tcp_congestion_control=$1" >/dev/null 2>&1; }
apply_qdisc(){
  # A name is insufficient to restore a queue's options/hierarchy or boot setup.
  # Until exact restoration is implemented, preserve the actual queue unchanged.
  [ "$1" = "$(sysctl_value net.core.default_qdisc)" ]
}
_buffer_value(){
  local min default maximum extra
  read -r min default maximum extra <<< "$(sysctl_value "$1")"
  [[ "$min" =~ ^[0-9]+$ && "$default" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ && -z "$extra" ]] || return 1
  [ "$2" -ge "$default" ] || return 1
  printf '%s %s %s\n' "$min" "$default" "$2"
}
apply_wmem(){ local value; value="$(_buffer_value net.ipv4.tcp_wmem "$1")" || return 1; sysctl -w "net.ipv4.tcp_wmem=$value" >/dev/null 2>&1; }
apply_rmem(){ local value; value="$(_buffer_value net.ipv4.tcp_rmem "$1")" || return 1; sysctl -w "net.ipv4.tcp_rmem=$value" >/dev/null 2>&1; }

apply_candidate_verified(){
  local cc="$1" qdisc="$2" wmem="$3" rmem="$4" expected actual key
  session_restore_runtime || { MEASURE_REASON=baseline_restore_failed; return 2; }
  expected="$(cat "$SESSION_DIR/original.json")" || return 2
  if [ -n "$cc" ]; then
    apply_cc "$cc" || return 1
    expected="$(jq -c --arg v "$cc" '."net.ipv4.tcp_congestion_control"=$v' <<< "$expected")" || return 1
  fi
  if [ -n "$qdisc" ]; then apply_qdisc "$qdisc" || return 1; fi
  if [ -n "$wmem" ]; then
    local wval; wval="$(_buffer_value net.ipv4.tcp_wmem "$wmem")" || return 1
    apply_wmem "$wmem" || return 1
    expected="$(jq -c --arg v "$wval" '."net.ipv4.tcp_wmem"=$v' <<< "$expected")" || return 1
  fi
  if [ -n "$rmem" ]; then
    local rval; rval="$(_buffer_value net.ipv4.tcp_rmem "$rmem")" || return 1
    apply_rmem "$rmem" || return 1
    expected="$(jq -c --arg v "$rval" '."net.ipv4.tcp_rmem"=$v' <<< "$expected")" || return 1
  fi
  actual="$(_runtime_json)" || return 1
  if ! jq -e --argjson a "$actual" '.==$a' <<< "$expected" >/dev/null; then
    MEASURE_REASON=candidate_readback_mismatch; return 1
  fi
  # Accepted TCP sockets can inherit their listener's CC. Recreate only the
  # explicitly selected proxy service, never an inferred service name.
  if [ -n "$AT_PROXY_SERVICE" ]; then _restart_proxy_service || { MEASURE_REASON=proxy_service_restart_failed; return 1; }; fi
  printf '%s\n' "$actual" > "$SESSION_DIR/applied.json" || return 1
}

_at_budget_add(){ BUDGET_USED_BYTES=$(( BUDGET_USED_BYTES + ${1:-0} )); }

_resource_snapshot(){
  local cpu="" available="" cgroup=""
  if [ -r /proc/stat ]; then cpu="$(awk 'NR==1{$1="";print;exit}' /proc/stat)"; fi
  if [ -r /proc/meminfo ]; then available="$(awk '/MemAvailable/{print $2;exit}' /proc/meminfo)"; fi
  if [ -r /sys/fs/cgroup/memory.current ]; then read -r cgroup < /sys/fs/cgroup/memory.current; fi
  jq -cn --arg cpu "$cpu" --arg available "$available" --arg cgroup "$cgroup" \
    '{cpu_jiffies:($cpu|split(" ")|map(select(length>0)|tonumber)),
      mem_available_kib:(($available|tonumber?)//null),cgroup_memory_bytes:(($cgroup|tonumber?)//null)}'
}

run_iperf3_json(){
  local target="$1" direction="$2" duration="$3" parallel="${4:-1}"
  local remaining reservation probe_reserve=0 started raw probe_file rc probe_rc=0 pid sampler=""
  local resources_before resources_after socket_file sndbuf_pct
  local sample_limit=0 accounted_bytes mode=timed probe_parsed=""
  IPERF_THROUGHPUT=0; IPERF_RETR=null; IPERF_RTT=null; IPERF_BYTES=0
  IPERF_SNDBUF_LIMITED=0; IPERF_RWND_LIMITED=0
  IPERF_SNDBUF_EVIDENCE=0
  IPERF_PROXY='{"status":"not_configured"}'
  MEASURE_REASON=""
  remaining=$(( RUN_START + AT_MAX_SECONDS - $(date +%s) ))
  [ "$remaining" -ge $((duration + 5)) ] || { MEASURE_REASON=time_budget_exhausted; return 2; }
  if [ "$AT_RATE_MBPS" -eq 0 ]; then
    [ "$AT_SAMPLE_MIB" -gt 0 ] && [ "$parallel" -eq 1 ] || { MEASURE_REASON=invalid_byte_quota; return 1; }
    mode=byte_bounded
    sample_limit=$((AT_SAMPLE_MIB * 1048576))
    # iperf's quota is payload, not wire bytes. Allow one default TCP write block.
    reservation=$((sample_limit + 131072))
  else
    # Payload estimate with 10% reserve, including every stream. Not a wire-byte cap.
    reservation="$(awk -v d="$duration" -v r="$AT_RATE_MBPS" -v p="$parallel" 'BEGIN{printf "%.0f", d*r*1000000/8*p*1.10}')"
  fi
  if [ -n "$AT_PROBE_COMMAND" ]; then probe_reserve=$(( ${PROXY_MAX_BYTES:-33554432} + ${PROXY_REQUESTS:-20} * ${PROXY_SMALL_MAX_BYTES:-65536} )); fi
  [ $(( BUDGET_USED_BYTES + reservation + probe_reserve )) -le "$BUDGET_LIMIT_BYTES" ] || { MEASURE_REASON=traffic_budget_exhausted; return 2; }
  _at_budget_add $((reservation + probe_reserve))
  MEASURE_SEQ=$((MEASURE_SEQ+1))
  raw="$SESSION_DIR/iperf-$(printf '%04d' "$MEASURE_SEQ").json"
  probe_file="$SESSION_DIR/probe-$(printf '%04d' "$MEASURE_SEQ").json"
  started="$(date +%s)"
  resources_before="$(_resource_snapshot)" || return 1
  socket_file="${raw%.json}.ss.txt"
  local args=(-c "$target" -J --get-server-output)
  if [ "$AT_RATE_MBPS" -eq 0 ]; then args+=(-b 0 -n "$sample_limit")
  else args+=(-t "$duration" -b "${AT_RATE_MBPS}M"); fi
  [ "$direction" = upload ] && args+=(-R)
  [ "$parallel" -gt 1 ] && args+=(-P "$parallel")
  timeout --signal=TERM --kill-after=3 "$((duration+5))" iperf3 "${args[@]}" > "$raw" 2>"${raw%.json}.stderr" &
  pid=$!
  if has ss; then
    (sleep 1; timeout 2 ss -tinm dst "$target" dport = :5201 > "$socket_file" 2>/dev/null || true) &
    sampler=$!
  fi
  if [ -n "$AT_PROBE_COMMAND" ]; then
    timeout --signal=TERM --kill-after=3 "$((duration+5))" "$AT_PROBE_COMMAND" > "$probe_file" 2>"${probe_file%.json}.stderr" || probe_rc=$?
  fi
  wait "$pid"; rc=$?
  if [ -n "$sampler" ]; then wait "$sampler" || true; fi
  resources_after="$(_resource_snapshot)" || return 1
  if [ -s "$socket_file" ]; then
    sndbuf_pct="$(awk '
      /bytes_sent:/ && /sndbuf_limited:/ {
        bytes=0; pct=0
        for(i=1;i<=NF;i++){
          if($i~/^bytes_sent:/){b=$i;sub(/^bytes_sent:/,"",b);bytes=b+0}
          if($i~/^sndbuf_limited:/){p=$i;sub(/^[^(]*\(/,"",p);sub(/%.*/,"",p);pct=p+0}
        }
        if(bytes>=1048576 && pct>=5 && pct>best)best=pct
      } END{print best+0}' "$socket_file")"
    if known_positive "$sndbuf_pct"; then IPERF_SNDBUF_EVIDENCE=1; fi
  fi
  local parsed='{}' status=failed actual='{}'
  if [ "$rc" -eq 0 ]; then
    parsed="$(jq -cse '
       if length==1 and (.[0]|type)=="object" then .[0] else error("expected one iperf object") end |
      if .error then error(.error) else . end |
      (.end.sum_received // .end.sum) as $recv |
      (.server_output_json // {}) as $server |
      ([.end.streams[]?.sender.mean_rtt, $server.end.streams[]?.sender.mean_rtt] | map(select(type=="number" and .>0))) as $rtt |
      {tp:($recv.bits_per_second/1000000), bytes:$recv.bytes,
       accounted_bytes:([$recv.bytes,.end.sum_sent.bytes,$server.end.sum_sent.bytes] | map(select(type=="number")) | max),
       seconds:(.end.sum_sent.seconds // $server.end.sum_sent.seconds // $recv.seconds // null),
       retr:(.end.sum_sent.retransmits // $server.end.sum_sent.retransmits // null),
       rtt:(if ($rtt|length)>0 then ($rtt|add/length) else null end),
       sndbuf:(.end.sum_sent.sndbuf_limited // $server.end.sum_sent.sndbuf_limited // 0),
       rwnd:(.end.sum_sent.rwnd_limited // $server.end.sum_sent.rwnd_limited // 0)} |
      select(.tp>0 and .bytes>0 and (.tp|type)=="number" and (.bytes|type)=="number" and
        (.bytes|floor)==.bytes and .bytes<=9007199254740991 and
        (.accounted_bytes|type)=="number" and .accounted_bytes>=.bytes and
        (.accounted_bytes|floor)==.accounted_bytes and .accounted_bytes<=9007199254740991 and
        (.retr==null or ((.retr|type)=="number" and .retr>=0 and (.retr|floor)==.retr)))
    ' "$raw" 2>/dev/null)" || parsed='{}'
    [ -n "$parsed" ] || parsed='{}'
    if [ -n "$parsed" ] && jq -e '.tp>0 and .bytes>0' <<< "$parsed" >/dev/null; then
      read -r IPERF_THROUGHPUT IPERF_BYTES IPERF_RETR IPERF_RTT IPERF_SNDBUF_LIMITED IPERF_RWND_LIMITED < <(jq -r '[.tp,.bytes,.retr,.rtt,.sndbuf,.rwnd]|map(if .==null then "null" else tostring end)|@tsv' <<< "$parsed")
      accounted_bytes="$(jq -r .accounted_bytes <<< "$parsed")"
      BUDGET_USED_BYTES=$(( BUDGET_USED_BYTES - reservation + accounted_bytes ))
      status=ok
      if [ "$AT_RATE_MBPS" -eq 0 ]; then
        if [ "$accounted_bytes" -gt "$reservation" ]; then
          status=failed; MEASURE_REASON=sample_byte_limit_exceeded
        elif ! jq -e --argjson minimum "$duration" '.seconds|type=="number" and .>=$minimum' <<< "$parsed" >/dev/null; then
          status=failed; MEASURE_REASON=sample_too_short
        fi
      fi
    fi
  fi
  if [ -n "$AT_PROBE_COMMAND" ]; then
    if [ "$probe_rc" -eq 0 ] && probe_parsed="$(jq -cse --argjson limit "$probe_reserve" '
       if length==1 and (.[0]|type)=="object" then .[0] else error("expected one probe object") end |
       select(
      .status=="ok" and (.requests|type)=="number" and .requests>=10 and (.requests|floor)==.requests and
      (.errors|type)=="number" and .errors>=0 and .errors<=.requests and (.errors|floor)==.errors and
      (.p50_ms|type)=="number" and .p50_ms>0 and
      (.p95_ms|type)=="number" and .p95_ms>=.p50_ms and
      (.download_mbps|type)=="number" and .download_mbps>0 and
       (.bytes|type)=="number" and .bytes>0 and .bytes<=$limit and (.bytes|floor)==.bytes)
    ' "$probe_file" 2>/dev/null)" && [ -n "$probe_parsed" ]; then
      IPERF_PROXY="$probe_parsed"
      BUDGET_USED_BYTES=$(( BUDGET_USED_BYTES - probe_reserve + $(jq -r .bytes <<< "$probe_parsed") ))
    else IPERF_PROXY='{"status":"failed"}'; status=failed; MEASURE_REASON=proxy_measurement_failed; fi
  fi
  if [ "$BUDGET_USED_BYTES" -gt "$BUDGET_LIMIT_BYTES" ]; then status=failed; MEASURE_REASON=traffic_budget_exceeded; fi
  [ "$status" = ok ] || MEASURE_REASON="${MEASURE_REASON:-iperf_measurement_failed}"
  actual="$(_runtime_json)" || return 1
  jq -cn --argjson seq "$MEASURE_SEQ" --arg stage "${MEASURE_STAGE:-unknown}" --arg role "${MEASURE_ROLE:-unknown}" \
    --arg target "$target" --arg direction "$direction" --arg status "$status" --arg reason "$MEASURE_REASON" --arg candidate "${MEASURE_CANDIDATE:-original}" \
    --argjson started "$started" --argjson ended "$(date +%s)" --arg raw "${raw##*/}" \
    --argjson metrics "$parsed" --argjson proxy "$IPERF_PROXY" --argjson actual "$actual" \
    --argjson before "$resources_before" --argjson after "$resources_after" --argjson sndbuf_evidence "$IPERF_SNDBUF_EVIDENCE" \
    --arg mode "$mode" --argjson sample_limit "$sample_limit" --argjson minimum "$duration" --argjson process_rc "$rc" \
    '{seq:$seq,stage:$stage,role:$role,candidate:$candidate,target:$target,direction:$direction,
      sender:(if $direction=="download" then "tuned_vps" else "peer" end),
      receiver:(if $direction=="download" then "peer" else "tuned_vps" end),
      status:$status,reason:$reason,process_exit_code:$process_rc,started:$started,ended:$ended,raw:$raw,
      limits:{mode:$mode,requested_seconds:$minimum,payload_quota_bytes:$sample_limit,timeout_seconds:($minimum+5)},
      metrics:$metrics,proxy:$proxy,actual:$actual,resources:{before:$before,after:$after},sender_buffer_limited_evidence:($sndbuf_evidence==1)}' >> "$SESSION_DIR/measurements.jsonl" || return 1
  [ "$status" = ok ]
}

_current_measurement_json(){
  jq -cn --argjson tp "$IPERF_THROUGHPUT" --argjson retr "$IPERF_RETR" --argjson rtt "$IPERF_RTT" \
    --argjson bytes "$IPERF_BYTES" --argjson proxy "$IPERF_PROXY" '{tp:$tp,retr:$retr,rtt:$rtt,bytes:$bytes,proxy:$proxy}'
}

# A diagnostic, not proof: only kernel-reported sender buffer limiting enables
# buffer candidates. Receive-side rwnd limiting cannot identify the receiver's
# actual constraint without instrumentation on that peer, so it is not enough.
run_diagnostic_buffer_test(){
  BUFFER_LIMITED=0
  if [ "$2" = download ] && [ "$IPERF_SNDBUF_EVIDENCE" -eq 1 ]; then BUFFER_LIMITED=1; fi
  session_log "buffer_evidence=ss_sender_sndbuf_limited_5pct enabled=$BUFFER_LIMITED"
}

_measurement_gates(){
  # JSON baseline/candidate; a failed pair vetoes the entire candidate.
  local reason
  reason="$(jq -nr --argjson b "$1" --argjson c "$2" \
    --argjson rf "$AT_MAX_RTT_FACTOR" --argjson abs "$AT_RTT_TOLERANCE_MS" \
    --argjson retrf "$AT_MAX_RETR_FACTOR" --argjson floor "$AT_RETR_FLOOR" '
    def number: type=="number";
    def limit($x): [($x*$rf/100),($x+$abs*1000)]|max;
    if ($b.tp|number|not) or $b.tp<=0 or ($c.tp|number|not) or $c.tp<=0 or $b.bytes<=0 or $c.bytes<=0 then "invalid_measurement"
    elif $c.tp < $b.tp*0.95 then "throughput_regression"
    elif (($b.rtt|number) and ($c.rtt|number|not)) then "rtt_missing"
    elif (($b.rtt|number) and ($c.rtt|number) and $b.rtt>0 and $c.rtt>limit($b.rtt)) then "rtt_regression"
    elif (($b.retr|number) and ($c.retr|number|not)) then "retransmits_missing"
    elif (($b.retr|number) and ($c.retr|number) and
      ($c.retr*1073741824/$c.bytes) > ([($b.retr*1073741824/$b.bytes*$retrf/100),$floor]|max)) then "retransmit_regression"
    elif $b.proxy.status=="ok" and $c.proxy.status!="ok" then "proxy_missing"
    elif $c.proxy.status=="failed" then "proxy_failed"
    elif $c.proxy.status=="ok" and $c.proxy.errors>0 then "proxy_errors"
    elif $b.proxy.status=="ok" and $c.proxy.status=="ok" and
      $c.proxy.p95_ms*1000>limit($b.proxy.p95_ms*1000) then "proxy_p95_regression"
    elif $b.proxy.status=="ok" and $c.proxy.status=="ok" and
      $c.proxy.download_mbps<$b.proxy.download_mbps*0.95 then "proxy_throughput_regression"
    else "" end')" || return 1
  SCORE_REJECT_REASON="$reason"
  [ -z "$reason" ]
}

score_candidate(){
  local b c
  b="$(jq -cn --argjson t "$4" --argjson r "$5" --argjson d "$6" --argjson n "$7" '{tp:$t,retr:$r,rtt:$d,bytes:$n,proxy:{status:"not_configured"}}')" || return 1
  c="$(jq -cn --argjson t "$1" --argjson r "$2" --argjson d "$3" --argjson n "$8" '{tp:$t,retr:$r,rtt:$d,bytes:$n,proxy:{status:"not_configured"}}')" || return 1
  CANDIDATE_SCORE=-1
  _measurement_gates "$b" "$c" || return 1
  # Throughput ranks only already-admissible candidates. No zero-loss bonus.
  CANDIDATE_SCORE="$(awk -v c="$1" -v b="$4" 'BEGIN{printf "%.8f",c/b}')"
}

_median(){
  printf '%s\n' "$@" | awk '
    NF {a[++n]=$1} END{for(i=1;i<=n;i++)for(j=i+1;j<=n;j++)if(a[i]>a[j]){t=a[i];a[i]=a[j];a[j]=t}
    if(!n)print 0;else if(n%2)print a[(n+1)/2];else printf "%.4f\n",(a[n/2]+a[n/2+1])/2}'
}

_pair_statistics(){
  # Per-pair relative gains; median/MAD are conservative heuristics, not a CI.
  jq -sc --arg stage "$RETEST_STAGE" --argjson min_tp "$AT_MIN_TP_GAIN" --argjson min_lat "$AT_MIN_RTT_GAIN" '
    def median: sort | length as $n | if $n==0 then null elif $n%2==1 then .[($n/2|floor)] else (.[($n/2|floor)-1]+.[($n/2|floor)])/2 end;
    def mad: . as $a | median as $m | [$a[]|(. - $m)|fabs]|median;
    def throughput: if .proxy.status=="ok" then .proxy.download_mbps else .tp end;
    def latency: if .proxy.status=="ok" then .proxy.p95_ms*1000 else .rtt end;
    [.[]|select(.stage==$stage and .valid)] as $p |
    [$p[]|((.candidate|throughput)/(.baseline|throughput)-1)*100] as $g |
    [$p[].baseline|throughput] as $b |
    [$p[]|select((.baseline|latency)>0 and (.candidate|latency)>0)|
      (1-(.candidate|latency)/(.baseline|latency))*100] as $lg |
    [$p[]|(.baseline|latency)|select(.>0)] as $lb |
    {pairs:($p|length),gain_pct:($g|median),tp_direction_fraction:(if ($g|length)>0 then ([$g[]|select(.>0)]|length)/($g|length) else 0 end),
      baseline_relative_mad:(if ($b|length)>0 then 100*($b|mad)/($b|median) else null end),
      latency_gain_pct:($lg|median),latency_pairs:($lg|length),
      latency_direction_fraction:(if ($lg|length)>0 then ([$lg[]|select(.>0)]|length)/($lg|length) else 0 end),
      latency_relative_mad:(if ($lb|length)>0 then 100*($lb|mad)/($lb|median) else null end),
      base_tp:($b|median),cand_tp:([$p[].candidate|throughput]|median),
      throughput_metric:(if $p[0].baseline.proxy.status=="ok" then "proxy_download_mbps" else "iperf_mbps" end),
      latency_metric:(if $p[0].baseline.proxy.status=="ok" then "proxy_p95_us" else "tcp_mean_rtt_us" end),
      base_latency:($lb|median),cand_latency:([$p[].candidate|latency|select(.>0)]|median),
      base_rtt:([$p[].baseline.rtt|select(.!=null and .>0)]|median),
      cand_rtt:([$p[].candidate.rtt|select(.!=null and .>0)]|median)} |
    .tp_threshold=([$min_tp,2*(.baseline_relative_mad//0)]|max) |
    .latency_threshold=([$min_lat,2*(.latency_relative_mad//0)]|max) |
    .heuristic=true | .statistical_significance_claimed=false
  ' "$1"
}

is_reliable_improvement(){
  # Decision MUST follow a completed retest; four median arguments are display
  # compatibility only and cannot bypass the pair evidence or hard gates.
  IMPROVEMENT_REASON=insufficient_valid_pairs
  [ "$RETEST_GATE_FAILED" -eq 0 ] || { IMPROVEMENT_REASON=pair_gate_failed; return 1; }
  if jq -e '.pairs>=3 and .gain_pct>=.tp_threshold and .tp_direction_fraction>=0.8' <<< "$RETEST_STATS" >/dev/null; then
    IMPROVEMENT_REASON=paired_throughput_improvement; return 0
  fi
  if jq -e '.pairs>=3 and .latency_pairs==.pairs and .latency_gain_pct>=.latency_threshold and .latency_direction_fraction>=0.8' <<< "$RETEST_STATS" >/dev/null; then
    IMPROVEMENT_REASON=paired_latency_improvement; return 0
  fi
  IMPROVEMENT_REASON=insufficient_or_noisy_improvement
  return 1
}

interleaved_retest(){
  local target="$1" direction="$2" duration="$3" cc="$4" qdisc="$5" wmem="$6" rmem="$7"
  local rounds="${8:-$AT_RETEST_ROUNDS}" round role b c valid failure order rc
  RETEST_GATE_FAILED=0; RETEST_VALID_PAIRS=0; RETEST_STATS='{}'
  : > "$SESSION_DIR/current-pairs.jsonl"
  for ((round=1;round<=rounds;round++)); do
    MEASURE_PAIR="$round"
    b='{}'; c='{}'; valid=true; failure=""
    if ((round%2)); then order='baseline candidate'; else order='candidate baseline'; fi
    for role in $order; do
      rc=0
      if [ "$role" = baseline ]; then session_restore_runtime || rc=2
      else apply_candidate_verified "$cc" "$qdisc" "$wmem" "$rmem" || rc=$?; fi
      if [ "$rc" -ne 0 ]; then
        RETEST_GATE_FAILED=1; failure="${MEASURE_REASON:-apply_failed}"; valid=false; break
      fi
      MEASURE_STAGE="$RETEST_STAGE"; MEASURE_ROLE="$role"
      if run_iperf3_json "$target" "$direction" "$duration" 1; then
        if [ "$role" = baseline ]; then b="$(_current_measurement_json)"; else c="$(_current_measurement_json)"; fi
      else valid=false; failure="${MEASURE_REASON:-measurement_failed}"; break; fi
    done
    if [ "$valid" = true ]; then
      if ! _measurement_gates "$b" "$c"; then
        valid=false; RETEST_GATE_FAILED=1; failure="$SCORE_REJECT_REASON"
      else RETEST_VALID_PAIRS=$((RETEST_VALID_PAIRS+1)); fi
    fi
    jq -cn --arg stage "$RETEST_STAGE" --argjson round "$round" --arg order "$order" --arg candidate "${MEASURE_CANDIDATE:-unknown}" \
      --argjson b "$b" --argjson c "$c" --argjson valid "$valid" --arg reason "$failure" \
      '{stage:$stage,round:$round,order:$order,candidate_id:$candidate,baseline:$b,candidate:$c,valid:$valid,reason:$reason}' \
      >> "$SESSION_DIR/current-pairs.jsonl" || return 1
    if [ -n "$failure" ]; then session_log "$RETEST_STAGE round=$round reason=$failure"; fi
    # Do not retry until a candidate happens to pass; no extra rounds on noise.
    [ "$RETEST_GATE_FAILED" -eq 0 ] || break
    case "$failure" in *budget*) break ;; esac
  done
  cat "$SESSION_DIR/current-pairs.jsonl" >> "$SESSION_DIR/pairs.jsonl" || return 1
  session_restore_runtime || { MEASURE_REASON=baseline_restore_failed; return 2; }
  RETEST_STATS="$(_pair_statistics "$SESSION_DIR/current-pairs.jsonl")" || return 1
  RETEST_BASE_TP_MEDIAN="$(jq -r '.base_tp//0' <<< "$RETEST_STATS")"
  RETEST_CAND_TP_MEDIAN="$(jq -r '.cand_tp//0' <<< "$RETEST_STATS")"
  RETEST_BASE_RTT_MEDIAN="$(jq -r .base_rtt <<< "$RETEST_STATS")"
  RETEST_CAND_RTT_MEDIAN="$(jq -r .cand_rtt <<< "$RETEST_STATS")"
  # A phase with any missing pairs is inconclusive, not evidence of improvement.
  [ "$RETEST_GATE_FAILED" -eq 0 ] && [ "$RETEST_VALID_PAIRS" -eq "$rounds" ] && [ "$RETEST_VALID_PAIRS" -ge 3 ]
}

persist_final_atomic(){
  local cc="$1" qdisc="$2" wmem="$3" rmem="$4" tmp changes key value
  changes="$SESSION_DIR/persistent-changes.conf"
  : > "$changes" || return 1
  if [ -n "$cc" ]; then printf 'net.ipv4.tcp_congestion_control = %s\n' "$cc" >> "$changes" || return 1; fi
  # qdisc is deliberately unchanged, including its boot configuration.
  [ -z "$qdisc" ] || [ "$qdisc" = "$(sysctl_value net.core.default_qdisc)" ] || return 1
  if [ -n "$wmem" ]; then value="$(_buffer_value net.ipv4.tcp_wmem "$wmem")" || return 1; printf 'net.ipv4.tcp_wmem = %s\n' "$value" >> "$changes" || return 1; fi
  if [ -n "$rmem" ]; then value="$(_buffer_value net.ipv4.tcp_rmem "$rmem")" || return 1; printf 'net.ipv4.tcp_rmem = %s\n' "$value" >> "$changes" || return 1; fi
  [ -s "$changes" ] || return 1
  tmp="$(mktemp "${CONF}.XXXXXX")" || return 1
  # Retain all untouched entries and comments, not just a whitelist of four keys.
  if [ -f "$SESSION_DIR/orig_persistent.conf" ]; then
    awk -F= 'NR==FNR{key=$1;gsub(/[[:space:]]/,"",key);changed[key]=1;next}
      {key=$1;gsub(/[[:space:]]/,"",key);if(!(key in changed))print}' "$changes" "$SESSION_DIR/orig_persistent.conf" > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  cat "$changes" >> "$tmp" || { rm -f "$tmp"; return 1; }
  # Verify the staged file and the runtime state which was actually measured.
  while IFS= read -r key; do
    value="${key#* = }"; key="${key%% = *}"
    [ "$(normalize_value "$(sysctl_value "$key")")" = "$(normalize_value "$value")" ] || { rm -f "$tmp"; return 1; }
  done < "$changes"
  RUN_PERSIST_TOUCHED=1
  mv -f "$tmp" "$CONF" || { rm -f "$tmp"; return 1; }
  # No sysctl --system: it would modify unrelated, unmeasured runtime settings.
  while IFS= read -r key; do
    value="${key#* = }"; key="${key%% = *}"
    [ "$(awk -F' = ' -v k="$key" '$1==k{v=$2}END{print v}' "$CONF")" = "$value" ] || return 1
    [ "$(normalize_value "$(sysctl_value "$key")")" = "$(normalize_value "$value")" ] || return 1
  done < "$changes"
}

_finalize_and_persist(){
  apply_candidate_verified "$@" || return 1
  if [ "$AT_NO_PERSIST" -eq 1 ]; then RUN_RESULT=validated; RUN_REASON=temporary_candidate_validated; return 0; fi
  persist_final_atomic "$@" || return 1
  RUN_COMMITTED=1; RUN_RESULT=committed; RUN_REASON=independent_acceptance_passed
}

_write_report(){
  local tmp actual='{}' version policy script_hash=unknown hash_output
  tmp="$SESSION_DIR/report.json.tmp"
  actual="$(_runtime_json)" || return 1
  version="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse HEAD 2>/dev/null || printf unknown)"
  # A process substitution is a consumed stream, not a hashable source file.
  if [ -f "${BASH_SOURCE[0]}" ]; then
    hash_output="$(sha256sum -- "${BASH_SOURCE[0]}")" || return 1
    script_hash="${hash_output%% *}"
    [[ "$script_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
  fi
  policy="$(jq -cn --argjson tp "$AT_MIN_TP_GAIN" --argjson latency "$AT_MIN_RTT_GAIN" \
    --argjson factor "$AT_MAX_RTT_FACTOR" --argjson absolute "$AT_RTT_TOLERANCE_MS" \
    --argjson retr "$AT_MAX_RETR_FACTOR" --argjson floor "$AT_RETR_FLOOR" \
    --argjson rounds "$AT_RETEST_ROUNDS" --argjson accept "$AT_ACCEPT_ROUNDS" \
    --argjson seconds "$AT_MAX_SECONDS" --argjson duration "$AT_DURATION" \
    '{min_tp_gain_pct:$tp,min_latency_gain_pct:$latency,max_rtt_factor_pct:$factor,rtt_tolerance_ms:$absolute,
      max_retransmit_factor_pct:$retr,retransmit_floor_per_gib:$floor,retest_pairs:$rounds,acceptance_pairs:$accept,
      max_seconds:$seconds,measurement_seconds:$duration,direction_consistency:0.8}')" || return 1
  jq -n --arg result "$RUN_RESULT" --arg reason "$RUN_REASON" --arg version "$SCRIPT_VERSION" --arg commit "$version" \
    --arg kernel "$(uname -r)" --arg iperf_version "$(iperf3 --version 2>/dev/null | head -n1)" --arg script_hash "$script_hash" \
    --arg target "$AT_TARGET" --arg direction "$AT_DIRECTION" --arg iface "$ACTUAL_IFACE" \
    --argjson selected "$RUN_SELECTED" --argjson persisted "$([ "$RUN_COMMITTED" -eq 1 ] && echo true || echo false)" \
    --argjson restored "$RUN_RESTORE_VERIFIED" --argjson used "$BUDGET_USED_BYTES" --argjson limit "$BUDGET_LIMIT_BYTES" \
    --argjson rate "$AT_RATE_MBPS" --argjson sample_mib "$AT_SAMPLE_MIB" --argjson started "$RUN_START" --argjson ended "$(date +%s)" \
    --argjson actual "$actual" --argjson retests "$RETEST_RESULTS" --argjson acceptance "$ACCEPTANCE_STATS" --argjson policy "$policy" \
    --argjson acceptance_attempted "$ACCEPTANCE_ATTEMPTED" --argjson acceptance_completed "$ACCEPTANCE_COMPLETED" --argjson acceptance_passed "$ACCEPTANCE_PASSED" \
    --argjson request "${WINNER_CONFIG:-null}" --arg probe "$AT_PROBE_COMMAND" --arg service "$AT_PROXY_SERVICE" \
    --slurpfile original "$SESSION_DIR/original.json" --slurpfile measurements "$SESSION_DIR/measurements.jsonl" \
    --slurpfile pairs "$SESSION_DIR/pairs.jsonl" \
    --slurpfile candidates "$SESSION_DIR/candidates.jsonl" --slurpfile decisions "$SESSION_DIR/decisions.jsonl" \
    '{schema:2,result:$result,reason:$reason,version:$version,commit:$commit,script_sha256:$script_hash,kernel:$kernel,iperf_version:$iperf_version,
      target:$target,direction:$direction,interface:$iface,started:$started,ended:$ended,
      selected:$selected,applied:(if $persisted then true elif $restored then false else null end),persisted:$persisted,
      restore_attempted:($persisted|not),restore_verified:$restored,reboot_verified:false,
      proxy_experience:(if ([$measurements[]|select(.status=="ok" and .proxy.status=="ok")]|length)>0 then "measured_on_probe_host" else "not_verified" end),
      proxy_probe:{configured:($probe!=""),valid_measurements:([$measurements[]|select(.status=="ok" and .proxy.status=="ok")]|length),
        failed_measurements:([$measurements[]|select(.proxy.status=="failed")]|length)},
      proxy_service:$service,listener_refresh:(if $service=="" then "not_managed" else "explicit_service_restart" end),
      policy:($policy+{rate_ceiling_mbps:$rate,unlimited_rate:($rate==0),sample_mib:$sample_mib,
        measurement_mode:(if $rate==0 then "byte_bounded" else "timed" end),
        noise_rule:"paired_median_and_MAD_heuristic",statistical_significance_claimed:false,qdisc:"preserved"}),
      budget:{used_or_reserved_payload_bytes:$used,limit_bytes:$limit,wire_byte_hard_cap:false},
      original:$original[0],requested:$request,final:$actual,retests:$retests,acceptance:$acceptance,
      acceptance_phase:{attempted:$acceptance_attempted,completed:$acceptance_completed,passed:$acceptance_passed},
      candidates:$candidates,decisions:$decisions,
      measurements:$measurements,pairs:$pairs}' > "$tmp" || return 1
  mv "$tmp" "$SESSION_DIR/report.json"
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
  local missing=0 command
  green "TCP 迷之调参环境检查"
  for command in sysctl gawk mkdir cat; do
    if has "$command"; then
      green "[已安装] $command"
    else
      red "[缺少] $command"
      missing=1
    fi
  done
  if [ "$missing" -eq 1 ]; then
    red '预览所需依赖缺失，请自行安装后重试；预览不安装组件或加载模块。'
    return 1
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
    [[ " $available " == *" $MYSTERY_CC "* ]] || yellow "当前内核未报告 $MYSTERY_CC 可用，仅按公式生成预览。"
    break
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
  yellow '队列选择仅用于公式预览，不加载模块或改动实际队列。'
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
  red '旧版公式配置仅供预览，应用和持久化已禁用；请使用自动调优流程。'
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
  yellow "旧版公式仅生成预览，不能应用或持久化；其中包含未经本链路验证的系统策略。"
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
  green "当前内核可识别的公式配置预览（不会应用）"
  cat "$MYSTERY_CANDIDATE"
  echo
  mystery_log "result=previewed-not-applied"
  yellow "仅保存公式预览和日志到 $STATE_DIR；未经测量验收，不提供应用入口。"
  pause
}

mystery_tune_menu(){
  local choice
  while true; do
    clear_screen
    green "调试区 - TCP 迷之调参"
    echo "--------------------------------"
    echo "1. 生成旧版公式配置预览（禁止应用）"
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


##############################################################################
# 自动调优流程（替代旧 tune_flow）
##############################################################################

# 命令行参数覆盖（可在调用前设置）
# AT_MAX_CANDIDATES N  AT_DURATION N  AT_BUDGET_GIB N

_validate_auto_options(){
  local name value
  for name in AT_MAX_CANDIDATES AT_DURATION AT_MAX_SECONDS AT_RETEST_ROUNDS AT_ACCEPT_ROUNDS AT_MAX_SHORTLIST AT_EXPECTED_CONNECTIONS AT_BUFFER_MAX_MIB; do
    value="${!name}"
    [[ "$value" =~ ^[1-9][0-9]{0,5}$ ]] || { red "无效正整数: $name=$value"; return 1; }
  done
  for name in AT_RATE_MBPS AT_SAMPLE_MIB; do
    value="${!name}"
    [[ "$value" =~ ^(0|[1-9][0-9]{0,5})$ ]] || { red "无效非负整数: $name=$value"; return 1; }
  done
  [ "$AT_SAMPLE_MIB" -le 4096 ] || return 1
  if [ "$AT_RATE_MBPS" -eq 0 ]; then
    [ "$AT_SAMPLE_MIB" -gt 0 ] || { red '不限速模式需要 --sample-mib 指定每轮载荷上限。'; return 1; }
  else
    [ "$AT_SAMPLE_MIB" -eq 0 ] || { red '--sample-mib 仅用于 --rate-mbps 0。'; return 1; }
  fi
  [ "$AT_MAX_CANDIDATES" -le 16 ] && [ "$AT_MAX_SHORTLIST" -le 3 ] &&
    [ "$AT_DURATION" -ge 2 ] && [ "$AT_DURATION" -le 120 ] &&
    [ "$AT_RETEST_ROUNDS" -ge 3 ] && [ "$AT_RETEST_ROUNDS" -le 15 ] &&
    [ "$AT_ACCEPT_ROUNDS" -ge 3 ] && [ "$AT_ACCEPT_ROUNDS" -le 15 ] &&
    [ "$AT_MAX_SECONDS" -le 86400 ] && [ "$AT_RATE_MBPS" -le 100000 ] || { red '参数超出支持范围。'; return 1; }
  for name in AT_BUDGET_GIB AT_MIN_TP_GAIN AT_MIN_RTT_GAIN AT_MAX_RTT_FACTOR AT_RTT_TOLERANCE_MS AT_MAX_RETR_FACTOR AT_RETR_FLOOR; do
    value="${!name}"; numeric "$value" || { red "无效数值: $name=$value"; return 1; }
  done
  awk -v b="$AT_BUDGET_GIB" -v t="$AT_MIN_TP_GAIN" -v l="$AT_MIN_RTT_GAIN" \
    -v r="$AT_MAX_RTT_FACTOR" -v a="$AT_RTT_TOLERANCE_MS" -v f="$AT_MAX_RETR_FACTOR" -v q="$AT_RETR_FLOOR" \
    'BEGIN{exit !(b>0 && b<=10240 && t>0 && t<=100 && l>0 && l<100 && r>=100 && r<=150 && a>=0 && a<=50 && f>=100 && f<=1000 && q>=0 && q<=100000)}' || return 1
  valid_target_host "$AT_TARGET" && [[ "$AT_TARGET" != -* ]] || { red '需要合法的 --target IP/域名。'; return 1; }
  case "$AT_DIRECTION" in download|upload) ;; *) return 1 ;; esac
  [ "$AT_PRIMARY_NODE" = 0 ] || { red '自动 SSH 多节点提交暂不可用。'; return 1; }
  if [ -n "$AT_PROBE_COMMAND" ]; then [ -f "$AT_PROBE_COMMAND" ] && [ -x "$AT_PROBE_COMMAND" ] || { red '--probe-command 必须是可执行文件路径。'; return 1; }; fi
  if [ -n "$AT_PROBE_COMMAND" ]; then AT_PROBE_COMMAND="$(cd "$(dirname "$AT_PROBE_COMMAND")" && pwd)/$(basename "$AT_PROBE_COMMAND")"; fi
  if [ -n "$AT_PROXY_SERVICE" ]; then [[ "$AT_PROXY_SERVICE" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.@-]*$ ]] || return 1; fi
  if [ -n "${PROXY_HOST:-}${PROXY_TEST_URL:-}" ]; then
    [ -n "${PROXY_HOST:-}" ] && [ -n "${PROXY_TEST_URL:-}" ] || { red '代理验收需同时指定 PROXY_HOST 和 PROXY_TEST_URL。'; return 1; }
    if [ -z "$AT_PROBE_COMMAND" ]; then
      [ -n "${PROXY_SMALL_URL:-}" ] || { red '内置代理探针还需要 PROXY_SMALL_URL。'; return 1; }
    fi
  fi
  for name in PROXY_MAX_BYTES PROXY_SMALL_MAX_BYTES PROXY_REQUESTS; do
    value="${!name:-}"
    [ -z "$value" ] || [[ "$value" =~ ^[1-9][0-9]{0,9}$ ]] || { red "无效代理参数: $name"; return 1; }
  done
  [ "${PROXY_REQUESTS:-20}" -ge 10 ] && [ "${PROXY_REQUESTS:-20}" -le 200 ] || return 1
  [ "${PROXY_MAX_BYTES:-33554432}" -le 1073741824 ] && [ "${PROXY_SMALL_MAX_BYTES:-65536}" -le 1048576 ] || return 1
}

_proxy_probe_impl() (
  # May run on the actual client through a --probe-command SSH wrapper.
  # curl has bounded duration and response sizes; failures remain failures.
  set -uo pipefail
  local tmp bulk_pid bulk_rc=0 rc http bytes elapsed sample i sample_bytes=0 curl_banner
  # Older curl cannot stop an unknown-length/chunked response at --max-filesize.
  curl_banner="$(curl --disable --version 2>/dev/null)" || curl_banner=""
  if ! [[ "$curl_banner" =~ ^curl[[:space:]]+([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})([[:space:]+-]|$) ]] ||
    ! ((10#${BASH_REMATCH[1]} > 8 || (10#${BASH_REMATCH[1]} == 8 && 10#${BASH_REMATCH[2]} >= 4))); then
    printf 'proxy probe requires curl >= 8.4.0 for bounded response bodies; upgrade curl on the probe host.\n' >&2
    exit 1
  fi
  tmp="$(mktemp -d)" || exit 1
  trap '[ -z "${bulk_pid:-}" ] || kill "$bulk_pid" 2>/dev/null || true; rm -f "$tmp/bulk" "$tmp/samples"; rmdir "$tmp"' EXIT
  local max_bytes="${PROXY_MAX_BYTES:-33554432}" small_max="${PROXY_SMALL_MAX_BYTES:-65536}"
  local duration="${PROXY_DURATION:-10}" count="${PROXY_REQUESTS:-20}"
  # Ignore curlrc and NO_PROXY so the declared SOCKS path is actually measured.
  local common=(--disable --silent --show-error --socks5-hostname "${PROXY_HOST}:${PROXY_PORT:-1080}" --noproxy "" --connect-timeout 5 --max-time "$duration" --output /dev/null)
  curl "${common[@]}" --range "0-$((max_bytes-1))" --max-filesize "$max_bytes" \
    --write-out '%{http_code} %{size_download} %{time_total}\n' "$PROXY_TEST_URL" > "$tmp/bulk" &
  bulk_pid=$!
  : > "$tmp/samples"
  for ((i=0;i<count;i++)); do
    # Only classify samples as loaded while the bulk request is still active.
    kill -0 "$bulk_pid" 2>/dev/null || break
    rc=0
    sample="$(curl "${common[@]}" --max-filesize "$small_max" \
      --write-out '%{http_code} %{size_download} %{time_total}\n' "${PROXY_SMALL_URL:-$PROXY_TEST_URL}")" || rc=$?
    read -r http bytes elapsed <<< "$sample"
    [[ "${bytes:-}" =~ ^[0-9]+$ ]] || bytes=0
    sample_bytes=$((sample_bytes+bytes))
    # A request which finishes after the bulk ended is not a loaded sample.
    # Its received bytes still belong to this measurement's traffic ledger.
    kill -0 "$bulk_pid" 2>/dev/null || break
    jq -cn --argjson rc "$rc" --arg http "${http:-000}" --argjson elapsed "${elapsed:-0}" \
      '{ok:($rc==0 and ($http=="200" or $http=="206")),ms:($elapsed*1000)}' >> "$tmp/samples" || exit 1
  done
  wait "$bulk_pid" || bulk_rc=$?
  bulk_pid=""
  read -r http bytes elapsed < "$tmp/bulk"
  [[ "${bytes:-}" =~ ^[0-9]+$ ]] || exit 1
  [ "$bulk_rc" -eq 0 ] && { [ "$http" = 200 ] || [ "$http" = 206 ]; } || exit 1
  [ "$bytes" -gt 0 ] && [ "$bytes" -le "$max_bytes" ] || exit 1
  jq -sc --argjson bulk "$bytes" --argjson small "$sample_bytes" --argjson seconds "${elapsed:-0}" '
    def percentile($p): sort|.[((length*$p|ceil)-1)];
    . as $s | [$s[]|select(.ok)|.ms] as $lat |
    if ($s|length)<10 or ($lat|length)<10 or $seconds<=0 then error("insufficient loaded samples") else
    {status:"ok",requests:($s|length),errors:([$s[]|select(.ok|not)]|length),
     p50_ms:($lat|percentile(0.5)),p95_ms:($lat|percentile(0.95)),
     download_mbps:($bulk*8/$seconds/1000000),bytes:($bulk+$small)} end
  ' "$tmp/samples"
)

_prepare_proxy_probe(){
  [ -z "$AT_PROBE_COMMAND" ] && [ -n "${PROXY_HOST:-}" ] || return 0
  AT_PROBE_COMMAND="$SESSION_DIR/proxy-probe.sh"
  {
    printf '#!/usr/bin/env bash\n'
    local name
    for name in PROXY_HOST PROXY_PORT PROXY_TEST_URL PROXY_SMALL_URL PROXY_MAX_BYTES PROXY_SMALL_MAX_BYTES PROXY_REQUESTS; do
      printf '%s=%q\n' "$name" "${!name:-}"
    done
    printf 'PROXY_DURATION=%q\n' "$AT_DURATION"
    declare -f _proxy_probe_impl
    printf '_proxy_probe_impl\n'
  } > "$AT_PROBE_COMMAND" && chmod 700 "$AT_PROBE_COMMAND"
}

_add_candidate(){
  local cc="$1" w="$2" r="$3" label="$4" i
  [ "${#CAND_CC[@]}" -lt "$AT_MAX_CANDIDATES" ] || return 0
  for ((i=0;i<${#CAND_CC[@]};i++)); do
    [ "${CAND_CC[$i]}:${CAND_WMEM[$i]}:${CAND_RMEM[$i]}" != "$cc:$w:$r" ] || return 0
  done
  i=${#CAND_CC[@]}
  jq -cn --arg candidate_label "$label" --arg cc "$cc" --arg q "$CURRENT_QDISC" --arg w "$w" --arg r "$r" \
    '{label:$candidate_label,cc:$cc,qdisc:$q,wmem_max:$w,rmem_max:$r}' >> "$SESSION_DIR/candidates.jsonl" || return 1
  CAND_CC[$i]="$cc"; CAND_QDISC[$i]="$CURRENT_QDISC"
  CAND_WMEM[$i]="$w"; CAND_RMEM[$i]="$r"; CAND_LABEL[$i]="$label"
  return 0
}

_record_decision(){
  jq -cn --arg candidate "${MEASURE_CANDIDATE:-original}" --arg stage "$1" --arg status "$2" --arg reason "$3" \
    '{candidate:$candidate,stage:$stage,status:$status,reason:$reason}' >> "$SESSION_DIR/decisions.jsonl"
}

_buffer_candidates(){
  # Refine the best screening CC, still compared against the original baseline.
  [ "$BUFFER_LIMITED" -eq 1 ] && [ "$AT_DIRECTION" = download ] || return 0
  known_positive "$BASELINE_RTT" || return 0
  local cc="$1" mem_kb headroom cap current factor value max_cgroup used_cgroup
  mem_kb="$(awk '/MemAvailable/{print $2;exit}' /proc/meminfo)"
  [[ "$mem_kb" =~ ^[0-9]+$ ]] || return 0
  headroom=$((mem_kb*1024))
  if [ -r /sys/fs/cgroup/memory.max ] && [ -r /sys/fs/cgroup/memory.current ]; then
    read -r max_cgroup < /sys/fs/cgroup/memory.max
    read -r used_cgroup < /sys/fs/cgroup/memory.current
    if [[ "$max_cgroup" =~ ^[0-9]+$ && "$used_cgroup" =~ ^[0-9]+$ ]]; then
      [ "$max_cgroup" -gt "$used_cgroup" ] || return 0
      [ $((max_cgroup-used_cgroup)) -ge "$headroom" ] || headroom=$((max_cgroup-used_cgroup))
    fi
  fi
  # At most 25% headroom across expected sockets, allowing 2x bookkeeping.
  cap=$((headroom / AT_EXPECTED_CONNECTIONS / 8))
  [ "$cap" -le $((AT_BUFFER_MAX_MIB*1024*1024)) ] || cap=$((AT_BUFFER_MAX_MIB*1024*1024))
  current="$(sysctl_value net.ipv4.tcp_wmem | awk '{print $3}')"
  for factor in 1.5 2; do
    value="$(awk -v t="$BASELINE_THROUGHPUT" -v r="$BASELINE_RTT" -v f="$factor" 'BEGIN{printf "%.0f",t*r/8*f}')"
    [ "$value" -le "$cap" ] || value="$cap"
    [ "$value" -gt "$current" ] || continue
    _add_candidate "$cc" "$value" "" "CC=$cc,wmem_max=$value" || return 1
  done
}

_auto_main(){
  RUN_REASON=internal_error
  local cmd baseline candidate cc idx rc best_screen_cc score qualified
  local current_cc available_cc
  _validate_auto_options || { RUN_REASON=invalid_options; return 1; }
  require_root || { RUN_REASON=root_required; return 1; }
  for cmd in sysctl awk iperf3 tc ip jq timeout flock cmp mktemp sha256sum; do
    has "$cmd" || { red "缺少命令: $cmd"; RUN_REASON=missing_dependency; return 1; }
  done
  if [ -n "${PROXY_HOST:-}" ]; then has curl || { RUN_REASON=curl_required; return 1; }; fi
  if [ -n "$AT_PROXY_SERVICE" ]; then
    has systemctl && systemctl is-active --quiet "$AT_PROXY_SERVICE" || { RUN_REASON=proxy_service_not_active; return 1; }
  fi
  [ ! -f "$MYSTERY_CONF" ] || { RUN_REASON=legacy_experimental_config_present; return 1; }
  BUDGET_LIMIT_BYTES="$(awk -v g="$AT_BUDGET_GIB" 'BEGIN{printf "%.0f",g*1073741824}')"
  RUN_START="$(date +%s)"
  lock_acquire || { RUN_REASON=lock_or_unrecovered_session; return 1; }
  check_actual_qdisc || { RUN_REASON=route_or_queue_unknown; return 1; }
  if [ "$ACTUAL_IFACE" = lo ] && [ "$AT_NO_PERSIST" -ne 1 ]; then RUN_REASON=loopback_requires_no_persist; return 1; fi
  session_create || { RUN_REASON=snapshot_failed; return 1; }
  watchdog_start "$SESSION_DIR/restore.sh" || { RUN_REASON=watchdog_failed; return 1; }
  _prepare_proxy_probe || { RUN_REASON=proxy_probe_setup_failed; return 1; }
  if [ -n "$AT_PROXY_SERVICE" ]; then _restart_proxy_service || { RUN_REASON=proxy_service_restart_failed; return 1; }; fi
  local rate_display="${AT_RATE_MBPS} Mbps"
  [ "$AT_RATE_MBPS" -ne 0 ] || rate_display=不限速
  printf '会话: %s\n目标: %s；方向: %s；速率上限: %s；载荷预算: %s GiB\n' "$SESSION_DIR" "$AT_TARGET" "$AT_DIRECTION" "$rate_display" "$AT_BUDGET_GIB"
  if [ "$AT_RATE_MBPS" -eq 0 ]; then
    printf '不限速；每轮 %s MiB 载荷；至少 %s 秒样本；单轮超时 %s 秒。\n' "$AT_SAMPLE_MIB" "$AT_DURATION" "$((AT_DURATION+5))"
  fi
  session_log "start target=$AT_TARGET direction=$AT_DIRECTION no_persist=$AT_NO_PERSIST"
  MEASURE_STAGE=baseline; MEASURE_ROLE=baseline; MEASURE_CANDIDATE=original
  if ! run_iperf3_json "$AT_TARGET" "$AT_DIRECTION" "$AT_DURATION" 1; then
    RUN_REASON="${MEASURE_REASON:-baseline_failed}"
    case "$RUN_REASON" in *budget*) RUN_RESULT=no_change; return 2 ;; esac
    return 1
  fi
  baseline="$(_current_measurement_json)"
  if ! _measurement_gates "$baseline" "$baseline"; then RUN_REASON="baseline_$SCORE_REJECT_REASON"; return 1; fi
  printf '%s\n' "$baseline" > "$SESSION_DIR/baseline.json"
  BASELINE_THROUGHPUT="$IPERF_THROUGHPUT"; BASELINE_RETR="$IPERF_RETR"
  BASELINE_RTT="$IPERF_RTT"; BASELINE_BYTES="$IPERF_BYTES"
  run_diagnostic_buffer_test "$AT_TARGET" "$AT_DIRECTION" "$AT_DURATION"
  current_cc="$(sysctl_value net.ipv4.tcp_congestion_control)"
  CURRENT_QDISC="$(sysctl_value net.core.default_qdisc)"
  available_cc="$(sysctl_value net.ipv4.tcp_available_congestion_control)"
  CAND_CC=(); CAND_QDISC=(); CAND_WMEM=(); CAND_RMEM=(); CAND_LABEL=()
  # Local CC does not govern a remote sender's congestion window.
  if [ "$AT_DIRECTION" = download ]; then
    for cc in bbr cubic; do
      [ "$cc" = "$current_cc" ] && continue
      if [[ " $available_cc " == *" $cc "* ]]; then
        _add_candidate "$cc" "" "" "CC=$cc" || { RUN_REASON=candidate_plan_failed; return 1; }
      fi
    done
  fi
  # Receiving-side buffer evidence is deliberately not inferred from -P4.
  # If no sending CC candidate exists, measured sndbuf evidence may still refine.
  if [ "${#CAND_CC[@]}" -eq 0 ]; then
    _buffer_candidates "$current_cc" || { RUN_REASON=candidate_plan_failed; return 1; }
  fi
  RES_SCORE=(); SHORTLIST=()
  best_screen_cc="$current_cc"; local best_score=1 buffer_added=0
  for ((idx=0;idx<${#CAND_CC[@]};idx++)); do
    MEASURE_CANDIDATE="${CAND_LABEL[$idx]}"
    MEASURE_REASON=""
    rc=0
    apply_candidate_verified "${CAND_CC[$idx]}" "${CAND_QDISC[$idx]}" "${CAND_WMEM[$idx]}" "${CAND_RMEM[$idx]}" || rc=$?
    if [ "$rc" -eq 2 ]; then RUN_REASON=baseline_restore_failed; return 1; fi
    if [ "$rc" -ne 0 ]; then
      session_log "invalid_candidate=$MEASURE_CANDIDATE reason=${MEASURE_REASON:-apply_failed}"
      _record_decision screening invalid "${MEASURE_REASON:-apply_failed}" || return 1
      continue
    fi
    MEASURE_STAGE=screening; MEASURE_ROLE=candidate
    if ! run_iperf3_json "$AT_TARGET" "$AT_DIRECTION" "$AT_DURATION" 1; then
      session_log "screening_failed=$MEASURE_CANDIDATE reason=$MEASURE_REASON"
      _record_decision screening failed "$MEASURE_REASON" || return 1
      case "$MEASURE_REASON" in *budget*) break ;; esac
      continue
    fi
    candidate="$(_current_measurement_json)"
    if _measurement_gates "$baseline" "$candidate"; then
      score="$(jq -nr --argjson b "$baseline" --argjson c "$candidate" 'def tp: if .proxy.status=="ok" then .proxy.download_mbps else .tp end; ($c|tp)/($b|tp)')"
      qualified="$(jq -nr --argjson b "$baseline" --argjson c "$candidate" --argjson gain "$AT_MIN_RTT_GAIN" '
        def tp: if .proxy.status=="ok" then .proxy.download_mbps else .tp end;
        def lat: if .proxy.status=="ok" then .proxy.p95_ms else .rtt end;
        ($c|tp)>($b|tp) or (($b|lat)>0 and ($c|lat)>0 and (1-($c|lat)/($b|lat))*100 >= $gain)')"
      if [ "$qualified" = true ]; then
        RES_SCORE[$idx]="$score"; SHORTLIST+=("$idx")
        if awk -v s="$score" -v b="$best_score" 'BEGIN{exit !(s>b)}'; then best_score="$score"; best_screen_cc="${CAND_CC[$idx]}"; fi
      fi
      _record_decision screening "$qualified" screening_gain || return 1
    else
      session_log "screen_rejected=$MEASURE_CANDIDATE reason=$SCORE_REJECT_REASON"
      _record_decision screening rejected "$SCORE_REJECT_REASON" || return 1
    fi
    # Once CC screening is complete, add a small buffer refinement on its leader.
    if [ "$buffer_added" -eq 0 ] && [ "$idx" -eq $((${#CAND_CC[@]}-1)) ]; then
      buffer_added=1
      _buffer_candidates "$best_screen_cc" || { RUN_REASON=candidate_plan_failed; return 1; }
    fi
  done
  session_restore_runtime || { RUN_REASON=baseline_restore_failed; return 1; }
  if [ "${#SHORTLIST[@]}" -eq 0 ]; then
    RUN_RESULT=no_change; RUN_REASON="${MEASURE_REASON:-no_admissible_candidate}"; return 2
  fi
  # Small finite shortlist, sorted only after hard gates. First accepted option
  # satisfies the goal of acceptable improvement, not a global optimum claim.
  local sorted="" i j winner=-1
  for i in "${SHORTLIST[@]}"; do printf '%s\t%s\n' "${RES_SCORE[$i]}" "$i"; done > "$SESSION_DIR/shortlist.tsv"
  sorted="$(sort -k1,1nr "$SESSION_DIR/shortlist.tsv" | head -n "$AT_MAX_SHORTLIST" | awk '{print $2}')"
  for i in $sorted; do
    MEASURE_CANDIDATE="${CAND_LABEL[$i]}"; RETEST_STAGE=retest; MEASURE_REASON=""
    rc=0
    interleaved_retest "$AT_TARGET" "$AT_DIRECTION" "$AT_DURATION" \
      "${CAND_CC[$i]}" "${CAND_QDISC[$i]}" "${CAND_WMEM[$i]}" "${CAND_RMEM[$i]}" "$AT_RETEST_ROUNDS" || rc=$?
    [ "$rc" -ne 2 ] || { RUN_REASON=baseline_restore_failed; return 1; }
    printf '%s\n' "$RETEST_STATS" > "$SESSION_DIR/retest-$i.json"
    RETEST_RESULTS="$(jq -c --arg candidate "$MEASURE_CANDIDATE" --argjson complete "$([ "$rc" -eq 0 ] && echo true || echo false)" \
      --argjson stats "$RETEST_STATS" '.+[{candidate:$candidate,completed:$complete,statistics:$stats}]' <<< "$RETEST_RESULTS")" || return 1
    if [ "$rc" -eq 0 ] && is_reliable_improvement; then winner="$i"; break; fi
    session_log "retest_rejected=$MEASURE_CANDIDATE reason=${MEASURE_REASON:-$IMPROVEMENT_REASON}"
  done
  [ "$winner" -ge 0 ] || { RUN_RESULT=no_change; RUN_REASON="${MEASURE_REASON:-insufficient_or_noisy_improvement}"; return 2; }
  # Fresh holdout data. A failed holdout is terminal: do not keep trying winners.
  RETEST_STAGE=acceptance; MEASURE_REASON=""; rc=0; ACCEPTANCE_ATTEMPTED=true
  interleaved_retest "$AT_TARGET" "$AT_DIRECTION" "$AT_DURATION" \
    "${CAND_CC[$winner]}" "${CAND_QDISC[$winner]}" "${CAND_WMEM[$winner]}" "${CAND_RMEM[$winner]}" "$AT_ACCEPT_ROUNDS" || rc=$?
  ACCEPTANCE_STATS="$RETEST_STATS"
  [ "$rc" -ne 0 ] || ACCEPTANCE_COMPLETED=true
  [ "$rc" -ne 2 ] || { RUN_REASON=baseline_restore_failed; return 1; }
  if [ "$rc" -ne 0 ] || ! is_reliable_improvement; then
    RUN_RESULT=no_change; RUN_REASON="acceptance_${MEASURE_REASON:-$IMPROVEMENT_REASON}"; return 2
  fi
  ACCEPTANCE_PASSED=true
  WINNER_CONFIG="$(jq -cn --arg cc "${CAND_CC[$winner]}" --arg q "${CAND_QDISC[$winner]}" \
    --arg w "${CAND_WMEM[$winner]}" --arg r "${CAND_RMEM[$winner]}" '{cc:$cc,qdisc:$q,wmem_max:$w,rmem_max:$r}')"
  RUN_SELECTED=true
  _finalize_and_persist "${CAND_CC[$winner]}" "${CAND_QDISC[$winner]}" "${CAND_WMEM[$winner]}" "${CAND_RMEM[$winner]}" || { RUN_REASON=final_apply_or_persist_failed; return 1; }
  [ "$RUN_COMMITTED" -eq 1 ] && return 0
  return 3
}

_at_cleanup(){
  # EXIT handler owns all normal, error and signal paths; never return to menu
  # with experimental parameters still active.
  local rc="$1" restored=0
  trap - EXIT INT TERM
  if [ "$rc" -ne 0 ] && [ "$RUN_COMMITTED" -eq 1 ]; then RUN_COMMITTED=0; fi
  if [ -n "$SESSION_DIR" ] && [ -s "$SESSION_DIR/snapshot.conf" ]; then
    if [ "$RUN_COMMITTED" -ne 1 ]; then
      if [ "$RUN_PERSIST_TOUCHED" -eq 1 ]; then _restore_orig_persistent || restored=1; fi
      session_restore_runtime || restored=1
      if [ "$restored" -eq 0 ]; then RUN_RESTORE_VERIFIED=true
      else RUN_RESULT=failed; RUN_REASON=restore_failed; rc=1; fi
    fi
    # A report is part of a successful commit. Roll back on report-write failure.
    if [ -f "$SESSION_DIR/original.json" ] && [ -f "$SESSION_DIR/measurements.jsonl" ] && ! _write_report; then
      RUN_RESULT=failed; RUN_REASON=report_failed; rc=1
      if [ "$RUN_COMMITTED" -eq 1 ]; then
        RUN_COMMITTED=0
        # A disk failure must not prevent restoring the still-writable runtime.
        _restore_orig_persistent || restored=1
        session_restore_runtime || restored=1
        if [ "$restored" -eq 0 ]; then RUN_RESTORE_VERIFIED=true
        else RUN_RESTORE_VERIFIED=false; fi
      fi
      _write_report || red '无法保存报告，请检查磁盘和会话目录。'
    fi
    if [ "$restored" -eq 0 ] && ! touch "$SESSION_DIR/complete"; then
      RUN_RESULT=failed; RUN_REASON=completion_marker_failed; rc=1
      if [ "$RUN_COMMITTED" -eq 1 ]; then
        RUN_COMMITTED=0
        _restore_orig_persistent || restored=1
        session_restore_runtime || restored=1
        if [ "$restored" -eq 0 ]; then RUN_RESTORE_VERIFIED=true
        else RUN_RESTORE_VERIFIED=false; fi
      fi
      _write_report || red '无法更新失败报告；会话未标记完成，请检查恢复状态。'
    fi
    session_log "result=$RUN_RESULT reason=$RUN_REASON restore_verified=$RUN_RESTORE_VERIFIED"
    if [ -f "$SESSION_DIR/report.json" ]; then printf 'REPORT=%s/report.json\n' "$SESSION_DIR"
    else printf 'SESSION=%s\n' "$SESSION_DIR"; fi
  fi
  watchdog_stop
  lock_release
  printf 'RESULT=%s\nREASON=%s\n' "$RUN_RESULT" "$RUN_REASON"
  exit "$rc"
}

auto_tune_flow() (
  # Isolate traps/FDs without throwing away measurement state via command substitution.
  umask 077
  SESSION_DIR=""; WATCHDOG_PID=""; LOCK_HELD=0
  BUDGET_USED_BYTES=0; BUDGET_LIMIT_BYTES=0; MEASURE_SEQ=0
  RUN_RESULT=failed; RUN_REASON=not_started; RUN_SELECTED=false; RUN_COMMITTED=0
  RUN_RESTORE_VERIFIED=false; RUN_PERSIST_TOUCHED=0; RUN_START="$(date +%s)"
  RETEST_STATS='{}'; RETEST_RESULTS='[]'; ACCEPTANCE_STATS=null
  ACCEPTANCE_ATTEMPTED=false; ACCEPTANCE_COMPLETED=false; ACCEPTANCE_PASSED=false; WINNER_CONFIG=null
  trap '_at_cleanup "$?"' EXIT
  trap 'RUN_RESULT=failed; RUN_REASON=interrupted; exit 1' INT TERM
  if [ "$AT_AUTO" -ne 1 ]; then
    read -rp 'iperf3 目标 IP/域名: ' AT_TARGET
    read -rp '方向 download=VPS发送 / upload=VPS接收 [download]: ' AT_DIRECTION
    AT_DIRECTION="${AT_DIRECTION:-download}"
  fi
  _auto_main
)


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


##############################################################################
# 远程节点自动调优（替代旧 remote_tune_flow）
##############################################################################

remote_auto_tune_flow(){
  red "SSH 多节点自动提交暂时关闭：请用 --target 单节点流程逐条路径测试。"
  printf 'RESULT=failed\nREASON=multi_node_commit_not_supported\n'
  return 1
}

# 单节点单次测试（支持方向和并发）
_remote_run_one_test(){
  local index="$1" target="$2" direction="${3:-download}" duration="${4:-20}" parallel="${5:-1}"
  local json bps retr rtt bytes server_log server_pid ssh_status ssh_error
  server_log="$(mktemp)"
  ssh_error="$(mktemp)"

  local iperf_args=("-c" "$target" "-J" "-t" "$duration")
  [ "$direction" = "download" ] && iperf_args+=("-R")
  [ "$parallel" -gt 1 ] && iperf_args+=("-P" "$parallel")
  local iperf_cmd="iperf3 ${iperf_args[*]}"

  iperf3 -s -1 >"$server_log" 2>&1 &
  server_pid=$!
  sleep 1

  json="$(ssh_node "$index" "$iperf_cmd" 2>"$ssh_error")"
  ssh_status=$?
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true

  if [ "$ssh_status" -ne 0 ] || ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    [ -s "$ssh_error" ] && { yellow "SSH/远程错误："; cat "$ssh_error"; }
    rm -f "$server_log" "$ssh_error"
    IPERF_THROUGHPUT=0; IPERF_RETR=0; IPERF_RTT=0; IPERF_BYTES=0
    return 1
  fi
  rm -f "$server_log" "$ssh_error"

  bps="$(printf '%s' "$json" | jq -r '.end.sum_received.bits_per_second // .end.sum.bits_per_second // 0')"
  retr="$(printf '%s' "$json" | jq -r '(.server_output_json.end.sum_sent.retransmits // .end.sum_sent.retransmits // 0)')"
  rtt="$(printf '%s' "$json" | jq -r '[.end.streams[]?.sender.mean_rtt // empty] | if length>0 then (add/length) else 0 end' 2>/dev/null || echo 0)"
  bytes="$(printf '%s' "$json" | jq -r '.end.sum_received.bytes // .end.sum.bytes // 0')"

  IPERF_THROUGHPUT="$(awk "BEGIN{printf \"%.2f\", ${bps:-0} / 1000000}")"
  IPERF_RETR="${retr:-0}"
  IPERF_RTT="$(awk "BEGIN{printf \"%.0f\", ${rtt:-0}}")"
  IPERF_BYTES="${bytes:-0}"
  _at_budget_add "${bytes:-0}"
  printf '%s %s %s\t%s Mbps\tRetr=%s\tRTT=%sus\n' \
    "${CAND_LABEL[$i]:-baseline}" "${NODE_LABEL[$index]}" \
    "$direction" "$IPERF_THROUGHPUT" "$IPERF_RETR" "$IPERF_RTT" >> "$SESSION_DIR/results.tsv"
  return 0
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
    echo "6. 本地/远程节点：自动调优（自动选参 + 持久化）"
    echo "7. SSH 多节点自动提交（暂时关闭，改用单目标测试）"
    echo "8. TCP 迷之调参（已废弃，仅生成预览）"
    echo
    green "[ 恢复 / 退出 ]"
    echo "9. 恢复最近自动调优会话的原配置"
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
      6) auto_tune_flow ;;
      7) remote_auto_tune_flow ;;
      8) mystery_tune_menu ;;
      9) restore_baseline ;;
      10) reset_to_initial_state ;;
      0) exit 0 ;;
      *) red "无效输入"; sleep 1 ;;
    esac
  done
}

##############################################################################
# CLI 参数解析
##############################################################################

_cli_error(){ printf 'tcptune: %s\nRESULT=failed\nREASON=invalid_options\n' "$*" >&2; exit 1; }
_parse_cli_args(){
  local run_auto=0 option value variable
  while [ $# -gt 0 ]; do
    option="$1"
    case "$option" in
      --auto-tune) AT_AUTO=1; run_auto=1; shift ;;
      --no-persist) AT_NO_PERSIST=1; shift ;;
      --target|--direction|--max-candidates|--duration|--budget-gib|--max-seconds|--rate-mbps|--sample-mib|--retest-rounds|--accept-rounds|--expected-connections|--buffer-max-mib|--probe-command|--proxy-service|--primary-node)
        [ $# -ge 2 ] && [[ "$2" != --* ]] || _cli_error "$option 缺少参数"
        value="$2"
        case "$option" in
          --target) variable=AT_TARGET ;;
          --direction) variable=AT_DIRECTION ;;
          --max-candidates) variable=AT_MAX_CANDIDATES ;;
          --duration) variable=AT_DURATION ;;
          --budget-gib) variable=AT_BUDGET_GIB ;;
          --max-seconds) variable=AT_MAX_SECONDS ;;
          --rate-mbps) variable=AT_RATE_MBPS ;;
          --sample-mib) variable=AT_SAMPLE_MIB ;;
          --retest-rounds) variable=AT_RETEST_ROUNDS ;;
          --accept-rounds) variable=AT_ACCEPT_ROUNDS ;;
          --expected-connections) variable=AT_EXPECTED_CONNECTIONS ;;
          --buffer-max-mib) variable=AT_BUFFER_MAX_MIB ;;
          --probe-command) variable=AT_PROBE_COMMAND ;;
          --proxy-service) variable=AT_PROXY_SERVICE ;;
          --primary-node) variable=AT_PRIMARY_NODE ;;
        esac
        printf -v "$variable" '%s' "$value"
        shift 2 ;;
      --help|-h)
        cat <<HELP
tcptune $SCRIPT_VERSION
用法: sudo bash tcptune.sh --auto-tune --target HOST [选项]
  --direction download|upload   download=VPS发送，upload=VPS接收
  --no-persist                  临时验证，结束后恢复（成功退出码3）
  --max-candidates N            最大候选数（默认$AT_MAX_CANDIDATES）
  --duration N                  限速测量时长；不限速时最短有效样本2..120秒（默认$AT_DURATION）
  --retest-rounds N             复测3..15对（默认$AT_RETEST_ROUNDS）
  --accept-rounds N             独立验收3..15对（默认$AT_ACCEPT_ROUNDS）
  --budget-gib N                应用层载荷预算（默认$AT_BUDGET_GIB GiB；非线速硬上限）
  --max-seconds N               会话时间预算（默认$AT_MAX_SECONDS秒）
  --rate-mbps N                 每流iperf速率上限；0=不限速（默认$AT_RATE_MBPS Mbps）
  --sample-mib N                不限速必填，每轮1..4096 MiB载荷；另预留128 KiB写块余量
  --expected-connections N      缓冲内存预算并发数（默认$AT_EXPECTED_CONNECTIONS）
  --buffer-max-mib N            单连接缓冲上限（默认$AT_BUFFER_MAX_MIB MiB）
  --probe-command PATH          可执行测量回调，仅路径，不使用eval
  --proxy-service UNIT          显式允许重启该代理服务以重建监听socket（会中断代理）
  --help                       帮助
退出码: 0=committed, 1=failed, 2=no_change, 3=validated且已恢复
SOCKS5验收: PROXY_HOST / PROXY_PORT / PROXY_TEST_URL / PROXY_SMALL_URL
实际队列保持原样；SSH多节点自动提交暂不可用。
HELP
        exit 0 ;;
      *) _cli_error "未知参数: $option" ;;
    esac
  done
  if [ "$run_auto" -eq 1 ]; then auto_tune_flow; exit $?; fi
}

# Only execute when run as a script, not when sourced (e.g., by tests)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _parse_cli_args "$@"
  menu
fi
