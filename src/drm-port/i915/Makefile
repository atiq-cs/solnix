# Makefile -- illumos i915 port (rung 1 of docs/x1-gpu-route.md).
#
#   make obj     kernel ET_REL object(s) against the illumos gate headers
#   make test    userland self-check of the same sources + its negative control
#   make probe   measure the OpenBSD-kernel-API gap of unmodified OpenBSD
#                files (OBSD=<OpenBSD sys/dev/pci/drm checkout>, the pinned
#                tree from ./fetch-obsd-drm.sh DEST -> DEST/obsd-drm)
#
# GATE_INC defaults to the solnix gate proto on dixi (dixi has no /usr/include).
GATE_INC ?= /nix/store/s7zkx8nx5sfxixmyqmlnrybrrh14jkmb-illumos-gate-proto/usr/include
CC       = gcc
KFLAGS   = -m64 -mcmodel=kernel -mno-red-zone -D_KERNEL -ffreestanding -nostdinc \
           -std=gnu11 -O2 -Wall -Werror -fno-strict-aliasing \
           -Iopenbsd-orig/include -I. -I$(GATE_INC)
UFLAGS   = -m64 -O2 -Wall -Werror -Iopenbsd-orig/include -I.

OBJS = i915_pciid.o

obj: $(OBJS)

i915_pciid.o: i915_pciid.c i915_pciid.h openbsd-orig/include/drm/intel/pciids.h
	$(CC) $(KFLAGS) -c i915_pciid.c -o $@

test:
	$(CC) $(UFLAGS) -o test_pciid test/test_pciid.c i915_pciid.c
	./test_pciid
	$(CC) $(UFLAGS) -DI915_PCIID_SABOTAGE -o test_pciid_neg test/test_pciid.c i915_pciid.c
	@if ./test_pciid_neg > test_pciid_neg.out; then \
	    echo "NEGATIVE CONTROL DID NOT FAIL"; exit 1; \
	 else echo "negative control (CFL-H GT2 list removed): FAILS as required"; \
	    grep FAIL test_pciid_neg.out; fi
	$(CC) $(UFLAGS) -Wno-unused-const-variable -DI915_PCIID_SABOTAGE_ADLP -o test_pciid_neg2 test/test_pciid.c i915_pciid.c
	@if ./test_pciid_neg2 > test_pciid_neg2.out; then \
	    echo "NEGATIVE CONTROL (ADL-P) DID NOT FAIL"; exit 1; \
	 else echo "negative control (ADL-P list removed): FAILS as required"; \
	    grep FAIL test_pciid_neg2.out; fi

# test-ioc: the Linux -> OpenBSD DRM ioctl translation (i915_drmioc.h)
# against OpenBSD's own uapi headers. OBSD = the OpenBSD sys/dev/pci/drm
# tree; ANV = the dir with linux-ioctl-compat.h (the encoding solnix
# libdrm/Mesa are built with).
ANV ?= ../anv
UAPI = $(OBSD)/include/uapi/drm
TFLAGS = -m64 -O2 -Wall -D__OpenBSD__ -Itest -I$(UAPI) -I$(ANV)
test-ioc:
	$(CC) -E -dM -D__OpenBSD__ -I$(UAPI) $(UAPI)/i915_drm.h | \
	    awk '$$1 == "\#define" && $$2 ~ /^DRM_IOCTL_/ && $$3 ~ /^DRM_IO(W|R|WR)?\(/ {print "M(" $$2 ")"}' | \
	    sort -u > test/ioc_list.h
	@echo "ioctls in OpenBSD uapi drm.h + i915_drm.h: `wc -l < test/ioc_list.h`"
	for e in LINUX OBSD ILLUMOS; do \
	    $(CC) $(TFLAGS) -DTBL_$$e -c test/drmioc_tbl.c -o test/tbl_$$e.o || exit 1; done
	$(CC) $(TFLAGS) -Werror -o test/test_drmioc test/test_drmioc.c test/tbl_*.o
	./test/test_drmioc
	$(CC) $(TFLAGS) -Werror -DI915_DRMIOC_SABOTAGE -o test/test_drmioc_neg test/test_drmioc.c test/tbl_*.o
	@if ./test/test_drmioc_neg > test/drmioc_neg.out; then \
	    echo "NEGATIVE CONTROL DID NOT FAIL"; exit 1; \
	 else echo "negative control (Linux dir bits read as BSD): FAILS as required, \
	    `grep -c ^FAIL test/drmioc_neg.out` checks"; fi
	$(CC) $(TFLAGS) -Werror -DI915_MINOR_SABOTAGE -o test/test_minor_neg test/test_drmioc.c test/tbl_*.o
	@if ./test/test_minor_neg > test/minor_neg.out; then \
	    echo "NEGATIVE CONTROL (minor) DID NOT FAIL"; exit 1; \
	 else echo "negative control (SVR3 minor x & 0xff): FAILS as required:"; \
	    grep ^FAIL test/minor_neg.out; fi

PROBE_FILES = i915/i915_pci.c i915/intel_device_info.c
probe:
	sh ./probe-headers.sh $(OBSD) $(PROBE_FILES)

# test-console: the fbdev draw arithmetic AND tem's modechange-callback contract
# (the "handover succeeded" claim). Two negative controls, each must FAIL:
#   SABOTAGE     -- a top-down overlapping copy (wrong scroll direction)
#   SABOTAGE_TEM -- the refuted belief that a same-mode modechg_cb repaints
#                   and takes over the panic/kmdb polled console
test-console:
	$(CC) $(UFLAGS) -o test/test_console test/test_console.c
	./test/test_console
	$(CC) $(UFLAGS) -DSABOTAGE -o test/test_console_neg test/test_console.c
	@if ./test/test_console_neg > test/test_console_neg.out 2>&1; then \
	    echo "NEGATIVE CONTROL (draw) DID NOT FAIL"; exit 1; \
	 else echo "negative control (top-down overlapping copy): FAILS as required"; \
	    grep ^FAIL test/test_console_neg.out; fi
	$(CC) $(UFLAGS) -DSABOTAGE_TEM -o test/test_console_tem_neg test/test_console.c
	@if ./test/test_console_tem_neg > test/test_console_tem_neg.out 2>&1; then \
	    echo "NEGATIVE CONTROL (tem) DID NOT FAIL"; exit 1; \
	 else echo "negative control (same-mode callback assumed to repaint): FAILS as required"; \
	    grep ^FAIL test/test_console_tem_neg.out; fi

clean:
	rm -f $(OBJS) test_pciid test_pciid_neg test_pciid_neg.out \
	    test_pciid_neg2 test_pciid_neg2.out \
	    test/test_console test/test_console_neg test/test_console_neg.out \
	    test/test_console_tem_neg test/test_console_tem_neg.out

.PHONY: obj test test-ioc test-console probe clean
