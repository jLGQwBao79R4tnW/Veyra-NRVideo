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

# Inside a container (distrobox, toolbox) whose distribution differs from the
# host, the host's Vulkan ICD file can name a library path that does not exist
# here, and Vulkan falls back to llvmpipe. Point the loader at this system's
# libGLX_nvidia instead. Skipped when VK_DRIVER_FILES is already set.
fix_container_icd() {
  { [ -f /run/.containerenv ] || [ -f /.dockerenv ]; } || return 0
  [ -z "${VK_DRIVER_FILES:-}" ] || return 0
  local dir="$VEYRA_HOME/icd" lib files="" arch
  mkdir -p "$dir"
  while read -r arch lib; do
    [ -f "$lib" ] || continue
    printf '{"file_format_version":"1.0.1","ICD":{"library_path":"%s","api_version":"1.4.0"}}\n' "$lib" \
      > "$dir/nvidia_icd.$arch.json"
    files="${files:+$files:}$dir/nvidia_icd.$arch.json"
  done < <(ldconfig -p 2>/dev/null | awk '/libGLX_nvidia\.so\.0 / { print (/x86-64/ ? "x86_64" : "i686"), $NF }' | sort -u)
  [ -n "$files" ] && export VK_DRIVER_FILES="$files"
  return 0
}
fix_container_icd

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

# Keep user data in one place, outside the prefixes and the versioned app
# folder, so that it survives a version change and is the same with and
# without VEYRA_VFG:
#   <prefix>/.../AppData/Local/Veyra  PS5/Xbox/Moonlight pairing (remoteplay/)
#   <app>/runtime_local               Veyra settings, presets, playlist
# Each location becomes a symlink into $VEYRA_HOME/user. Existing data is moved
# there the first time; a second, different copy is set aside, never deleted.
# The PS5 profile is DPAPI-encrypted, which in Wine is keyed by the user name
# ("steamuser" in every Proton prefix), so it reads back in either prefix.
share_dir() {
  local here_dir="$1" shared="$2" seed
  [ -L "$here_dir" ] && return 0
  if pgrep -f 'veyra_qml_ui\.exe' >/dev/null 2>&1; then
    say "Veyra is running; close it and start again to move $(basename "$here_dir") to $shared"
    return 0
  fi
  mkdir -p "$(dirname "$shared")" "$(dirname "$here_dir")"
  if [ -d "$here_dir" ]; then
    if [ ! -e "$shared" ]; then
      mv "$here_dir" "$shared"
    else
      mv "$here_dir" "$here_dir.local-$(date +%Y%m%d-%H%M%S)"
      say "kept the previous $(basename "$here_dir") of this folder next to it; using $shared"
    fi
  elif [ ! -e "$shared" ] && [ "$#" -gt 2 ]; then
    # First run of a new Veyra version: start from the newest older one.
    # shellcheck disable=SC2012  # our own folder names, no newlines
    seed="$(ls -dt "${@:3}" 2>/dev/null | head -n1 || true)"
    if [ -n "$seed" ]; then cp -a "$seed" "$shared"; say "copied settings from $seed"; fi
  fi
  mkdir -p "$shared"
  ln -s "$shared" "$here_dir"
}
share_dir "$prefix/pfx/drive_c/users/steamuser/AppData/Local/Veyra" "$VEYRA_HOME/user/LocalAppData-Veyra"
if [ -z "${VEYRA_APP:-}" ]; then
  older=()
  for d in "$VEYRA_HOME"/app/*/runtime_local; do
    [ -d "$d" ] && [ ! -L "$d" ] && older+=("$d")
  done
  share_dir "$app/runtime_local" "$VEYRA_HOME/user/runtime_local" "${older[@]}"
fi

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
