/*
 * pvr_vm.c - C-PVR-b: the PowerVR GPU MMU (device-virtual address space),
 * illumos side. The pvr analogue of Linux's pvr_vm.c + pvr_mmu.c, expressed
 * against the C1 framework. Handles CREATE_VM_CONTEXT (0x03),
 * DESTROY_VM_CONTEXT (0x04), VM_MAP (0x05), VM_UNMAP (0x06).
 *
 * A pvr_vm_context is one GPU address space: a page-table root plus a mapping
 * list that records which BO is mapped at which device-virtual address. The
 * PowerVR MMU is a multi-level page table (pvr_mmu.c, 2643 LOC of PT walk +
 * cache flush) programming device-physical BO pages into GPU-virtual space.
 *
 * For the COMPILE milestone we implement the address-space bookkeeping (the
 * context, the mapping list, range validation, the map/unmap ioctl ABI) and
 * the page-table op *interface* (pvr_mmu_map / pvr_mmu_unmap). The actual PT
 * page-walk + the MMU cache flush registers are BXE-2-32-hardware-gated: they
 * program device registers + require the FW MMU context that only exists once
 * the BXE FW has booted. The bookkeeping is the C1-framework part; the PT walk
 * is the metal part -- the same split C3-amdgpu's GART page-table takes.
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/errno.h>
#include <sys/list.h>

#include "drm_internal.h"
#include "pvr_priv.h"
#include "uapi/pvr_drm.h"

/* the userspace GPU heap layout (pvr_rogue_heap_config.h) -- the general heap
 * spans the low canonical device-virtual range userspace maps into. */
#define	PVR_VM_DEVICE_ADDR_MIN	0x00010000ULL
#define	PVR_VM_DEVICE_ADDR_MAX	0x0000ffffffffffffULL	/* 48-bit dev-VA */
#define	PVR_VM_PAGE_SIZE	4096

extern struct pvr_gem_object *pvr_gem_object_lookup(struct pvr_softc *,
    uint32_t handle);

/*
 * pvr_vm_mapping - one BO mapped into a VM context at a device-virtual address.
 * Linux uses drm_gpuva/drm_gpuvm; here a simple list (the FIFO submit path
 * serializes, so O(n) lookup is fine for the compile milestone).
 */
struct pvr_vm_mapping {
	list_node_t		node;
	struct pvr_gem_object	*obj;
	uint64_t		bo_offset;
	uint64_t		device_addr;
	uint64_t		size;
};

/*
 * pvr_vm_context - one GPU address space. Linux: struct pvr_vm_context
 * (pvr_vm.c). Holds the page-table root object + the mapping list.
 */
struct pvr_vm_context {
	struct kref		ref;
	struct pvr_softc	*pvr;
	boolean_t		is_kernel;
	kmutex_t		lock;
	list_t			mappings;	/* struct pvr_vm_mapping */
	struct pvr_fw_object	*pt_root_obj;	/* the PT root (FW obj) */
	uint32_t		handle;		/* client vm_ctx handle */
};

/*
 * pvr_mmu_map / pvr_mmu_unmap - the page-table op interface. The real walk
 * (pvr_mmu.c) programs the multi-level PT + flushes the MMU cache registers;
 * that is BXE-hardware-gated (device registers + the FW MMU context). For the
 * compile milestone these validate + record; the PT program is the metal step.
 */
static int
pvr_mmu_map(struct pvr_vm_context *vm, struct pvr_vm_mapping *m)
{
	(void) vm; (void) m;
	/*
	 * HARDWARE-GATED: pvr_mmu_map_range walks the PT levels, allocates PT
	 * pages (FW objects), writes the leaf PTEs with the BO's device-physical
	 * page addresses, and flushes the MMU cache via ROGUE_CR_MMU_* registers.
	 * Needs the booted FW + the real BXE. The bookkeeping above is complete.
	 */
	return (0);
}

static void
pvr_mmu_unmap(struct pvr_vm_context *vm, struct pvr_vm_mapping *m)
{
	(void) vm; (void) m;	/* HARDWARE-GATED: clears PTEs + flushes cache */
}

/*
 * pvr_vm_create_context - allocate a GPU address space. is_kernel selects the
 * FW-heap context (kernel_vm_ctx) vs a userspace context. Linux:
 * pvr_vm_create_context.
 */
struct pvr_vm_context *
pvr_vm_create_context(struct pvr_softc *sc, boolean_t is_kernel)
{
	struct pvr_vm_context *vm = kmem_zalloc(sizeof (*vm), KM_SLEEP);

	kref_init(&vm->ref);
	vm->pvr = sc;
	vm->is_kernel = is_kernel;
	mutex_init(&vm->lock, NULL, MUTEX_DRIVER, NULL);
	list_create(&vm->mappings, sizeof (struct pvr_vm_mapping),
	    offsetof(struct pvr_vm_mapping, node));
	/*
	 * The PT root is a FW object (a GEM BO mapped into the FW heap). Its
	 * allocation is FW-heap-gated (pvr_fw_object_create needs the FW heap
	 * set up); off-hardware it is NULL and the map path records only.
	 */
	vm->pt_root_obj = pvr_fw_object_create(sc, PVR_VM_PAGE_SIZE,
	    PVR_BO_FW_FLAGS_DEVICE_UNCACHED);
	return (vm);
}

static void
pvr_vm_context_free(struct pvr_vm_context *vm)
{
	struct pvr_vm_mapping *m;

	while ((m = list_remove_head(&vm->mappings)) != NULL) {
		pvr_mmu_unmap(vm, m);
		if (m->obj != NULL)
			pvr_gem_object_put(m->obj);
		kmem_free(m, sizeof (*m));
	}
	list_destroy(&vm->mappings);
	if (vm->pt_root_obj != NULL)
		pvr_fw_object_destroy(vm->pvr, vm->pt_root_obj);
	mutex_destroy(&vm->lock);
	kmem_free(vm, sizeof (*vm));
}

