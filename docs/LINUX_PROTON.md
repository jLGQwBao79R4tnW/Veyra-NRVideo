# Running Veyra on Linux through Proton

Veyra is a Windows application (D3D12, DXGI, NVIDIA NGX). There is no native
Linux build. The Windows portable package runs under Proton, and this page
records what was measured, what works, what does not, and how to start it.

Everything here was tested on one machine on 2026-11-15. Treat other hardware,
drivers and Proton builds as untested.

| | |
|---|---|
| GPU | NVIDIA GeForce RTX 3060 Ti, 8 GB |
| Driver | NVIDIA 615.78.08 |
| System | Fedora 44, KDE Plasma, Wayland (Xwayland), kernel 7.3.3 |
| Veyra | 2.1.6 NVIDIA win64 portable |
| Proton | Proton Experimental 11.0 (20261112); GE-Proton11-3 for NVIDIA VFG |

## What works

| Feature | Stock Proton Experimental | Notes |
|---|---|---|
| UI, D3D12 device | yes | vkd3d-proton, feature level 12_2 |
| Local video playback | yes | software decode |
| RTX Video Super Resolution (NGX) | yes | needs `nvngx.dll` and `_nvngx.dll` in the prefix, see below |
| FSR 3.1 frame generation 2X | yes | 30 → 60 at 4K output, about 6–7 ms per frame |
| PS5 Remote Play | yes | discovery, pairing, 1080p60 H.264, DualSense with gyro and touchpad |
| NVIDIA VFG 2X (RTX 30 experimental path) | **no** | works with two patched components, see "NVIDIA VFG" |
| DLSS Frame Generation (RTX 30 path) | no | see "Known problems" |
| NVOF optical flow | no | use "Zero motion" |
| D3D12VA hardware decode | no | falls back to software decode automatically |
| Capture cards, Xbox, Moonlight | not tested | |

Measured PS5 Remote Play session (11 minutes, 1080p60 H.264, about 7.5 Mbit/s):
no lost packets and no transport or decode errors; software decode about
2.3 ms per frame; RTX Video SR 1080p → 4K about 4.5 ms; FSR 3.1 FG 2X gave
120 fps on screen from 60 fps input with 0.09% of frames dropped; in-app
latency from frame arrival to present about 29 ms (P95).

A PS5 sends a 60 fps stream even when the game renders at 30 fps, with every
frame repeated. To interpolate real game frames in that case, enable
"Remove duplicate frames" (Automatic removal or 60→30) in Pro mode. This case
has not been measured on Linux yet.

## Quick start

Requirements: the proprietary NVIDIA driver, `curl`, `tar`, and `unzip` or
`python3`. Nothing else has to be installed by hand.

```bash
scripts/linux/veyra-proton.sh                    # open Veyra
scripts/linux/veyra-proton.sh ~/Videos/clip.mp4  # open a file directly
scripts/linux/veyra-proton.sh --setup            # only download and prepare
```

On first run the script downloads the pinned Veyra package and the pinned
GE-Proton, verifies their checksums and unpacks them under
`~/.local/share/veyra-proton` (`VEYRA_HOME`). It does not use or touch Steam's
Proton installs or game prefixes, so Steam updates cannot change what runs,
and every machine ends up with the same versions. About 1.2 GB is downloaded.

`VEYRA_LOG=1` writes a Proton log to `$VEYRA_HOME/logs`. Veyra's own log is
`logs/veyra-qml.log` inside the package folder.

A fresh install starts with super resolution and frame generation off; turn
them on once and Veyra remembers. Tab switches to Pro mode. Enable "Super
resolution" → RTX Video Super Resolution, and "Frame Gen" → FSR 3.1 · 2X. Keep
the motion source on "Zero motion".

The measurements in "What works" for the stock path were taken with Proton
Experimental. The launcher uses the pinned GE-Proton11-3 instead, on which
RTX Video SR and FSR frame generation were also confirmed; PS5 Remote Play
has not been re-run on it. `VEYRA_PROTON` selects another Proton for
comparison.

### NGX libraries

RTX Video SR needs the Wine NGX libraries that ship with the Linux NVIDIA
driver (`nvngx.dll`, `_nvngx.dll`, usually in `/usr/lib64/nvidia/wine`).
Proton copies them into the prefix when it finds them next to
`libGLX_nvidia.so.0`. That lookup fails inside containers such as distrobox,
so the launcher copies them itself and searches the usual host and
`/run/host` locations. Set `VEYRA_NGX_DIR` if the driver keeps them elsewhere.

### Running from a distrobox or toolbox container

