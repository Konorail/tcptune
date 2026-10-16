#!/usr/bin/env bash
# Actual measurement/parser/budget path; executable fixtures, no host writes/network.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

prepare_measurement(){
  setup_mock
  check_actual_qdisc; session_create
  AT_RATE_MBPS=0; AT_SAMPLE_MIB=4
  RUN_START="$(date +%s)"; BUDGET_LIMIT_BYTES=10000000
  BUDGET_USED_BYTES=0; MEASURE_SEQ=0
  jq -n '{end:{sum_received:{bits_per_second:10000000,bytes:4193280,seconds:3},
    sum_sent:{bytes:4194304,seconds:3,retransmits:0},streams:[{sender:{mean_rtt:1000}}]}}' > "$CASE_TMP/input.json"
  iperf3(){
    printf '%s\n' "$@" > "$CASE_TMP/args"
    if [ -f "$CASE_TMP/hang" ]; then sleep 30; fi
    cat "$CASE_TMP/input.json"
    [ ! -f "$CASE_TMP/fail" ]
  }
  install_mock_iperf
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE_TMP/bin/ss"
  chmod +x "$CASE_TMP/bin/ss"
}

byte_quota(){
  prepare_measurement
  assert_ok 'unlimited sender measurement succeeds' run_iperf3_json 192.0.2.1 download 2 1
  assert_ok 'byte quota reaches iperf executable' grep -qx 4194304 "$CASE_TMP/args"
  assert_ok 'unlimited bitrate reaches iperf executable' grep -qx 0 "$CASE_TMP/args"
  assert_bad 'byte mode does not also request timed termination' grep -qx -- -t "$CASE_TMP/args"
  assert_eq 'budget uses sender bytes when receiver reports fewer' 4194304 "$BUDGET_USED_BYTES"
  assert_json 'measurement records its actual duration and byte quota' "$SESSION_DIR/measurements.jsonl" \
    '.status=="ok" and .limits.mode=="byte_bounded" and .limits.payload_quota_bytes==4194304 and .metrics.seconds==3'
  assert_ok 'unlimited receiver measurement succeeds' run_iperf3_json 192.0.2.1 upload 2 1
  assert_ok 'reverse direction is preserved' grep -qx -- -R "$CASE_TMP/args"
  assert_eq 'both directions share the budget' 8388608 "$BUDGET_USED_BYTES"
}

quota_preflight(){
  prepare_measurement
  BUDGET_LIMIT_BYTES=4194304
  assert_bad 'write-block headroom must fit before starting' run_iperf3_json 192.0.2.1 download 2 1
  assert_eq 'budget refusal has explicit reason' traffic_budget_exhausted "$MEASURE_REASON"
  assert_bad 'refused measurement starts no iperf process' test -e "$CASE_TMP/args"
  assert_eq 'refused measurement spends no bytes' 0 "$BUDGET_USED_BYTES"
  BUDGET_LIMIT_BYTES=10000000
  assert_bad 'unsupported parallel byte quotas fail closed' run_iperf3_json 192.0.2.1 download 2 4
}

short_sample(){
  prepare_measurement
  jq '.end.sum_sent.seconds=0.1' "$CASE_TMP/input.json" > "$CASE_TMP/next.json"
  mv "$CASE_TMP/next.json" "$CASE_TMP/input.json"
  assert_bad 'brief burst cannot authorize tuning' run_iperf3_json 192.0.2.1 download 2 1
  assert_eq 'short sample reason is retained' sample_too_short "$MEASURE_REASON"
  assert_eq 'rejected data is still charged' 4194304 "$BUDGET_USED_BYTES"
  assert_json 'short sample remains visible in evidence' "$SESSION_DIR/measurements.jsonl" \
    '.status=="failed" and .reason=="sample_too_short"'
}

quota_overrun(){
  prepare_measurement
  jq '.end.sum_sent.bytes=5000000' "$CASE_TMP/input.json" > "$CASE_TMP/next.json"
  mv "$CASE_TMP/next.json" "$CASE_TMP/input.json"
  assert_bad 'excess transfer is rejected despite valid throughput' run_iperf3_json 192.0.2.1 download 2 1
  assert_eq 'excess quota has explicit reason' sample_byte_limit_exceeded "$MEASURE_REASON"
  assert_eq 'excess bytes are charged rather than hidden' 5000000 "$BUDGET_USED_BYTES"
}

failed_measurement(){
  prepare_measurement; touch "$CASE_TMP/fail"
  assert_bad 'failed iperf cannot produce a successful sample' run_iperf3_json 192.0.2.1 download 2 1
  assert_eq 'failed transfer keeps full byte reservation' 4325376 "$BUDGET_USED_BYTES"
}

deadline(){
  prepare_measurement; touch "$CASE_TMP/hang"
  assert_bad 'hung sender is terminated by the real timeout' run_iperf3_json 192.0.2.1 download 2 1
  assert_json 'timeout exit status is retained in evidence' "$SESSION_DIR/measurements.jsonl" \
    '.status=="failed" and .process_exit_code==124 and .limits.timeout_seconds==7'
  assert_eq 'timeout keeps the byte reservation' 4325376 "$BUDGET_USED_BYTES"
}

