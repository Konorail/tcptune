#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

negative_control(){ assert_eq 'intentional failing assertion' expected incorrect; }
if [ "${TCPTUNE_TEST_NEGATIVE_CONTROL:-0}" = 1 ]; then
  run_case negative-control negative_control
  finish_suite
  exit $?
fi

gates(){
  assert_bad 'delay nearly doubles despite +10% throughput' score_candidate 110 0 199000 100 0 100000 10000000 11000000
  assert_bad 'throughput falls below 95%' score_candidate 94 0 100000 100 0 100000 10000000 9400000
  assert_bad 'zero baseline does not hide retransmit explosion' score_candidate 110 1000000 100000 100 0 100000 10000000 11000000
  assert_bad 'known baseline RTT cannot become unknown' score_candidate 110 0 null 100 0 100000 10000000 11000000
  assert_ok 'unknown RTT on both sides is not zero latency' score_candidate 110 0 null 100 0 null 10000000 11000000
  assert_bad 'zero throughput is invalid' score_candidate 0 0 100000 0 0 100000 100 100
  assert_ok 'low-loss slower option admissible for latency branch' score_candidate 97 0 70000 100 10 100000 10000000 10000000
  local slow="$CANDIDATE_SCORE"
  assert_ok 'faster option is admissible' score_candidate 120 10 100000 100 10 100000 10000000 10000000
  assert_ok 'zero retransmissions get no ranking windfall' awk -v s="$slow" -v f="$CANDIDATE_SCORE" 'BEGIN{exit !(f>s)}'
}

proxy_gates(){
  local b c
  b='{"tp":100,"rtt":100000,"retr":0,"bytes":10000000,"proxy":{"status":"ok","p95_ms":100,"errors":0,"download_mbps":80}}'
  c='{"tp":150,"rtt":100000,"retr":0,"bytes":15000000,"proxy":{"status":"ok","p95_ms":190,"errors":0,"download_mbps":100}}'
  assert_bad 'application P95 vetoes throughput gain' _measurement_gates "$b" "$c"
  c="$(jq -c '.proxy.p95_ms=100|.proxy.errors=1' <<< "$c")"
  assert_bad 'application errors veto throughput gain' _measurement_gates "$b" "$c"
  c="$(jq -c '.proxy.errors=0|.proxy.download_mbps=70' <<< "$c")"
  assert_bad 'application throughput regression vetoes iperf gain' _measurement_gates "$b" "$c"
  c="$(jq -c '.proxy={status:"not_configured"}' <<< "$c")"
  assert_bad 'application metric coverage cannot disappear' _measurement_gates "$b" "$c"
}

