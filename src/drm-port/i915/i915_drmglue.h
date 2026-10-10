/*
 * i915_drmglue.h -- i915_drmglue.c's interface for i915_illumos.c: plain C
 * types only, so the DDI file never includes OpenBSD's drm headers.
 */
#ifndef _I915_DRMGLUE_H
#define _I915_DRMGLUE_H
struct pollhead;
extern int i915_glue_has_master(dev_t);
extern void i915_glue_restore(dev_t);
extern int i915_glue_dumb_map(dev_t, uint64_t, size_t, void **, size_t *,
    int *, void **);
extern void i915_glue_dumb_unmap(void *);
extern int i915_glue_chpoll(dev_t, short, int, short *, struct pollhead **);
extern int i915_glue_drm_unit(void *);
extern void i915_glue_pollhead_clean(dev_t);
#endif
