#include <stdio.h>
#include <stdint.h>
#include "linux-ioctl-compat.h"
#define DRM_IOCTL_BASE 0x64
#define DRM_IOWR(nr,type) _IOWR(DRM_IOCTL_BASE,nr,type)
#define DRM_IOW(nr,type)  _IOW(DRM_IOCTL_BASE,nr,type)
#define DRM_COMMAND_BASE 0x40
#define DRM_AMDGPU_GEM_CREATE 0x00
#define DRM_AMDGPU_CS 0x04
#define DRM_AMDGPU_INFO 0x05
union drm_amdgpu_gem_create { uint64_t a,b; uint32_t c,d; uint64_t h; };
union drm_amdgpu_cs { uint32_t a,b,c,d; uint64_t e,f; };
struct drm_amdgpu_info { uint64_t a,b; uint32_t c,d; };
int main(void){
  unsigned gc = DRM_IOWR(DRM_COMMAND_BASE+DRM_AMDGPU_GEM_CREATE, union drm_amdgpu_gem_create);
  unsigned cs = DRM_IOWR(DRM_COMMAND_BASE+DRM_AMDGPU_CS, union drm_amdgpu_cs);
  unsigned in = DRM_IOW(DRM_COMMAND_BASE+DRM_AMDGPU_INFO, struct drm_amdgpu_info);
  printf("AMDGPU_GEM_CREATE = 0x%08x (dir=%u type=0x%02x nr=0x%02x size=%u)\n",
    gc, _IOC_DIR(gc), _IOC_TYPE(gc), _IOC_NR(gc), _IOC_SIZE(gc));
  printf("AMDGPU_CS         = 0x%08x (nr=0x%02x)\n", cs, _IOC_NR(cs));
  printf("AMDGPU_INFO       = 0x%08x (dir=%u nr=0x%02x)\n", in, _IOC_DIR(in), _IOC_NR(in));
  printf("expect: type=0x64 nr=0x40(GEM_CREATE)/0x44(CS)/0x45(INFO), Linux _IOC dir bits high\n");
  return 0;
}
