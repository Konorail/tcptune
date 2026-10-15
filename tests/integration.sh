#!/usr/bin/env bash
# integration.sh — mock-based integration tests for the full auto_tune_flow.
# Tests are isolated: no real network, no real sysctl writes, no root required.
# All external calls are stubbed. Run with: bash tests/integration.sh

set -u
PASS=0; FAIL=0; SKIP=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TCPTUNE="${SCRIPT_DIR}/../tcptune.sh"

#############################################################################
# Test helpers
#############################################################################
assert_eq(){ local d="$1" e="$2" a="$3"
  if [ "$e" = "$a" ]; then printf '  PASS: %s\n' "$d"; (( PASS++ )); return 0
  else printf '  FAIL: %s: expected "%s" got "%s"\n' "$d" "$e" "$a"; (( FAIL++ )); return 1; fi
}
assert_zero(){ local d="$1" v="$2"
  if [ "$v" -eq 0 ] 2>/dev/null; then printf '  PASS: %s\n' "$d"; (( PASS++ )); return 0
  else printf '  FAIL: %s: expected 0 got "%s"\n' "$d" "$v"; (( FAIL++ )); return 1; fi
}
assert_nonzero(){ local d="$1" v="$2"
  if [ "${v:-0}" -ne 0 ] 2>/dev/null; then printf '  PASS: %s\n' "$d"; (( PASS++ )); return 0
  else printf '  FAIL: %s: expected non-zero got "%s"\n' "$d" "$v"; (( FAIL++ )); return 1; fi
}

#############################################################################
# Set up stub environment shared by all tests.
# Load tcptune.sh WITHOUT executing main (BASH_SOURCE guard must be active).
#############################################################################
_load_tcptune(){
  # Source first (guard keeps menu from running); stubs are defined after
  # shellcheck source=../tcptune.sh
  source "$TCPTUNE" 2>/dev/null

  # Override after sourcing so tcptune.sh definitions don't win
  sysctl(){ :; }
  sysctl_value(){
    case "$1" in
      net.ipv4.tcp_congestion_control) echo "cubic" ;;
      net.ipv4.tcp_available_congestion_control) echo "cubic bbr reno" ;;
      net.core.default_qdisc) echo "fq_codel" ;;
      net.ipv4.tcp_wmem) echo "4096 16384 4194304" ;;
      net.ipv4.tcp_rmem) echo "4096 87380 6291456" ;;
      *) echo "0" ;;
    esac
  }
  require_root(){ return 0; }
  lock_acquire(){ LOCK_HELD=1; return 0; }
  lock_release(){ LOCK_HELD=0; return 0; }
  watchdog_start(){ WATCHDOG_PID=0; return 0; }
  watchdog_stop(){ WATCHDOG_PID=""; return 0; }
  clear_screen(){ :; }
  pause(){ :; }
  # stub has() so the dependency check does not fail in a test environment without iperf3
  has(){ return 0; }
  check_actual_qdisc(){ ACTUAL_IFACE="eth0"; ACTUAL_QDISC="fq_codel"; }
  run_diagnostic_buffer_test(){ BUFFER_LIMITED=0; return 0; }
  ping(){ echo "rtt min/avg/max/mdev = 10.0/15.0/20.0/1.0 ms"; }
  session_log(){ :; }
  # apply stubs: succeed by default; tests override _APPLY_CC_FAIL=1 to force failure
  apply_cc(){    [ "${_APPLY_CC_FAIL:-0}"    -eq 1 ] && return 1; return 0; }
  apply_qdisc(){ [ "${_APPLY_QDISC_FAIL:-0}" -eq 1 ] && return 1; return 0; }
  apply_wmem(){  return 0; }
  apply_rmem(){  return 0; }
  # persist stub: succeed by default; tests set _PERSIST_FAIL=1 to force failure
  persist_final_atomic(){ [ "${_PERSIST_FAIL:-0}" -eq 1 ] && return 1; return 0; }
  # restore stub: always succeed
  session_restore_runtime(){ return 0; }
  # session_create stub: create a real temp dir but with controlled content
  session_create(){
    _setup_session
    return 0
  }
}

