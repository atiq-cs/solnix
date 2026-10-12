/* Direct-ICD proof: dlopen libvulkan_lvp.so, get vk_icdGetInstanceProcAddr, create
 * an instance, enumerate physical devices, print the device name + driver. This is
 * exactly what the Vulkan loader does for an ICD -- proving lavapipe is a real CPU
 * Vulkan device on illumos without needing the loader built. */
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
typedef PFN_vkVoidFunction (*GIPA)(VkInstance, const char*);
int main(int argc, char**argv){
  const char* icdlib = argc>1 ? argv[1] : "/root/mesa-lavapipe-out/lib/libvulkan_lvp.so";
  void* h = dlopen(icdlib, RTLD_NOW|RTLD_LOCAL);
  if(!h){ fprintf(stderr,"dlopen FAIL: %s\n", dlerror()); return 2; }
  GIPA gipa = (GIPA)dlsym(h, "vk_icdGetInstanceProcAddr");
  if(!gipa){ fprintf(stderr,"no vk_icdGetInstanceProcAddr (not an ICD?)\n"); return 2; }
  printf("ICD entry vk_icdGetInstanceProcAddr: FOUND\n");
  PFN_vkCreateInstance ci = (PFN_vkCreateInstance)gipa(NULL,"vkCreateInstance");
  if(!ci){ fprintf(stderr,"no vkCreateInstance\n"); return 2; }
  VkApplicationInfo ai={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.apiVersion=VK_API_VERSION_1_1};
  VkInstanceCreateInfo ici={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&ai};
  VkInstance inst;
  VkResult r = ci(&ici,NULL,&inst);
  if(r!=VK_SUCCESS){ fprintf(stderr,"vkCreateInstance=%d\n",r); return 3; }
  printf("vkCreateInstance: OK\n");
  PFN_vkEnumeratePhysicalDevices epd=(PFN_vkEnumeratePhysicalDevices)gipa(inst,"vkEnumeratePhysicalDevices");
  PFN_vkGetPhysicalDeviceProperties gpp=(PFN_vkGetPhysicalDeviceProperties)gipa(inst,"vkGetPhysicalDeviceProperties");
  uint32_t n=0; epd(inst,&n,NULL);
  printf("physical devices: %u\n", n);
  if(!n){ fprintf(stderr,"NO_DEVICE\n"); return 4; }
  VkPhysicalDevice pd[8]; if(n>8)n=8; epd(inst,&n,pd);
  int llvmpipe=0;
  for(uint32_t i=0;i<n;i++){ VkPhysicalDeviceProperties p; gpp(pd[i],&p);
    printf("  device[%u]: %s  apiVersion=%u.%u.%u driverVersion=%u\n", i, p.deviceName,
      VK_VERSION_MAJOR(p.apiVersion),VK_VERSION_MINOR(p.apiVersion),VK_VERSION_PATCH(p.apiVersion), p.driverVersion);
    if(strstr(p.deviceName,"llvmpipe")||strstr(p.deviceName,"LLVM")) llvmpipe=1;
  }
  printf("%s\n", llvmpipe ? "LAVAPIPE_ENUMERATED_PASS" : "DEVICE_BUT_NOT_LLVMPIPE");
  return llvmpipe?0:5;
}