If the container's distribution differs from the host, the host Vulkan ICD
file can point at a library path that does not exist in the container, and
Vulkan then falls back to llvmpipe. The launcher detects a container and
writes its own ICD files that point at the container's `libGLX_nvidia.so.0`.
Set `VK_DRIVER_FILES` yourself to override. Running directly on the host
needs none of this.

### Settings and pairing

Veyra keeps its data in two places: PS5, Xbox and Moonlight pairing in
`%LOCALAPPDATA%\Veyra` inside the Wine prefix (`remoteplay/<id>.dat` plus
`settings.ini`), and its own settings, presets and playlist in
`runtime_local/` next to `veyra_qml_ui.exe`. With one prefix per mode and one
app folder per version, PS5 had to be paired again after every version change
and when switching to `VEYRA_VFG=1`.

The launcher therefore turns both into symlinks into `$VEYRA_HOME/user/`
(`LocalAppData-Veyra`, `runtime_local`) on every start. Existing data is moved
there the first time. If the shared folder already exists, a different local
copy is renamed to `*.local-<date>` and kept. A new Veyra version without
settings starts from a copy of the newest older version's `runtime_local`.
Nothing is moved while Veyra is running.

The PS5 profile is encrypted with `CryptProtectData`. Wine derives that key
from the user name, which is `steamuser` in every Proton prefix, so the same
file decrypts in both prefixes. Confirmed on the test machine on 2026-11-18:
a profile paired in `prefix` was read in `prefix-vfg` (`profiles=1
readFailures=0`). If it ever does not, the log shows
`[remoteplay-ui] profiles=N readFailures=M` with M > 0, and pairing once more
fixes it.

## NVIDIA VFG

NVIDIA VFG shares D3D12 buffers and fences with CUDA. Under Proton this fails
in two places that need a patched component, and the CUDA bridge has a third
bug that crashes on repeated VFG starts:

1. **CUDA bridge.** Stock Proton ships a stub `nvcuda.dll`, so `cuInit` is
   missing. GE-Proton and Proton-CachyOS ship the nvidia-libs bridge
   (`PROTON_NVIDIA_NVCUDA=1`), but on Wine 11 it cannot turn shared D3D12
   handles into file descriptors: `sharedgpures.sys` is gone, shared resources
   are D3DKMT objects inside wineserver, and the D3D12 handle types were not
   handled at all. Result: `cuImportExternalMemory` returns
   `CUDA_ERROR_INVALID_VALUE`. Tracked upstream as SveSop/nvcuda#18; the proper
   fix is Wine MR !12339 (draft at the time of writing).
   `scripts/linux/patches/0001-nvcuda-wine11-d3dkmt-external-memory.patch`
   resolves the fd through the private wineserver request
   `d3dkmt_object_open`. The request number differs between Proton builds, so
   the patch reads it from the running wineserver's symbol table. This is a
   stopgap: it stops working if a build strips wineserver symbols.

2. **vkd3d-proton.** `VfgBackend.cpp` creates a shared committed *buffer*
   (`D3D12_HEAP_FLAG_SHARED` + `CreateSharedHandle`). vkd3d-proton implements
   shared committed resources for textures only, so the buffer gets no
   exportable memory and `CreateSharedHandle` returns `S_OK` with a null
   handle. `scripts/linux/patches/0002-vkd3d-proton-shared-committed-buffers.patch`
   gives shared committed buffers a dedicated exportable allocation registered
   with D3DKMT (2 files, 64 lines).

3. **nvcuda double destroy (crash on the third VFG start).** nvcuda keeps the
   last four imported external semaphores in a ring (`semaphoreHandling()`,
   upstream commit `d612b0f` "Aggressively try to destroy used semaphores")
   and destroys the oldest when the ring wraps, even if the application has
   already destroyed it. Each VFG start imports two fences, and Veyra destroys
   them when VFG is turned off. So the third VFG start in one Veyra session
   (switching FG to NVIDIA VFG, away and back twice) destroyed a semaphore a
   second time and libcuda crashed: `page fault on read access to
   0x0000000000000048` in `libcuda.so.1`, called from
   `cuDestroyExternalSemaphore` inside `wine_cuImportExternalSemaphore`
   (seen 2026-11-18 on the test machine). The first two VFG starts worked
   (60 generated frames per second, 120 fps output).
   `scripts/linux/patches/0003-nvcuda-no-double-destroy-of-external-semaphores.patch`
   removes a semaphore from the ring when the application destroys it.
   The launcher rebuilds the overlay by itself when the patch set changes
   (`patches=` line in `.veyra-vfg-complete`).

### Pinned versions

All versions live in `scripts/linux/versions.sh`. The scripts download exactly
these and stop on a checksum or version mismatch:

| Component | Pinned to | Enforced by |
|---|---|---|
| Veyra | 2.1.9 NVIDIA win64 portable (measurements above were on 2.1.6) | SHA-256 of the release zip |
| Proton | GE-Proton11-3 | SHA-512 of the release tarball |
| nvcuda | SveSop/nvcuda `772b344a3594fca916999c5c5288d875332de482` (`v0.3-13-g772b344`) | full commit hash |
| vkd3d-proton | HansKristian-Work/vkd3d-proton `3dfc6f07d0953b1e8b41705275c2c59cc7374fc5` (`vkd3d-1.1-5438-g3dfc6f07d`) | full commit hash |

The two source commits are the ones GE-Proton11-3 itself bundles; the build
script checks the bundled `version` files and stops if they differ.

New upstream releases of any of these therefore do not change or break an
install: the scripts keep fetching the same files, into their own folder.

Two things are not pinned: the build container image (`fedora:44`, override
with `VEYRA_VFG_IMAGE`) and the Wine headers and compilers it installs (Wine
11.21 headers when tested). Two builds on the same machine gave a
byte-identical `nvcuda.dll.so`; `d3d12core.dll` and `d3d12.dll` differed only
in the PE build timestamps. A different container image or compiler version
could change the binaries further even though the sources are identical.

Moving to a newer GE-Proton means updating `versions.sh`, rebasing the
patches onto the commits that build ships, and re-testing. The patches become
unnecessary once vkd3d-proton supports shared committed buffers and Wine
MR !12339 lands with an nvcuda release that uses it.

### Running with NVIDIA VFG

```bash
VEYRA_VFG=1 scripts/linux/veyra-proton.sh
```

The first start builds the overlay (`build-vfg-proton.sh`, needs `git` and
podman or docker): it builds both patched components in a throw-away Fedora
container and installs them into a copy of the pinned GE-Proton at
`$VEYRA_HOME/proton/GE-Proton11-3-veyra-vfg`. Later starts reuse it. This mode
has its own prefix (`$VEYRA_HOME/prefix-vfg`), because Proton does not replace
`d3d12core.dll` in an existing prefix. User data is shared between the two
modes, see "Settings and pairing".

In Veyra choose "Frame Gen" → NVIDIA VFG → 2X.

Behind a proxy, pass container options through `VEYRA_VFG_RUN_ARGS`.
Inside a distrobox or toolbox without its own podman or docker, the build
script uses the host's engine through `distrobox-host-exec` or `host-spawn`.
`CONTAINER_ENGINE` may name the engine directly, also as several words
(`CONTAINER_ENGINE="host-spawn docker"`). On the test machine (Ubuntu 24.04
distrobox on Fedora, docker on the host through `host-spawn`) the overlay
build of 2.1.9 took about 6 minutes.

The scripts were run from nothing on the test machine (inside a distrobox,
docker on the host): setup took 66 s, the overlay build 162 s. NVIDIA VFG 2X
then ran as with the hand-built components: 60 fps from 30, 1% low 47.9 fps,
no CUDA errors. The whole install takes about 5.8 GB, of which 1.2 GB is the
download cache and 0.4 GB the build tree; both can be deleted afterwards.

GE-Proton may download an FSR4 upgrade library into the prefix on first run
("Automatic FSR4 upgrade"); that is GE-Proton's own behaviour.

## Known problems

Differences seen under Proton that are candidates for fixes, in Veyra or
upstream:

- **DLSS Frame Generation, RTX 30 path.** With optical flow:
  `[nvof-session] scalar cap WIDTH_MIN query failed st=11`, although dxvk-nvapi
  creates the optical flow session. With "Zero motion": the DLSS-G patches
  apply, then `native requirements result=0xBAD00012` and
  `driver gate publication/restore failed`; the patch probably expects the
  Windows driver's `_nvngx.dll`.
- **D3D12VA decode.** `av_hwdevice_ctx_init failed code=-22`, software
  fallback is used.
- **GPU engine counters.** `PdhEnumObjectItemsW` for "GPU Engine" is a stub in
  Wine: `GPU engine counters unavailable`.
- **GPU priority.** `gpu-priority requested=4 actual=-1 ntstatus=0x7F`.
- **Qt TLS.** `Failed to enumerate ciphers` (schannel); the update check still
  succeeds.
- **dxvk-nvapi.** `NvAPI_Disp_GetVRRInfo` and
  `NvAPI_DISP_GetMonitorCapabilities` are not implemented.
- **Frame generation cannot be enabled from the command line** in
  `veyra_qml_ui.exe`; the `--fg*` switches exist only in the legacy shell.

## Upstream sync 2026-11-18