#############################################################################
# create a temp session dir and wire globals for a test run
#############################################################################
_setup_session(){
  local tmpdir
  tmpdir="$(mktemp -d)"
  SESSION_DIR="$tmpdir"
  mkdir -p "$SESSION_DIR"
  # snapshot.conf used in before/after compare display
  printf 'net.ipv4.tcp_congestion_control = cubic\nnet.core.default_qdisc = fq_codel\n' \
    > "$SESSION_DIR/snapshot.conf"
  # orig_persistent.conf
  printf '' > "$SESSION_DIR/orig_persistent.conf"
  printf 'absent' > "$SESSION_DIR/orig_persistent.status"
  # pre-create restore.sh so watchdog / restore calls don't fail
  printf '#!/bin/bash\necho restore\n' > "$SESSION_DIR/restore.sh"
  BUDGET_USED_BYTES=0
  AT_BUDGET_GIB=20
}
_cleanup_session(){ rm -rf "${SESSION_DIR:-/tmp/_never}"; SESSION_DIR=""; }

#############################################################################
# Helpers to simulate iperf3 results
# Usage: _mock_iperf3 <call_number> [tp_mbps retr rtt_us bytes]
# Caller sets _MOCK_TP / _MOCK_RETR / _MOCK_RTT / _MOCK_BYTES arrays;
# run_iperf3_json is redefined to pop from the front of those arrays.
#############################################################################
_MOCK_CALLS=0
_MOCK_TP=()
_MOCK_RETR=()
_MOCK_RTT=()
_MOCK_BYTES=()
_MOCK_FAIL=()  # indices (0-based) at which to fail

_mock_run_iperf3_json(){
  local idx="$_MOCK_CALLS"
  _MOCK_CALLS=$(( _MOCK_CALLS + 1 ))
  # Check if this call index should fail
  local _f
  for _f in "${_MOCK_FAIL[@]:-}"; do
    [ "$_f" = "$idx" ] && return 1
  done
  IPERF_THROUGHPUT="${_MOCK_TP[$idx]:-100}"
  IPERF_RETR="${_MOCK_RETR[$idx]:-0}"
  IPERF_RTT="${_MOCK_RTT[$idx]:-50000}"
  IPERF_BYTES="${_MOCK_BYTES[$idx]:-250000000}"
  _at_budget_add "${IPERF_BYTES:-0}"
  return 0
}

#############################################################################
# stub apply functions (default: success; override with apply_cc_FAIL=1 etc)
#############################################################################
_APPLY_CC_FAIL=0
_APPLY_QDISC_FAIL=0
apply_cc(){    [ "$_APPLY_CC_FAIL"    -eq 1 ] && return 1; return 0; }
apply_qdisc(){ [ "$_APPLY_QDISC_FAIL" -eq 1 ] && return 1; return 0; }
apply_wmem(){  return 0; }
apply_rmem(){  return 0; }

#############################################################################
# stub persist / session restore
#############################################################################
_PERSIST_FAIL=0
persist_final_atomic(){ [ "$_PERSIST_FAIL" -eq 1 ] && return 1; return 0; }
session_restore_runtime(){ return 0; }
session_create(){
  _setup_session
  return 0
}
_at_cleanup(){ return 0; }

#############################################################################
# Override sysctl_value to generate exactly 1 candidate (CC=bbr only).
# Call this after _load_tcptune in tests that need predictable mock data:
#   call 0 = baseline, call 1 = bbr screening, calls 2-7 = retest (3 pairs).
#############################################################################
_single_cand_env(){
  sysctl_value(){
    case "$1" in
      net.ipv4.tcp_congestion_control) echo "cubic" ;;
      net.ipv4.tcp_available_congestion_control) echo "cubic bbr" ;;
      net.core.default_qdisc) echo "fq" ;;  # already fq → no fq candidate generated
      net.ipv4.tcp_wmem) echo "4096 16384 4194304" ;;
      net.ipv4.tcp_rmem) echo "4096 87380 6291456" ;;
      *) echo "0" ;;
    esac
  }
}

#############################################################################
# Run auto_tune_flow in --auto-tune mode and capture output + exit code.
# Uses a temp file to avoid a nested subshell (arrays are not copied into $()).
#############################################################################
_run_auto(){
  AT_AUTO=1
  AT_TARGET="192.0.2.1"
  AT_DIRECTION="download"
  AT_DURATION=1
  AT_MAX_CANDIDATES=4
  AT_RETEST_ROUNDS=3
  AT_MAX_SHORTLIST=3
  AT_MIN_TP_GAIN=5
  AT_MIN_RTT_GAIN=20
  AT_MAX_RTT_FACTOR=200
  AT_EXIT_COMMITTED=0
  AT_EXIT_FAILED=1
  AT_EXIT_NO_CHANGE=2
  run_iperf3_json(){ _mock_run_iperf3_json "$@"; }
  _MOCK_CALLS=0
  RESULT_LINE=""
  local _out_file _rc
  _out_file="$(mktemp)"
  auto_tune_flow > "$_out_file" 2>/dev/null
  _rc=$?
  RESULT_LINE="$(grep '^RESULT=' "$_out_file" | tail -1)"
  rm -f "$_out_file"
  return $_rc
}

