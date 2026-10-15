#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

committed(){
  setup_mock; run_mock_auto
  assert_eq 'commit exit code' 0 "$AUTO_RC"
  assert_json 'commit records measured/selected/persisted state' "$REPORT" '.result=="committed" and .selected and .applied and .persisted and (.reboot_verified|not)'
  assert_json 'fresh acceptance data exists' "$REPORT" '([.pairs[]|select(.stage=="acceptance")]|length)==3 and ([.pairs[]|select(.stage=="retest")]|length)==3'
  assert_json 'pair order is balanced' "$REPORT" '[.pairs[]|select(.stage=="retest")|.order]==["baseline candidate","candidate baseline","baseline candidate"]'
  assert_ok 'unrelated persistent setting survives' grep -q 'net.core.somaxconn = 1234' "$CONF"
  assert_ok 'CC persisted' grep -q 'net.ipv4.tcp_congestion_control = bbr' "$CONF"
  assert_eq 'runtime matches winner' bbr "$(sysctl_value net.ipv4.tcp_congestion_control)"
  assert_ok 'standalone restore script remains' test -x "$(dirname "$REPORT")/restore.sh"
  assert_bad 'no tc replacement occurred' test -f "$CASE_TMP/tc-mutation"
}

temporary(){
  setup_mock; AT_NO_PERSIST=1; run_mock_auto
  assert_eq 'temporary success has distinct exit code' 3 "$AUTO_RC"
  assert_json 'temporary outcome accurately reports restoration' "$REPORT" '.result=="validated" and .selected and (.applied|not) and (.persisted|not) and .restore_verified'
  assert_ok 'persistent file byte-for-byte unchanged' cmp -s "$CONF" "$CASE_TMP/original.conf"
  assert_eq 'runtime restored to baseline' cubic "$(sysctl_value net.ipv4.tcp_congestion_control)"
}

unchanged(){
  setup_mock; MOCK_SCENARIO=no_gain; run_mock_auto
  assert_eq 'tiny gain returns no_change' 2 "$AUTO_RC"
  assert_json 'no_change verified restored' "$REPORT" '.result=="no_change" and .restore_verified and (.applied|not)'
  assert_ok 'old file survives no_change' cmp -s "$CONF" "$CASE_TMP/original.conf"
}

latency(){
  setup_mock; MOCK_SCENARIO=latency; run_mock_auto
  assert_eq 'latency-led winner can commit' 0 "$AUTO_RC"
  assert_json 'paired latency gain is measured' "$REPORT" '.acceptance.latency_gain_pct>20 and .acceptance.gain_pct<0'
}

bad_latency(){
  setup_mock; MOCK_SCENARIO=latency_regression; run_mock_auto
  assert_eq 'bad latency returns no_change' 2 "$AUTO_RC"
  assert_json 'no selection' "$REPORT" '(.selected|not) and .restore_verified'
}

late_retrans(){
  setup_mock; MOCK_SCENARIO=late_retrans; run_mock_auto
  assert_eq 'retest retransmission explosion rejected' 2 "$AUTO_RC"
  assert_json 'bad pair veto recorded' "$REPORT" '[.pairs[].reason]|index("retransmit_regression")!=null'
  assert_eq 'CC restored' cubic "$(sysctl_value net.ipv4.tcp_congestion_control)"
}

holdout(){
  setup_mock; MOCK_SCENARIO=holdout_failure; run_mock_auto
  assert_eq 'new data can overturn screening/retest winner' 2 "$AUTO_RC"
  assert_json 'holdout rejection is explicit' "$REPORT" '.reason|startswith("acceptance_")'
  assert_ok 'holdout failure does not persist' cmp -s "$CONF" "$CASE_TMP/original.conf"
}

application_failures(){
  setup_mock; MOCK_SCENARIO=apply_failure; run_mock_auto
  assert_eq 'unapplied candidate never wins' 2 "$AUTO_RC"
  assert_eq 'only baseline measured' 1 "$(wc -l < "$CASE_TMP/network.log" | tr -d ' ')"
  assert_json 'restored after apply failure' "$REPORT" '.restore_verified'
}

