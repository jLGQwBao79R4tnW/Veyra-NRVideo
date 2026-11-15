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

Requirements: Steam with Proton Experimental installed, the proprietary NVIDIA
driver, and the Veyra NVIDIA portable package extracted somewhere.

```bash
VEYRA_APP=/path/to/Veyra-2.1.6-NVIDIA-win64-portable scripts/linux/veyra-proton.sh
# or open a file directly
VEYRA_APP=/path/to/Veyra-2.1.6-NVIDIA-win64-portable scripts/linux/veyra-proton.sh ~/Videos/clip.mp4
```

The script uses its own prefix (`~/.local/share/veyra-proton/prefix`) and does
not touch Steam game prefixes. `VEYRA_LOG=1` writes a Proton log next to the
prefix. Veyra's own log is `logs/veyra-qml.log` inside the package folder.

In Veyra: Tab switches to Pro mode. Enable "Super resolution" → RTX Video
Super Resolution, and "Frame Gen" → FSR 3.1 · 2X. Keep the motion source on
"Zero motion".

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
Vulkan then falls back to llvmpipe. Write an ICD JSON with the container's
path to `libGLX_nvidia.so.0` and export `VK_DRIVER_FILES` before starting the
launcher. Running directly on the host avoids this.

## NVIDIA VFG

NVIDIA VFG shares D3D12 buffers and fences with CUDA. Under Proton this fails
in two places, and both need a patched component:

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

### Pinned versions

The patches are written against, and were tested with, exactly these versions.
`build-vfg-proton.sh` checks out these commits and nothing newer:

| Component | Pinned to | How it is enforced |
|---|---|---|
| nvcuda | SveSop/nvcuda `772b344a3594fca916999c5c5288d875332de482` (`v0.3-13-g772b344`) | fixed commit in the script |
| vkd3d-proton | HansKristian-Work/vkd3d-proton `3dfc6f07d0953b1e8b41705275c2c59cc7374fc5` (`vkd3d-1.1-5438-g3dfc6f07d`) | fixed commit in the script |
| Proton base | GE-Proton11-3 | the script reads the two `version` files inside the GE-Proton folder and stops if they differ |

New upstream releases of nvcuda, vkd3d-proton or GE-Proton therefore do not
change or break an overlay: the script keeps building the same sources, and an
overlay that is already built is a self-contained folder. Keep GE-Proton11-3
installed, because the overlay is a symlink copy of it and Steam may offer to
replace it with a newer GE-Proton.

Two things are not pinned: the build container image (`fedora:44`, override
with `VEYRA_VFG_IMAGE`) and the Wine headers it installs (11.21 when tested).
Moving to a newer GE-Proton means rebasing both patches onto the commits that
build ships and re-testing; `VEYRA_VFG_FORCE=1` only skips the check. The
patches become unnecessary once vkd3d-proton supports shared committed buffers
and Wine MR !12339 lands with an nvcuda release that uses it.

Result with both patches, test clip 1080p30 → SR to 4K → VFG 2X, quality
Medium, `compatibility=SM86-experimental`: 60 fps on screen from 30, 1% low
47 fps, VFG about 8.3 ms average and 10.6 ms P95 per frame, no CUDA errors,
no visible artifacts on the synthetic clip. Not yet measured: real content and
a live PS5 stream.

### Building the overlay

```bash
scripts/linux/build-vfg-proton.sh            # needs GE-Proton11-3, podman or docker, git
VEYRA_PROTON="$HOME/.local/share/veyra-proton/vfg/GE-Proton-veyra-vfg/proton" \
VEYRA_CUDA=1 VEYRA_PREFIX="$HOME/.local/share/veyra-proton/prefix-vfg" \
VEYRA_APP=/path/to/Veyra-2.1.6-NVIDIA-win64-portable scripts/linux/veyra-proton.sh
```

The script builds both components in a throw-away Fedora container and
installs them into a symlink copy of GE-Proton; the original GE-Proton install
is not modified. Use a separate prefix for it, because Proton does not replace
`d3d12core.dll` in an existing prefix. PS5 pairing is stored per prefix.

`build-vfg-proton.sh` automates the commands that were run by hand for the
measurements above. The script itself has not been run end to end yet.

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