##############################################################################
# TEST 1: committed — candidate +10% throughput, passes screening + retest
# 1 candidate (bbr): call 0=baseline, call 1=screening, calls 2-7=retest pairs
##############################################################################
echo "=== 1. committed path: +10% throughput ==="
(
  _load_tcptune; _single_cand_env
  _APPLY_CC_FAIL=0; _PERSIST_FAIL=0; _MOCK_FAIL=()
  #  idx 0: baseline=100 Mbps
  #  idx 1: bbr screening=110 Mbps (+10%, score>1, qualifies)
  #  idx 2-7: retest 3 pairs (base=100, cand=110 each)
  _MOCK_TP=(    100  110  100 110  100 110  100 110 )
  _MOCK_RETR=(  0    0    0   0    0   0    0   0   )
  _MOCK_RTT=(   50000 50000 50000 50000 50000 50000 50000 50000 )
  _MOCK_BYTES=( 250000000 275000000 250000000 275000000 250000000 275000000 250000000 275000000 )
  _run_auto; rc=$?
  assert_eq "exit code is AT_EXIT_COMMITTED(0)" "0" "$rc"
  assert_eq "RESULT=committed" "RESULT=committed" "$RESULT_LINE"
  _cleanup_session
)

##############################################################################
# TEST 2: no_change — all candidates rejected in screening (tp only +2%)
# 1 candidate (bbr): call 0=baseline, call 1=screening
##############################################################################
echo "=== 2. no_change: all candidates below threshold in screening ==="
(
  _load_tcptune; _single_cand_env
  _APPLY_CC_FAIL=0; _PERSIST_FAIL=0; _MOCK_FAIL=()
  # baseline 100 Mbps, bbr candidate 102 (+2% → below AT_MIN_TP_GAIN=5, no RTT improvement)
  _MOCK_TP=(    100 102 )
  _MOCK_RETR=(  0   0   )
  _MOCK_RTT=(   50000 50000 )
  _MOCK_BYTES=( 250000000 255000000 )
  _run_auto; rc=$?
  assert_eq "exit code is AT_EXIT_NO_CHANGE(2)" "2" "$rc"
  assert_eq "RESULT=no_change" "RESULT=no_change" "$RESULT_LINE"
  _cleanup_session
)

##############################################################################
# TEST 3: no_change — candidate passes screening (+10%) but retest median only +2%
# 1 candidate: call 0=baseline, 1=screening, calls 2-7=retest (base=100, cand=102)
##############################################################################
echo "=== 3. no_change: retest insufficient improvement ==="
(
  _load_tcptune; _single_cand_env
  _APPLY_CC_FAIL=0; _PERSIST_FAIL=0; _MOCK_FAIL=()
  # screening: 110 (+10% → passes), retest: 102 (+2% → below threshold)
  _MOCK_TP=(    100 110  100 102  100 102  100 102 )
  _MOCK_RETR=(  0   0    0   0    0   0    0   0   )
  _MOCK_RTT=(   50000 50000 50000 50000 50000 50000 50000 50000 )
  _MOCK_BYTES=( 250000000 275000000 250000000 255000000 250000000 255000000 250000000 255000000 )
  _run_auto; rc=$?
  assert_eq "exit code is AT_EXIT_NO_CHANGE(2)" "2" "$rc"
  assert_eq "RESULT=no_change" "RESULT=no_change" "$RESULT_LINE"
  _cleanup_session
)

##############################################################################
# TEST 4: failed — baseline test fails (call 0 fails)
##############################################################################
echo "=== 4. failed: baseline iperf3 fails ==="
(
  _load_tcptune; _single_cand_env
  _APPLY_CC_FAIL=0; _PERSIST_FAIL=0
  _MOCK_FAIL=( 0 )  # call index 0 (baseline) fails
  _MOCK_TP=(   100 110 )
  _MOCK_RETR=( 0   0   )
  _MOCK_RTT=(  50000 50000 )
  _MOCK_BYTES=( 250000000 275000000 )
  _run_auto; rc=$?
  assert_eq "exit code is AT_EXIT_FAILED(1)" "1" "$rc"
  assert_eq "RESULT=failed" "RESULT=failed" "$RESULT_LINE"
  _cleanup_session
)

