# Sourced by the build and test tasks: sets `os` to the preset prefix for this host and, on
# Windows, loads the MSVC environment so Ninja finds cl.exe.
# shellcheck shell=bash

case "$(uname)" in
  Darwin) os=macos ;;
  MINGW* | MSYS* | CYGWIN*) os=windows ;;
  *) os=linux ;;
esac

if [[ "${os}" == windows && -z "${VSCMD_VER:-}" ]]; then
  # Windows names it ProgramFiles, but the case survives only some launchers.
  program_files=$(cygpath -u "${ProgramFiles:-${PROGRAMFILES:-C:\\Program Files}}")
  vswhere="${program_files} (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
  vs_path=$("${vswhere}" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | tr -d '\r')
  [[ -n "${vs_path}" ]] || {
    echo "no Visual Studio with the C++ workload; install it from https://visualstudio.microsoft.com" >&2
    exit 1
  }
  # vcvars64 changes PATH, INCLUDE, LIB and friends; `set` prints the result for bash to import.
  # Through a batch file: a quoted path passed straight to cmd.exe arrives with its quotes
  # escaped by the MSYS argument conversion, and cmd cannot find the script.
  vcvars_bat=$(mktemp --suffix=.bat)
  printf 'call "%s\\VC\\Auxiliary\\Build\\vcvars64.bat" >nul\r\nset\r\n' "$(cygpath -w "${vs_path}")" >"${vcvars_bat}"
  while IFS='=' read -r name value; do
    case "${name}" in
      Path | PATH) PATH="$(cygpath -u -p "${value}"):${PATH}" ;;
      INCLUDE | LIB | LIBPATH | VCToolsInstallDir | VCINSTALLDIR | VSINSTALLDIR | VSCMD_VER | WindowsSdkDir | WindowsSDKVersion | UCRTVersion | UniversalCRTSdkDir) export "${name}=${value}" ;;
      *) ;;
    esac
  done < <(cmd.exe //d //c "$(cygpath -w "${vcvars_bat}")" | tr -d '\r')
  rm -f "${vcvars_bat}"
  export PATH
fi