paired_stats(){
  SESSION_DIR="$CASE_TMP"; RETEST_STAGE=retest; RETEST_GATE_FAILED=0
  local b c i file="$CASE_TMP/pairs"
  : > "$file"
  for i in 80 100 120 90 110; do
    b="$(jq -cn --argjson t "$i" '{tp:$t,rtt:100000,proxy:{status:"not_configured"}}')"
    c="$(jq -cn --argjson t "$i" '{tp:($t*1.1),rtt:100000,proxy:{status:"not_configured"}}')"
    jq -cn --argjson b "$b" --argjson c "$c" '{stage:"retest",valid:true,baseline:$b,candidate:$c}' >> "$file"
  done
  RETEST_STATS="$(_pair_statistics "$file")"
  printf '%s\n' "$RETEST_STATS" > "$CASE_TMP/statistics.json"
  assert_json 'median paired gain is 10%' "$CASE_TMP/statistics.json" '.gain_pct>9.99 and .gain_pct<10.01'
  assert_bad 'baseline dispersion raises the improvement threshold' is_reliable_improvement
  # Same clear gain with a stable baseline qualifies.
  jq -c '.baseline.tp=100|.candidate.tp=110' "$file" > "$file.stable"
  RETEST_STATS="$(_pair_statistics "$file.stable")"
  assert_ok 'consistent stable +10% gain qualifies' is_reliable_improvement
  RETEST_STATS="$(jq -c '.tp_direction_fraction=0.6' <<< "$RETEST_STATS")"
  assert_bad '60% directional consistency is insufficient' is_reliable_improvement
  RETEST_STATS="$(jq -c '.pairs=2|.tp_direction_fraction=1' <<< "$RETEST_STATS")"
  assert_bad 'two pairs never authorize commit' is_reliable_improvement
  RETEST_STATS='{"pairs":5,"latency_pairs":5,"latency_gain_pct":28,"latency_threshold":20,"latency_direction_fraction":1,"gain_pct":-3,"tp_threshold":5,"tp_direction_fraction":0}'
  assert_ok 'latency branch can accept 97% throughput after gates' is_reliable_improvement
  jq -c '.baseline.tp=100|.candidate.tp=100|.baseline.proxy={status:"ok",download_mbps:50,p95_ms:100}|.candidate.proxy={status:"ok",download_mbps:55,p95_ms:100}' "$file.stable" > "$file.proxy"
  RETEST_STATS="$(_pair_statistics "$file.proxy")"
  assert_ok 'proxy throughput is primary when actual client probe configured' is_reliable_improvement
  assert_eq 'metric named truthfully' proxy_download_mbps "$(jq -r .throughput_metric <<< "$RETEST_STATS")"
  RETEST_GATE_FAILED=1
  assert_bad 'failed hard gate cannot be offset by a median benefit' is_reliable_improvement
}

validation(){
  AT_TARGET=192.0.2.1
  assert_ok 'defaults valid' _validate_auto_options
  AT_RETEST_ROUNDS=2; assert_bad 'fewer than three rounds invalid' _validate_auto_options
  AT_RETEST_ROUNDS=5; AT_DURATION=08; assert_bad 'ambiguous octal-like integer rejected' _validate_auto_options
  AT_DURATION=10; AT_MAX_RTT_FACTOR=200; assert_bad 'permissive 200% RTT policy rejected' _validate_auto_options
  AT_MAX_RTT_FACTOR=115; AT_BUDGET_GIB=NaN; assert_bad 'nonfinite budget rejected' _validate_auto_options
  AT_BUDGET_GIB=20; AT_RATE_MBPS=0
  assert_bad 'unlimited rate requires explicit byte quota' _validate_auto_options
  AT_SAMPLE_MIB=256; assert_ok 'unlimited mode accepts a bounded quota' _validate_auto_options
  AT_SAMPLE_MIB=08; assert_bad 'octal-like quota rejected' _validate_auto_options
  AT_SAMPLE_MIB=4097; assert_bad 'oversized quota rejected' _validate_auto_options
  AT_SAMPLE_MIB=256; AT_RATE_MBPS=1000
  assert_bad 'byte quota cannot silently change timed semantics' _validate_auto_options
}

normalization(){
  assert_eq 'tabs and spaces normalize identically' '4096 16384 8388608' "$(normalize_value $'4096\t16384 8388608')"
  setup_mock
  assert_ok 'buffer preserves original min and default' apply_wmem 8388608
  assert_eq 'only max changes' '4096 16384 8388608' "$(normalize_value "$(sysctl_value net.ipv4.tcp_wmem)")"
  assert_bad 'buffer smaller than default rejected' apply_wmem 1000
  assert_bad 'queue changes deliberately rejected' apply_qdisc fq
  assert_ok 'queue preservation succeeds' apply_qdisc fq_codel
}

runner_negative(){
  local rc=0
  TCPTUNE_TEST_NEGATIVE_CONTROL=1 bash "$TEST_DIR/regression.sh" > "$CASE_TMP/negative.log" 2>&1 || rc=$?
  assert_eq 'intentional assertion failure exits suite nonzero' 1 "$rc"
  assert_ok 'negative suite counts failed child assertion' grep -q 'FAIL=1' "$CASE_TMP/negative.log"
  : > "$CASE_TMP/empty.json"
  assert_bad 'empty JSON artifact cannot pass assertions' _json_matches "$CASE_TMP/empty.json" true
}

