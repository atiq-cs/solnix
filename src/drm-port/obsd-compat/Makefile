# Makefile -- the OpenBSD-kernel-API-on-illumos compat layer (src/drm-port/obsd-compat).
#
#   make obj     obsd_kern.o, a kernel ET_REL object against the gate proto
#   make syms    every undefined symbol of obsd_kern.o must be a symbol the
#                running illumos kernel (unix + genunix) defines; prints the
#                ones that are not (they are PLANNED or a bug) and fails
#   make negctl  the same check on an object with a deliberately bogus
#                external call; it must FAIL
GATE_INC ?= /nix/store/s7zkx8nx5sfxixmyqmlnrybrrh14jkmb-illumos-gate-proto/usr/include
CC      = gcc
NM      = gnm
KFLAGS  = -m64 -mcmodel=kernel -mno-red-zone -D_KERNEL -ffreestanding -nostdinc \
          -std=gnu11 -O2 -Wall -Werror -fno-strict-aliasing -I. -I$(GATE_INC)
KERNEL  = /platform/i86pc/kernel/amd64/unix /kernel/amd64/genunix

obj: obsd_kern.o
obsd_kern.o: obsd_kern.c obsd_prelude.h obsd_kern.h obsd_vm.h obsd_bus.h
	$(CC) $(KFLAGS) -c obsd_kern.c -o $@

kern-syms.txt:
	for k in $(KERNEL); do $(NM) -g --defined-only $$k | awk '{print $$3}'; done | sort -u > $@

syms: obsd_kern.o kern-syms.txt
	$(NM) -u obsd_kern.o | awk '{print $$2}' | sort -u > undef.txt
	comm -23 undef.txt kern-syms.txt > unresolved.txt
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
	rm -f obsd_kern.o negctl.c negctl.o negctl.txt undef.txt unresolved.txt kern-syms.txt

.PHONY: obj syms negctl clean
