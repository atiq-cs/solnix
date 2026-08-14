# amdgpu crib — provenance (solnix C3-amdgpu-a)

## Source

    upstream:  https://github.com/NetBSD/src.git   (NetBSD-current mirror)
    pin:       5a7765109d6feb3a897b349b8d58572a0b7812f2   (same pin as ../netbsd-ref)
    subtree:   sys/external/bsd/drm2/dist/drm/amd/amdgpu
    tree sha:  d4a55e6c84ff0658d0ebaa18b3ffc8a3016c0449   (the amdgpu dir at this pin)
    fetched:   via the GitHub git-blobs API (Accept: application/vnd.github.raw),
               NOT a full clone — the amdgpu dir is 329 files; only the
               device-init crib subset below was pulled.

The amdgpu dir underneath is the Linux amdgpu driver imported into NetBSD's
drm2 (each file carries both the AMD/Red Hat MIT copyright header AND a NetBSD
`$NetBSD: amdgpu_*.c,v ...$` RCS id, e.g. `amdgpu_device.c,v 1.21 2024/07/01`).
NetBSD prefixes every imported Linux file with `amdgpu_` (Linux `nv.c` ->
NetBSD `amdgpu_nv.c`, Linux `device.c` -> `amdgpu_device.c`).

Same pin as ../netbsd-ref deliberately: the C1 linux-compat shim was written
against this NetBSD pin's linux/*.h, so amdgpu cribbed from the SAME pin sees
the same KPI boundary. (The alternate reference is Linux upstream
drivers/gpu/drm/amd/amdgpu at any LTS tag — identical logic, minus NetBSD's
`amdgpu_` prefix and its `__KERNEL_RCSID`.)

## Files pulled (the Navi 12 / gfx1011 device-init crib, src/)

    amdgpu.h            38334  the adev (amdgpu_device) struct + IP-block API
    amdgpu_device.c    126295  amdgpu_device_init + ip_early_init/ip_init chain
    amdgpu_drv.c        60903  the PCI id table + pci_driver probe/remove
    amdgpu_drv.h         1823
    amdgpu_discovery.c   11979  IP discovery (Navi reads the on-chip IP table)
    amdgpu_discovery.h    1738
    amdgpu_nv.c         29071  the Navi asic path: nv_set_ip_blocks ->
                               nv_reg_base_init -> navi12_reg_base_init,
                               nv_common_early_init (CHIP_NAVI12 case)
    amdgpu_kms.c        43367  the drm driver ioctl table + load/unload
    amdgpu_object.h     10028  amdgpu_bo (buffer object, the TTM BO wrapper)
    amdgpu_ttm.h         5506  the amdgpu<->TTM manager glue
    amdgpu_gmc.h         9626  graphics memory controller (VRAM/GTT apertures)
    amdgpu_gart.h        3256  GART (the GPU page table over system RAM = GTT)
    amdgpu_bo_list.h     2964
    nvd.h, nv.h, soc15.h        Navi/SOC15 register + asic headers

## Device target

    g4ad EC2  ->  AMD Radeon Pro V520  ->  Navi 12  ->  gfx1011
    PCI id:   1002:7362  (vendor AMD 0x1002)
    asic:     CHIP_NAVI12  (amdgpu_nv.c handles it; navi12_reg_base_init)

## Device-init call chain (the compile target for C3-amdgpu-a)

    amdgpu_pci_probe (amdgpu_drv.c, matches 1002:7362)
      -> drm_dev_alloc + amdgpu_driver_load_kms (amdgpu_kms.c)
        -> amdgpu_device_init (amdgpu_device.c:2937)
          -> pci BAR map (VRAM aperture BAR0, MMIO regs BAR5/rmmio)
          -> amdgpu_device_ip_early_init (device.c:1742)
            -> nv_set_ip_blocks (amdgpu_nv.c:463)      [asic_type==CHIP_NAVI12]
              -> nv_reg_base_init -> navi12_reg_base_init  (IP register bases)
              -> nv_common_early_init                       (per-asic caps)
