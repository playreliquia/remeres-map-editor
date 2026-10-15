#!/usr/bin/env bash
# Failure injection for the Windows save checks in #47. Runs from WSL and drives powershell.exe
# through interop, so an agent can hold a map file open, toggle its read-only attribute and
# collect evidence while the editor runs on Windows. docs/mcp.md lists the cases.
set -euo pipefail

readonly default_timeout=600
# Test seam: tests/tools/test_windows_save_checks.sh points this at a fake /proc.
readonly proc_root=${WINDOWS_SAVE_CHECKS_PROC:-/proc}
readonly state_root=${WINDOWS_SAVE_CHECKS_STATE:-${XDG_STATE_HOME:-${HOME}/.local/state}/windows-save-checks}

usage() {
  cat <<'EOF'
Usage: tools/windows-save-checks.sh [options] <command> [args]

Drive the Windows failure-injection checks for a map save from WSL.

Commands:
  hold <file>               Open <file> from Windows with FileShare None and keep it open
                            until `release` or the timeout, so a save hits a sharing violation.
  release <file>            Close the handle `hold` opened and confirm Windows can open the file.
  readonly <file> on|off    Set or clear the Windows read-only attribute. Idempotent.
  evidence <file>           Report ~ files next to <file>, backups/, `git status --porcelain`
                            and `git diff --summary` as a fenced Markdown block.

<file> is a map or sidecar path as map_info.filename returns it (D:\maps\world.otbm) or a
WSL path (/mnt/d/maps/world.otbm).

Options:
  --allow-dirty             Run `hold` and `readonly on` even when the file's git checkout
                            has uncommitted changes.
  --timeout <seconds>       How long `hold` keeps the file open without a `release`.
                            Default 600.
  -h, --help                Show this help.

`hold` and `readonly on` refuse to start while the checkout has uncommitted changes, so the
evidence afterwards shows only what the save did. `release`, `readonly off` and `evidence`
always run: they clean up or report.

Exit status: 0 on success, 1 on a failed check, 2 on a usage error.
EOF
}

die() {
  printf 'windows-save-checks: %s\n' "$*" >&2
  exit 1
}

usage_error() {
  printf 'windows-save-checks: %s\n' "$*" >&2
  printf 'Run with --help for usage.\n' >&2
  exit 2
}

require_wsl() {
  local marker
  for marker in "${proc_root}"/sys/fs/binfmt_misc/WSLInterop*; do
    [[ -e "${marker}" ]] && return 0
  done
  if grep -qi microsoft "${proc_root}/version" 2>/dev/null; then
    return 0
  fi
  die "not running under WSL: this script drives Windows through WSL interop"
}

require_powershell() {
  command -v powershell.exe >/dev/null ||
    die "powershell.exe is not on PATH: enable WSL interop and appendWindowsPath in /etc/wsl.conf"
}

