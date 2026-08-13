# Makefile - build the illumos DRM core + GEM stub as a kernel module (C1a).
#
# Cross/native-compiles against the installed illumos kernel headers under
# /usr/include. Produces ET_REL AMD64 objects and links them into a single
# kernel module `drm`. This is the R-P17-equivalent milestone: the drm-core +
# GEM stub COMPILING against illumos headers. It does not need to load.

CC      = gcc
KFLAGS  = -m64 -D_KERNEL -ffreestanding -nostdinc -std=gnu99 \
          -Wall -Wno-unknown-pragmas -fno-strict-aliasing \
          -I/usr/include -Isrc
LDFLAGS = -r

OBJS = src/drm_core.o src/drm_gem.o
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
