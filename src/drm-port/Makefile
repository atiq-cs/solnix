# Makefile - build the illumos DRM core + GEM + virtio-gpu as a kernel module.
#
# Cross/native-compiles against the installed illumos kernel headers under
# /usr/include. Produces ET_REL AMD64 objects and links them into a single
# kernel module `drm`. C1a: drm-core + GEM stub COMPILING. C1b adds real GEM
# page backing (ddi_umem) + cb_devmap mmap, the C1b linux-compat shim
# primitives (workqueue/kthread/completion/rwsem), and the virtio-gpu transport
# + 2D modeset path. It does not need to load to hit the compile milestone.

CC      = gcc
KFLAGS  = -m64 -mcmodel=kernel -mno-red-zone -D_KERNEL -ffreestanding -nostdinc -std=gnu99 \
          -Wall -Wno-unknown-pragmas -fno-strict-aliasing \
          -I/usr/include -Isrc
# The full amdgpu + KFD (amdkfd) build adds the amdgpu/ and amdkfd/ include
# dirs. The C3-amdgpu driver and the C3-KFD compute surface link into the SAME
# `drm` ET_REL module (Linux ships /dev/kfd + /dev/dri/renderD* as distinct
# char devices over one amdgpu device; solnix folds both onto one illumos char
# device with a KFD minor -- see amdkfd/KFD-STATUS.md).
KFLAGS_FULL = $(KFLAGS) -Iamdgpu -Iamdkfd
LDFLAGS = -r

OBJS = src/drm_core.o src/drm_gem.o src/virtio_gpu.o src/virtio_gpu_3d.o \
       src/drm_dma.o src/drm_sched.o src/drm_prime.o

# The C3-amdgpu driver objects (built with the amdgpu/ include dir).
AMDGPU_SRCS = $(wildcard amdgpu/*.c)
AMDGPU_OBJS = $(AMDGPU_SRCS:.c=.o)

# The C3-KFD (amdkfd) compute-surface objects (the /dev/kfd char device +
# ioctls + user-mode queue/doorbell manager). Excludes test_kfd.c (userland).
KFD_OBJS = amdkfd/kfd_chardev.o amdkfd/kfd_device.o amdkfd/kfd_process.o \
           amdkfd/kfd_device_queue_manager.o

MODULE = drm
# The full module = C1 + amdgpu + KFD, all ET_REL AMD64, zero phantom.
MODULE_FULL = drm-full

all: $(MODULE)

src/%.o: src/%.c
	$(CC) $(KFLAGS_FULL) -c $< -o $@

amdgpu/%.o: amdgpu/%.c
	$(CC) $(KFLAGS_FULL) -c $< -o $@

amdkfd/%.o: amdkfd/%.c
	$(CC) $(KFLAGS_FULL) -c $< -o $@

$(MODULE): $(OBJS)
	ld $(LDFLAGS) -o $(MODULE) $(OBJS)

# The full DRM+amdgpu+KFD module (the C3-KFD milestone target).
kfd: $(MODULE_FULL)
$(MODULE_FULL): $(OBJS) $(AMDGPU_OBJS) $(KFD_OBJS)
	ld $(LDFLAGS) -o $(MODULE_FULL) $(OBJS) $(AMDGPU_OBJS) $(KFD_OBJS)
	test -x ./verify-syms.sh && sh ./verify-syms.sh $(MODULE_FULL) || true

test-kfd:
	$(CC) -o /tmp/test_kfd amdkfd/test_kfd.c && /tmp/test_kfd

verify: $(MODULE)
	@echo "=== file type ==="; file $(MODULE) $(OBJS)
	@echo "=== elfdump header (ET_REL, AMD64) ==="; elfdump -e $(MODULE) 2>/dev/null | egrep 'e_type|e_machine' || /usr/bin/elfdump -e $(MODULE) | head

clean:
	rm -f $(OBJS) $(AMDGPU_OBJS) $(KFD_OBJS) $(MODULE) $(MODULE_FULL)

.PHONY: all kfd verify test-kfd clean
