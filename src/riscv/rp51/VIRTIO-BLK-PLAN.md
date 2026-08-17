# virtio-blk MMIO -- driver plan for R-P52 (toward a REAL disk)

R-P51 keeps the RAM-backed blockfs (bdev0 over `bdev_strategy(blkno, buf, rw)`).
This document is the R-P52 plan: a **virtio-blk MMIO** driver so blockfs runs
over a REAL qemu `-drive` that persists **across boots** (not just across an
unmount+remount in one boot).  It is the "reach" part of R-P51's task #3,
deferred here per the anti-wedge rule (the virtqueue descriptor ring is real
work); the RAM-blockfs stays the default until R-P52 lands the sector read.

The scope of the R-P52 milestone is deliberately small: **read ONE sector from
a qemu `-drive if=none ... -device virtio-blk-device` through a real virtqueue**
(real disk I/O).  Write-back + making blockfs mount the virtio disk come after.

--------------------------------------------------------------------------
## qemu invocation (the substrate R-P52 boots against)

    qemu-system-riscv64 -machine virt -smp 2 -m 256M -nographic \
      -bios $BIOS -kernel unix.elf \
      -drive file=disk.img,if=none,format=raw,id=hd0 \
      -device virtio-blk-device,drive=hd0

`-machine virt` exposes virtio-mmio transports.  qemu places up to 8 virtio-mmio
slots at `0x10001000 + i*0x1000` (each 0x1000 wide), IRQs 1..8 on the PLIC.  The
device tree (already parsed at boot for CLINT/PLIC) has the `virtio_mmio@...`
nodes; R-P52 can hardcode the first slot `0x10001000` to start (qemu assigns the
virtio-blk-device to a fixed slot for a given -device order), then generalize by
walking the FDT.

--------------------------------------------------------------------------
## virtio-mmio register layout (virtio v1.0, the "modern" MMIO transport)

Offsets from the device base (e.g. 0x10001000).  32-bit MMIO reads/writes.

    0x000 MagicValue        R    0x74726976 ("virt" little-endian)
    0x004 Version           R    2 (v1.0 modern; 1 = legacy, reject)
    0x008 DeviceID          R    2 = block device (0 = no device present)
    0x00c VendorID          R    0x554d4551 (qemu)
    0x010 DeviceFeatures    R    device feature bits (select via 0x014)
    0x014 DeviceFeaturesSel W    which 32-bit window of DeviceFeatures
    0x020 DriverFeatures    W    features WE accept (select via 0x024)
    0x024 DriverFeaturesSel W    which 32-bit window of DriverFeatures
    0x030 QueueSel          W    select the virtqueue to configure (blk: 0)
    0x034 QueueNumMax       R    max queue size the device supports
    0x038 QueueNum          W    the queue size WE choose (<= QueueNumMax)
    0x044 QueueReady        RW   1 = queue is live
    0x050 QueueNotify       W    write the queue index to kick the device
    0x060 InterruptStatus   R    bit0 = used-ring update, bit1 = config change
    0x064 InterruptACK      W    write back the bits handled
    0x070 Status            RW   device status (ACK/DRIVER/FEATURES_OK/DRIVER_OK)
    0x080 QueueDescLow      W    phys addr of the descriptor table (low 32)
    0x084 QueueDescHigh     W                                        (high 32)
    0x090 QueueDriverLow    W    phys addr of the avail ring (low 32)
    0x094 QueueDriverHigh   W                                        (high 32)
    0x0a0 QueueDeviceLow    W    phys addr of the used ring   (low 32)
    0x0a4 QueueDeviceHigh   W                                        (high 32)
    0x100 Config            R    virtio_blk_config (capacity at +0, in 512B sectors)

Status bits (write cumulatively to 0x070):
    ACKNOWLEDGE 1  DRIVER 2  FEATURES_OK 8  DRIVER_OK 4  FAILED 128

--------------------------------------------------------------------------
## the split virtqueue (one queue, index 0, for virtio-blk)