void
pvr_vm_context_put(struct pvr_vm_context *vm)
{
	if (vm == NULL)
		return;
	if (atomic_dec_uint_nv(&vm->ref.refcount) == 0)
		pvr_vm_context_free(vm);
}

/*
 * pvr_vm_map - map a BO into a VM context at a device-virtual address. Linux:
 * pvr_vm_map. Validates the range, records the mapping, programs the PT.
 */
int
pvr_vm_map(struct pvr_vm_context *vm, struct pvr_gem_object *obj,
    uint64_t bo_offset, uint64_t device_addr, uint64_t size)
{
	struct pvr_vm_mapping *m;
	int err;

	if (size == 0 || (size & (PVR_VM_PAGE_SIZE - 1)) != 0)
		return (EINVAL);
	if ((device_addr & (PVR_VM_PAGE_SIZE - 1)) != 0)
		return (EINVAL);
	if (device_addr < PVR_VM_DEVICE_ADDR_MIN ||
	    device_addr + size > PVR_VM_DEVICE_ADDR_MAX)
		return (EINVAL);
	if (bo_offset + size > pvr_gem_object_size(obj))
		return (EINVAL);

	m = kmem_zalloc(sizeof (*m), KM_SLEEP);
	m->obj = obj;
	m->bo_offset = bo_offset;
	m->device_addr = device_addr;
	m->size = size;

	mutex_enter(&vm->lock);
	err = pvr_mmu_map(vm, m);
	if (err == 0) {
		pvr_gem_object_get_ref(obj);
		list_insert_tail(&vm->mappings, m);
	}
	mutex_exit(&vm->lock);

	if (err != 0)
		kmem_free(m, sizeof (*m));
	return (err);
}

/*
 * pvr_vm_unmap - remove a mapping by device-virtual address + size. Linux:
 * pvr_vm_unmap.
 */
int
pvr_vm_unmap(struct pvr_vm_context *vm, uint64_t device_addr, uint64_t size)
{
	struct pvr_vm_mapping *m, *found = NULL;

	mutex_enter(&vm->lock);
	for (m = list_head(&vm->mappings); m != NULL;
	    m = list_next(&vm->mappings, m)) {
		if (m->device_addr == device_addr && m->size == size) {
			found = m;
			break;
		}
	}
	if (found != NULL) {
		pvr_mmu_unmap(vm, found);
		list_remove(&vm->mappings, found);
	}
	mutex_exit(&vm->lock);

	if (found == NULL)
		return (ENOENT);
	if (found->obj != NULL)
		pvr_gem_object_put(found->obj);
	kmem_free(found, sizeof (*found));
	return (0);
}

/* --- the ioctl handlers (matching the pvr_drm.h ABI exactly) --- */

int
pvr_create_vm_context_ioctl(struct pvr_softc *sc, struct pvr_file *pf,
    intptr_t arg, int mode)
{
	struct drm_pvr_ioctl_create_vm_context_args a;
	struct pvr_vm_context *vm;

	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	if (a._padding_4 != 0)
		return (EINVAL);

	vm = pvr_vm_create_context(sc, B_FALSE);
	if (vm == NULL)
		return (ENOMEM);

	vm->handle = idr_alloc(&pf->vm_ctx_handles, vm);
	a.handle = vm->handle;
	if (ddi_copyout(&a, (void *)arg, sizeof (a), mode) != 0) {
		(void) idr_remove(&pf->vm_ctx_handles, vm->handle);
		pvr_vm_context_put(vm);
		return (EFAULT);
	}
	return (0);
}

int
pvr_destroy_vm_context_ioctl(struct pvr_softc *sc, struct pvr_file *pf,
    intptr_t arg, int mode)
{
	struct drm_pvr_ioctl_destroy_vm_context_args a;
	struct pvr_vm_context *vm;

	(void) sc;
	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	if (a._padding_4 != 0)
		return (EINVAL);

	vm = idr_remove(&pf->vm_ctx_handles, a.handle);
	if (vm == NULL)
		return (EINVAL);
	pvr_vm_context_put(vm);
	return (0);
}

int
pvr_vm_map_ioctl(struct pvr_softc *sc, struct pvr_file *pf,
    intptr_t arg, int mode)
{
	struct drm_pvr_ioctl_vm_map_args a;
	struct pvr_vm_context *vm;
	struct pvr_gem_object *obj;

	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	if (a._padding_14 != 0)
		return (EINVAL);

	vm = idr_find(&pf->vm_ctx_handles, a.vm_context_handle);
	if (vm == NULL)
		return (EINVAL);
	obj = pvr_gem_object_lookup(sc, a.handle);
	if (obj == NULL)
		return (ENOENT);

	return (pvr_vm_map(vm, obj, a.offset, a.device_addr, a.size));
}

int
pvr_vm_unmap_ioctl(struct pvr_softc *sc, struct pvr_file *pf,
    intptr_t arg, int mode)
{
	struct drm_pvr_ioctl_vm_unmap_args a;
	struct pvr_vm_context *vm;

	(void) sc;
	if (ddi_copyin((void *)arg, &a, sizeof (a), mode) != 0)
		return (EFAULT);
	if (a._padding_4 != 0)
		return (EINVAL);

	vm = idr_find(&pf->vm_ctx_handles, a.vm_context_handle);
	if (vm == NULL)
		return (EINVAL);

	return (pvr_vm_unmap(vm, a.device_addr, a.size));
}