# Prints the WSL path for a Windows path (D:\..., \\server\...) or a WSL path.
to_posix() {
  local path=$1
  if [[ "${path}" =~ ^[A-Za-z]:[\\/] || "${path}" == \\\\* ]]; then
    wslpath -u "${path}" || die "wslpath could not convert ${path}"
  elif [[ "${path}" == /* ]]; then
    printf '%s\n' "${path}"
  else
    printf '%s/%s\n' "${PWD}" "${path}"
  fi
}

to_windows() {
  wslpath -w "$1" || die "wslpath could not convert $1 to a Windows path"
}

# Quotes a string as a PowerShell single-quoted literal. PowerShell also ends such a literal at
# the typographic single quotes, so those are doubled too.
ps_quote() {
  local text=$1 quote
  for quote in "'" $'\xe2\x80\x98' $'\xe2\x80\x99' $'\xe2\x80\x9a' $'\xe2\x80\x9b'; do
    text=${text//"${quote}"/"${quote}${quote}"}
  done
  printf "'%s'" "${text}"
}

# -EncodedCommand carries a script as UTF-16, so a non-ASCII path or a quote survives the trip
# through interop unchanged.
ps_encode() {
  # Progress records would reach stderr as CLIXML.
  printf "\$ProgressPreference = 'SilentlyContinue'\n%s" "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0
}

ps_run() {
  powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "$(ps_encode "$1")"
}

checkout_of() {
  git -C "$(dirname "$1")" rev-parse --show-toplevel 2>/dev/null
}

require_clean() {
  local file=$1 top status
  ((allow_dirty)) && return 0
  # A scratch copy outside any checkout has nothing to protect.
  top=$(checkout_of "${file}") || return 0
  status=$(git -C "${top}" status --porcelain)
  [[ -z "${status}" ]] && return 0
  printf '%s\n' "${status}" >&2
  die "the checkout ${top} has uncommitted changes: commit or restore them, or pass --allow-dirty"
}

require_file() {
  [[ -f "$1" ]] || die "no such file: $1"
}

# One state directory per held file, keyed by its case-folded Windows path.
state_dir_for() {
  local key
  key=$(printf '%s' "${1,,}" | sha1sum)
  printf '%s/%s\n' "${state_root}" "${key%% *}"
}

# The kernel's start time for a pid, which tells a reused pid apart from the holder.
start_time_of() {
  local stat fields
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  # The command name in field 2 may hold spaces, so count fields after its closing paren.
  stat=${stat##*) }
  read -r -a fields <<<"${stat}"
  printf '%s\n' "${fields[19]}"
}

# True while the holder this script started still runs.
holder_alive() {
  local dir=$1 started
  [[ -f "${dir}/pid" && -f "${dir}/start" ]] || return 1
  started=$(start_time_of "$(<"${dir}/pid")") || return 1
  [[ "${started}" == "$(<"${dir}/start")" ]]
}

cmd_hold() {
  local file windows dir script pid log waited
  file=$(to_posix "$1")
  require_file "${file}"
  require_clean "${file}"
  require_powershell
  windows=$(to_windows "${file}")
  dir=$(state_dir_for "${windows}")
  if holder_alive "${dir}"; then
    die "${windows} is already held: run release first"
  fi
  rm -rf "${dir}"
  mkdir -p "${dir}"
  printf '%s\n' "${windows}" >"${dir}/file"
  log="${dir}/log"
  : >"${log}"

  # ReadWrite first, as the editor's own handles would ask for; a read-only file only opens
  # for Read. Either way FileShare None makes every other open, rename and delete fail.
  script="\$path = $(ps_quote "${windows}")
try {
  \$stream = [System.IO.File]::Open(\$path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
} catch {
  try {
    \$stream = [System.IO.File]::Open(\$path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
  } catch {
    [Console]::Out.WriteLine('error ' + \$_.Exception.Message)
    exit 1
  }
}
[Console]::Out.WriteLine('held ' + \$PID)
[Console]::Out.Flush()
try {
  Start-Sleep -Seconds ${timeout}
  [Console]::Out.WriteLine('timeout')
} finally {
  \$stream.Dispose()
}"

  # setsid: the holder outlives this script and the caller's process group.
  setsid powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -EncodedCommand "$(ps_encode "${script}")" >"${log}" 2>&1 </dev/null &
  pid=$!
  printf '%s\n' "${pid}" >"${dir}/pid"
  start_time_of "${pid}" >"${dir}/start" || true

  # powershell.exe takes a few seconds to start on a cold machine.
  for ((waited = 0; waited < 300; waited++)); do
    if grep -q '^held ' "${log}"; then
      printf 'held %s for up to %ss (windows pid %s); run release to free it\n' \
        "${windows}" "${timeout}" "$(sed -n 's/^held \([0-9]*\).*/\1/p' "${log}" | tr -d '\r')"
      return 0
    fi
    if ! holder_alive "${dir}"; then
      tr -d '\r' <"${log}" >&2
      rm -rf "${dir}"
      die "could not hold ${windows}"
    fi
    sleep 0.1
  done
  kill "${pid}" 2>/dev/null || true
  tr -d '\r' <"${log}" >&2
  rm -rf "${dir}"
  die "powershell.exe did not open ${windows} within 30s"
}

cmd_release() {
  local file windows dir windows_pid="" script waited
  file=$(to_posix "$1")
  require_powershell
  windows=$(to_windows "${file}")
  dir=$(state_dir_for "${windows}")
  if [[ ! -d "${dir}" ]]; then
    printf 'windows-save-checks: %s is not held\n' "${windows}" >&2
    return 0
  fi
  if holder_alive "${dir}"; then
    windows_pid=$(sed -n 's/^held \([0-9]*\).*/\1/p' "${dir}/log" | tr -d '\r')
  fi

  # Stop only the PowerShell this script started: once the holder exits, Windows may hand its
  # pid to an unrelated process.
  script="\$path = $(ps_quote "${windows}")
\$holder = '${windows_pid}'
if (\$holder) {
  \$process = Get-Process -Id ([int]\$holder) -ErrorAction SilentlyContinue
  if (\$process -and \$process.ProcessName -eq 'powershell') {
    Stop-Process -Id \$process.Id -Force
  }
}
\$deadline = (Get-Date).AddSeconds(10)
while (\$true) {
  try {
    \$stream = [System.IO.File]::Open(\$path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]'ReadWrite, Delete')
    \$stream.Dispose()
    [Console]::Out.WriteLine('free')
    exit 0
  } catch {
    if ((Get-Date) -gt \$deadline) {
      [Console]::Out.WriteLine('busy ' + \$_.Exception.Message)
      exit 1
    }
    Start-Sleep -Milliseconds 200
  }
}"
  local output status=0
  output=$(ps_run "${script}" | tr -d '\r') || status=$?

  for ((waited = 0; waited < 50; waited++)); do
    holder_alive "${dir}" || break
    sleep 0.1
  done
  if holder_alive "${dir}"; then
    kill "$(<"${dir}/pid")" 2>/dev/null || true
  fi
  rm -rf "${dir}"

  if ((status != 0)); then
    printf '%s\n' "${output}" >&2
    die "${windows} is still open in another process"
  fi
  printf 'released %s\n' "${windows}"
}

cmd_readonly() {
  local file state windows value expected output was now
  file=$(to_posix "$1")
  state=$2
  case "${state}" in
    on) value="\$true" expected=true ;;
    off) value="\$false" expected=false ;;
    *) usage_error "readonly takes on or off, not '${state}'" ;;
  esac
  require_file "${file}"
  if [[ "${state}" == on ]]; then
    require_clean "${file}"
  fi
  require_powershell
  windows=$(to_windows "${file}")

  output=$(ps_run "\$item = Get-Item -LiteralPath $(ps_quote "${windows}") -Force
\$was = \$item.IsReadOnly
\$item.IsReadOnly = ${value}
\$item.Refresh()
[Console]::Out.WriteLine(('was ' + \$was + ' now ' + \$item.IsReadOnly).ToLowerInvariant())" | tr -d '\r') ||
    die "could not change the read-only attribute of ${windows}: ${output}"

  read -r _ was _ now <<<"${output}"
  [[ "${now}" == "${expected}" ]] ||
    die "the read-only attribute of ${windows} did not change: ${output}"
  printf 'read-only %s for %s (was %s)\n' "${state}" "${windows}" "$([[ "${was}" == true ]] && echo on || echo off)"
}