cli_order(){
  auto_tune_flow(){ printf '%s %s %s %s %s\n' "$AT_TARGET" "$AT_DURATION" "$AT_NO_PERSIST" "$AT_RATE_MBPS" "$AT_SAMPLE_MIB"; return 2; }
  local rc=0
  (_parse_cli_args --auto-tune --no-persist --duration 7 --target 192.0.2.1) > "$CASE_TMP/cli" || rc=$?
  assert_eq 'CLI forwards actual flow status' 2 "$rc"
  assert_eq 'options after --auto-tune are parsed first' '192.0.2.1 7 1 1000 0' "$(cat "$CASE_TMP/cli")"
  (_parse_cli_args --auto-tune --sample-mib 256 --target 192.0.2.1 --rate-mbps 0 --no-persist) > "$CASE_TMP/unlimited-cli" || true
  assert_eq 'unlimited CLI options reach the tuning flow' '192.0.2.1 10 1 0 256' "$(cat "$CASE_TMP/unlimited-cli")"
  assert_bad 'missing argument fails' bash "$REPO/tcptune.sh" --duration
  assert_bad 'unknown option fails' bash "$REPO/tcptune.sh" --bogus-option
}

proxy_probe(){
  PROXY_HOST=127.0.0.1; PROXY_TEST_URL=http://origin/bulk; PROXY_SMALL_URL=http://origin/small
  PROXY_REQUESTS=20; PROXY_MAX_BYTES=1000000; PROXY_SMALL_MAX_BYTES=4096
  curl(){
    if [ "${1:-}" = --disable ] && [ "${2:-}" = --version ]; then
      printf 'curl 8.4.0 test\n'
      return 0
    fi
    local is_bulk=0 arg count=0 i
    for arg in "$@"; do [ "$arg" != --range ] || is_bulk=1; done
    if [ "$is_bulk" -eq 1 ]; then
      for ((i=0;i<100;i++)); do
        if [ -f "$CASE_TMP/probe-count" ]; then read -r count < "$CASE_TMP/probe-count"; fi
        [ "$count" -lt 20 ] || break
        sleep 0.05
      done
      printf '206 100000 1.0\n'
    else
      if [ -f "$CASE_TMP/probe-count" ]; then read -r count < "$CASE_TMP/probe-count"; fi
      printf '%s\n' "$((count+1))" > "$CASE_TMP/probe-count.next"
      mv "$CASE_TMP/probe-count.next" "$CASE_TMP/probe-count"
      printf '200 1024 0.020\n'
    fi
  }
  assert_ok 'proxy probe actually aggregates concurrent loaded requests' _probe_to_file
  assert_json 'proxy quantiles and byte accounting include late bytes' "$CASE_TMP/probe.json" '.requests>=19 and .requests<=20 and .errors==0 and .p50_ms==20 and .p95_ms==20 and .bytes==120480'
}
_probe_to_file(){ _proxy_probe_impl > "$CASE_TMP/probe.json"; }

candidate_records(){
  SESSION_DIR="$CASE_TMP"; CURRENT_QDISC=fq_codel
  CAND_CC=(); CAND_QDISC=(); CAND_WMEM=(); CAND_RMEM=(); CAND_LABEL=()
  assert_ok 'candidate serializes on supported jq versions' _add_candidate bbr '' '' 'CC=bbr'
  assert_json 'candidate plan includes its label and parameters' "$SESSION_DIR/candidates.jsonl" \
    '.label=="CC=bbr" and .cc=="bbr" and .qdisc=="fq_codel" and .wmem_max=="" and .rmem_max==""'
  assert_ok 'duplicate candidate is ignored' _add_candidate bbr '' '' 'duplicate'
  assert_eq 'candidate plan has one record' 1 "$(wc -l < "$SESSION_DIR/candidates.jsonl" | tr -d ' ')"
  rm "$SESSION_DIR/candidates.jsonl"; mkdir "$SESSION_DIR/candidates.jsonl"
  assert_bad 'plan write failure is surfaced' _add_candidate cubic '' '' 'CC=cubic'
  assert_eq 'failed plan cannot leave an unrecorded candidate' 1 "${#CAND_CC[@]}"
}

