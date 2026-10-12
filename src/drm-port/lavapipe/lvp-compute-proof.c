/* Direct-ICD compute proof: dispatch out[i]=in[i]*2 on lavapipe via the ICD proc
 * chain (no loader). Resolves device fns via vkGetDeviceProcAddr. Verifies result;
 * expected multiplier parameterised so a WRONG value makes it FAIL (checker can fail). */
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef PFN_vkVoidFunction (*GIPA)(VkInstance,const char*);
static GIPA gipa; static VkInstance inst; static VkDevice dev;
#define IP(n) ((PFN_##n)gipa(inst,#n))
static PFN_vkGetDeviceProcAddr gdpa;
#define DP(n) ((PFN_##n)gdpa(dev,#n))
#define N 1024
static unsigned char* readfile(const char*p,size_t*len){ FILE*f=fopen(p,"rb"); if(!f)return 0; fseek(f,0,SEEK_END);*len=ftell(f);fseek(f,0,SEEK_SET); unsigned char*b=malloc(*len); fread(b,1,*len,f); fclose(f); return b; }
int main(int argc,char**argv){
  const char* icdlib = argc>1?argv[1]:"/root/mesa-lavapipe-out/lib/libvulkan_lvp.so";
  const char* spv = argc>2?argv[2]:"/root/double.spv";
  unsigned mult = argc>3?(unsigned)atoi(argv[3]):2;
  void*h=dlopen(icdlib,RTLD_NOW|RTLD_LOCAL); if(!h){fprintf(stderr,"dlopen %s\n",dlerror());return 2;}
  gipa=(GIPA)dlsym(h,"vk_icdGetInstanceProcAddr"); if(!gipa){fprintf(stderr,"no gipa\n");return 2;}
  PFN_vkCreateInstance ci=(PFN_vkCreateInstance)gipa(NULL,"vkCreateInstance");
  VkApplicationInfo ai={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.apiVersion=VK_API_VERSION_1_1};
  VkInstanceCreateInfo ici={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&ai};
  if(ci(&ici,0,&inst)!=VK_SUCCESS){fprintf(stderr,"NO_INSTANCE\n");return 2;}
  PFN_vkEnumeratePhysicalDevices epd=IP(vkEnumeratePhysicalDevices);
  uint32_t n=0; epd(inst,&n,0); if(!n){fprintf(stderr,"NO_DEVICE\n");return 4;}
  VkPhysicalDevice pd; n=1; epd(inst,&n,&pd);
  PFN_vkGetPhysicalDeviceProperties gpp=IP(vkGetPhysicalDeviceProperties);
  VkPhysicalDeviceProperties props; gpp(pd,&props); fprintf(stderr,"DEVICE: %s\n",props.deviceName);
  PFN_vkGetPhysicalDeviceQueueFamilyProperties gqf=IP(vkGetPhysicalDeviceQueueFamilyProperties);
  uint32_t nq=0; gqf(pd,&nq,0); VkQueueFamilyProperties*qf=malloc(nq*sizeof*qf); gqf(pd,&nq,qf);
  uint32_t cq=~0u; for(uint32_t i=0;i<nq;i++) if(qf[i].queueFlags&VK_QUEUE_COMPUTE_BIT){cq=i;break;}
  if(cq==~0u){fprintf(stderr,"NO_COMPUTE_QUEUE\n");return 3;}
  float prio=1; VkDeviceQueueCreateInfo qci={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=cq,.queueCount=1,.pQueuePriorities=&prio};
  VkDeviceCreateInfo dci={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.queueCreateInfoCount=1,.pQueueCreateInfos=&qci};
  PFN_vkCreateDevice cd=IP(vkCreateDevice); if(cd(pd,&dci,0,&dev)!=VK_SUCCESS){fprintf(stderr,"NO_DEV\n");return 3;}
  gdpa=IP(vkGetDeviceProcAddr);
  PFN_vkGetDeviceQueue gdq=DP(vkGetDeviceQueue); VkQueue q; gdq(dev,cq,0,&q);
  PFN_vkGetPhysicalDeviceMemoryProperties gmp=IP(vkGetPhysicalDeviceMemoryProperties);
  VkPhysicalDeviceMemoryProperties mp; gmp(pd,&mp);
  VkDeviceSize sz=N*4;
  PFN_vkCreateBuffer cb=DP(vkCreateBuffer); PFN_vkGetBufferMemoryRequirements gbmr=DP(vkGetBufferMemoryRequirements);
  PFN_vkAllocateMemory am=DP(vkAllocateMemory); PFN_vkBindBufferMemory bbm=DP(vkBindBufferMemory);
  PFN_vkMapMemory mm=DP(vkMapMemory); PFN_vkUnmapMemory um=DP(vkUnmapMemory);
  VkBufferCreateInfo bci={.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,.size=sz,.usage=VK_BUFFER_USAGE_STORAGE_BUFFER_BIT};
  VkBuffer ba,bb; cb(dev,&bci,0,&ba); cb(dev,&bci,0,&bb);
  VkMemoryRequirements mr; gbmr(dev,ba,&mr);
  uint32_t mt=~0u; for(uint32_t i=0;i<mp.memoryTypeCount;i++) if((mr.memoryTypeBits&(1u<<i))&&((mp.memoryTypes[i].propertyFlags&(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))==(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))){mt=i;break;}
  VkMemoryAllocateInfo mai={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=mr.size,.memoryTypeIndex=mt};
  VkDeviceMemory ma,mb; am(dev,&mai,0,&ma); am(dev,&mai,0,&mb); bbm(dev,ba,ma,0); bbm(dev,bb,mb,0);
  uint32_t*pa; mm(dev,ma,0,sz,0,(void**)&pa); for(int i=0;i<N;i++)pa[i]=i; um(dev,ma);
  size_t spvlen; unsigned char*spvb=readfile(spv,&spvlen); if(!spvb){fprintf(stderr,"no spv\n");return 2;}
  PFN_vkCreateShaderModule csm=DP(vkCreateShaderModule);
  VkShaderModuleCreateInfo smci={.sType=VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,.codeSize=spvlen,.pCode=(const uint32_t*)spvb};
  VkShaderModule sm; if(csm(dev,&smci,0,&sm)!=VK_SUCCESS){fprintf(stderr,"NO_SHADER\n");return 3;}
  VkDescriptorSetLayoutBinding b[2]={{0,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1,VK_SHADER_STAGE_COMPUTE_BIT,0},{1,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1,VK_SHADER_STAGE_COMPUTE_BIT,0}};
  VkDescriptorSetLayoutCreateInfo dl={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,.bindingCount=2,.pBindings=b};
  PFN_vkCreateDescriptorSetLayout cdsl=DP(vkCreateDescriptorSetLayout); VkDescriptorSetLayout dsl; cdsl(dev,&dl,0,&dsl);
  VkPushConstantRange pcr={VK_SHADER_STAGE_COMPUTE_BIT,0,4};
  VkPipelineLayoutCreateInfo pl={.sType=VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,.setLayoutCount=1,.pSetLayouts=&dsl,.pushConstantRangeCount=1,.pPushConstantRanges=&pcr};
  PFN_vkCreatePipelineLayout cpl=DP(vkCreatePipelineLayout); VkPipelineLayout plo; cpl(dev,&pl,0,&plo);
  VkComputePipelineCreateInfo cpi={.sType=VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,.stage={.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,.stage=VK_SHADER_STAGE_COMPUTE_BIT,.module=sm,.pName="main"},.layout=plo};
  PFN_vkCreateComputePipelines ccp=DP(vkCreateComputePipelines); VkPipeline pipe; if(ccp(dev,0,1,&cpi,0,&pipe)!=VK_SUCCESS){fprintf(stderr,"NO_PIPE\n");return 3;}
  VkDescriptorPoolSize ps={VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,2};
  VkDescriptorPoolCreateInfo dpi={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,.maxSets=1,.poolSizeCount=1,.pPoolSizes=&ps};
  PFN_vkCreateDescriptorPool cdp=DP(vkCreateDescriptorPool); VkDescriptorPool dp; cdp(dev,&dpi,0,&dp);
  VkDescriptorSetAllocateInfo dsa={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,.descriptorPool=dp,.descriptorSetCount=1,.pSetLayouts=&dsl};
  PFN_vkAllocateDescriptorSets ads=DP(vkAllocateDescriptorSets); VkDescriptorSet ds; ads(dev,&dsa,&ds);
  VkDescriptorBufferInfo i0={ba,0,sz},i1={bb,0,sz};
  VkWriteDescriptorSet w[2]={{.sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,.dstSet=ds,.dstBinding=0,.descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.pBufferInfo=&i0},{.sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,.dstSet=ds,.dstBinding=1,.descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.pBufferInfo=&i1}};
  PFN_vkUpdateDescriptorSets uds=DP(vkUpdateDescriptorSets); uds(dev,2,w,0,0);
  VkCommandPoolCreateInfo cpci={.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,.queueFamilyIndex=cq};
  PFN_vkCreateCommandPool ccpool=DP(vkCreateCommandPool); VkCommandPool cp; ccpool(dev,&cpci,0,&cp);
  VkCommandBufferAllocateInfo cbi={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,.commandPool=cp,.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY,.commandBufferCount=1};
  PFN_vkAllocateCommandBuffers acb=DP(vkAllocateCommandBuffers); VkCommandBuffer cmd; acb(dev,&cbi,&cmd);
  PFN_vkBeginCommandBuffer bcb=DP(vkBeginCommandBuffer); PFN_vkEndCommandBuffer ecb=DP(vkEndCommandBuffer);
  PFN_vkCmdBindPipeline cbp=DP(vkCmdBindPipeline); PFN_vkCmdBindDescriptorSets cbds=DP(vkCmdBindDescriptorSets);
  PFN_vkCmdPushConstants cpc=DP(vkCmdPushConstants); PFN_vkCmdDispatch cdisp=DP(vkCmdDispatch);
  PFN_vkQueueSubmit qs=DP(vkQueueSubmit); PFN_vkQueueWaitIdle qwi=DP(vkQueueWaitIdle);
  VkCommandBufferBeginInfo bi={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
  bcb(cmd,&bi); cbp(cmd,VK_PIPELINE_BIND_POINT_COMPUTE,pipe); cbds(cmd,VK_PIPELINE_BIND_POINT_COMPUTE,plo,0,1,&ds,0,0);
  uint32_t nn=N; cpc(cmd,plo,VK_SHADER_STAGE_COMPUTE_BIT,0,4,&nn); cdisp(cmd,(N+63)/64,1,1); ecb(cmd);
  VkSubmitInfo si={.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.commandBufferCount=1,.pCommandBuffers=&cmd};
  qs(q,1,&si,0); qwi(q);
  uint32_t*pb; mm(dev,mb,0,sz,0,(void**)&pb);
  int ok=1; for(int i=0;i<N;i++) if(pb[i]!=(uint32_t)i*mult){ if(i<3)fprintf(stderr,"mism[%d]=%u want %u\n",i,pb[i],(uint32_t)i*mult); ok=0; }
  um(dev,mb);
  printf("%s\n", ok?"COMPUTE_VERIFY_PASS":"COMPUTE_VERIFY_FAIL");
  return ok?0:5;
}
