#!/usr/bin/env bash
# Assertions are counted inside each isolated case, then returned to the parent.
set -uo pipefail
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$TEST_DIR")"
SUITE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/tcptune-tests.XXXXXX")" || exit 1
SUITE_TMP="$(cd "$SUITE_TMP" && pwd -P)"
PASS=0; FAIL=0; CASES=0
assert_eq(){
  if [ "$2" = "$3" ]; then T_PASS=$((T_PASS+1)); printf '  PASS %s\n' "$1"
  else T_FAIL=$((T_FAIL+1)); printf '  FAIL %s: expected <%s>, got <%s>\n' "$1" "$2" "$3"; fi
}
assert_ok(){
  local label="$1"; shift
  if "$@"; then T_PASS=$((T_PASS+1)); printf '  PASS %s\n' "$label"
  else T_FAIL=$((T_FAIL+1)); printf '  FAIL %s\n' "$label"; fi
}
assert_bad(){
  local label="$1"; shift
  if "$@"; then T_FAIL=$((T_FAIL+1)); printf '  FAIL %s (unexpected success)\n' "$label"
  else T_PASS=$((T_PASS+1)); printf '  PASS %s\n' "$label"; fi
}
_json_matches(){ [ -s "$1" ] && jq -e "$2" "$1" >/dev/null; }
assert_json(){ local label="$1" file="$2" expression="$3"; assert_ok "$label" _json_matches "$file" "$expression"; }
run_case(){
  local label="$1" fn="$2" rc p f r=0
  CASES=$((CASES+1)); CASE_TMP="$SUITE_TMP/case-$CASES"; mkdir "$CASE_TMP"
  printf 'CASE %s\n' "$label"
  (
    set -e
    T_PASS=0; T_FAIL=0
    trap 'r=$?; printf "%s %s\n" "$T_PASS" "$T_FAIL" > "$CASE_TMP/counts"; exit "$r"' EXIT
    source "$REPO/tcptune.sh"
    "$fn"
  )
  rc=$?
  p=0; f=0
  if [ -f "$CASE_TMP/counts" ]; then read -r p f < "$CASE_TMP/counts"; else f=1; fi
  if [ "$rc" -ne 0 ]; then f=$((f+1)); printf '  FAIL case terminated with status %s\n' "$rc"; fi
  PASS=$((PASS+p)); FAIL=$((FAIL+f))
}
finish_suite(){
  printf 'RESULT cases=%s PASS=%s FAIL=%s\n' "$CASES" "$PASS" "$FAIL"
  # Resolve and constrain the recursive cleanup target within the test temp base.
  local base resolved
  base="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
  resolved="$(cd "$SUITE_TMP" && pwd -P)"
  case "$resolved" in "$base"/tcptune-tests.*) rm -rf -- "$resolved" ;; *) printf 'Refused unsafe cleanup: %s\n' "$resolved" >&2; FAIL=$((FAIL+1)) ;; esac
  [ "$FAIL" -eq 0 ]
}