qdisc_mock(){
  tc(){
    case "${MOCK_QDISC_MODE:-valid}" in
      failed) printf '[{"kind":"fq_codel","root":true}]\n'; return 1 ;;
      empty) return 0 ;;
      multiple) printf '[{"kind":"fq_codel","root":true}]\n[{"kind":"fq_codel","root":true}]\n' ;;
      object) printf '{"kind":"fq_codel","root":true}\n' ;;
      empty_array) printf '[]\n' ;;
      non_object) printf '[null]\n' ;;
      *) printf '[{"kind":"fq_codel","root":true}]\n' ;;
    esac
  }
}

qdisc_route_validation(){
  setup_mock; qdisc_mock
  # Ordinary CLI execution does not enable pipefail. Exercise that exact state.
  set +o pipefail
  local mode
  for mode in failed empty multiple object empty_array non_object; do
    MOCK_QDISC_MODE="$mode"
    assert_bad "route rejects $mode queue output without pipefail" check_actual_qdisc
  done
  MOCK_QDISC_MODE=valid
  assert_ok 'route accepts one complete queue array' check_actual_qdisc
  assert_eq 'actual queue comes from verified JSON' fq_codel "$ACTUAL_QDISC"
}

qdisc_snapshot_validation(){
  setup_mock; qdisc_mock; set +o pipefail
  ACTUAL_IFACE=test0
  local mode
  for mode in failed empty multiple object empty_array non_object; do
    MOCK_QDISC_MODE="$mode"
    assert_bad "snapshot rejects $mode queue output without pipefail" session_create
  done
  MOCK_QDISC_MODE=valid
  assert_ok 'snapshot accepts one complete queue array' session_create
  assert_json 'snapshot contains the full queue array' "$SESSION_DIR/qdisc.json" 'type=="array" and length==1 and .[0].kind=="fq_codel"'
}

qdisc_restore_validation(){
  setup_mock; qdisc_mock; set +o pipefail
  ACTUAL_IFACE=test0
  session_create
  local mode
  for mode in failed empty multiple object empty_array non_object; do
    MOCK_QDISC_MODE="$mode"
    assert_bad "restore rejects $mode queue output without pipefail" session_restore_runtime
  done
  MOCK_QDISC_MODE=valid
  assert_ok 'restore verifies one unchanged queue array' session_restore_runtime
  : > "$SESSION_DIR/qdisc.json"
  assert_bad 'empty queue snapshot cannot verify restoration' session_restore_runtime
  printf '[]\n[{"kind":"fq_codel","root":true}]\n' > "$SESSION_DIR/qdisc.json"
  assert_bad 'multiple queue snapshot documents cannot verify restoration' session_restore_runtime
}

standalone_completion_failure(){
  setup_mock; install_mock_commands
  check_actual_qdisc; session_create
  apply_cc bbr
  printf 'net.ipv4.tcp_congestion_control = bbr\n' > "$CONF"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$CASE_TMP/bin/touch"
  chmod +x "$CASE_TMP/bin/touch"
  local rc=0
  bash "$SESSION_DIR/restore.sh" > "$CASE_TMP/restore-output" 2>&1 || rc=$?
  assert_eq 'standalone restoration rejects failed completion marker' 1 "$rc"
  assert_eq 'runtime restoration succeeds despite marker failure' cubic "$(sysctl_value net.ipv4.tcp_congestion_control)"
  assert_ok 'persistent restoration succeeds despite marker failure' cmp -s "$CONF" "$CASE_TMP/original.conf"
  assert_ok 'verified parameters remain accurately reported' grep -q '^restore_verified=true$' "$CASE_TMP/restore-output"
  assert_ok 'marker failure is separately identified' grep -q 'session_complete=false; reason=completion_marker_failed' "$CASE_TMP/restore-output"
  assert_bad 'failed standalone completion does not create marker' test -f "$SESSION_DIR/complete"
  assert_bad 'new tuning remains blocked until recovery completes' lock_acquire
  rm "$CASE_TMP/bin/touch"
  assert_ok 'recovery can record completion after storage is fixed' bash "$SESSION_DIR/restore.sh"
  assert_ok 'retried recovery creates the completion marker' test -f "$SESSION_DIR/complete"
  assert_ok 'new tuning can acquire lock after completed recovery' lock_acquire
  lock_release
}