readback(){
  setup_mock; MOCK_SCENARIO=readback_mismatch; run_mock_auto
  assert_eq 'readback mismatch cannot win' 2 "$AUTO_RC"
  assert_eq 'no measurement of unapplied candidate' 1 "$(wc -l < "$CASE_TMP/network.log" | tr -d ' ')"
}

retest_apply(){
  setup_mock; MOCK_SCENARIO=retest_apply_failure; run_mock_auto
  assert_eq 'application failure during retest rejects candidate' 2 "$AUTO_RC"
  assert_json 'failed retest recorded' "$REPORT" '[.pairs[]|select(.valid==false)]|length>0'
}

final_apply(){
  setup_mock; MOCK_SCENARIO=final_apply_failure; run_mock_auto
  assert_eq 'final application failure is failed outcome' 1 "$AUTO_RC"
  assert_json 'final failure restores baseline' "$REPORT" '.result=="failed" and .restore_verified and (.persisted|not)'
}

baseline_failure(){
  setup_mock; MOCK_SCENARIO=baseline_failure; run_mock_auto
  assert_eq 'baseline failure is not no_change' 1 "$AUTO_RC"
  assert_json 'baseline failure reports reason' "$REPORT" '.reason=="iperf_measurement_failed" and .restore_verified'
}

missing_pairs(){
  setup_mock; MOCK_SCENARIO=missing_pairs; run_mock_auto
  assert_eq 'missing pairs cannot authorize commit' 2 "$AUTO_RC"
  assert_json 'missing pair remains visible' "$REPORT" '[.pairs[]|select(.valid==false)]|length>0'
}

persist_failure(){
  setup_mock
  persist_final_atomic(){ RUN_PERSIST_TOUCHED=1; printf 'broken config' > "$CONF"; return 1; }
  run_mock_auto
  assert_eq 'persist failure is failed outcome' 1 "$AUTO_RC"
  assert_ok 'persistent bytes restored' cmp -s "$CONF" "$CASE_TMP/original.conf"
  assert_eq 'runtime restored on persist failure' cubic "$(sysctl_value net.ipv4.tcp_congestion_control)"
}

restore_failure(){
  setup_mock; MOCK_SCENARIO=restore_failure; run_mock_auto
  assert_eq 'restore failure is failed, never no_change' 1 "$AUTO_RC"
  assert_json 'restore failure honestly reported' "$REPORT" '.reason=="restore_failed" and (.restore_verified|not)'
  assert_bad 'failed restore does not mark session complete' test -f "$(dirname "$REPORT")/complete"
  assert_bad 'new run refuses unverified original state' lock_acquire
}

receiver(){
  setup_mock; AT_DIRECTION=upload; MOCK_SCENARIO=receiver_cc; run_mock_auto
  assert_eq 'receiver mode does not tune local sender CC' 2 "$AUTO_RC"
  assert_eq 'receiver mode only measures baseline without evidence' 1 "$(wc -l < "$CASE_TMP/network.log" | tr -d ' ')"
  assert_ok 'persistent config untouched' cmp -s "$CONF" "$CASE_TMP/original.conf"
}

budget_preflight(){
  setup_mock
  check_actual_qdisc; lock_acquire; session_create
  RUN_START="$(date +%s)"; BUDGET_LIMIT_BYTES=1; BUDGET_USED_BYTES=0
  iperf3(){ printf 'unexpected call\n' > "$CASE_TMP/unexpected"; return 1; }
  assert_bad 'budget checked before network invocation' run_iperf3_json "$AT_TARGET" download 2 1
  assert_eq 'budget reason' traffic_budget_exhausted "$MEASURE_REASON"
  assert_bad 'no network on exhausted budget' test -f "$CASE_TMP/unexpected"
  RUN_START=$(( $(date +%s)-1000 )); BUDGET_LIMIT_BYTES=999999999
  assert_bad 'time budget checked before network invocation' run_iperf3_json "$AT_TARGET" download 2 1
  assert_eq 'time reason' time_budget_exhausted "$MEASURE_REASON"
  touch "$SESSION_DIR/complete"; lock_release
}

