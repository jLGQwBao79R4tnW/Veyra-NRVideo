#!/bin/bash
# Build the Proton overlay that can run NVIDIA VFG in Veyra on Linux.
# veyra-proton.sh runs this automatically on its first start (unless VEYRA_VFG=0).
#
# It downloads the pinned GE-Proton (versions.sh) if it is not there yet,
# builds two patched components in a throw-away container and installs them
# into a copy of that GE-Proton:
#   - nvcuda (CUDA bridge)      + patches/0001-nvcuda-wine11-d3dkmt-external-memory.patch
#                                 + patches/0003-nvcuda-no-double-destroy-of-external-semaphores.patch
#   - vkd3d-proton (D3D12)      + patches/0002-vkd3d-proton-shared-committed-buffers.patch
#
# Everything is pinned: GE-Proton by release and checksum, the sources by full
# commit hash. The script stops if the GE-Proton it unpacked does not bundle
# exactly those component versions. Needs git, curl and podman or docker.
#
# Result: ~/.local/share/veyra-proton/proton/GE-Proton11-3-veyra-vfg
# See docs/LINUX_PROTON.md.
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=versions.sh
. "$here/versions.sh"

out="$VEYRA_VFG_PROTON_DIR"
src="$VEYRA_HOME/build/src"
# CONTAINER_ENGINE may hold several words, e.g. "host-spawn docker".
# shellcheck disable=SC2206
engine=(${CONTAINER_ENGINE:-$(command -v podman || command -v docker || true)})
# Inside a distrobox or toolbox there is usually no engine, but the host has
# one; reach it through the container's host bridge. The source folder lives
# under $HOME, which these containers share with the host at the same path.
if [ "${#engine[@]}" = 0 ]; then
  for bridge in distrobox-host-exec host-spawn; do
    command -v "$bridge" >/dev/null || continue
    for e in podman docker; do
      if "$bridge" "$e" --version >/dev/null 2>&1; then engine=("$bridge" "$e"); break 2; fi
    done
  done
fi
image="${VEYRA_VFG_IMAGE:-fedora:44}"
name=veyra-vfg-build

[ "${#engine[@]}" -gt 0 ] || die "podman or docker is required to build the VFG overlay"
command -v git >/dev/null || die "git is required"

ensure_ge_proton
ge="$VEYRA_GE_DIR"

# The overlay swaps single files inside GE-Proton, so the base must ship the
# component versions the patches were written and tested against.
check_bundled() { # name version-file expected
  local got; got="$(tr -d '[:space:]' < "$2" 2>/dev/null || true)"
  case "$got" in
    *"$3"*) ;;
    *) die "$1 bundled in $ge is '${got:-unknown}', expected $3" ;;
  esac
}
check_bundled nvcuda "$ge/files/lib/wine/nvidia-libs/nvcuda/version" "$NVCUDA_REV"
check_bundled vkd3d-proton "$ge/files/lib/wine/vkd3d-proton/version" "$VKD3D_REV"

mkdir -p "$src"
fetch() { # repo rev dir patch...
  if [ ! -d "$src/$3/.git" ]; then git clone "$1" "$src/$3"; fi
  git -C "$src/$3" fetch --quiet origin
  git -C "$src/$3" checkout --quiet --force --detach "$2"
  [ "$(git -C "$src/$3" rev-parse HEAD)" = "$2" ] || die "$3: commit $2 not found"
  git -C "$src/$3" clean -qfdx
  git -C "$src/$3" submodule update --init --recursive
  local repo_dir="$src/$3" p
  shift 3
  for p in "$@"; do git -C "$repo_dir" apply "$here/patches/$p"; done
}
say "fetching sources"
fetch "$NVCUDA_REPO" "$NVCUDA_REV" nvcuda 0001-nvcuda-wine11-d3dkmt-external-memory.patch \
  0003-nvcuda-no-double-destroy-of-external-semaphores.patch
fetch "$VKD3D_REPO" "$VKD3D_REV" vkd3d-proton 0002-vkd3d-proton-shared-committed-buffers.patch

say "building in a $image container (several minutes)"
"${engine[@]}" rm -f "$name" >/dev/null 2>&1 || true
# VEYRA_VFG_RUN_ARGS: extra arguments for the container, e.g. proxy settings.
# shellcheck disable=SC2086
"${engine[@]}" run -d --name "$name" ${VEYRA_VFG_RUN_ARGS:-} -v "$src:/work:z" "$image" sleep infinity >/dev/null
trap '"${engine[@]}" rm -f "$name" >/dev/null 2>&1 || true' EXIT
"${engine[@]}" exec "$name" dnf -y install wine-devel mingw64-gcc mingw64-gcc-c++ \
  mingw64-winpthreads-static meson ninja-build gcc gcc-c++ git glslang python3

# podman (rootless) maps the caller to root inside the container; docker needs -u.
user_args=()
"${engine[@]}" --version 2>/dev/null | grep -qi podman || user_args=(-u "$(id -u):$(id -g)")

"${engine[@]}" exec "${user_args[@]}" -w /work/nvcuda "$name" sh -c \
  'meson setup --cross-file build-wine64.txt --buildtype release build64 && ninja -C build64'
"${engine[@]}" exec "${user_args[@]}" -w /work/vkd3d-proton "$name" sh -c \
  'meson setup --cross-file build-win64.txt --buildtype release -Denable_extras=false build64 && ninja -C build64'

# Symlink copy of our own pinned GE-Proton. The launcher script must be a real
# file so that it resolves paths relative to the copy.
say "installing into $out"
rm -rf "$out"
cp -as "$ge" "$out"
rm "$out/proton" && cp "$ge/proton" "$out/proton"
# GE-Proton11-3 looks for nvidia-libs/nvapi when both NVAPI and the CUDA bridge are on.
[ -e "$out/files/lib/wine/nvidia-libs/nvapi" ] || ln -s ../nvapi "$out/files/lib/wine/nvidia-libs/nvapi"

install_file() { rm -f "$2"; cp "$1" "$2"; }
install_file "$src/nvcuda/build64/dlls/nvcuda/nvcuda.dll.so" \
  "$out/files/lib/wine/nvidia-libs/nvcuda/x86_64-windows/nvcuda.dll.so"
for f in d3d12core d3d12; do
  install_file "$src/vkd3d-proton/build64/libs/$f/$f.dll" \
    "$out/files/lib/wine/vkd3d-proton/x86_64-windows/$f.dll"
done
{
  echo "base=$GE_PROTON"
  echo "nvcuda=$NVCUDA_REV"
  echo "vkd3d-proton=$VKD3D_REV"
  echo "image=$image"
  echo "patches=$(vfg_patches_id)"
} > "$out/.veyra-vfg-complete"

say "done. Start Veyra with NVIDIA VFG support: $here/veyra-proton.sh"