completed_session_restore_failure(){
  setup_mock; MOCK_SCENARIO=restore_failure; install_mock_commands
  check_actual_qdisc; session_create
  apply_cc bbr
  touch "$SESSION_DIR/complete"
  printf 'net.ipv4.tcp_congestion_control = bbr\n' > "$CONF"
  local rc=0
  bash "$SESSION_DIR/restore.sh" > "$CASE_TMP/restore-output" 2>&1 || rc=$?
  assert_eq 'failed recovery of a completed session returns failure' 1 "$rc"
  assert_eq 'injected runtime restore failure actually leaves the candidate' bbr "$(sysctl_value net.ipv4.tcp_congestion_control)"
  assert_ok 'persistent recovery is still attempted independently' cmp -s "$CONF" "$CASE_TMP/original.conf"
  assert_ok 'failed runtime recovery is reported honestly' grep -q 'restore_verified=false' "$CASE_TMP/restore-output"
  assert_bad 'failed recovery invalidates the old completion marker' test -f "$SESSION_DIR/complete"
  assert_bad 'new tuning refuses the partially restored session' lock_acquire
}

standalone_marker_removal_failure(){
  setup_mock; install_mock_commands
  check_actual_qdisc; session_create
  apply_cc bbr
  touch "$SESSION_DIR/complete"
  printf 'net.ipv4.tcp_congestion_control = bbr\n' > "$CONF"
  cp "$CONF" "$CASE_TMP/before-recovery.conf"
  local real_rm rc=0
  real_rm="$(type -P rm)"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$CASE_TMP/bin/rm"
  chmod +x "$CASE_TMP/bin/rm"
  bash "$SESSION_DIR/restore.sh" > "$CASE_TMP/restore-output" 2>&1 || rc=$?
  "$real_rm" "$CASE_TMP/bin/rm"
  assert_eq 'marker deletion failure stops recovery' 1 "$rc"
  assert_eq 'marker deletion failure writes no runtime parameters' bbr "$(sysctl_value net.ipv4.tcp_congestion_control)"
  assert_ok 'marker deletion failure writes no persistent configuration' cmp -s "$CONF" "$CASE_TMP/before-recovery.conf"
  assert_ok 'failed deletion preserves the previous completed state' test -f "$SESSION_DIR/complete"
  assert_ok 'refusal clearly identifies that recovery never started' grep -q 'restore_attempted=false; reason=completion_marker_remove_failed' "$CASE_TMP/restore-output"
}

run_case completed-session-restore-failure completed_session_restore_failure
run_case standalone-marker-removal-failure standalone_marker_removal_failure
run_case standalone-completion-failure standalone_completion_failure
run_case queue-route-fail-closed qdisc_route_validation
run_case queue-snapshot-fail-closed qdisc_snapshot_validation
run_case queue-restore-fail-closed qdisc_restore_validation
run_case candidate-plan-json candidate_records
run_case constraints gates
run_case proxy-constraints proxy_gates
run_case paired-evidence paired_stats
run_case option-validation validation
run_case buffer-and-whitespace normalization
run_case runner-negative-control runner_negative
run_case cli-order-and-errors cli_order
run_case proxy-probe-aggregation proxy_probe
finish_suite
