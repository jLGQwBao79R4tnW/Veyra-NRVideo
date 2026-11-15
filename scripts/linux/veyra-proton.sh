#!/bin/bash
# Run the Windows build of Veyra on Linux through Proton.
#
#   veyra-proton.sh                    open Veyra
#   veyra-proton.sh ~/Videos/clip.mp4  open a video straight away
#
# Environment:
#   VEYRA_APP     folder with veyra_qml_ui.exe (default: this script's ../.. or $PWD)
#   VEYRA_PROTON  path to a Proton "proton" script (default: Proton Experimental from Steam)
#   VEYRA_PREFIX  compat data directory (default: ~/.local/share/veyra-proton/prefix)
#   VEYRA_CUDA=1  enable the nvidia-libs CUDA bridge (needed for NVIDIA VFG; needs a
#                 Proton build that ships it, see docs/LINUX_PROTON.md)
#   VEYRA_LOG=1   write a Proton log to $VEYRA_PREFIX/../logs
#
# See docs/LINUX_PROTON.md for what works and what does not.
set -euo pipefail

steam_root="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-$HOME/.local/share/Steam}"
[ -d "$steam_root" ] || steam_root="$HOME/.steam/steam"

find_app() {
  local here; here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
  local d
  for d in "${VEYRA_APP:-}" "$PWD" "$here" "$here/../.."; do
    [ -n "$d" ] && [ -f "$d/veyra_qml_ui.exe" ] && { (cd "$d" && pwd); return 0; }
  done
  return 1
}

app="$(find_app)" || {
  echo "veyra_qml_ui.exe not found. Set VEYRA_APP to the extracted portable package." >&2
  exit 1
}
proton="${VEYRA_PROTON:-$steam_root/steamapps/common/Proton - Experimental/proton}"
[ -f "$proton" ] || { echo "Proton not found at: $proton (set VEYRA_PROTON)" >&2; exit 1; }

prefix="${VEYRA_PREFIX:-${XDG_DATA_HOME:-$HOME/.local/share}/veyra-proton/prefix}"
mkdir -p "$prefix"

export STEAM_COMPAT_DATA_PATH="$prefix"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$steam_root"
export SteamAppId=0 SteamGameId=veyra
export PROTON_ENABLE_NVAPI=1 DXVK_ENABLE_NVAPI=1 PROTON_ENABLE_NGX_UPDATER=0
[ "${VEYRA_CUDA:-0}" = 1 ] && export PROTON_NVIDIA_NVCUDA=1

if [ "${VEYRA_LOG:-0}" = 1 ]; then
  mkdir -p "$prefix/../logs"
  export PROTON_LOG=1 PROTON_LOG_DIR="$(cd "$prefix/../logs" && pwd)"
fi

# NGX needs nvngx.dll and _nvngx.dll from the Linux NVIDIA driver in system32.
# Proton copies them itself when it finds <libGLX_nvidia dir>/nvidia/wine; inside
# containers (distrobox, toolbox) that lookup fails, so copy them explicitly.
copy_ngx() {
  local sys32="$prefix/pfx/drive_c/windows/system32" d
  [ -d "$sys32" ] || return 0
  for d in ${VEYRA_NGX_DIR:+"$VEYRA_NGX_DIR"} /usr/lib64/nvidia/wine \
           /usr/lib/x86_64-linux-gnu/nvidia/wine /usr/lib/nvidia/wine \
           /run/host/usr/lib64/nvidia/wine /run/host/usr/lib/x86_64-linux-gnu/nvidia/wine; do
    if [ -f "$d/nvngx.dll" ] && [ -f "$d/_nvngx.dll" ]; then
      cp -u "$d/nvngx.dll" "$d/_nvngx.dll" "$sys32/" 2>/dev/null || true
      return 0
    fi
  done
  echo "warning: nvngx.dll not found in the NVIDIA driver; RTX Video SR will not start (set VEYRA_NGX_DIR)" >&2
}

# The prefix does not exist before the first run; create it so NGX is in place
# before Veyra starts.
if [ ! -d "$prefix/pfx/drive_c/windows/system32" ]; then
  "$proton" run wineboot -u >/dev/null 2>&1 || true
fi
copy_ngx

args=()
if [ -n "${1:-}" ]; then
  args=("Z:$(realpath "$1" | sed 's|/|\\|g')")
fi

cd "$app"
exec "$proton" run "$app/veyra_qml_ui.exe" "${args[@]}"