timed_measurement(){
  prepare_measurement; AT_RATE_MBPS=100; AT_SAMPLE_MIB=0
  BUDGET_LIMIT_BYTES=100000000
  assert_ok 'existing timed mode still succeeds' run_iperf3_json 192.0.2.1 download 2 1
  assert_ok 'timed termination reaches iperf' grep -qx -- -t "$CASE_TMP/args"
  assert_bad 'timed mode does not add byte termination' grep -qx -- -n "$CASE_TMP/args"
  assert_eq 'timed mode also charges actual sender bytes' 4194304 "$BUDGET_USED_BYTES"
}

invalid_iperf_json(){
  prepare_measurement
  cp "$CASE_TMP/input.json" "$CASE_TMP/valid.json"
  local fixture
  for fixture in empty whitespace object array multiple; do
    case "$fixture" in
      empty) : > "$CASE_TMP/input.json" ;;
      whitespace) printf ' \n\t\n' > "$CASE_TMP/input.json" ;;
      object) printf '{}\n' > "$CASE_TMP/input.json" ;;
      array) printf '[]\n' > "$CASE_TMP/input.json" ;;
      multiple) cat "$CASE_TMP/valid.json" "$CASE_TMP/valid.json" > "$CASE_TMP/input.json" ;;
    esac
    BUDGET_USED_BYTES=0
    assert_bad "$fixture iperf output fails closed" run_iperf3_json 192.0.2.1 download 2 1
    assert_eq "$fixture iperf output has an explicit reason" iperf_measurement_failed "$MEASURE_REASON"
    assert_eq "$fixture iperf output retains its reservation" 4325376 "$BUDGET_USED_BYTES"
  done
  assert_eq 'every rejected iperf result remains in evidence' 5 "$(wc -l < "$SESSION_DIR/measurements.jsonl" | tr -d ' ')"
  assert_json 'invalid iperf evidence never claims usable metrics' "$SESSION_DIR/measurements.jsonl" \
    '.status=="failed" and .reason=="iperf_measurement_failed" and .metrics=={}'
}

invalid_probe_json(){
  prepare_measurement
  BUDGET_LIMIT_BYTES=100000000
  AT_PROBE_COMMAND="$CASE_TMP/probe.sh"
  printf '#!/usr/bin/env bash\ncat %q\n' "$CASE_TMP/probe-input.json" > "$AT_PROBE_COMMAND"
  chmod +x "$AT_PROBE_COMMAND"
  printf '%s\n' '{"status":"ok","requests":20,"errors":0,"p50_ms":10,"p95_ms":20,"download_mbps":10,"bytes":1000}' > "$CASE_TMP/probe-valid.json"
  local fixture
  for fixture in empty whitespace object array multiple; do
    case "$fixture" in
      empty) : > "$CASE_TMP/probe-input.json" ;;
      whitespace) printf ' \n\t\n' > "$CASE_TMP/probe-input.json" ;;
      object) printf '{}\n' > "$CASE_TMP/probe-input.json" ;;
      array) printf '[]\n' > "$CASE_TMP/probe-input.json" ;;
      multiple) cat "$CASE_TMP/probe-valid.json" "$CASE_TMP/probe-valid.json" > "$CASE_TMP/probe-input.json" ;;
    esac
    BUDGET_USED_BYTES=0
    assert_bad "$fixture probe output fails closed" run_iperf3_json 192.0.2.1 download 2 1
    assert_eq "$fixture probe output has an explicit reason" proxy_measurement_failed "$MEASURE_REASON"
    assert_eq "$fixture probe output retains its reservation" 39059456 "$BUDGET_USED_BYTES"
  done
  assert_eq 'every rejected probe result remains in evidence' 5 "$(wc -l < "$SESSION_DIR/measurements.jsonl" | tr -d ' ')"
  assert_json 'invalid probe evidence never claims a successful probe' "$SESSION_DIR/measurements.jsonl" \
    '.status=="failed" and .reason=="proxy_measurement_failed" and .proxy.status=="failed"'
  cp "$CASE_TMP/probe-valid.json" "$CASE_TMP/probe-input.json"
  BUDGET_USED_BYTES=0
  assert_ok 'one valid probe object still succeeds' run_iperf3_json 192.0.2.1 download 2 1
  assert_eq 'valid probe charges its actual bytes' 4195304 "$BUDGET_USED_BYTES"
}

run_case byte-quota-and-direction byte_quota
run_case byte-budget-preflight quota_preflight
run_case short-sample short_sample
run_case quota-overrun quota_overrun
run_case failed-measurement failed_measurement
run_case measurement-timeout deadline
run_case timed-compatibility timed_measurement
run_case invalid-iperf-json invalid_iperf_json
run_case invalid-probe-json invalid_probe_json
finish_suite
