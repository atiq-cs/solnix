/* anv-ioctl-encoding-test.c -- proof that ANV's i915/xe DRM ioctl numbers,
 * built from the bundled include/drm-uapi/{drm,xe,i915}_drm.h with the Linux
 * _IOC shim forced on illumos, match the Linux DRM ioctl encoding the C1 kernel
 * decodes. Mirrors radv/ioctl-encoding-test.c but for the Intel uapi. */
#include <stdio.h>
#include <stdint.h>
#include "drm.h"        /* bundled drm-uapi/drm.h (shim-forced Linux _IOC) */
#include "xe_drm.h"
#include "i915_drm.h"

static void show(const char *name, unsigned long v)
{
    unsigned dir  = (v >> 30) & 0x3;
    unsigned size = (v >> 16) & 0x3fff;
    unsigned type = (v >>  8) & 0xff;
    unsigned nr   = (v >>  0) & 0xff;
    printf("%-28s = 0x%08lx (dir=%u type=0x%02x nr=0x%02x size=%u)\n",
           name, v, dir, type, nr, size);
}

int main(void)
{
    /* type must be 'd' (0x64 = DRM); nr = COMMAND_BASE(0x40) + opcode */
    show("DRM_IOCTL_XE_DEVICE_QUERY",   DRM_IOCTL_XE_DEVICE_QUERY);
    show("DRM_IOCTL_XE_GEM_CREATE",     DRM_IOCTL_XE_GEM_CREATE);
    show("DRM_IOCTL_XE_VM_CREATE",      DRM_IOCTL_XE_VM_CREATE);
    show("DRM_IOCTL_XE_EXEC",           DRM_IOCTL_XE_EXEC);
    show("DRM_IOCTL_I915_GETPARAM",     DRM_IOCTL_I915_GETPARAM);
    show("DRM_IOCTL_I915_GEM_CREATE",   DRM_IOCTL_I915_GEM_CREATE);
    /* core DRM shared by both backends + the syncobj path intel_gem.c uses */
    show("DRM_IOCTL_SYNCOBJ_CREATE",    DRM_IOCTL_SYNCOBJ_CREATE);
    show("DRM_IOCTL_GEM_CLOSE",         DRM_IOCTL_GEM_CLOSE);
    return 0;
}
