/*
 * i915_pciid.h -- illumos i915 device match (see i915_pciid.c).
 */
#ifndef _I915_PCIID_H
#define	_I915_PCIID_H

#include <sys/types.h>

struct i915_pciid_info {
	const char	*platform;	/* upstream INTEL_<PLATFORM> name, lower case */
	uint8_t		gen;		/* graphics version */
	uint8_t		gt;		/* GT tier */
};

const struct i915_pciid_info *i915_pciid_match(uint16_t, uint16_t, uint32_t);
unsigned int i915_pciid_count(void);
uint16_t i915_pciid_device(unsigned int);

#endif /* _I915_PCIID_H */
