#!/usr/bin/env bash
# Report phase/provenance semantics, with isolated fake kernel/network backends.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

retest_is_not_acceptance(){
  setup_mock; MOCK_SCENARIO=no_gain; run_mock_auto
  assert_eq 'inconclusive retest does not commit' 2 "$AUTO_RC"
  assert_json 'unentered holdout has no acceptance statistics' "$REPORT" \
    '.schema==2 and .acceptance==null and .acceptance_phase=={attempted:false,completed:false,passed:false}'
  assert_json 'retest evidence keeps its own phase and candidate' "$REPORT" \
    '(.retests|length)==1 and .retests[0].candidate=="CC=bbr" and .retests[0].completed and .retests[0].statistics.pairs==3'
  assert_json 'source file has a verifiable SHA256' "$REPORT" '.script_sha256|test("^[a-f0-9]{64}$")'
  assert_eq 'source digest matches the file actually loaded' "$(sha256sum "$REPO/tcptune.sh" | cut -d' ' -f1)" "$(jq -r .script_sha256 "$REPORT")"
}

fresh_holdout(){
  setup_mock; AT_NO_PERSIST=1; run_mock_auto
  assert_eq 'successful temporary experiment validates' 3 "$AUTO_RC"
  assert_json 'passed holdout is explicitly distinguished from retest' "$REPORT" \
    '.acceptance_phase=={attempted:true,completed:true,passed:true} and .acceptance.pairs==3 and (.retests|length)==1'
}

failed_holdout(){
  setup_mock; MOCK_SCENARIO=holdout_failure; run_mock_auto
  assert_eq 'independent data can reject the candidate' 2 "$AUTO_RC"
  assert_json 'completed holdout can honestly report no improvement' "$REPORT" \
    '.acceptance_phase=={attempted:true,completed:true,passed:false} and .acceptance.gain_pct==0 and .retests[0].statistics.gain_pct>5'
}

probe_evidence(){
  setup_mock; check_actual_qdisc; session_create
  BUDGET_USED_BYTES=0; BUDGET_LIMIT_BYTES=100000000; RUN_START="$(date +%s)"
  AT_PROBE_COMMAND=/configured/probe
  assert_ok 'report writes before a probe ever succeeds' _write_report
  assert_json 'configured probe alone is not measured experience' "$SESSION_DIR/report.json" \
    '.proxy_experience=="not_verified" and .proxy_probe=={configured:true,valid_measurements:0,failed_measurements:0}'
  printf '%s\n' '{"status":"failed","proxy":{"status":"failed"}}' >> "$SESSION_DIR/measurements.jsonl"
  assert_ok 'failed probe can be reported' _write_report
  assert_json 'failed probe is not advertised as measured experience' "$SESSION_DIR/report.json" \
    '.proxy_experience=="not_verified" and .proxy_probe.failed_measurements==1 and .proxy_probe.valid_measurements==0'
  printf '%s\n' '{"status":"ok","proxy":{"status":"ok","errors":0}}' >> "$SESSION_DIR/measurements.jsonl"
  assert_ok 'valid probe can be reported' _write_report
  assert_json 'experience label requires actual successful measurement evidence' "$SESSION_DIR/report.json" \
    '.proxy_experience=="measured_on_probe_host" and .proxy_probe.valid_measurements==1'
}

latency_units(){
  local file="$CASE_TMP/proxy-pairs.jsonl" stats
  RETEST_STAGE=retest
  printf '%s\n' '{"stage":"retest","valid":true,"baseline":{"tp":100,"rtt":1000,"proxy":{"status":"ok","download_mbps":50,"p95_ms":100}},"candidate":{"tp":100,"rtt":1000,"proxy":{"status":"ok","download_mbps":60,"p95_ms":70}}}' > "$file"
  stats="$(_pair_statistics "$file")"
  printf '%s\n' "$stats" > "$CASE_TMP/stats.json"
  assert_json 'proxy P95 gain is paired with correctly named values and units' "$CASE_TMP/stats.json" \
    '.latency_metric=="proxy_p95_us" and .base_latency==100000 and .cand_latency==70000 and .latency_gain_pct>29 and .base_rtt==1000'
}

run_case retest-not-holdout retest_is_not_acceptance
run_case passed-holdout fresh_holdout
run_case failed-holdout failed_holdout
run_case proxy-evidence probe_evidence
run_case latency-units latency_units
finish_suite