json_parser(){
  setup_mock
  check_actual_qdisc; lock_acquire; session_create
  RUN_START="$(date +%s)"; BUDGET_LIMIT_BYTES=999999999; BUDGET_USED_BYTES=0
  iperf3(){
    printf '%s\n' "$*" > "$CASE_TMP/iperf-args"
    printf '{"end":{"sum_received":{"bits_per_second":100000000,"bytes":25000000}},"server_output_json":{"end":{"sum_sent":{"retransmits":7},"streams":[{"sender":{"mean_rtt":123456}}]}}}\n'
  }
  install_mock_iperf
  assert_ok 'receiver parses remote sender RTT/retransmissions' run_iperf3_json "$AT_TARGET" upload 2 1
  assert_eq 'remote retransmit counter' 7 "$IPERF_RETR"
  assert_eq 'remote mean RTT' 123456 "$IPERF_RTT"
  assert_ok 'reverse direction requested' grep -q -- '-R' "$CASE_TMP/iperf-args"
  assert_eq 'actual bytes replace reserved estimate' 25000000 "$BUDGET_USED_BYTES"
  assert_json 'raw data linked from measurement' "$SESSION_DIR/measurements.jsonl" '.sender=="peer" and .metrics.rtt==123456'
  iperf3(){ printf '{"end":{"sum_received":{"bits_per_second":100000000,"bytes":25000000}}}\n'; }
  install_mock_iperf
  assert_ok 'unknown sender fields allowed as unknown' run_iperf3_json "$AT_TARGET" download 2 1
  assert_eq 'missing RTT is null' null "$IPERF_RTT"
  assert_eq 'missing retransmit counter is null' null "$IPERF_RETR"
  touch "$SESSION_DIR/complete"; lock_release
}

buffer_apply_failure(){
  setup_mock; check_actual_qdisc; lock_acquire; session_create
  apply_wmem(){ return 1; }
  assert_bad 'buffer write failure propagates' apply_candidate_verified bbr fq_codel 8388608 ''
  assert_ok 'baseline can be restored' session_restore_runtime
  touch "$SESSION_DIR/complete"; lock_release
}

unsupported_remote(){
  assert_bad 'legacy multi-node auto commit explicitly unavailable' remote_auto_tune_flow
}

standalone_restore(){
  setup_mock; rm -f "$CONF"
  run_mock_auto
  assert_eq 'originally absent config can be committed' 0 "$AUTO_RC"
  install_mock_commands
  assert_ok 'generated restore script is valid Bash' bash -n "$(dirname "$REPORT")/restore.sh"
  assert_ok 'standalone restore executes its real implementation' bash "$(dirname "$REPORT")/restore.sh"
  assert_eq 'standalone restores multi-word values' '4096 16384 4194304' "$(normalize_value "$(sysctl_value net.ipv4.tcp_wmem)")"
  assert_eq 'standalone restores original CC' cubic "$(sysctl_value net.ipv4.tcp_congestion_control)"
  assert_bad 'originally absent persistent file removed' test -f "$CONF"
  assert_bad 'complex qdisc never replaced during restore' test -f "$CASE_TMP/tc-mutation"
}

