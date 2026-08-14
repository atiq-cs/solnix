# /root/drm-port/amdgpu/ — C3-amdgpu-a phase artifact

The C3-amdgpu-a scaffolding: the smallest load-bearing amdgpu piece (PCI
attach + asic detect + BAR map + register access + interrupt vector) compiling
against illumos headers + the C1 DRM framework, for the g4ad target
(AMD Radeon Pro V520 = Navi 12 = gfx1011, PCI 1002:7362).

## Contents

    amdgpu.c        the reduced amdgpu_device_init: amdgpu_transport_attach
    amdgpu_priv.h   the softc (reduced adev) + BAR/register/asic model
    amdgpu.o        the compiled ET_REL AMD64 object (reference copy)

The BUILD copies live in ../src/ (amdgpu.c + amdgpu_priv.h are in the Makefile
OBJS and linked into the single ../drm module). These are the canonical
phase-artifact copies.

## Build + verify (from ../ )

    cd .. && make            # builds src/amdgpu.o + links it into `drm`
    ./verify-syms.sh         # 113 undefs, zero phantom (all real illumos KPI)
    gcc -o /tmp/t test/test_c3_amdgpu.c && /tmp/t   # logic self-check: PASS

## What it does (COMPILE only — does NOT run, does NOT bring up any IP block)

  1. pci_config_setup + read vendor/device/rev -> classify CHIP_NAVI12
  2. ddi_regs_map_setup BAR5 (MMIO regs) + BAR0 (VRAM aperture)
  3. amdgpu_rreg32/_wreg32 = RREG32/WREG32 via ddi_get32/ddi_put32 (4*reg)
  4. ddi_intr_alloc (MSI-X preferred) + ddi_intr_add_handler (vector reserved)

Called from the C1 drm_attach exactly like virtio_gpu_transport_attach; returns
NULL on a non-AMD-GPU parent (clean no-op, same contract).

## Crib + design

  - crib pinned in ../amdgpu-ref/ (see its PROVENANCE.md)
  - the full illumos-layering design (TTM/PCI/GEM/rings/KFD/firmware, what's new
    vs C1, the linux-compat gaps) in ../docs/design-gpu-amdgpu.md

## R-next: C3-amdgpu-b = the smallest TTM (VRAM range allocator over BAR0 +
GTT via ddi_dma), the key new subsystem C1 deferred. See the design doc.
