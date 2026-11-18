# Pinned versions for running Veyra on Linux. Sourced by the other scripts.
# Every machine downloads exactly these files and verifies their checksums,
# so two installs cannot end up with different component versions.
# Changing anything here means re-testing; see docs/LINUX_PROTON.md.

VEYRA_VERSION=2.1.9
VEYRA_PKG="Veyra-${VEYRA_VERSION}-NVIDIA-win64-portable"
VEYRA_PKG_URL="https://github.com/Likely7/Veyra-NRVideo/releases/download/v${VEYRA_VERSION}/${VEYRA_PKG}.zip"
VEYRA_PKG_SHA256=4225ecb11a8e96c2826b4b0b798feb811d7ae237f3edf0b627f3b6895c79f362

GE_PROTON=GE-Proton11-3
GE_PROTON_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${GE_PROTON}/${GE_PROTON}.tar.gz"
GE_PROTON_SHA512=528ae7831f909c0a4fff5d83889ac6dab3c9706746cd148f05f3064ac042763853d68277e2a815f18f16c17285d5d128864a03c563956c0dce30bafcd16aa77c

# Components rebuilt with the patches in ./patches for NVIDIA VFG. These are
# the commits GE-Proton11-3 itself ships.
NVCUDA_REPO=https://github.com/SveSop/nvcuda.git
NVCUDA_REV=772b344a3594fca916999c5c5288d875332de482
NVCUDA_VERSION=v0.3-13-g772b344          # files/lib/wine/nvidia-libs/nvcuda/version
VKD3D_REPO=https://github.com/HansKristian-Work/vkd3d-proton.git
VKD3D_REV=3dfc6f07d0953b1e8b41705275c2c59cc7374fc5
VKD3D_VERSION=vkd3d-1.1-5438-g3dfc6f07d  # files/lib/wine/vkd3d-proton/version

# Everything is installed below this folder, away from Steam's own
# compatibilitytools.d, so Steam or a Proton manager cannot replace it.
VEYRA_HOME="${VEYRA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/veyra-proton}"
VEYRA_GE_DIR="$VEYRA_HOME/proton/$GE_PROTON"
VEYRA_VFG_PROTON_DIR="$VEYRA_HOME/proton/$GE_PROTON-veyra-vfg"
VEYRA_APP_DIR="$VEYRA_HOME/app/$VEYRA_PKG"

say() { echo "veyra-proton: $*" >&2; }
die() { say "$*"; exit 1; }

# download_verified URL ALGO(sha256|sha512) EXPECTED DEST
# Downloads to DEST unless a file with the right checksum is already there.
download_verified() {
  local url="$1" algo="$2" want="$3" dest="$4" got
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ]; then
    got="$("${algo}sum" "$dest" | cut -d' ' -f1)"
    [ "$got" = "$want" ] && return 0
    say "$(basename "$dest") is incomplete or changed, downloading again"
  fi
  say "downloading $(basename "$dest")"
  curl --fail --location --retry 3 --progress-bar --continue-at - --output "$dest.part" "$url" \
    || die "download failed: $url"
  got="$("${algo}sum" "$dest.part" | cut -d' ' -f1)"
  if [ "$got" != "$want" ]; then
    rm -f "$dest.part"
    die "checksum mismatch for $(basename "$dest"): got $got, expected $want"
  fi
  mv "$dest.part" "$dest"
}

# Pinned GE-Proton in our own folder. Prints nothing; the result is $VEYRA_GE_DIR.
ensure_ge_proton() {
  [ -f "$VEYRA_GE_DIR/proton" ] && return 0
  local tarball="$VEYRA_HOME/downloads/$GE_PROTON.tar.gz" tmp="$VEYRA_HOME/proton/.unpack.$$"
  download_verified "$GE_PROTON_URL" sha512 "$GE_PROTON_SHA512" "$tarball"
  say "unpacking $GE_PROTON"
  rm -rf "$tmp"; mkdir -p "$tmp"
  tar -xzf "$tarball" -C "$tmp"
  [ -f "$tmp/$GE_PROTON/proton" ] || { rm -rf "$tmp"; die "unexpected layout in $GE_PROTON.tar.gz"; }
  rm -rf "$VEYRA_GE_DIR"; mv "$tmp/$GE_PROTON" "$VEYRA_GE_DIR"; rm -rf "$tmp"
}

# Pinned Veyra portable package. The result is $VEYRA_APP_DIR.
ensure_veyra_app() {
  [ -f "$VEYRA_APP_DIR/veyra_qml_ui.exe" ] && return 0
  local zip="$VEYRA_HOME/downloads/$VEYRA_PKG.zip" tmp="$VEYRA_HOME/app/.unpack.$$" exe
  download_verified "$VEYRA_PKG_URL" sha256 "$VEYRA_PKG_SHA256" "$zip"
  say "unpacking $VEYRA_PKG"
  rm -rf "$tmp"; mkdir -p "$tmp"
  if command -v unzip >/dev/null; then unzip -q "$zip" -d "$tmp"
  else python3 -m zipfile -e "$zip" "$tmp"; fi
  exe="$(find "$tmp" -maxdepth 3 -name veyra_qml_ui.exe -print -quit)"
  [ -n "$exe" ] || { rm -rf "$tmp"; die "veyra_qml_ui.exe not found in $VEYRA_PKG.zip"; }
  rm -rf "$VEYRA_APP_DIR"; mv "$(dirname "$exe")" "$VEYRA_APP_DIR"; rm -rf "$tmp"
}

# Identifies the patch set an overlay was built from; veyra-proton.sh rebuilds
# the overlay when the patches change.
vfg_patches_id() {
  cat "$(dirname "${BASH_SOURCE[0]}")"/patches/*.patch | sha256sum | cut -c1-16
}
