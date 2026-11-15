# Patches for third-party components

These patches are not applied to Veyra. They patch components of Proton so that
NVIDIA VFG can share D3D12 buffers and fences with CUDA on Linux. See
`docs/LINUX_PROTON.md` and `../build-vfg-proton.sh`.

| Patch | Project | Base commit | Project licence |
|---|---|---|---|
| `0001-nvcuda-wine11-d3dkmt-external-memory.patch` | https://github.com/SveSop/nvcuda | `772b344` | LGPL (see upstream LICENSE.md) |
| `0002-vkd3d-proton-shared-committed-buffers.patch` | https://github.com/HansKristian-Work/vkd3d-proton | `3dfc6f07d0953b1e8b41705275c2c59cc7374fc5` | LGPL-2.1 |

Each patch is offered under the licence of the project it modifies.