setup_mock(){
  STATE_DIR="$CASE_TMP/state"; CONF="$CASE_TMP/99-tcptune.conf"
  SESSIONS_BASE="$STATE_DIR/sessions"; MYSTERY_CONF="$CASE_TMP/no-mystery"
  MOCK_SYS_DIR="$CASE_TMP/sysctl"; mkdir -p "$MOCK_SYS_DIR"
  printf 'cubic\n' > "$MOCK_SYS_DIR/net.ipv4.tcp_congestion_control"
  printf 'cubic bbr\n' > "$MOCK_SYS_DIR/net.ipv4.tcp_available_congestion_control"
  printf 'fq_codel\n' > "$MOCK_SYS_DIR/net.core.default_qdisc"
  printf '4096\t16384\t4194304\n' > "$MOCK_SYS_DIR/net.ipv4.tcp_wmem"
  printf '4096\t87380\t6291456\n' > "$MOCK_SYS_DIR/net.ipv4.tcp_rmem"
  printf '212992\n' > "$MOCK_SYS_DIR/net.core.wmem_max"
  printf '212992\n' > "$MOCK_SYS_DIR/net.core.rmem_max"
  printf '# old config\nnet.core.somaxconn = 1234\n' > "$CONF"
  cp "$CONF" "$CASE_TMP/original.conf"
  MOCK_SCENARIO=good
  MOCK_NETWORK_CALLS=0
  require_root(){ return 0; }
  flock(){ return 0; } # Windows lacks flock; real Linux lock tested separately.
  watchdog_start(){ return 0; }
  watchdog_stop(){ return 0; }
  sysctl(){
    local key val
    case "$1" in
      -n) IFS= read -r val < "$MOCK_SYS_DIR/$2"; printf '%s\n' "$val" ;;
      -w)
        key="${2%%=*}"; val="${2#*=}"
        printf '%s=%s\n' "$key" "$val" >> "$CASE_TMP/writes.log"
        if [ "$key" = net.ipv4.tcp_congestion_control ] && [ "$val" = bbr ]; then
          case "$MOCK_SCENARIO" in
            apply_failure) return 1 ;;
            readback_mismatch) return 0 ;;
            retest_apply_failure) [ "${MEASURE_STAGE:-}" != retest ] || return 1 ;;
            final_apply_failure) [ "$RUN_SELECTED" != true ] || return 1 ;;
          esac
        fi
        if [ "$MOCK_SCENARIO" = restore_failure ] && [ "$key" = net.ipv4.tcp_congestion_control ] && [ "$val" = cubic ]; then return 1; fi
        printf '%s\n' "$val" > "$MOCK_SYS_DIR/$key" ;;
      *) return 1 ;;
    esac
  }
  ip(){ printf '192.0.2.1 dev test0 src 192.0.2.2\n'; }
  tc(){
    if [ "$1" = -j ]; then printf '[{"kind":"htb","handle":"1:","root":true,"options":{"default":10}}]\n'
    elif [ "$1" = qdisc ] && [ "$2" = show ]; then printf 'qdisc htb 1: root default 10\n'
    else printf 'UNEXPECTED TC MUTATION\n' >> "$CASE_TMP/tc-mutation"; return 1; fi
  }
  iperf3(){ printf 'iperf 3 mock\n'; }
  AT_AUTO=1; AT_TARGET=192.0.2.1; AT_DIRECTION=download
  AT_DURATION=2; AT_RETEST_ROUNDS=3; AT_ACCEPT_ROUNDS=3
  AT_MAX_CANDIDATES=4; AT_MAX_SHORTLIST=3; AT_MAX_SECONDS=300
  AT_RATE_MBPS=1000; AT_SAMPLE_MIB=0; AT_BUDGET_GIB=20; AT_NO_PERSIST=0
  AT_MIN_TP_GAIN=5; AT_MIN_RTT_GAIN=20; AT_MAX_RTT_FACTOR=115
  AT_RTT_TOLERANCE_MS=5; AT_MAX_RETR_FACTOR=300; AT_RETR_FLOOR=100
  AT_PROBE_COMMAND=""; AT_PROXY_SERVICE=""; PROXY_HOST=""; PROXY_TEST_URL=""
  PROXY_MAX_BYTES=33554432; PROXY_REQUESTS=20; PROXY_SMALL_MAX_BYTES=65536
}

