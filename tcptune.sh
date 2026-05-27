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
MIB=$((1024 * 1024))
MIN_WINDOW=87380
SSH_CONNECT_TIMEOUT=8

green(){ printf '\033[32m%s\033[0m\n' "$*"; }
red(){ printf '\033[31m%s\033[0m\n' "$*" >&2; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
pause(){ read -rp "按回车返回菜单..." _; }
has(){ command -v "$1" >/dev/null 2>&1; }
clear_screen(){ has clear && clear || printf '\n'; }

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
  green "当前 TCP / 队列参数"
  printf 'net.ipv4.tcp_available_congestion_control = %s\n' "$(sysctl_value net.ipv4.tcp_available_congestion_control)"
  printf 'net.ipv4.tcp_congestion_control = %s\n' "$(sysctl_value net.ipv4.tcp_congestion_control)"
  printf 'net.core.default_qdisc = %s\n' "$(sysctl_value net.core.default_qdisc)"
  printf 'net.ipv4.tcp_wmem = %s\n' "$(sysctl_value net.ipv4.tcp_wmem)"
  printf 'net.ipv4.tcp_rmem = %s\n' "$(sysctl_value net.ipv4.tcp_rmem)"
  printf 'net.core.wmem_max = %s\n' "$(sysctl_value net.core.wmem_max)"
  printf 'net.core.rmem_max = %s\n' "$(sysctl_value net.core.rmem_max)"
  echo
  green "当前接口 qdisc"
  if has tc; then
    tc qdisc show 2>/dev/null || yellow "无法读取 qdisc。"
  else
    yellow "缺少 tc（通常由 iproute2 提供）。"
  fi
  echo
  pause
}

install_base(){
  require_root || return 1
  if has apt-get; then
    apt-get update &&
      DEBIAN_FRONTEND=noninteractive apt-get install -y iperf3 iproute2 iputils-ping gawk jq openssh-client sshpass ca-certificates
  elif has apk; then
    apk add iperf3 iproute2 iputils gawk jq openssh-client sshpass ca-certificates
  elif has dnf; then
    dnf install -y iperf3 iproute iputils gawk jq openssh-clients sshpass ca-certificates
  elif has yum; then
    yum install -y iperf3 iproute iputils gawk jq openssh-clients sshpass ca-certificates
  else
    red "暂不支持当前包管理器，请手动安装 iperf3、iproute2、ping、awk、jq、ssh；密码模式另需 sshpass。"
    return 1
  fi
}

install_sshpass(){
  require_root || return 1
  green "正在安装密码认证所需组件：sshpass"
  if has apt-get; then
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y sshpass
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
  green "环境检查"
  local missing=0 command
  for command in sysctl awk iperf3 tc ping jq ssh; do
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
  if [ "$missing" -eq 1 ]; then
    echo
    read -rp "是否尝试安装缺失依赖？[y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] && install_base
  fi
  echo
  pause
}

install_optional_speed_tool(){
  local tool="$1"
  require_root || return 1
  green "正在尝试安装可选测速组件：$tool"
  if has apt-get; then
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "$tool"
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

tune_flow(){
  local host direction duration client_bw vps_bw rtt bottleneck bdp candidate
  local mib_value choice applied last_good="" next_step margin final_candidate command
  clear_screen
  green "文章方案一：BDP 起点 + iperf3 交互调优"
  echo "说明：脚本运行在 VPS；带宽与 RTT 必须对应客户端和该 VPS 的目标链路。"
  echo "公网 speedtest 的结果不会作为 BDP 输入。"
  echo
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
    green "TCP 调优管理脚本 - 文章方案一"
    echo "--------------------------------"
    echo "1. 环境检查 / 安装依赖"
    echo "2. 查看当前 TCP / qdisc 状态"
    echo "3. 手工客户端：BDP 与 iperf3 交互调优"
    echo "4. SSH 远程节点：下载方向自动测试调优"
    echo "5. 启动 iperf3 服务端（手工模式使用）"
    echo "6. 恢复调优前基线配置"
    echo "7. 独立公网测速（Ookla / LibreSpeed）"
    echo "0. 退出"
    echo
    read -rp "请输入选择 [0-7]: " num
    case "$num" in
      1) check_env ;;
      2) show_status ;;
      3) tune_flow ;;
      4) remote_tune_flow ;;
      5) start_iperf_server ;;
      6) restore_baseline ;;
      7) public_speedtest_menu ;;
      0) exit 0 ;;
      *) red "无效输入"; sleep 1 ;;
    esac
  done
}

menu
