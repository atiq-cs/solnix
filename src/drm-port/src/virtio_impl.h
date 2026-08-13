/*
 * virtio_impl.h - the illumos virtio framework KPI (declarations only).
 *
 * illumos ships a virtio framework as the loadable module `virtio`
 * (/kernel/misc/amd64/virtio); vioif(4D)/vioblk(4D) bind to it. The framework
 * header (uts/common/io/virtio/virtio.h) is NOT installed under /usr/include on
 * this build host, so this file re-declares ONLY the exported KPI the C1b
 * virtio-gpu skeleton calls. Every prototype here matches a real GLOBAL FUNC
 * symbol exported by the `virtio` module (verified with
 *   elfdump -s /kernel/misc/amd64/virtio | grep 'FUNC GLOB'
 * ), so the linked object's virtio_* undefined symbols resolve against the
 * kernel virtio module at load time -- no phantom symbols.
 *
 * The opaque handle types (virtio_t, virtio_queue_t, virtio_chain_t,
 * virtio_dma_t) are treated as incomplete pointers here: the driver only ever
 * holds pointers to them and calls the KPI, never dereferences the internals.
 *
 * This mirrors what NetBSD's drm2 does with its own virtio(9) attach glue, but
 * bound to illumos's virtio KPI instead of NetBSD's.
 */

#ifndef _VIRTIO_IMPL_H_
#define _VIRTIO_IMPL_H_

#include <sys/types.h>
#include <sys/dditypes.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>

/* opaque framework handles (real definitions live in the virtio module). */
typedef struct virtio virtio_t;
typedef struct virtio_queue virtio_queue_t;
typedef struct virtio_chain virtio_chain_t;
typedef struct virtio_dma virtio_dma_t;

/*
 * virtio_init - attach the framework to a virtio PCI child.
 *   dip     : this driver's dev_info
 *   driver_features : the feature bits this driver understands
 *   allow_indirect  : B_TRUE to permit indirect descriptors
 * Returns a virtio_t handle, or NULL on failure. The driver then discovers
 * queues, calls virtio_init_complete, and only afterwards touches devcfg.
 */
extern virtio_t *virtio_init(dev_info_t *dip, uint64_t driver_features,
    boolean_t allow_indirect);

/*
 * virtio_init_complete - finish negotiation and set DRIVER_OK.
 *   nvqs : number of interrupt vectors the driver wants (0 = no per-queue
 *          interrupt handlers registered / polling only).
 * Returns DDI_SUCCESS / DDI_FAILURE.
 */
extern int virtio_init_complete(virtio_t *vio, int nvqs);

extern void virtio_fini(virtio_t *vio, boolean_t failed);
extern void virtio_shutdown(virtio_t *vio);
extern void virtio_device_reset(virtio_t *vio);

/* feature negotiation helpers. */
extern boolean_t virtio_feature_present(virtio_t *vio, uint64_t feature);
extern uint64_t virtio_features(virtio_t *vio);

/*
 * virtio_queue_alloc - claim a virtqueue by index.
 *   qidx      : virtqueue index (0 = controlq, 1 = cursorq for virtio-gpu)
 *   name      : label for kstats/debugging
 *   func      : per-queue interrupt handler (may be NULL for polled use)
 *   funcarg   : callback argument
 *   force_direct : B_TRUE to forbid indirect descriptors on this queue
 *   max_segs  : max scatter-gather segments per chain
 */
extern virtio_queue_t *virtio_queue_alloc(virtio_t *vio, uint16_t qidx,
    const char *name, ddi_intr_handler_t *func, void *funcarg,
    boolean_t force_direct, uint_t max_segs);

extern uint_t virtio_queue_size(virtio_queue_t *vq);
extern uint_t virtio_queue_nactive(virtio_queue_t *vq);
extern virtio_chain_t *virtio_queue_poll(virtio_queue_t *vq);
extern void virtio_queue_flush(virtio_queue_t *vq);
extern void virtio_queue_no_interrupt(virtio_queue_t *vq, boolean_t stop_intr);

/*
 * descriptor-chain API. A chain is one request: allocate it against a queue,
 * append DMA cookies (each a guest-physical segment + direction), submit it,
 * then reclaim on completion via virtio_queue_poll.
 */
extern virtio_chain_t *virtio_chain_alloc(virtio_queue_t *vq, int kmflags);
extern void virtio_chain_free(virtio_chain_t *vic);
extern void virtio_chain_clear(virtio_chain_t *vic);
extern void *virtio_chain_data(virtio_chain_t *vic);
extern void virtio_chain_data_set(virtio_chain_t *vic, void *data);
extern int virtio_chain_append(virtio_chain_t *vic, uint64_t pa, size_t len,
    int dir);
extern void virtio_chain_submit(virtio_chain_t *vic, boolean_t flush);
extern size_t virtio_chain_received_length(virtio_chain_t *vic);

/* virtio_chain_append direction values. */
#define VIRTIO_DIR_DEVICE_WRITES	1	/* device writes (driver reads) */
#define VIRTIO_DIR_DEVICE_READS		2	/* device reads (driver writes) */

/*
 * DMA memory API. Allocate host-shared, DMA-able memory, get its
 * guest-physical cookie(s), sync it, free it.
 */
extern virtio_dma_t *virtio_dma_alloc(virtio_t *vio, size_t sz,
    const ddi_dma_attr_t *attr, int kmflags, const char *name);
extern void virtio_dma_free(virtio_dma_t *vidma);
extern void *virtio_dma_va(virtio_dma_t *vidma, size_t off);
extern size_t virtio_dma_size(virtio_dma_t *vidma);
extern uint_t virtio_dma_ncookies(virtio_dma_t *vidma);
extern uint64_t virtio_dma_cookie_pa(virtio_dma_t *vidma, uint_t idx);
extern size_t virtio_dma_cookie_size(virtio_dma_t *vidma, uint_t idx);
extern void virtio_dma_sync(virtio_dma_t *vidma, int flag);

/* device config space accessors (endian-correct, at devcfg offsets). */
extern uint8_t  virtio_dev_get8(virtio_t *vio, uintptr_t off);
extern uint16_t virtio_dev_get16(virtio_t *vio, uintptr_t off);
extern uint32_t virtio_dev_get32(virtio_t *vio, uintptr_t off);
extern uint64_t virtio_dev_get64(virtio_t *vio, uintptr_t off);
extern void virtio_dev_put8(virtio_t *vio, uintptr_t off, uint8_t val);
extern void virtio_dev_put16(virtio_t *vio, uintptr_t off, uint16_t val);
extern void virtio_dev_put32(virtio_t *vio, uintptr_t off, uint32_t val);

#endif /* _VIRTIO_IMPL_H_ */
