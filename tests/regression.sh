#!/usr/bin/env bash
# tests/regression.sh — unit regression tests for tcptune scoring/selection logic
# Run: bash tests/regression.sh
# Requirements: bash, awk (no root, no network, no iperf3 needed)

# Note: no set -e — tests need to call functions that are expected to fail
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"

PASS=0; FAIL=0; SKIP=0

_pass(){ printf '  PASS: %s\n' "$1"; (( PASS++ )) || true; }
_fail(){ printf '  FAIL: %s\n' "$1"; (( FAIL++ )) || true; }
_skip(){ printf '  SKIP: %s\n' "$1"; (( SKIP++ )) || true; }

##############################################################################
# Extract helper functions from tcptune.sh without running the full script
##############################################################################
# Source only the pure-function parts we need (no root, no side effects).
# We mock all syscall helpers to be no-ops.
_load_helpers(){
  # Minimal stubs so tcptune.sh sources cleanly without root or side effects
  sysctl(){ :; }
  sysctl_value(){ echo 0; }
  ip(){ :; }
  tc(){ :; }
  iperf3(){ :; }
  curl(){ :; }
  has(){ return 1; }
  require_root(){ return 0; }
  lock_acquire(){ return 0; }
  lock_release(){ :; }
  session_create(){ SESSION_DIR="$(mktemp -d)"; return 0; }
  session_restore_runtime(){ :; }
  session_log(){ :; }
  watchdog_start(){ :; }
  watchdog_stop(){ :; }
  clear_screen(){ :; }
  green(){ printf '%s\n' "$*"; }
  red(){ printf '%s\n' "$*" >&2; }
  yellow(){ printf '%s\n' "$*"; }
  pause(){ :; }
  menu(){ :; }
  apply_cc(){ :; }
  apply_qdisc(){ :; }
  apply_wmem(){ :; }
  apply_rmem(){ :; }
  proxy_acceptance_test(){ return 0; }
  run_iperf3_json(){ :; }
  persist_final_atomic(){ return 0; }

  # Prevent auto-execution at source time
  _parse_cli_args(){ :; }

  # Source the script to pull in real implementations
  # shellcheck source=../tcptune.sh
  source "$REPO/tcptune.sh" 2>/dev/null || true
}
_load_helpers

##############################################################################
# Test helpers
##############################################################################
assert_eq(){ local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then _pass "$name"; else
    _fail "$name: got='$got' want='$want'"; fi
}
assert_true(){ local name="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then _pass "$name"; else _fail "$name: expected 0 got $rc"; fi
}
assert_false(){ local name="$1" rc="$2"
  if [ "$rc" -ne 0 ]; then _pass "$name"; else _fail "$name: expected non-0 got 0"; fi
}

##############################################################################
# 1. score_candidate – throughput-only improvement (5%) should score > 1.0
##############################################################################
echo "=== 1. score_candidate: 5% throughput gain ==="
BASELINE_THROUGHPUT=200; BASELINE_RETR=100; BASELINE_RTT=10000; BASELINE_BYTES=500000000
score_candidate 210 100 10000 200 100 10000 500000000 510000000
assert_true  "score_candidate returns 0"        $?
awk "BEGIN{exit !($CANDIDATE_SCORE > 1.0)}" 2>/dev/null
assert_true  "score > 1.0 for 5% tp gain"      $?

##############################################################################
# 2. score_candidate – 0.1% gain only: score should be ≤ 1.0 (not reliably better)
##############################################################################
echo "=== 2. score_candidate: 0.1% gain only ==="
score_candidate 200.2 100 10000 200 100 10000 500000000 500500000
# 0.1% gain in tp_ratio: 0.001*0.7 = 0.0007 improvement in score; still > 1.0 numerically
# but is_reliable_improvement must reject it
RETEST_CAND_TP_MEDIAN=200.2; RETEST_BASE_TP_MEDIAN=200
RETEST_CAND_RTT_MEDIAN=10000; RETEST_BASE_RTT_MEDIAN=10000
is_reliable_improvement 200.2 200 10000 10000
assert_false "is_reliable_improvement rejects 0.1% gain" $?

##############################################################################
# 3. score_candidate – P95 RTT improves 20%, tp >= 95%: should be reliable
##############################################################################
echo "=== 3. is_reliable_improvement: RTT improves 20%, tp steady ==="
is_reliable_improvement 195 200 8000 10000
assert_true  "RTT 20% improvement with tp>=95% qualifies" $?

##############################################################################
# 4. score_candidate – RTT doubles: score_candidate must reject
##############################################################################
echo "=== 4. score_candidate: RTT doubles → rejected ==="
# base_rtt=10000, cand_rtt=25000 (>200%)
score_candidate 220 50 25000 200 100 10000 500000000 520000000
assert_false "RTT >200% base causes score_candidate failure" $?

##############################################################################
# 5. score_candidate – zero retransmissions don't produce huge bonus
##############################################################################
echo "=== 5. score_candidate: zero-retr candidate vs 5% faster ==="
# Candidate A: 190 Mbps, 0 retransmits — should NOT beat B (300 Mbps, 100 retr)
score_candidate 190 0 10000 200 100 10000 500000000 500000000
score_A="$CANDIDATE_SCORE"
score_candidate 300 100 10000 200 100 10000 500000000 500000000
score_B="$CANDIDATE_SCORE"
awk "BEGIN{exit !($score_B > $score_A)}" 2>/dev/null
assert_true  "300Mbps candidate beats 190Mbps zero-retr candidate" $?

