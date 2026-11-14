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

# test-kref: linux/kref.h + linux/refcount.h as the build patches them
# (obsd-norcu.patch, obsd-refcount.patch): the vmdump.4 over-release
# sequence must release once and report. The negative control (without
# obsd-refcount.patch) releases twice and must fail.
test-kref: test/test_kref.c obsd-norcu.patch obsd-refcount.patch
	for v in a b; do mkdir -p test/kref/$$v/include/linux test/kref/$$v/inc/linux test/kref/$$v/inc/sys; \
	  cp $(OBSD)/include/linux/kref.h $(OBSD)/include/linux/refcount.h test/kref/$$v/include/linux/; \
	  for h in linux/atomic.h linux/spinlock.h sys/rwlock.h; do : > test/kref/$$v/inc/$$h; done; done
	cd test/kref/a && sed -n '/^--- a\/include\/linux\/kref.h/,$$p' ../../../obsd-norcu.patch | patch -s -p1 -F0
	cd test/kref/b && sed -n '/^--- a\/include\/linux\/kref.h/,$$p' ../../../obsd-norcu.patch | patch -s -p1 -F0
	cd test/kref/a && patch -s -p1 -F0 < ../../../obsd-refcount.patch
	for v in a b; do cp test/kref/$$v/include/linux/kref.h test/kref/$$v/include/linux/refcount.h test/kref/$$v/inc/linux/; done
	$(CC) -m64 -O2 -Wall -Werror -Wno-pointer-sign -Itest/kref/a/inc -o test/test_kref test/test_kref.c
	$(CC) -m64 -O2 -Wall -Werror -Wno-pointer-sign -Itest/kref/b/inc -o test/test_kref_neg test/test_kref.c
	./test/test_kref
	@if ./test/test_kref_neg > test/kref/neg.out; then echo "NEGATIVE CONTROL (kref) DID NOT FAIL"; exit 1; \
	 else echo "negative control (no obsd-refcount.patch) FAILS as required:"; grep ^FAIL test/kref/neg.out; fi

# test-idr: the idr/xarray section of drm_linux.c (OBSD = the pinned OpenBSD
# tree) under threads that share drm files, as drm ioctls run here with
# KERNEL_LOCK a no-op. With obsd-idrlock.patch it must pass every run; the
# negative control, the same section without the patch, must fail every run.
# IDR_RUNS runs of IDR_SECS seconds each.
IDR_RUNS ?= 8
IDR_SECS ?= 3
# from the idr_cmp prototype to sg_alloc_table, less its return-type line
IDR_CUT = awk '/^sg_alloc_table/ && p {exit} p {print prev} {prev = $$0} /^int idr_cmp\(struct idr_entry \*, struct idr_entry \*\);/ {p = 1}'
test-idr: test/test_idr_race.c obsd-idrlock.patch
	mkdir -p test/idr/a test/idr/sys
	: > test/idr/sys/_null.h
	cp $(OBSD)/drm_linux.c test/idr/a/drm_linux.c
	cd test/idr/a && patch -s -p1 -F0 < ../../../obsd-idrlock.patch
	$(IDR_CUT) test/idr/a/drm_linux.c > test/idr/fixed.c
	$(IDR_CUT) $(OBSD)/drm_linux.c > test/idr/orig.c
	@test "`awk '/mtx_enter\(&obsd_idr_mtx\)/{n++} END{print n+0}' test/idr/fixed.c`" -ge 20 || { echo "FAIL: no idr lock in the cut"; exit 1; }
	@test "`awk '/^(idr_alloc|__xa_load|idr_find)\(/{n++} END{print n+0}' test/idr/orig.c`" -eq 3 || { echo "FAIL: the region cut moved"; exit 1; }
	$(CC) $(UFLAGS) -Itest/idr -Wno-unused-function '-DIDR_REGION="idr/fixed.c"' -o test/test_idr test/test_idr_race.c -lpthread
	$(CC) $(UFLAGS) -Itest/idr -Wno-unused-function '-DIDR_REGION="idr/orig.c"' -o test/test_idr_neg test/test_idr_race.c -lpthread
	@i=0; while [ $$i -lt $(IDR_RUNS) ]; do i=$$((i+1)); \
	  IDR_SECS=$(IDR_SECS) ./test/test_idr || { echo "FAIL: run $$i of $(IDR_RUNS)"; exit 1; }; done
	@i=0; neg=0; while [ $$i -lt $(IDR_RUNS) ]; do i=$$((i+1)); \
	  if IDR_SECS=$(IDR_SECS) ./test/test_idr_neg > test/idr/neg$$i.out 2>&1; then :; else neg=$$((neg+1)); fi; done; \
	  echo "negative control (no obsd-idrlock.patch): $$neg of $(IDR_RUNS) runs FAIL"; \
	  cat test/idr/neg*.out | grep '^FAIL' | sed 's/[0-9][0-9]*/N/g' | sort | uniq -c | sort -rn | head -8; \
	  test $$neg -eq $(IDR_RUNS) || { echo "NEGATIVE CONTROL DID NOT FAIL EVERY RUN"; exit 1; }

clean:
	rm -f $(OBJS) test_pciid test_pciid_neg test_pciid_neg.out \
	    test_pciid_neg2 test_pciid_neg2.out \
	    test/test_console test/test_console_neg test/test_console_neg.out \
	    test/test_console_tem_neg test/test_console_tem_neg.out \
	    test/test_kref test/test_kref_neg test/kref/neg.out \
	    test/test_idr test/test_idr_neg test/idr/*.c test/idr/*.out test/idr/a/* test/idr/sys/_null.h

.PHONY: obj test test-ioc test-console test-kref test-idr probe clean
