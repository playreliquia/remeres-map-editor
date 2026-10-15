#!/usr/bin/env bash
# Tests for tools/windows-save-checks.sh. Stubs for wslpath and powershell.exe stand in for WSL
# interop, so the tests run on any Linux host. Pass test names to run a subset.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
readonly script="${repo_root}/tools/windows-save-checks.sh"

# The real PATH minus any directory with a powershell.exe, so a run on WSL never reaches Windows.
host_path=
IFS=: read -r -a path_entries <<<"${PATH}"
for entry in "${path_entries[@]}"; do
  [[ -n "${entry}" && ! -e "${entry}/powershell.exe" ]] || continue
  host_path+="${host_path:+:}${entry}"
done
readonly host_path

# Builds a fresh sandbox: a fake /proc that reads as WSL, a fake drive mount, the stubs and a
# state directory. Sets `sandbox`.
make_sandbox() {
  sandbox=$(mktemp -d)
  mkdir -p "${sandbox}/proc" "${sandbox}/mnt/d/maps" "${sandbox}/bin" "${sandbox}/ps" "${sandbox}/stub"
  printf 'Linux version 6.6.87.2-microsoft-standard-WSL2\n' >"${sandbox}/proc/version"

  # wslpath: D:\x maps to <sandbox>/mnt/d/x and back; any other path maps to a UNC path.
  cat >"${sandbox}/bin/wslpath" <<EOF
#!/usr/bin/env bash
set -euo pipefail
mnt='${sandbox}/mnt'
case "\$1" in
  -u)
    path=\${2//\\\\//}
    drive=\${path:0:1}
    printf '%s/%s%s\n' "\${mnt}" "\${drive,,}" "\${path:2}"
    ;;
  -w)
    if [[ "\$2" == "\${mnt}"/?/* ]]; then
      rest=\${2#"\${mnt}"/}
      drive=\${rest:0:1}
      rest=\${rest:1}
      printf '%s:%s\n' "\${drive^^}" "\${rest//\\//\\\\}"
    else
      printf '\\\\\\\\wsl.localhost\\\\Test%s\n' "\${2//\\//\\\\}"
    fi
    ;;
  *) exit 1 ;;
esac
EOF

  # powershell.exe: logs each decoded script and answers as the real one would.
  cat >"${sandbox}/ps/powershell.exe" <<EOF
#!/usr/bin/env bash
set -euo pipefail
stub='${sandbox}/stub'
while [[ "\$1" != -EncodedCommand ]]; do shift; done
script=\$(printf '%s' "\$2" | base64 -d | iconv -f UTF-16LE -t UTF-8)
printf '%s\n----\n' "\${script}" >>"\${stub}/scripts"
if [[ "\${script}" == *'FileShare]::None'* ]]; then
  printf '%s\n' "\$\$" >"\${stub}/holder"
  printf 'held 4242\r\n'
  exec sleep 300
elif [[ "\${script}" == *Stop-Process* ]]; then
  if [[ -f "\${stub}/busy" ]]; then
    printf 'busy The process cannot access the file\r\n'
    exit 1
  fi
  kill "\$(<"\${stub}/holder")" 2>/dev/null || true
  printf 'free\r\n'
elif [[ "\${script}" == *IsReadOnly* ]]; then
  was=\$(cat "\${stub}/readonly" 2>/dev/null || echo false)
  now=false
  [[ "\${script}" == *'IsReadOnly = \$true'* ]] && now=true
  printf '%s\n' "\${now}" >"\${stub}/readonly"
  printf 'was %s now %s\r\n' "\${was}" "\${now}"
fi
EOF
  chmod +x "${sandbox}/bin/wslpath" "${sandbox}/ps/powershell.exe"
}

run_script() {
  WINDOWS_SAVE_CHECKS_PROC="${sandbox}/proc" WINDOWS_SAVE_CHECKS_STATE="${sandbox}/state" \
    PATH="${sandbox}/bin:${sandbox}/ps:${host_path}" "${script}" "$@"
}

# A git checkout at D:\maps holding a committed map and sidecar.
make_checkout() {
  local dir="${sandbox}/mnt/d/maps"
  git -C "${dir}" init -q
  git -C "${dir}" config core.fileMode true
  printf 'otbm' >"${dir}/world.otbm"
  printf '<houses/>' >"${dir}/world-house.xml"
  git -C "${dir}" add .
  git -C "${dir}" -c user.name=test -c user.email=test@example.invalid commit -q -m initial
}

fail() {
  printf '  %s\n' "$@" >&2
  return 1
}

expect_contains() {
  [[ "$1" == *"$2"* ]] || fail "expected to find: $2" "in: $1"
}

test_windows_save_checks_outside_wsl_fails() {
  printf 'Linux version 6.8.0-generic\n' >"${sandbox}/proc/version"
  local err status=0
  err=$(run_script evidence 'D:\maps\world.otbm' 2>&1 >/dev/null) || status=$?
  ((status == 1)) || fail "exit ${status}, expected 1"
  expect_contains "${err}" "not running under WSL"
}

test_windows_save_checks_missing_powershell_fails() {
  make_checkout
  rm "${sandbox}/ps/powershell.exe"
  local err status=0
  err=$(run_script readonly 'D:\maps\world.otbm' on 2>&1 >/dev/null) || status=$?
  ((status == 1)) || fail "exit ${status}, expected 1"
  expect_contains "${err}" "powershell.exe is not on PATH"
}

test_windows_save_checks_windows_path_converts_to_wsl_path() {
  make_checkout
  run_script readonly 'D:\maps\world.otbm' on >/dev/null
  expect_contains "$(<"${sandbox}/stub/scripts")" "Get-Item -LiteralPath 'D:\maps\world.otbm'"
}

test_windows_save_checks_wsl_path_passes_through() {
  make_checkout
  run_script readonly "${sandbox}/mnt/d/maps/world.otbm" on >/dev/null
  expect_contains "$(<"${sandbox}/stub/scripts")" "Get-Item -LiteralPath 'D:\maps\world.otbm'"
}

test_windows_save_checks_quote_in_path_is_doubled() {
  printf 'otbm' >"${sandbox}/mnt/d/maps/o'brien.otbm"
  run_script readonly "D:\\maps\\o'brien.otbm" on >/dev/null
  expect_contains "$(<"${sandbox}/stub/scripts")" "'D:\maps\o''brien.otbm'"
}

test_windows_save_checks_readonly_twice_is_idempotent() {
  make_checkout
  local first second off
  first=$(run_script readonly 'D:\maps\world.otbm' on)
  second=$(run_script readonly 'D:\maps\world.otbm' on)
  off=$(run_script readonly 'D:\maps\world.otbm' off)
  expect_contains "${first}" "read-only on for D:\maps\world.otbm (was off)"
  expect_contains "${second}" "read-only on for D:\maps\world.otbm (was on)"
  expect_contains "${off}" "read-only off for D:\maps\world.otbm (was on)"
}

test_windows_save_checks_dirty_checkout_refuses_hold_and_readonly_on() {
  make_checkout
  printf 'edited' >"${sandbox}/mnt/d/maps/world.otbm"
  local command err status
  for command in hold readonly; do
    status=0
    if [[ "${command}" == hold ]]; then
      err=$(run_script hold 'D:\maps\world-house.xml' 2>&1 >/dev/null) || status=$?
    else
      err=$(run_script readonly 'D:\maps\world.otbm' on 2>&1 >/dev/null) || status=$?
    fi
    ((status == 1)) || fail "${command}: exit ${status}, expected 1"
    expect_contains "${err}" "has uncommitted changes"
    expect_contains "${err}" " M world.otbm"
  done
  [[ ! -e "${sandbox}/stub/scripts" ]] || fail "powershell.exe ran despite the refusal"
}

test_windows_save_checks_allow_dirty_runs_readonly_on() {
  make_checkout
  printf 'edited' >"${sandbox}/mnt/d/maps/world.otbm"
  local out
  out=$(run_script --allow-dirty readonly 'D:\maps\world.otbm' on)
  expect_contains "${out}" "read-only on"
}

test_windows_save_checks_dirty_checkout_allows_readonly_off() {
  make_checkout
  printf 'edited' >"${sandbox}/mnt/d/maps/world.otbm"
  local out
  out=$(run_script readonly 'D:\maps\world.otbm' off)
  expect_contains "${out}" "read-only off"
}

test_windows_save_checks_hold_then_release_frees_file() {
  make_checkout
  local held released holder
  held=$(run_script --timeout 30 hold 'D:\maps\world-house.xml')
  expect_contains "${held}" "held D:\maps\world-house.xml for up to 30s (windows pid 4242)"
  expect_contains "$(<"${sandbox}/stub/scripts")" "\$seconds = 30"
  holder=$(<"${sandbox}/stub/holder")
  kill -0 "${holder}" 2>/dev/null || fail "the holder is not running after hold"

  released=$(run_script release 'D:\maps\world-house.xml')
  expect_contains "${released}" "released D:\maps\world-house.xml"
  expect_contains "$(<"${sandbox}/stub/scripts")" "\$holder = '4242'"
  ! kill -0 "${holder}" 2>/dev/null || fail "the holder still runs after release"
  [[ -z "$(ls -A "${sandbox}/state")" ]] || fail "release left state behind"
}

test_windows_save_checks_second_hold_refuses() {
  make_checkout
  run_script hold 'D:\maps\world-house.xml' >/dev/null
  local err status=0
  err=$(run_script hold 'D:\maps\world-house.xml' 2>&1 >/dev/null) || status=$?
  run_script release 'D:\maps\world-house.xml' >/dev/null
  ((status == 1)) || fail "exit ${status}, expected 1"
  expect_contains "${err}" "already held"
}

test_windows_save_checks_release_while_still_open_fails() {
  make_checkout
  run_script hold 'D:\maps\world-house.xml' >/dev/null
  touch "${sandbox}/stub/busy"
  local err status=0
  err=$(run_script release 'D:\maps\world-house.xml' 2>&1 >/dev/null) || status=$?
  kill "$(<"${sandbox}/stub/holder")" 2>/dev/null || true
  ((status == 1)) || fail "exit ${status}, expected 1"
  expect_contains "${err}" "is still open in another process"
}

test_windows_save_checks_evidence_reports_tilde_backups_status_and_mode_changes() {
  make_checkout
  local dir="${sandbox}/mnt/d/maps" out
  printf 'saved' >"${dir}/world.otbm"
  chmod +x "${dir}/world-house.xml"
  printf 'old' >"${dir}/world.otbm~"
  mkdir "${dir}/backups"
  printf 'old' >"${dir}/backups/world.20261015.otbm"
  out=$(run_script evidence 'D:\maps\world.otbm')
  [[ "${out}" == '```text'* ]] || fail "evidence does not open a text fence" "${out}"
  [[ "${out}" == *'```' ]] || fail "evidence does not close the fence" "${out}"
  expect_contains "${out}" "map:      D:\maps\world.otbm"
  expect_contains "${out}" $'~ files:\n  world.otbm~'
  expect_contains "${out}" "backups/: present (1 files)"
  expect_contains "${out}" " M world.otbm"
  expect_contains "${out}" "?? world.otbm~"
  expect_contains "${out}" "mode change 100644 => 100755 world-house.xml"
}

test_windows_save_checks_evidence_clean_checkout_reports_none() {
  make_checkout
  local out
  out=$(run_script evidence 'D:\maps\world.otbm')
  expect_contains "${out}" $'~ files:\n  none'
  expect_contains "${out}" "backups/: absent"
  expect_contains "${out}" $'git status --porcelain:\n  clean'
  expect_contains "${out}" $'git diff --summary:\n  no mode changes'
}

test_windows_save_checks_hold_oversized_timeout_is_rejected() {
  make_checkout
  local timeout err status
  # One past the Start-Sleep limit, and one past what bash arithmetic holds.
  for timeout in 2147484 99999999999999999999; do
    status=0
    err=$(run_script --timeout "${timeout}" hold 'D:\maps\world-house.xml' 2>&1 >/dev/null) || status=$?
    ((status == 2)) || fail "--timeout ${timeout}: exit ${status}, expected 2"
    expect_contains "${err}" "--timeout is at most 2147483 seconds"
  done
  [[ ! -e "${sandbox}/stub/scripts" ]] || fail "powershell.exe ran despite the oversized timeout"
}

test_windows_save_checks_hold_largest_timeout_is_accepted() {
  make_checkout
  local held
  held=$(run_script --timeout 2147483 hold 'D:\maps\world-house.xml')
  run_script release 'D:\maps\world-house.xml' >/dev/null
  expect_contains "${held}" "for up to 2147483s"
  expect_contains "$(<"${sandbox}/stub/scripts")" "\$seconds = 2147483"
}

test_windows_save_checks_unknown_command_exits_with_usage_error() {
  local status=0
  run_script frobnicate 2>/dev/null || status=$?
  ((status == 2)) || fail "exit ${status}, expected 2"
}

# Isolates git from the host's config, so a global hook or template cannot change the results.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

if (($# > 0)); then
  tests=("$@")
else
  mapfile -t tests < <(declare -F | awk '$3 ~ /^test_/ { print $3 }')
fi

failed=0
for name in "${tests[@]}"; do
  make_sandbox
  # A subshell outside any condition, so set -e stops the test at its first failed check.
  set +e
  (
    set -e
    "${name}"
  )
  status=$?
  set -e
  if ((status == 0)); then
    printf 'ok - %s\n' "${name}"
  else
    printf 'not ok - %s\n' "${name}"
    failed=$((failed + 1))
  fi
  rm -rf "${sandbox}"
done
printf '%d of %d failed\n' "${failed}" "${#tests[@]}"
((failed == 0))
