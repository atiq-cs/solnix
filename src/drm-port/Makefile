# Makefile - build the illumos DRM core + GEM + virtio-gpu as a kernel module.
#
# Cross/native-compiles against the installed illumos kernel headers under
# /usr/include. Produces ET_REL AMD64 objects and links them into a single
# kernel module `drm`. C1a: drm-core + GEM stub COMPILING. C1b adds real GEM
# page backing (ddi_umem) + cb_devmap mmap, the C1b linux-compat shim
# primitives (workqueue/kthread/completion/rwsem), and the virtio-gpu transport
# + 2D modeset path. It does not need to load to hit the compile milestone.

CC      = gcc
KFLAGS  = -m64 -D_KERNEL -ffreestanding -nostdinc -std=gnu99 \
          -Wall -Wno-unknown-pragmas -fno-strict-aliasing \
          -I/usr/include -Isrc
LDFLAGS = -r

OBJS = src/drm_core.o src/drm_gem.o src/virtio_gpu.o src/virtio_gpu_3d.o \
       src/drm_dma.o src/drm_sched.o src/drm_prime.o
MODULE = drm

all: $(MODULE)

src/%.o: src/%.c
	$(CC) $(KFLAGS) -c $< -o $@

$(MODULE): $(OBJS)
	ld $(LDFLAGS) -o $(MODULE) $(OBJS)

verify: $(MODULE)
	@echo "=== file type ==="; file $(MODULE) $(OBJS)
	@echo "=== elfdump header (ET_REL, AMD64) ==="; elfdump -e $(MODULE) 2>/dev/null | egrep 'e_type|e_machine' || /usr/bin/elfdump -e $(MODULE) | head

clean:
	rm -f $(OBJS) $(MODULE)

.PHONY: all verify clean