mock_measurement(){
  MOCK_NETWORK_CALLS=$((MOCK_NETWORK_CALLS+1))
  printf '%s %s %s\n' "${MEASURE_STAGE:-}" "${MEASURE_ROLE:-}" "${MEASURE_CANDIDATE:-}" >> "$CASE_TMP/network.log"
  MEASURE_REASON=""; IPERF_THROUGHPUT=100; IPERF_RETR=0; IPERF_RTT=100000
  IPERF_BYTES=25000000; IPERF_PROXY='{"status":"not_configured"}'
  IPERF_SNDBUF_LIMITED=0; IPERF_RWND_LIMITED=0
  [ "$MOCK_SCENARIO" != baseline_failure ] || { MEASURE_REASON=iperf_measurement_failed; return 1; }
  if [ "${MEASURE_ROLE:-}" = candidate ]; then
    if [ "$MOCK_SCENARIO" = interrupted ]; then kill -TERM "$BASHPID"; return 1; fi
    IPERF_THROUGHPUT=110
    case "$MOCK_SCENARIO" in
      no_gain) IPERF_THROUGHPUT=100.1 ;;
      noisy)
        if [ "${MEASURE_STAGE:-}" != screening ]; then
          case "${MEASURE_PAIR:-1}" in 1) IPERF_THROUGHPUT=88 ;; 2) IPERF_THROUGHPUT=110 ;; *) IPERF_THROUGHPUT=132 ;; esac
        fi ;;
      latency) IPERF_THROUGHPUT=97; IPERF_RTT=70000 ;;
      latency_regression) IPERF_RTT=199000 ;;
      late_retrans) [ "${MEASURE_STAGE:-}" != retest ] || IPERF_RETR=1000000 ;;
      holdout_failure) [ "${MEASURE_STAGE:-}" != acceptance ] || IPERF_THROUGHPUT=100 ;;
      missing_pairs) [ "${MEASURE_STAGE:-}" != retest ] || { MEASURE_REASON=iperf_measurement_failed; return 1; } ;;
      receiver_cc) IPERF_THROUGHPUT=999 ;;
    esac
  elif [ "$MOCK_SCENARIO" = noisy ] && [ "${MEASURE_STAGE:-}" != baseline ]; then
    case "${MEASURE_PAIR:-1}" in 1) IPERF_THROUGHPUT=80 ;; 2) IPERF_THROUGHPUT=100 ;; *) IPERF_THROUGHPUT=120 ;; esac
  fi
  MEASURE_SEQ=$((MEASURE_SEQ+1))
  _at_budget_add "$IPERF_BYTES"
  jq -cn --arg stage "${MEASURE_STAGE:-}" --arg role "${MEASURE_ROLE:-}" --argjson m "$(_current_measurement_json)" \
    '{stage:$stage,role:$role,metrics:$m}' >> "$SESSION_DIR/measurements.jsonl"
}

install_mock_commands(){
  local command
  mkdir -p "$CASE_TMP/bin"
  for command in sysctl tc; do
    {
      printf '#!/usr/bin/env bash\n'
      printf 'MOCK_SYS_DIR=%q\nCASE_TMP=%q\nMOCK_SCENARIO=%q\nRUN_SELECTED=false\n' "$MOCK_SYS_DIR" "$CASE_TMP" "$MOCK_SCENARIO"
      declare -f "$command"
      printf '%s "$@"\n' "$command"
    } > "$CASE_TMP/bin/$command"
    chmod +x "$CASE_TMP/bin/$command"
  done
  if ! type -P flock >/dev/null; then
    printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE_TMP/bin/flock"
    chmod +x "$CASE_TMP/bin/flock"
  fi
  PATH="$CASE_TMP/bin:$PATH"
}

install_mock_iperf(){
  mkdir -p "$CASE_TMP/bin"
  {
    printf '#!/usr/bin/env bash\nCASE_TMP=%q\n' "$CASE_TMP"
    declare -f iperf3
    printf 'iperf3 "$@"\n'
  } > "$CASE_TMP/bin/iperf3"
  chmod +x "$CASE_TMP/bin/iperf3"
  PATH="$CASE_TMP/bin:$PATH"
}

install_mock_service(){
  mkdir -p "$CASE_TMP/bin"
  {
    printf '#!/usr/bin/env bash\nCASE_TMP=%q\nMOCK_SYS_DIR=%q\n' "$CASE_TMP" "$MOCK_SYS_DIR"
    cat <<'SERVICE'
case "$1" in
  is-active) exit 0 ;;
  restart)
    read -r cc < "$MOCK_SYS_DIR/net.ipv4.tcp_congestion_control"
    if [ "$cc" = bbr ] && [ -f "$CASE_TMP/service-fail" ]; then exit 1; fi
    printf '%s\n' "$cc" > "$CASE_TMP/listener-cc"
    printf '%s\n' "$cc" >> "$CASE_TMP/service-restarts"
    ;;
  *) exit 1 ;;
esac
SERVICE
  } > "$CASE_TMP/bin/systemctl"
  chmod +x "$CASE_TMP/bin/systemctl"
  PATH="$CASE_TMP/bin:$PATH"
}

run_mock_auto(){
  run_iperf3_json(){ mock_measurement "$@"; }
  AUTO_RC=0
  auto_tune_flow > "$CASE_TMP/output" 2> "$CASE_TMP/stderr" || AUTO_RC=$?
  REPORT="$(find "$SESSIONS_BASE" -name report.json -type f | head -n1)"
  if [ "$AUTO_RC" -eq 1 ]; then cat "$CASE_TMP/stderr"; fi
}