multiple_candidates(){
  setup_mock
  printf 'reno\n' > "$MOCK_SYS_DIR/net.ipv4.tcp_congestion_control"
  printf 'reno cubic bbr\n' > "$MOCK_SYS_DIR/net.ipv4.tcp_available_congestion_control"
  # Override metrics after the normal fixture, using actual applied CC.
  run_iperf3_json(){
    mock_measurement "$@" || return $?
    if [ "$MEASURE_ROLE" = candidate ]; then
      if [ "$(sysctl_value net.ipv4.tcp_congestion_control)" = bbr ]; then IPERF_THROUGHPUT=101
      else IPERF_THROUGHPUT=107; fi
    fi
  }
  AUTO_RC=0; auto_tune_flow > "$CASE_TMP/output" 2> "$CASE_TMP/stderr" || AUTO_RC=$?
  REPORT="$(find "$SESSIONS_BASE" -name report.json -type f | head -n1)"
  assert_eq 'multiple candidate selection succeeds' 0 "$AUTO_RC"
  assert_json '107% candidate beats 101% candidate' "$REPORT" '.requested.cc=="cubic"'
}

noisy(){
  setup_mock; MOCK_SCENARIO=noisy; run_mock_auto
  assert_eq 'stable paired gain below measured noise stays unchanged' 2 "$AUTO_RC"
  assert_json 'noise raises the acceptance threshold' "$REPORT" '.acceptance.tp_threshold>5'
}

interrupted(){
  setup_mock; MOCK_SCENARIO=interrupted; run_mock_auto
  assert_eq 'TERM interrupts the entire tuning flow' 1 "$AUTO_RC"
  assert_json 'interrupt restoration verified' "$REPORT" '.reason=="interrupted" and .restore_verified and (.applied|not)'
  assert_ok 'persistent bytes unchanged by interrupt' cmp -s "$CONF" "$CASE_TMP/original.conf"
}

report_failure(){
  setup_mock
  _write_report(){ return 1; }
  run_mock_auto
  assert_eq 'report write failure rejects commit' 1 "$AUTO_RC"
  assert_eq 'report write failure restores runtime' cubic "$(sysctl_value net.ipv4.tcp_congestion_control)"
  assert_ok 'report write failure restores persistent config' cmp -s "$CONF" "$CASE_TMP/original.conf"
}

proxy_service(){
  setup_mock; install_mock_service; install_mock_commands
  AT_PROXY_SERVICE=test-proxy.service
  run_mock_auto
  assert_eq 'explicit proxy service can be refreshed' 0 "$AUTO_RC"
  assert_eq 'committed listener uses selected CC' bbr "$(cat "$CASE_TMP/listener-cc")"
  assert_ok 'generated rollback also restores the listener' bash "$(dirname "$REPORT")/restore.sh"
  assert_eq 'rolled-back listener uses original CC' cubic "$(cat "$CASE_TMP/listener-cc")"
}

proxy_service_failure(){
  setup_mock; install_mock_service
  AT_PROXY_SERVICE=test-proxy.service; touch "$CASE_TMP/service-fail"
  run_mock_auto
  assert_eq 'failed listener refresh cannot win' 2 "$AUTO_RC"
  assert_eq 'listener recovered after restart failure' cubic "$(cat "$CASE_TMP/listener-cc")"
  assert_json 'listener failure reason recorded' "$REPORT" '[.decisions[].reason]|index("proxy_service_restart_failed")!=null'
}

run_case committed committed
run_case no-persist temporary
run_case negligible-gain unchanged
run_case latency-branch latency
run_case latency-regression bad_latency
run_case late-retransmissions late_retrans
run_case independent-holdout holdout
run_case apply-failure application_failures
run_case readback-mismatch readback
run_case retest-apply-failure retest_apply
run_case final-apply-failure final_apply
run_case baseline-failure baseline_failure
run_case missing-pairs missing_pairs
run_case persist-failure persist_failure
run_case restore-failure restore_failure
run_case sender-direction receiver
run_case budget-preflight budget_preflight
run_case real-json-parser json_parser
run_case buffer-write-failure buffer_apply_failure
run_case remote-commit-guard unsupported_remote
run_case standalone-rollback standalone_restore
run_case multiple-candidates multiple_candidates
run_case noisy-pairs noisy
run_case signal-rollback interrupted
run_case report-failure report_failure
run_case proxy-service-refresh proxy_service
run_case proxy-service-failure proxy_service_failure
finish_suite
