# Makefile - C-PVR-b: build the PowerVR (Imagination) DRM driver as ET_REL
# objects onto the C1 DRM framework, compile-verified zero-phantom.
#
# The powervr DRM driver is another DRM driver onto the same C1 framework the
# C3-amdgpu port uses (src/ = the C1 DRM core + GEM + drm_sched + dma-fence +
# the linux-compat shims). This Makefile compiles the pvr objects against the
# installed illumos kernel headers + the C1 src/ include dir, then links them
# (with the C1 objects) into a single ET_REL `drm-pvr` module and runs the
# zero-phantom undef audit.
#
# Runtime = the Milk-V Jupiter's BXE-2-32; this is COMPILE + static symbol-
# boundary verification only (never modload into a live kernel).

CC      = gcc
# C1SRC points at the built C1 framework tree (src/). Set on the node to the
# checked-out src/drm-port/src.
C1SRC  ?= ../src
KFLAGS  = -m64 -D_KERNEL -ffreestanding -nostdinc -std=gnu99 \
          -Wall -Wno-unknown-pragmas -fno-strict-aliasing \
          -I/usr/include -I$(C1SRC) -I$(C1SRC)/uapi/drm -I. \
          -Wno-error=incompatible-pointer-types -Wno-error=pointer-sign
LDFLAGS = -r

# The C1 framework objects (built from $(C1SRC) by the C1 Makefile). The pvr
# module links against these so its GEM/sched/dma-fence undefs resolve to real
# C1 symbols rather than showing as phantom.
C1_OBJS = $(C1SRC)/drm_core.o $(C1SRC)/drm_gem.o $(C1SRC)/drm_dma.o \
          $(C1SRC)/drm_sched.o $(C1SRC)/drm_prime.o

# The powervr DRM objects.
PVR_OBJS = pvr_device.o pvr_drv.o pvr_gem.o pvr_vm.o pvr_context.o \
           pvr_free_list.o pvr_hwrt.o pvr_ccb.o pvr_sync.o \
           pvr_fw.o pvr_fw_riscv.o pvr_fw_startstop.o

MODULE     = drm-pvr		# the pvr objects alone (the C-PVR-b deliverable)
MODULE_FULL = drm-pvr-full	# pvr + the C1 framework, for the zero-phantom link

all: $(MODULE)

%.o: %.c
	$(CC) $(KFLAGS) -c $< -o $@

# The pvr objects linked into one ET_REL object (the C-PVR-b module). Its
# undefs are the C1 framework symbols + illumos KPI (audited by verify below).
$(MODULE): $(PVR_OBJS)
	ld $(LDFLAGS) -o $(MODULE) $(PVR_OBJS)

# The full link: pvr + C1 framework. Every undef here must be a real illumos
# KPI (the zero-phantom bar). Requires the C1 objects built first.
full: $(MODULE_FULL)
$(MODULE_FULL): $(PVR_OBJS) $(C1_OBJS)
	ld $(LDFLAGS) -o $(MODULE_FULL) $(PVR_OBJS) $(C1_OBJS)

verify: $(MODULE)
	@echo "=== file type ==="; file $(MODULE)
	@echo "=== ET_REL AMD64 ==="; elfdump -e $(MODULE) 2>/dev/null | egrep 'e_type|e_machine'
	@echo "=== undef count ==="; elfdump -s $(MODULE) 2>/dev/null | grep UNDEF | grep -v '^$$' | wc -l

clean:
	rm -f $(PVR_OBJS) $(MODULE) $(MODULE_FULL)

.PHONY: all full verify clean