Three contiguous (per-region) structures in memory the device reads by phys
addr.  For a queue of size N (use a small power of two, e.g. 8):

    struct virtq_desc {          /* the descriptor table: N entries */
        u64 addr;                /* phys addr of a buffer */
        u32 len;                 /* buffer length */
        u16 flags;               /* 1=NEXT (chained), 2=WRITE (device writes) */
        u16 next;                /* index of the next desc if NEXT set */
    } desc[N];

    struct virtq_avail {         /* driver -> device: heads of new chains */
        u16 flags;
        u16 idx;                 /* driver increments after adding */
        u16 ring[N];             /* ring[idx % N] = head desc index */
    } avail;

    struct virtq_used {          /* device -> driver: completed chains */
        u16 flags;
        u16 idx;                 /* device increments on completion */
        struct { u32 id; u32 len; } ring[N];
    } used;

Alignment (v1.0 modern): desc, avail, used may be separately placed (that is why
there are three QueueDesc/Driver/Device address-pair registers) -- just keep each
in identity-mapped, physically-contiguous kernel memory (the kernel already runs
with a known VA->PA map; use the boot allocator / a static aligned buffer).

--------------------------------------------------------------------------
## the virtio-blk request (a 3-descriptor chain)

    struct virtio_blk_req {
        u32 type;                /* 0 = VIRTIO_BLK_T_IN (read), 1 = OUT (write) */
        u32 reserved;
        u64 sector;              /* 512-byte sector number */
    } hdr;                       /* desc[0]: read-only by device (flags=NEXT) */
    /* desc[1]: the 512-byte data buffer
         read  -> flags = NEXT | WRITE (device writes into it)
         write -> flags = NEXT        (device reads from it) */
    u8 status;                   /* desc[2]: flags = WRITE; 0=OK 1=IOERR 2=UNSUPP */

So a one-sector READ is a chain of 3 descriptors: hdr (RO) -> data (WRITE) ->
status (WRITE).

--------------------------------------------------------------------------
## init + one-sector-read sequence (the R-P52 milestone)

  1. probe: MagicValue==0x74726976, Version==2, DeviceID==2 (else no blk).
  2. Status = 0; Status |= ACKNOWLEDGE; Status |= DRIVER.
  3. read DeviceFeatures (both windows); accept the minimal set (clear
     VIRTIO_F_RING_EVENT_IDX etc. -- accept 0 features to start); write
     DriverFeatures; Status |= FEATURES_OK; re-read Status, confirm FEATURES_OK
     stuck (else FAILED).
  4. QueueSel=0; QueueNumMax must be >= our N; QueueNum=N.
  5. allocate desc/avail/used (zeroed, aligned); program the six
     QueueDesc/Driver/Device Low/High address registers; QueueReady=1.
  6. Status |= DRIVER_OK.  (capacity is in Config+0, sectors of 512B.)
  7. read sector S:
       - build hdr{type=0, sector=S}, a 512B data buf, a status byte;
       - desc[0]=hdr(RO,NEXT->1); desc[1]=data(WRITE,NEXT->2); desc[2]=status(WRITE);
       - avail.ring[avail.idx % N] = 0 (head); memory barrier; avail.idx++;
       - QueueNotify = 0 (kick);
       - poll used.idx (or take the PLIC IRQ + read InterruptStatus, ACK it)
         until it advances; check status byte == 0; the 512 bytes are in data.

  Barriers: a `fence` (RISC-V) before bumping avail.idx and before reading
  used.idx -- the device sees memory through DMA, ordering matters.

--------------------------------------------------------------------------
## wiring into the existing block layer

`bdev_strategy(blkno, buf, rw)` is already the one choke point blockfs uses.
R-P52 adds a `virtio_blk_strategy()` with the same signature and routes bdev1
(or a `mount`ed virtio disk) through it, leaving bdev0 (RAM) as the fallback.
blockfs then needs no change -- it already talks only to `bdev_strategy`.  A
buffer cache is a later optimization, not needed for the first sector read.

CRIB PROVENANCE: virtio spec v1.0 sec 2.6 (split virtqueue) + sec 4.2 (MMIO
transport) + sec 5.2 (block device); illumos `uts/common/io/vioblk/` +
`uts/common/io/virtio/virtio.c` (the illumos virtio framework: virtio_init_*,
virtq alloc, virtio_push_chain / virtio_sync); the OpenSBI/qemu `virt` machine
places virtio-mmio at 0x10001000+.
