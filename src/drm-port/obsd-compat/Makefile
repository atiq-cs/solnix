# Makefile -- the OpenBSD-kernel-API-on-illumos compat layer (src/drm-port/obsd-compat).
#
#   make obj     $(KOBJS), kernel ET_REL objects against the gate proto
#   make syms    every undefined symbol of $(KOBJS) that they do not define
#                themselves must be a symbol the
#                running illumos kernel (unix + genunix) defines; prints the
#                ones that are not (they are PLANNED or a bug) and fails
#   make negctl  the same check on an object with a deliberately bogus
#                external call; it must FAIL
#   make test    userland tests (test/) with their negative controls
GATE_INC ?= /nix/store/s7zkx8nx5sfxixmyqmlnrybrrh14jkmb-illumos-gate-proto/usr/include
CC      = gcc
NM      = gnm
# -mno-mmx -mno-sse: the gate kernel's NO_SIMD (Makefile.master); see i915/simd-gate.sh.
KFLAGS  = -m64 -mcmodel=kernel -mno-red-zone -mno-mmx -mno-sse -D_KERNEL -ffreestanding -nostdinc \
          -std=gnu11 -O2 -Wall -Werror -fno-strict-aliasing -I. -I$(GATE_INC)
KERNEL  = /platform/i86pc/kernel/amd64/unix /kernel/amd64/genunix
UCC     = gcc
UFLAGS  = -m64 -O2 -Wall -Werror -DOBSD_USERTEST -D_REENTRANT
ULIBS   = -lpthread
KOBJS   = obsd_kern.o obsd_time.o obsd_bus.o obsd_vm.o obsd_glue.o
# Symbols the compat objects use that OpenBSD's drm objects define (the
# autoconf glue runs drm_attach through drm_ca/drm_cd, drm_drv.c); they
# resolve inside the module, not against the kernel.
DRMSYMS = drm_ca drm_cd

obj: $(KOBJS)
%.o: %.c obsd_prelude.h obsd_kern.h obsd_vm.h obsd_bus.h
	$(CC) $(KFLAGS) -c $< -o $@

kern-syms.txt:
	for k in $(KERNEL); do $(NM) -g --defined-only $$k | awk '{print $$3}'; done | sort -u > $@

syms: $(KOBJS) kern-syms.txt
	for o in $(KOBJS); do $(NM) -u $$o; done | awk '{print $$2}' | sort -u > undef.txt
	for o in $(KOBJS); do $(NM) -g --defined-only $$o; done | awk '{print $$3}' | sort -u > defined.txt
	for s in $(DRMSYMS); do echo $$s; done | sort > drmsyms.txt
	comm -23 undef.txt defined.txt | comm -23 - kern-syms.txt | comm -23 - drmsyms.txt > unresolved.txt
	@echo "undefined: `wc -l < undef.txt`  not in kernel: `wc -l < unresolved.txt`"
	@cat unresolved.txt
	@test ! -s unresolved.txt

negctl: kern-syms.txt
	printf '#include "obsd_kern.c"\nvoid obsd_negctl(void) { extern void no_such_kernel_function(void); no_such_kernel_function(); }\n' > negctl.c
	$(CC) $(KFLAGS) -c negctl.c -o negctl.o
	$(NM) -u negctl.o | awk '{print $$2}' | sort -u | comm -23 - kern-syms.txt > negctl.txt
	@if test -s negctl.txt; then echo "negative control FAILS as required:"; cat negctl.txt; \
	 else echo "NEGATIVE CONTROL DID NOT FAIL"; exit 1; fi

clean:
	rm -f $(KOBJS) test/test_sleep test/test_sleep_neg? test/neg?.out test/test_bars test/test_bars_neg test/bars_neg.out test/test_vm test/test_vm_neg test/vm_neg.out negctl.c negctl.o negctl.txt undef.txt defined.txt drmsyms.txt unresolved.txt kern-syms.txt

.PHONY: obj syms negctl clean test

# Userland test of obsd_time.c's sleep queue (test/test_sleep.c) and its two
# negative controls, each of which must FAIL.
test: test/test_sleep.c test/obsd_ushim.h obsd_time.c test/test_bars.c obsd_bus.c test/test_vm.c test/obsd_vmshim.h obsd_vm.c
	$(UCC) -m64 -O2 -Wall -Werror -o test/test_bars test/test_bars.c
	./test/test_bars
	$(UCC) -m64 -O2 -Wall -Werror -DBARS_SABOTAGE -o test/test_bars_neg test/test_bars.c
	if ./test/test_bars_neg > test/bars_neg.out; then echo "NEGATIVE CONTROL (bars) DID NOT FAIL"; exit 1; \
	 else echo "negative control (bars: entries swapped) FAILS as required:"; grep FAIL test/bars_neg.out; fi
	$(UCC) -m64 -O2 -Wall -Werror -DOBSD_USERTEST -o test/test_vm test/test_vm.c -lavl -lpthread
	./test/test_vm
	$(UCC) -m64 -O2 -Wall -Werror -DOBSD_USERTEST -DOBSD_VM_SABOTAGE -o test/test_vm_neg test/test_vm.c -lavl -lpthread
	if ./test/test_vm_neg > test/vm_neg.out; then echo "NEGATIVE CONTROL (vm) DID NOT FAIL"; exit 1; \
	 else echo "negative control (vm: exact-pfn AVL compare) FAILS as required:"; grep FAIL test/vm_neg.out; fi
	$(UCC) $(UFLAGS) -o test/test_sleep test/test_sleep.c $(ULIBS)
	./test/test_sleep
	for s in 1 2; do \
	  $(UCC) $(UFLAGS) -DOBSD_SLEEP_SABOTAGE=$$s -o test/test_sleep_neg$$s test/test_sleep.c $(ULIBS); \
	  if ./test/test_sleep_neg$$s > test/neg$$s.out; then \
	    echo "NEGATIVE CONTROL $$s DID NOT FAIL"; exit 1; \
	  else echo "negative control $$s FAILS as required:"; grep FAIL test/neg$$s.out; fi; \
	done
