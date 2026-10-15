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
}

cli_order(){
  auto_tune_flow(){ printf '%s %s %s\n' "$AT_TARGET" "$AT_DURATION" "$AT_NO_PERSIST"; return 2; }
  local rc=0
  (_parse_cli_args --auto-tune --no-persist --duration 7 --target 192.0.2.1) > "$CASE_TMP/cli" || rc=$?
  assert_eq 'CLI forwards actual flow status' 2 "$rc"
  assert_eq 'options after --auto-tune are parsed first' '192.0.2.1 7 1' "$(cat "$CASE_TMP/cli")"
  assert_bad 'missing argument fails' bash "$REPO/tcptune.sh" --duration
  assert_bad 'unknown option fails' bash "$REPO/tcptune.sh" --bogus-option
}

proxy_probe(){
  PROXY_HOST=127.0.0.1; PROXY_TEST_URL=http://origin/bulk; PROXY_SMALL_URL=http://origin/small
  PROXY_REQUESTS=20; PROXY_MAX_BYTES=1000000; PROXY_SMALL_MAX_BYTES=4096
  curl(){
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
  assert_json 'proxy quantiles and byte accounting' "$CASE_TMP/probe.json" '.requests==20 and .errors==0 and .p50_ms==20 and .p95_ms==20 and .bytes==120480'
}
_probe_to_file(){ _proxy_probe_impl > "$CASE_TMP/probe.json"; }

run_case constraints gates
run_case proxy-constraints proxy_gates
run_case paired-evidence paired_stats
run_case option-validation validation
run_case buffer-and-whitespace normalization
run_case runner-negative-control runner_negative
run_case cli-order-and-errors cli_order
run_case proxy-probe-aggregation proxy_probe
finish_suite