Upstream `Likely7/Veyra-NRVideo` main was merged at `33dfdf71` (fork point
was `c327d45`, 2026-11-15). The merge was clean: upstream did not touch
`scripts/linux/` or this page, and none of our files exist upstream.

What this means for the Linux path:

- **The launcher now pins Veyra 2.1.9** (was 2.1.6). The SHA-256
  `4225ecb1…5c79f362` (731,012,476 bytes) is taken from upstream's release
  record `docs/RELEASE_2.1.9_EXECUTION_2026-11-15.md`; the 2.1.6 hash in the
  matching 2.1.6 record equals the one we measured by downloading, so the
  record is trusted. The zip itself could not be downloaded from the cloud
  session (GitHub releases blocked by the network allowlist), so its layout is
  unchecked; `ensure_veyra_app` finds `veyra_qml_ui.exe` up to three levels
  deep and stops with an error otherwise. 2.1.9 unpacks next to 2.1.6 under
  `$VEYRA_HOME/app/` and uses the same prefixes, so settings and PS5 pairing
  carry over. To go back, set `VEYRA_VERSION` and `VEYRA_PKG_SHA256` to the
  2.1.6 values (git history) or point `VEYRA_APP` at the old folder.
- **2.1.9 first start, 2026-11-18, test machine** (GE-Proton11-3, stock
  path): `--setup` downloaded the zip, the SHA-256 matched and
  `veyra_qml_ui.exe` was found. Veyra started: RTX 3060 Ti detected, D3D12
  through vkd3d-proton (no llvmpipe), intro played, UI about 62 fps, update
  check "current". Same known warnings as 2.1.6 (Qt TLS ciphers, GPU engine
  counters, GPU priority). New in 2.1.9: `[startup-music] engine error 4
  hr=0x80004003`, the startup music does not play under Proton (E_POINTER;
  cause not investigated). Proton `err:` lines were only OpenXR and winebth,
  both harmless.
  Frame generation "does not turn on" on a fresh 2.1.9 profile: the default
  FG motion source is Automatic, which for DLSS-G (backend 0) and FSR
  (backend 2) means NVIDIA optical flow. dxvk-nvapi 0.9.2's `nvofapi64`
  creates the session but answers the `WIDTH_MIN` capability query with
  status 11, Veyra fails closed (`[nvof-session] scalar cap WIDTH_MIN query
  failed st=11`, `[graph] NVOF init failed`) and rolls FG back to off without
  a visible error. Fix: set the frame generation motion source to "Zero
  motion" and use FSR 3.1 · 2X. NVIDIA VFG in the same run failed with
  `[vfg] missing API cuInit` because the launcher was started without
  `VEYRA_VFG=1`, as expected.
  Still to check on 2.1.9: RTX Video SR, FSR 3.1 FG 2X, PS5 Remote Play,
  `VEYRA_VFG=1` with NVIDIA VFG 2X. Until then the "What works" table
  describes 2.1.6.
- **NVIDIA VFG patches still apply to the same code.** `src/pipeline/VfgBackend.cpp`
  is unchanged upstream, so the shared committed buffer + CUDA import path the
  two patches fix is the same.
- **Upstream now has its own, unrelated Linux part:** a native OBS filter in
  `linux/obs/` (3D LUT, exposure/contrast/saturation, FXAA, sharpen; no NGX,
  no VFG), see [OBS_FILTER.md](OBS_FILTER.md). On non-Windows the top-level
  `CMakeLists.txt` now builds only that module and stops. It is not a Linux
  port of the player and does not replace the Proton path. Built here with
  `libobs-dev` 30.0.2 on Ubuntu 24.04: module and parser test pass.
  Note: the test is registered in `linux/obs`, so `ctest --test-dir out/obs`
  (as in `.github/workflows/obs-filter-checks.yml`) finds no tests and exits
  successfully; `ctest --test-dir out/obs/linux/obs` runs it.
- **New upstream features not checked under Proton** (in upstream main, some only after
  the 2.1.9 release; none tried under Proton yet): DirectShow virtual camera
  (`virtualcam/`, registered by `veyra-camera-setup.exe`), Bilibili page,
  Dolby Vision profile 5/7, startup music and intro, AMD AMF frame rate
  conversion (AMD only), the optional software decode switch for Xbox, and the
  NVIDIA VRR profile row (writes NvAPI driver profiles through
  `nvapi64.dll`; under Proton that is dxvk-nvapi, where driver profiles are
  stubbed at best, so expect it not to work).
- Two new upstream workflows now also run in this fork: `obs-filter-checks.yml`
  (Ubuntu) and `vrr-profile-checks.yml` (Windows runner).