indent() {
  local text=$1 empty=$2
  if [[ -z "${text}" ]]; then
    printf '  %s\n' "${empty}"
  else
    printf '%s\n' "${text}" | sed 's/^/  /'
  fi
}

cmd_evidence() {
  local file dir name windows tildes backups top
  file=$(to_posix "$1")
  dir=$(dirname "${file}")
  name=$(basename "${file}")
  [[ -d "${dir}" ]] || die "no such directory: ${dir}"
  windows=$(wslpath -w "${file}" 2>/dev/null || printf '%s' "${file}")

  tildes=$(find "${dir}" -maxdepth 1 -name '*~' -printf '%f\n' | LC_ALL=C sort)
  if [[ -d "${dir}/backups" ]]; then
    backups="present ($(find "${dir}/backups" -type f | wc -l | tr -d ' ') files)"
  else
    backups=absent
  fi

  printf '```text\n'
  printf 'map:      %s\n' "${windows}"
  if top=$(checkout_of "${file}"); then
    printf 'checkout: %s at %s\n' "${top}" "$(git -C "${top}" rev-parse --short HEAD)"
  else
    printf 'checkout: none (%s is not in a git checkout)\n' "${name}"
  fi
  printf '~ files:\n'
  indent "${tildes}" none
  printf 'backups/: %s\n' "${backups}"
  if [[ -n "${top}" ]]; then
    printf 'git status --porcelain:\n'
    indent "$(git -C "${top}" status --porcelain)" clean
    printf 'git diff --summary:\n'
    indent "$(git -C "${top}" diff --summary)" 'no mode changes'
  fi
  printf '```\n'
}

allow_dirty=0
timeout=${default_timeout}
args=()
while (($# > 0)); do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --allow-dirty) allow_dirty=1 ;;
    --timeout)
      (($# > 1)) || usage_error "--timeout needs a number of seconds"
      timeout=$2
      shift
      ;;
    --timeout=*) timeout=${1#--timeout=} ;;
    --)
      shift
      args+=("$@")
      break
      ;;
    -*) usage_error "unknown option $1" ;;
    *) args+=("$1") ;;
  esac
  shift
done
[[ "${timeout}" =~ ^[1-9][0-9]*$ ]] || usage_error "--timeout takes a whole number of seconds, not '${timeout}'"
((${#args[@]} > 0)) || usage_error "no command given"

command=${args[0]}
args=("${args[@]:1}")
expect_args() {
  ((${#args[@]} == $1)) || usage_error "${command} takes $1 argument(s), got ${#args[@]}"
}

case "${command}" in
  hold | release | readonly | evidence) require_wsl ;;
  *) usage_error "unknown command ${command}" ;;
esac
case "${command}" in
  hold)
    expect_args 1
    cmd_hold "${args[0]}"
    ;;
  release)
    expect_args 1
    cmd_release "${args[0]}"
    ;;
  readonly)
    expect_args 2
    cmd_readonly "${args[0]}" "${args[1]}"
    ;;
  evidence)
    expect_args 1
    cmd_evidence "${args[0]}"
    ;;
  *) ;;
esac
