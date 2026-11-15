#!/bin/bash
# Build a GE-Proton overlay that can run NVIDIA VFG in Veyra on Linux.
#
# It builds two patched components in a throw-away container and installs them
# into a symlink copy of GE-Proton, leaving the original install untouched:
#   - nvcuda (CUDA bridge)      + patches/0001-nvcuda-wine11-d3dkmt-external-memory.patch
#   - vkd3d-proton (D3D12)      + patches/0002-vkd3d-proton-shared-committed-buffers.patch
#
# Usage: build-vfg-proton.sh [path to GE-Proton11-3]
# Result: $VEYRA_VFG_DIR/GE-Proton-veyra-vfg/proton   (use it as VEYRA_PROTON with VEYRA_CUDA=1)
#
# Tested with GE-Proton11-3 only: the patches target the exact nvcuda and
# vkd3d-proton commits that build ships. See docs/LINUX_PROTON.md.
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ge="${1:-$HOME/.steam/steam/compatibilitytools.d/GE-Proton11-3}"
work="${VEYRA_VFG_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/veyra-proton/vfg}"
out="$work/GE-Proton-veyra-vfg"
engine="${CONTAINER_ENGINE:-$(command -v podman || command -v docker || true)}"
image="${VEYRA_VFG_IMAGE:-fedora:44}"
name=veyra-vfg-build

nvcuda_repo=https://github.com/SveSop/nvcuda.git
nvcuda_rev=772b344
vkd3d_repo=https://github.com/HansKristian-Work/vkd3d-proton.git
vkd3d_rev=3dfc6f07d0953b1e8b41705275c2c59cc7374fc5

[ -f "$ge/proton" ] || { echo "GE-Proton not found at $ge" >&2; exit 1; }
[ -n "$engine" ] || { echo "podman or docker is required" >&2; exit 1; }
mkdir -p "$work/src"

fetch() { # repo rev dir patch
  if [ ! -d "$work/src/$3/.git" ]; then git clone "$1" "$work/src/$3"; fi
  git -C "$work/src/$3" fetch --quiet origin
  git -C "$work/src/$3" checkout --quiet --force "$2"
  git -C "$work/src/$3" clean -qfd -e 'build64'
  git -C "$work/src/$3" submodule update --init --recursive
  git -C "$work/src/$3" apply "$here/patches/$4"
}
fetch "$nvcuda_repo" "$nvcuda_rev" nvcuda 0001-nvcuda-wine11-d3dkmt-external-memory.patch
fetch "$vkd3d_repo" "$vkd3d_rev" vkd3d-proton 0002-vkd3d-proton-shared-committed-buffers.patch

"$engine" rm -f "$name" >/dev/null 2>&1 || true
"$engine" run -d --name "$name" -v "$work/src:/work:z" "$image" sleep infinity >/dev/null
trap '"$engine" rm -f "$name" >/dev/null 2>&1 || true' EXIT
"$engine" exec "$name" dnf -y install wine-devel mingw64-gcc mingw64-gcc-c++ \
  mingw64-winpthreads-static meson ninja-build gcc gcc-c++ git glslang python3

# podman (rootless) maps the caller to root inside the container; docker needs -u.
user_args=()
case "$engine" in *docker) user_args=(-u "$(id -u):$(id -g)");; esac

"$engine" exec "${user_args[@]}" -w /work/nvcuda "$name" sh -c \
  'rm -rf build64 && meson setup --cross-file build-wine64.txt --buildtype release build64 && ninja -C build64'
"$engine" exec "${user_args[@]}" -w /work/vkd3d-proton "$name" sh -c \
  'rm -rf build64 && meson setup --cross-file build-win64.txt --buildtype release --strip -Denable_extras=false build64 && ninja -C build64'

# Symlink copy of GE-Proton; the launcher script must be a real file so that it
# resolves paths relative to the copy.
rm -rf "$out"
cp -as "$(readlink -f "$ge")" "$out"
rm "$out/proton" && cp "$ge/proton" "$out/proton"
# GE-Proton11-3 looks for nvidia-libs/nvapi when both NVAPI and the CUDA bridge are on.
[ -e "$out/files/lib/wine/nvidia-libs/nvapi" ] || ln -s ../nvapi "$out/files/lib/wine/nvidia-libs/nvapi"

install_file() { rm -f "$2"; cp "$1" "$2"; }
install_file "$work/src/nvcuda/build64/dlls/nvcuda/nvcuda.dll.so" \
  "$out/files/lib/wine/nvidia-libs/nvcuda/x86_64-windows/nvcuda.dll.so"
for f in d3d12core d3d12; do
  install_file "$work/src/vkd3d-proton/build64/libs/$f/$f.dll" \
    "$out/files/lib/wine/vkd3d-proton/x86_64-windows/$f.dll"
done

echo
echo "Done. Run Veyra with NVIDIA VFG support:"
echo "  VEYRA_PROTON='$out/proton' VEYRA_CUDA=1 VEYRA_PREFIX=\"\$HOME/.local/share/veyra-proton/prefix-vfg\" $here/veyra-proton.sh"
echo "Use a fresh prefix: Proton does not replace d3d12core.dll in an existing one."