##############################################################################
# TEST 5: no_change — apply_cc fails, candidate skipped
##############################################################################
echo "=== 5. no_change: apply_cc fails for all candidates ==="
(
  _load_tcptune; _single_cand_env
  _APPLY_CC_FAIL=0; _PERSIST_FAIL=0; _MOCK_FAIL=()
  # apply_cc always fails → candidate is skipped, no iperf3 call for candidate
  # Only baseline (1 call) → no candidates qualify → no_change
  apply_cc(){ return 1; }
  _MOCK_TP=(    100 )
  _MOCK_RETR=(  0   )
  _MOCK_RTT=(   50000 )
  _MOCK_BYTES=( 250000000 )
  _run_auto; rc=$?
  assert_eq "exit code is AT_EXIT_NO_CHANGE(2)" "2" "$rc"
  assert_eq "RESULT=no_change" "RESULT=no_change" "$RESULT_LINE"
  _cleanup_session
)

##############################################################################
# TEST 6: failed — persist fails after retest confirms improvement
##############################################################################
echo "=== 6. failed: persist_final_atomic fails ==="
(
  _load_tcptune; _single_cand_env
  _APPLY_CC_FAIL=0; _PERSIST_FAIL=1; _MOCK_FAIL=()
  # baseline 100, screening 110, retest 3 pairs all 110
  _MOCK_TP=( 100 110  100 110  100 110  100 110 )
  _MOCK_RETR=( 0 0 0 0 0 0 0 0 )
  _MOCK_RTT=( 50000 50000 50000 50000 50000 50000 50000 50000 )
  _MOCK_BYTES=( 250000000 275000000 250000000 275000000 250000000 275000000 250000000 275000000 )
  _run_auto; rc=$?
  assert_eq "exit code is AT_EXIT_FAILED(1)" "1" "$rc"
  assert_eq "RESULT=failed" "RESULT=failed" "$RESULT_LINE"
  _cleanup_session
)

##############################################################################
# TEST 7: no_change — 0.1% tp gain never commits
##############################################################################
echo "=== 7. no_change: 0.1% throughput gain is not enough ==="
(
  _load_tcptune; _single_cand_env
  _APPLY_CC_FAIL=0; _PERSIST_FAIL=0; _MOCK_FAIL=()
  # baseline 100, candidate 100.1 (+0.1% → below AT_MIN_TP_GAIN=5, no RTT gain)
  _MOCK_TP=(    100 100.1 )
  _MOCK_RETR=(  0   0     )
  _MOCK_RTT=(   50000 50000 )
  _MOCK_BYTES=( 250000000 250250000 )
  _run_auto; rc=$?
  assert_eq "exit code is AT_EXIT_NO_CHANGE(2)" "2" "$rc"
  assert_eq "RESULT=no_change" "RESULT=no_change" "$RESULT_LINE"
  _cleanup_session
)

##############################################################################
# TEST 8: no_change — RTT doubles even though tp +10%: degradation gate blocks
##############################################################################
echo "=== 8. no_change: RTT > 200% blocks commit even with tp +10% ==="
(
  _load_tcptune; _single_cand_env
  _APPLY_CC_FAIL=0; _PERSIST_FAIL=0; _MOCK_FAIL=()
  # baseline: 100Mbps, RTT=50000us
  # candidates: 110Mbps, RTT=250000us (5× baseline → >200%)
  _MOCK_TP=( 100 110 )
  _MOCK_RETR=( 0 0 )
  _MOCK_RTT=( 50000 250000 )
  _MOCK_BYTES=( 250000000 275000000 )
  _run_auto; rc=$?
  # RTT > 200% base → score_candidate rejects → no candidates pass → no_change
  assert_eq "exit code is AT_EXIT_NO_CHANGE(2)" "2" "$rc"
  assert_eq "RESULT=no_change" "RESULT=no_change" "$RESULT_LINE"
  _cleanup_session
)