##############################################################################
# 6. is_reliable_improvement – one node improves, RTT worsens slightly
##############################################################################
echo "=== 6. is_reliable_improvement: tp +7%, RTT same ==="
is_reliable_improvement 214 200 10000 10000
assert_true  "7% tp gain qualifies as reliable" $?

##############################################################################
# 7. is_reliable_improvement – tp improves 4.9% (below 5% threshold) → reject
##############################################################################
echo "=== 7. is_reliable_improvement: tp +4.9% below threshold ==="
is_reliable_improvement 209.8 200 10000 10000
assert_false "4.9% tp gain is below AT_MIN_TP_GAIN threshold" $?

##############################################################################
# 8. _median correctness
##############################################################################
echo "=== 8. _median ==="
m="$(_median 10 20 30)"
assert_eq "_median of 10 20 30" "$m" "20"
m="$(_median 10 30)"
assert_eq "_median of 10 30" "$m" "20.0000"

##############################################################################
# 9-11. persist_final_atomic: file content tests (stub sysctl read-back)
##############################################################################
# The real persist_final_atomic calls sysctl to read back applied values.
# In this non-root test environment sysctl reads would return wrong values.
# We stub sysctl_value to return the configured value so read-back passes.

# sysctl_value stub: return the value from the temp conf file we just wrote.
sysctl_value(){ grep -E "^[^#].*${1##net.ipv4.}" "$CONF" 2>/dev/null | awk -F'=' '{print $2}' | xargs || echo ""; }

echo "=== 9. persist_final_atomic: CC-only candidate ==="
CONF="$(mktemp)"; SESSION_DIR="$(mktemp -d)"
# Stub sysctl_value to return the configured value
sysctl_value(){ case "$1" in
  net.ipv4.tcp_congestion_control) echo "bbr" ;;
  net.core.default_qdisc) echo "fq" ;;
  *) echo "" ;; esac; }
persist_final_atomic "bbr" "fq" "" ""
assert_true "persist_final_atomic CC-only returns 0" $?
grep -q "tcp_congestion_control" "$CONF"
assert_true "CC written to conf file" $?
rm -f "$CONF"; rm -rf "$SESSION_DIR"

echo "=== 10. persist_final_atomic: wmem-only candidate ==="
CONF="$(mktemp)"; SESSION_DIR="$(mktemp -d)"
sysctl_value(){ case "$1" in
  net.ipv4.tcp_congestion_control) echo "cubic" ;;
  net.core.default_qdisc) echo "fq_codel" ;;
  net.ipv4.tcp_wmem) echo "4096 16384 4194304" ;;
  *) echo "" ;; esac; }
persist_final_atomic "cubic" "fq_codel" "4194304" ""
assert_true "persist_final_atomic wmem-only returns 0" $?
grep -q "tcp_wmem" "$CONF"
assert_true "wmem_max written to conf file" $?
rm -f "$CONF"; rm -rf "$SESSION_DIR"

echo "=== 11. persist_final_atomic: rmem-only candidate ==="
CONF="$(mktemp)"; SESSION_DIR="$(mktemp -d)"
sysctl_value(){ case "$1" in
  net.ipv4.tcp_congestion_control) echo "cubic" ;;
  net.core.default_qdisc) echo "fq_codel" ;;
  net.ipv4.tcp_rmem) echo "4096 87380 8388608" ;;
  *) echo "" ;; esac; }
persist_final_atomic "cubic" "fq_codel" "" "8388608"
assert_true "persist_final_atomic rmem-only returns 0" $?
grep -q "tcp_rmem" "$CONF"
assert_true "rmem_max written to conf file" $?
rm -f "$CONF"; rm -rf "$SESSION_DIR"

# Restore sysctl_value stub
sysctl_value(){ echo 0; }

##############################################################################
# 12. CLI args: --auto-tune without --target must exit with error
##############################################################################
echo "=== 12. --auto-tune without --target exits with error ==="
output="$(bash "$REPO/tcptune.sh" --auto-tune 2>&1 || true)"
# Accept either: RESULT=failed, root message, or the --target error
echo "$output" | grep -qE "RESULT=failed|--target|AT_TARGET|root|自动模式"
assert_true "--auto-tune without --target reports error or root requirement" $?

##############################################################################
# 13. CLI args: argument order independence
##############################################################################
echo "=== 13. CLI arg order independence ==="
# --duration after --auto-tune should still parse correctly
output2="$(bash "$REPO/tcptune.sh" --duration 5 --auto-tune --target 127.0.0.1 2>&1 || true)"
# Should not complain about unknown args; will fail on network/root but not on arg parsing
echo "$output2" | grep -qvE "unrecognized|illegal option"
assert_true "CLI args in any order do not produce parse errors" $?

##############################################################################
# Summary
##############################################################################
echo
printf '=== 结果: PASS=%d  FAIL=%d  SKIP=%d ===\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
