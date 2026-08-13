# NetBSD DRM/KMS crib reference (solnix C1a)

This tree is the **NetBSD-current source mirror** the solnix design docs
(`docs/design-gpu-compute-parity.md`, `docs/design-desktop-and-local-ai.md`,
`docs/netbsd-driver-substrate.md`) flag as a prerequisite for the illumos
DRM/KMS port. It is the crib reference for the linux-DRM-on-a-non-Linux-kernel
shim, the same adopt-the-BSD-driver pattern solnix already used for the ena NIC
(FreeBSD) and the RISC-V MD layer (NetBSD).

## Pinned revision

    upstream:  https://github.com/NetBSD/src.git
    branch:    HEAD (netbsd-current)
    commit:    5a7765109d6feb3a897b349b8d58572a0b7812f2
    fetched:   sparse + shallow (depth 1)

Reproduce:

    git init src && cd src
    git remote add origin https://github.com/NetBSD/src.git
    git config core.sparseCheckout true
    # sparse paths: see below
    git fetch --depth 1 origin 5a7765109d6feb3a897b349b8d58572a0b7812f2
    git checkout FETCH_HEAD

The 638M packfile was moved out of the working tree after checkout (only the
source files are retained here; re-fetch from the pinned commit to restore git
metadata).

## Sparse paths retained (the shim + core, NOT the 500k-LOC Linux drivers)

    sys/external/bsd/drm2/linux/          31 linux_*.c KPI shim  (~11k LOC)
    sys/external/bsd/drm2/drm/            20 .c NetBSD<->drm glue (~4.4k LOC)
    sys/external/bsd/drm2/include/        178 emulated linux/*.h headers
    sys/external/bsd/common/linux/        4 .c foundational KPI (work/rcu/srcu/tasklet)
    sys/external/bsd/drm2/dist/drm/       drm_drv.c drm_ioctl.c drm_file.c drm_gem.c (Linux core)
    sys/external/bsd/drm2/dist/include/   the Linux DRM UAPI + internal headers
    sys/external/bsd/drm2/ttm/            TTM (VRAM/GTT placement) glue

## License / attribution posture

The NetBSD-authored shim + glue files (`drm2/linux/*.c`, `drm2/drm/*.c`,
`common/linux/*.c`) are **2-clause BSD** (The NetBSD Foundation) — CDDL-
compatible, attribution-only, the same posture solnix accepts for CDDL n-hys.
Keep each adopted file's copyright header and `$NetBSD: ...,v ...$` RCS id
verbatim. The `dist/` sources underneath are the imported Linux DRM (MIT/GPL
per-file) — reference only; not adopted into the illumos module (the illumos
port re-implements the shim boundary against DDI, it does not lift Linux .c).

## RCS ids of the load-bearing crib files (this pin)

    drm/drm_cdevsw.c     $NetBSD: drm_cdevsw.c,v 1.31 2024/04/21 ...$   (cdevsw+fileops -> illumos cb_ops model)
    drm/drm_module.c     $NetBSD: drm_module.c,v 1.32 2023/09/05 ...$   (MODULE() -> illumos modlinkage model)
    drm/drm_stub.c       $NetBSD: drm_stub.c,v 1.1 2019/11/16 ...$      (drm_dev alloc/minor model)
    linux/linux_dma_fence.c  v1.42 2022/09/01                          (dma-fence -> illumos cv/condvar, C1c)
    linux/linux_dma_resv.c   v1.22 2022/02/15                          (reservation obj -> C1c)
    linux/linux_idr.c        v1.15 2021/12/19                          (idr -> illumos id_space/avl, C1a done)
    linux/linux_ww_mutex.c   v1.16 2023/07/29                          (ww_mutex -> illumos ksynch, C1b/c)
    linux/linux_kthread.c    v1.9  2021/12/19                          (kthread -> illumos thread_create, C1b)
    linux/linux_pci.c        v1.30 2024/06/24                          (pci_dev -> illumos pci/ddi, C1b)
    linux/linux_work.c       (common/linux) workqueue -> illumos taskq (C1b)

See ../DESIGN.md for the full layer -> illumos mapping.
