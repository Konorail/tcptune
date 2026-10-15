#!/usr/bin/env bash
# Real flock/process lifecycle against fake sysctl/tc executables; no root or
# network required, and no host sysctl writes. Windows intentionally skips this.
if ! command -v flock >/dev/null 2>&1; then
  printf 'SKIP linux-process: real flock unavailable (requires Linux)\n'
  exit 0
fi
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

atomic_lock(){
  setup_mock; unset -f flock
  assert_ok 'first process acquires real flock' lock_acquire
  local rc=0
  ( LOCK_HELD=0; if lock_acquire; then lock_release; exit 7; else exit 0; fi ) > "$CASE_TMP/contender" 2>&1 || rc=$?
  assert_eq 'second process cannot acquire same lock' 0 "$rc"
  lock_release
  assert_ok 'lock becomes available after release' lock_acquire
  lock_release
}

watchdog_kill(){
  declare -f watchdog_start watchdog_stop > "$CASE_TMP/real-watchdog.sh"
  setup_mock; unset -f flock
  source "$CASE_TMP/real-watchdog.sh"
  install_mock_commands
  local pid i rc=0
  (
    RUN_START="$(date +%s)"
    if [ "${WATCHDOG_MODE:-kill}" = deadline ]; then AT_MAX_SECONDS=-28; trap '' TERM; fi
    lock_acquire && check_actual_qdisc && session_create || exit 1
    apply_cc bbr || exit 1
    watchdog_start "$SESSION_DIR/restore.sh" || exit 1
    printf '%s\n' "$SESSION_DIR" > "$CASE_TMP/ready"
    while :; do sleep 1; done
  ) > "$CASE_TMP/worker.log" 2>&1 &
  pid=$!
  for ((i=0;i<100;i++)); do [ ! -s "$CASE_TMP/ready" ] || break; sleep 0.1; done
  assert_ok 'watchdog worker reached applied state' test -s "$CASE_TMP/ready"
  if [ ! -s "$CASE_TMP/ready" ]; then kill -KILL "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; return 1; fi
  SESSION_DIR="$(cat "$CASE_TMP/ready")"
  assert_eq 'candidate applied before kill' bbr "$(sysctl_value net.ipv4.tcp_congestion_control)"
  if [ "${WATCHDOG_MODE:-kill}" = kill ]; then
    kill -KILL "$pid"
    wait "$pid" 2>/dev/null || rc=$?
  fi
  for ((i=0;i<150;i++)); do [ ! -f "$SESSION_DIR/complete" ] || break; sleep 0.1; done
  assert_ok 'watchdog marks verified restoration after SIGKILL' test -f "$SESSION_DIR/complete"
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_eq 'watchdog restored original CC' cubic "$(sysctl_value net.ipv4.tcp_congestion_control)"
  assert_ok 'watchdog preserved persistent bytes' cmp -s "$CONF" "$CASE_TMP/original.conf"
}
watchdog_deadline(){ WATCHDOG_MODE=deadline; watchdog_kill; }

run_case atomic-real-flock atomic_lock
run_case killed-parent-watchdog watchdog_kill
run_case hung-parent-deadline watchdog_deadline
finish_suite
