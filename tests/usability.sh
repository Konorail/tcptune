#!/usr/bin/env bash
# Menu entry points against fake kernel state and bounded private files only.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

prepare_menu(){
  setup_mock
  pause(){ :; }
  clear_screen(){ :; }
  BASELINE="$CASE_TMP/legacy-baseline"
  MYSTERY_BASELINE="$CASE_TMP/mystery-baseline"
  MYSTERY_CANDIDATE="$CASE_TMP/mystery-candidate"
  MYSTERY_LOG="$CASE_TMP/mystery-log"
  SESSION_LOG="$CASE_TMP/session-log"
  REMOTE_SESSION_LOG="$CASE_TMP/remote-log"
  remove_sshpass_component(){ touch "$CASE_TMP/sshpass-removed"; }
  remove_xanmod_component(){ touch "$CASE_TMP/xanmod-removed"; }
  install_mock_commands
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE_TMP/bin/flock"
  chmod +x "$CASE_TMP/bin/flock"
  LOCK_HELD=0
}

restore_menu(){
  prepare_menu
  assert_bad 'restore without a session fails clearly' restore_baseline
  check_actual_qdisc; session_create
  apply_cc bbr
  assert_ok 'menu invokes the independent recovery script' restore_baseline
  assert_eq 'menu recovery restores original CC' cubic "$(sysctl_value net.ipv4.tcp_congestion_control)"
  assert_ok 'menu recovery preserves original persistent contents' cmp -s "$CONF" "$CASE_TMP/original.conf"
  local older="$SESSION_DIR"
  session_create
  assert_bad 'old recovery scripts cannot overwrite a newer session' bash "$older/restore.sh"
}

restore_locked(){
  prepare_menu
  check_actual_qdisc; session_create
  apply_cc bbr
  printf '#!/usr/bin/env bash\nexit 1\n' > "$CASE_TMP/bin/flock"
  assert_bad 'restore menu honors an existing tuning lock' restore_baseline
  assert_eq 'lock refusal leaves current runtime untouched' bbr "$(sysctl_value net.ipv4.tcp_congestion_control)"
}

reset_lock_and_recovery(){
  prepare_menu
  check_actual_qdisc; session_create
  apply_cc bbr
  flock(){ return 1; }
  assert_bad 'reset refuses a held lock before cleanup' reset_to_initial_state <<< y
  assert_bad 'locked reset does not uninstall components' test -e "$CASE_TMP/sshpass-removed"
  assert_ok 'locked reset preserves persistent configuration' test -f "$CONF"
  flock(){ return 0; }
  assert_bad 'reset refuses an unresolved session' reset_to_initial_state <<< y
  assert_eq 'unresolved reset does not overwrite runtime' bbr "$(sysctl_value net.ipv4.tcp_congestion_control)"
  touch "$SESSION_DIR/complete"
  assert_ok 'completed-session reset restores and then cleans up' reset_to_initial_state <<< y
  assert_eq 'reset restores latest automatic snapshot first' cubic "$(sysctl_value net.ipv4.tcp_congestion_control)"
  assert_ok 'component cleanup runs after verified recovery' test -f "$CASE_TMP/sshpass-removed"
  assert_ok 'reset retains the independent session recovery evidence' test -f "$SESSION_DIR/restore.sh"
}

legacy_preview_only(){
  prepare_menu
  printf 'net.ipv4.tcp_congestion_control = bbr\n' > "$MYSTERY_CANDIDATE"
  assert_bad 'deprecated formulas have no direct apply entry point' mystery_apply_candidate
  assert_bad 'deprecated apply writes no kernel state' test -e "$CASE_TMP/writes.log"
  assert_bad 'deprecated apply creates no persistent formula file' test -e "$MYSTERY_CONF"
  modprobe(){ touch "$CASE_TMP/module-loaded"; }
  assert_ok 'legacy transport can be previewed without loading modules' mystery_choose_transport <<< $'1\n1\n'
  assert_bad 'legacy transport selection loads no modules' test -e "$CASE_TMP/module-loaded"
  has(){ [ "$1" != gawk ] && command -v "$1" >/dev/null 2>&1; }
  install_base(){ touch "$CASE_TMP/base-installed"; }
  assert_bad 'missing preview dependency fails without installing it' mystery_check_environment <<< y
  assert_bad 'preview performs no package installation' test -e "$CASE_TMP/base-installed"
}

run_case menu-recovery restore_menu
run_case menu-recovery-lock restore_locked
run_case reset-lock-and-latest-session reset_lock_and_recovery
run_case legacy-preview-only legacy_preview_only
finish_suite
