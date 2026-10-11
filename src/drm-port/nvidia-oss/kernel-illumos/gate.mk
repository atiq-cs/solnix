# gate.mk -- solnix compile-gate goals for the vendored NVIDIA illumos port.
#
# This is a NEW solnix file (the vendored kernel-illumos/Makefile is kept
# verbatim). It `include`s the upstream Makefile and adds two license-segregated
# off-hardware compile goals, so the GPLv2 UVM path is an explicit opt-in and
# never contaminates the MIT base gate.
#
# Both goals compile EVERY glue .o and need NO nv-kernel.o / nv-modeset-kernel.o
# (no RM link, no GPU) -- exactly the upstream `objs:` target, split by license.
#
#   gmake -f gate.mk gate-mit   (DEFAULT) nvidia + nvidia_modeset + nvidia_i2c
#                               = MIT/permissive only, ZERO GPL obligation.
#                               The display / KMS / i2c path.
#   gmake -f gate.mk gate-uvm   OPT-IN. nvidia_uvm, which compiles NVIDIA's
#                               GPLv2 kernel-open/nvidia-uvm/uvm_common.c
#                               (CUDA Unified Memory). NOT run by default.
#   gmake -f gate.mk gate-all   both (for a full inventory; still off-hardware).
#
# Pass ILLUMOS_SRC=<illumos-gate tree> as to the upstream build.

include Makefile

# NVIDIA_OBJS, NVIDIA_MODESET_OBJS, NVIDIA_I2C_OBJS, NVIDIA_UVM_OBJS are all
# defined by the included Makefile; the per-%.o rules are too. We only add
# goals that select which object lists get built.

.PHONY: gate-mit gate-uvm gate-all
.DEFAULT_GOAL := gate-mit

# MIT/permissive-only: no file compiled here carries any GPL header.
gate-mit: $(NVIDIA_OBJS) $(NVIDIA_MODESET_OBJS) $(NVIDIA_I2C_OBJS)
	@echo "gate-mit OK: compiled nvidia + nvidia_modeset + nvidia_i2c objects (MIT/permissive, zero GPL)"

# OPT-IN GPLv2: nvidia_uvm pulls kernel-open/nvidia-uvm/uvm_common.c (GPL-2.0).
gate-uvm: $(NVIDIA_UVM_OBJS)
	@echo "gate-uvm OK: compiled nvidia_uvm objects (CUDA UVM, includes NVIDIA GPLv2 uvm_common.c)"

gate-all: gate-mit gate-uvm
	@echo "gate-all OK"