##############################################################################
# TEST 9: committed — RTT -25% with tp at 97% (above 95%): qualifies as improvement
##############################################################################
echo "=== 9. committed: RTT -25% with tp>=95% qualifies ==="
(
  _load_tcptune; _single_cand_env
  _APPLY_CC_FAIL=0; _PERSIST_FAIL=0; _MOCK_FAIL=()
  AT_MIN_RTT_GAIN=20
  # baseline: 100Mbps RTT=100000us; candidate: 97Mbps RTT=72000us (-28%)
  # screening passes (score > 1 because RTT gate lets it through and tp is 97%)
  # retest: tp median 97 vs base 100 → tp_ratio=0.97 → not 5% gain
  #   but RTT gain = (1-72/100)*100 = 28% >= 20%, tp >= 95% → qualifies
  _MOCK_TP=( 100 97  100 97  100 97  100 97 )
  _MOCK_RETR=( 0 0 0 0 0 0 0 0 )
  _MOCK_RTT=( 100000 72000  100000 72000  100000 72000  100000 72000 )
  _MOCK_BYTES=( 250000000 242500000 250000000 242500000 250000000 242500000 250000000 242500000 )
  _run_auto; rc=$?
  # RTT -28%, tp 97% (≥95%) → reliable improvement
  assert_eq "exit code is AT_EXIT_COMMITTED(0)" "0" "$rc"
  assert_eq "RESULT=committed" "RESULT=committed" "$RESULT_LINE"
  _cleanup_session
)

##############################################################################
# TEST 10: persist preserves prior managed entries when only CC changes
# Uses real persist_final_atomic with sysctl_value readback returning "bbr"
##############################################################################
echo "=== 10. persist_final_atomic preserves prior wmem when only CC changed ==="
(
  TCPTUNE="${TCPTUNE:-$(dirname "$0")/../tcptune.sh}"
  source "$TCPTUNE" 2>/dev/null
  # Stub sysctl (no-op) and sysctl_value to return "bbr" for readback
  sysctl(){ :; }
  sysctl_value(){
    case "$1" in
      net.ipv4.tcp_congestion_control) echo "bbr" ;;
      net.core.default_qdisc) echo "fq_codel" ;;
      net.ipv4.tcp_wmem) echo "4096 16384 4194304" ;;
      net.ipv4.tcp_rmem) echo "4096 87380 6291456" ;;
      *) echo "0" ;;
    esac
  }
  session_restore_runtime(){ return 0; }
  session_log(){ :; }
  SESSION_DIR="$(mktemp -d)"
  CONF="$SESSION_DIR/99-tcptune.conf"
  # Simulate: previous session had written wmem to orig_persistent.conf
  printf 'net.ipv4.tcp_wmem = 4096 16384 2097152\n' > "$SESSION_DIR/orig_persistent.conf"
  printf '' > "$SESSION_DIR/snapshot.conf"
  # persist CC only (wmem="" rmem="")
  persist_final_atomic "bbr" "" "" "" 2>/dev/null
  # conf should contain both CC and preserved wmem
  if grep -q 'tcp_congestion_control' "$CONF" && \
     grep -q 'tcp_wmem' "$CONF"; then
    printf '  PASS: prior wmem preserved when only CC changed\n'; (( PASS++ ))
  else
    printf '  FAIL: prior wmem was lost\n'
    [ -f "$CONF" ] && cat "$CONF" || printf '  (file missing)\n'
    (( FAIL++ ))
  fi
  rm -rf "$SESSION_DIR"
)

##############################################################################
# TEST 11: interleaved_retest only counts valid pairs (both sides must succeed)
##############################################################################
echo "=== 11. interleaved_retest: incomplete pairs not counted ==="
(
  _load_tcptune
  SESSION_DIR="$(mktemp -d)"
  printf '' > "$SESSION_DIR/snapshot.conf"
  BASELINE_THROUGHPUT=100; BASELINE_RETR=0; BASELINE_RTT=50000; BASELINE_BYTES=250000000
  AT_RETEST_ROUNDS=3
  _MOCK_CALLS=0
  # After call 0 (baseline round 1) fails, the pairs are:
  # Round 1: baseline(idx=0) fails; candidate(idx=1) runs but pair incomplete
  # Round 2: baseline(idx=2)=100, candidate(idx=3)=110 → valid pair
  # Round 3: baseline(idx=4)=100, candidate(idx=5)=110 → valid pair
  _MOCK_FAIL=( 0 )  # first call (baseline round 1) fails
  _MOCK_TP=( 100   100  100 110  100 110 )
  _MOCK_RETR=( 0    0    0   0    0   0  )
  _MOCK_RTT=( 50000 50000 50000 50000 50000 50000 )
  _MOCK_BYTES=( 250000000 250000000 250000000 275000000 250000000 275000000 )
  run_iperf3_json(){ _mock_run_iperf3_json "$@"; }
  RETEST_CAND_TP_MEDIAN=""; RETEST_BASE_TP_MEDIAN=""
  interleaved_retest "192.0.2.1" "download" "1" "bbr" "fq_codel" "" ""
  rc=$?
  # Should still return 0 (2 valid pairs out of 3 rounds is ≥ 2)
  assert_zero "interleaved_retest returns 0 with 2 valid pairs" "$rc"
  # Medians should be computed from the 2 valid pairs: base=100, cand=110
  # Compare numerically (median may be "110.0000" or "110")
  _median_ok=0
  awk "BEGIN{exit !(\"$RETEST_CAND_TP_MEDIAN\"+0 == 110)}" && _median_ok=1
  assert_zero "candidate TP median from valid pairs equals 110" "$(( 1 - _median_ok ))"
  rm -rf "$SESSION_DIR"
)

