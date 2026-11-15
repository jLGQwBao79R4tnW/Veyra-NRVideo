#!/bin/bash
# Run the Windows build of Veyra on Linux through Proton.
#
#   veyra-proton.sh                    open Veyra
#   veyra-proton.sh ~/Videos/clip.mp4  open a video straight away
#   veyra-proton.sh --setup            only download and prepare, do not start
#
# Nothing has to be installed by hand. On first run the script downloads the
# pinned Veyra package and the pinned GE-Proton (versions.sh), verifies their
# checksums and unpacks them under ~/.local/share/veyra-proton. Steam's own
# Proton installs are neither used nor touched, so every machine runs the same
# versions.
#
# Environment:
#   VEYRA_VFG=1    use the Proton overlay with patched nvcuda and vkd3d-proton,
#                  needed for NVIDIA VFG; it is built on first use
#                  (build-vfg-proton.sh, needs podman or docker)
#   VEYRA_LOG=1    write a Proton log to $VEYRA_HOME/logs
#   VEYRA_HOME     where everything lives (default ~/.local/share/veyra-proton)
#   VEYRA_NGX_DIR  folder with the driver's nvngx.dll, if not found automatically
# Overrides for development, outside the pinned set and untested:
#   VEYRA_APP      folder with veyra_qml_ui.exe
#   VEYRA_PROTON   path to another Proton's "proton" script
#   VEYRA_PREFIX   compat data directory
#
# See docs/LINUX_PROTON.md for what works and what does not.
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=versions.sh
. "$here/versions.sh"

setup_only=0
if [ "${1:-}" = "--setup" ]; then setup_only=1; shift; fi
vfg="${VEYRA_VFG:-0}"

if [ -n "${VEYRA_APP:-}" ]; then
  app="$VEYRA_APP"
  [ -f "$app/veyra_qml_ui.exe" ] || die "veyra_qml_ui.exe not found in VEYRA_APP=$app"
else
  ensure_veyra_app
  app="$VEYRA_APP_DIR"
fi

if [ -n "${VEYRA_PROTON:-}" ]; then
  proton="$VEYRA_PROTON"
  [ -f "$proton" ] || die "Proton not found at VEYRA_PROTON=$proton"
elif [ "$vfg" = 1 ]; then
  [ -f "$VEYRA_VFG_PROTON_DIR/.veyra-vfg-complete" ] || "$here/build-vfg-proton.sh"
  proton="$VEYRA_VFG_PROTON_DIR/proton"
else
  ensure_ge_proton
  proton="$VEYRA_GE_DIR/proton"
fi

# The two Proton variants ship different d3d12core.dll builds and Proton does
# not replace DLLs in an existing prefix, so each gets its own prefix.
if [ "$vfg" = 1 ]; then default_prefix="$VEYRA_HOME/prefix-vfg"; else default_prefix="$VEYRA_HOME/prefix"; fi
prefix="${VEYRA_PREFIX:-$default_prefix}"
mkdir -p "$prefix"

steam_root="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-$HOME/.local/share/Steam}"
[ -d "$steam_root" ] || steam_root="$HOME/.steam/steam"

export STEAM_COMPAT_DATA_PATH="$prefix"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$steam_root"
export SteamAppId=0 SteamGameId=veyra
export PROTON_ENABLE_NVAPI=1 DXVK_ENABLE_NVAPI=1 PROTON_ENABLE_NGX_UPDATER=0
[ "$vfg" = 1 ] && export PROTON_NVIDIA_NVCUDA=1

if [ "${VEYRA_LOG:-0}" = 1 ]; then
  mkdir -p "$VEYRA_HOME/logs"
  export PROTON_LOG=1 PROTON_LOG_DIR="$VEYRA_HOME/logs"
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
  say "warning: nvngx.dll not found in the NVIDIA driver; RTX Video SR will not start (set VEYRA_NGX_DIR)"
}

# The prefix does not exist before the first run; create it so NGX is in place
# before Veyra starts.
if [ ! -d "$prefix/pfx/drive_c/windows/system32" ]; then
  say "creating prefix $prefix"
  "$proton" run wineboot -u >/dev/null 2>&1 || true
fi
copy_ngx

if [ "$setup_only" = 1 ]; then
  say "ready: app=$app proton=$proton prefix=$prefix"
  exit 0
fi

args=()
if [ -n "${1:-}" ]; then
  args=("Z:$(realpath "$1" | sed 's|/|\\|g')")
fi

cd "$app"
exec "$proton" run "$app/veyra_qml_ui.exe" "${args[@]}"
