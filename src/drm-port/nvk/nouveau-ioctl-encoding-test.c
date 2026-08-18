#include <stdio.h>
#include <stdint.h>
#include "linux-ioctl-compat.h"
#define DRM_IOCTL_BASE 0x64
#define DRM_IOWR(nr,type) _IOWR(DRM_IOCTL_BASE,nr,type)
#define DRM_IOW(nr,type)  _IOW(DRM_IOCTL_BASE,nr,type)
#define DRM_COMMAND_BASE 0x40
#define DRM_NOUVEAU_GETPARAM 0x00
#define DRM_NOUVEAU_NVIF     0x07
#define DRM_NOUVEAU_VM_INIT  0x10
#define DRM_NOUVEAU_VM_BIND  0x11
#define DRM_NOUVEAU_EXEC     0x12
#define DRM_NOUVEAU_GEM_NEW  0x40
struct drm_nouveau_getparam { uint64_t a,b; };
struct drm_nouveau_vm_init { uint64_t a,b; };
struct drm_nouveau_vm_bind { uint32_t a,b; uint64_t c,d; };
struct drm_nouveau_exec { uint32_t a,b; uint64_t c,d,e,f; };
struct drm_nouveau_gem_new { uint64_t a[6]; };
int main(void){
  unsigned gp=DRM_IOWR(DRM_COMMAND_BASE+DRM_NOUVEAU_GETPARAM, struct drm_nouveau_getparam);
  unsigned vi=DRM_IOWR(DRM_COMMAND_BASE+DRM_NOUVEAU_VM_INIT, struct drm_nouveau_vm_init);
  unsigned vb=DRM_IOWR(DRM_COMMAND_BASE+DRM_NOUVEAU_VM_BIND, struct drm_nouveau_vm_bind);
  unsigned ex=DRM_IOWR(DRM_COMMAND_BASE+DRM_NOUVEAU_EXEC, struct drm_nouveau_exec);
  unsigned gn=DRM_IOWR(DRM_COMMAND_BASE+DRM_NOUVEAU_GEM_NEW, struct drm_nouveau_gem_new);
  printf("NOUVEAU_GETPARAM = 0x%08x (dir=%u type=0x%02x nr=0x%02x size=%u)\n",gp,_IOC_DIR(gp),_IOC_TYPE(gp),_IOC_NR(gp),_IOC_SIZE(gp));
  printf("NOUVEAU_VM_INIT  = 0x%08x (nr=0x%02x)\n",vi,_IOC_NR(vi));
  printf("NOUVEAU_VM_BIND  = 0x%08x (nr=0x%02x)\n",vb,_IOC_NR(vb));
  printf("NOUVEAU_EXEC     = 0x%08x (nr=0x%02x)\n",ex,_IOC_NR(ex));
  printf("NOUVEAU_GEM_NEW  = 0x%08x (nr=0x%02x)\n",gn,_IOC_NR(gn));
  printf("expect: type=0x64(DRM) nr=0x40+op, dir=3(RW), Linux _IOC\n");
  return 0;
}