##############################################################################
# TEST 12: restore.sh NOT deleted after successful commit
##############################################################################
echo "=== 12. restore.sh preserved after commit ==="
(
  _load_tcptune
  SESSION_DIR="$(mktemp -d)"
  printf 'net.ipv4.tcp_congestion_control = cubic\n' > "$SESSION_DIR/snapshot.conf"
  printf '' > "$SESSION_DIR/orig_persistent.conf"
  printf 'absent' > "$SESSION_DIR/orig_persistent.status"
  printf '#!/bin/bash\necho restore\n' > "$SESSION_DIR/restore.sh"
  CONF="$SESSION_DIR/99-tcptune.conf"
  _PERSIST_FAIL=0
  persist_final_atomic(){ printf 'net.ipv4.tcp_congestion_control = bbr\n' > "$CONF"; return 0; }
  _finalize_and_persist "bbr" "" "" "" >/dev/null 2>&1
  if [ -f "$SESSION_DIR/restore.sh" ]; then
    printf '  PASS: restore.sh preserved after successful commit\n'; (( PASS++ ))
  else
    printf '  FAIL: restore.sh was deleted after commit\n'; (( FAIL++ ))
  fi
  rm -rf "$SESSION_DIR"
)

##############################################################################
# TEST 13: AT_AUTO=1 exits with RESULT=failed (no pause) when not root
##############################################################################
echo "=== 13. auto mode: no pause when require_root fails ==="
(
  _load_tcptune
  # Override require_root to fail
  require_root(){ return 1; }
  AT_AUTO=1
  AT_TARGET="192.0.2.1"
  out="$(auto_tune_flow 2>/dev/null)"
  rc=$?
  RESULT_LINE="$(printf '%s\n' "$out" | grep '^RESULT=' | tail -1)"
  assert_eq "exit code is AT_EXIT_FAILED(1)" "1" "$rc"
  assert_eq "RESULT=failed when not root" "RESULT=failed" "$RESULT_LINE"
)

##############################################################################
# TEST 14: wmem readback failure prevents commit
##############################################################################
echo "=== 14. persist: wmem readback mismatch blocks commit ==="
(
  TCPTUNE="${TCPTUNE:-$(dirname "$0")/../tcptune.sh}"
  source "$TCPTUNE" 2>/dev/null
  SESSION_DIR="$(mktemp -d)"
  CONF="$SESSION_DIR/99-tcptune.conf"
  printf '' > "$SESSION_DIR/orig_persistent.conf"
  printf '' > "$SESSION_DIR/snapshot.conf"
  # sysctl no-op; readback returns mismatch for wmem (kernel rejected the value)
  sysctl(){ :; }
  sysctl_value(){
    case "$1" in
      net.ipv4.tcp_wmem) echo "4096 16384 999999" ;;  # mismatch: kernel returned different value
      net.ipv4.tcp_congestion_control) echo "bbr" ;;
      *) echo "" ;;
    esac
  }
  _restore_orig_persistent(){ return 0; }
  session_restore_runtime(){ return 0; }
  session_log(){ :; }
  persist_final_atomic "bbr" "" "2097152" "" 2>/dev/null
  rc=$?
  assert_nonzero "persist_final_atomic fails when wmem readback mismatches" "$rc"
  rm -rf "$SESSION_DIR"
)

##############################################################################
echo
echo "=== 结果: PASS=${PASS}  FAIL=${FAIL}  SKIP=${SKIP} ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
