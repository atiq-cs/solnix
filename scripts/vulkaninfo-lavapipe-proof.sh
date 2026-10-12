#!/bin/sh
# vulkaninfo-lavapipe-proof.sh -- negative-controlled proof that lavapipe is a
# REAL working CPU Vulkan device on solnix, not a build artifact that merely links.
#
# Two positive claims + one negative control each (a check that cannot fail
# proves nothing -- docs/working-with-subagents.md):
#
#   P1  vulkaninfo enumerates lavapipe as a VkPhysicalDevice
#         POSITIVE: with the lavapipe ICD on VK_ICD_FILENAMES, vulkaninfo prints
#                   a device whose driverID is DRIVER_ID_MESA_LLVMPIPE / deviceName
#                   contains "llvmpipe".
#         NEGATIVE: with VK_ICD_FILENAMES pointed at /dev/null (no ICD), vulkaninfo
#                   finds ZERO devices (VK_ERROR_INCOMPATIBLE_DRIVER / "no devices").
#                   If the negative still shows a device, some OTHER ICD is leaking
#                   in and the positive proves nothing -> the proof is INVALID.
#
#   P2  a trivial Vulkan COMPUTE shader runs on lavapipe and returns correct data
#         POSITIVE: dispatch a compute shader that writes out[i]=in[i]*2 over N
#                   elements; read back the buffer; every element matches.
#         NEGATIVE: run the same program with the ICD removed -> it must fail to
#                   get a device (no silent "pass" on zero work). Also a data
#                   negative: a deliberately wrong expected value must make the
#                   verify step report FAIL (the checker can actually fail).
#
# Usage:
#   LVP_PREFIX=/nix/store/...-mesa-lavapipe-25.1.4 \
#   LOADER_PREFIX=/root/ggml-vulkan/prefix \
#   sh vulkaninfo-lavapipe-proof.sh
set -u
LVP_PREFIX="${LVP_PREFIX:?set LVP_PREFIX to the nix-store mesa-lavapipe path}"
LOADER_PREFIX="${LOADER_PREFIX:-/root/ggml-vulkan/prefix}"
GCC="${GCC:-/usr/gcc/14}"
GLSLANG="${GLSLANG:-$(command -v glslangValidator || echo /usr/bin/glslangValidator)}"

ICD=$(ls "$LVP_PREFIX"/share/vulkan/icd.d/*lvp*.json "$LVP_PREFIX"/share/vulkan/icd.d/*.json 2>/dev/null | head -1)
[ -n "$ICD" ] || { echo "FAIL: no lavapipe ICD json under $LVP_PREFIX/share/vulkan/icd.d"; exit 1; }
export LD_LIBRARY_PATH="$LOADER_PREFIX/lib:$LVP_PREFIX/lib:$GCC/lib/amd64:$GCC/lib:${LD_LIBRARY_PATH:-}"
VKINFO="$LOADER_PREFIX/bin/vulkaninfo"; [ -x "$VKINFO" ] || VKINFO=$(command -v vulkaninfo || true)

echo "=== ICD: $ICD ==="
echo "=== loader: $LOADER_PREFIX  vulkaninfo: $VKINFO ==="

pass=0; fail=0
ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }

# ---------- P1 positive ----------
echo; echo "[P1+] vulkaninfo WITH lavapipe ICD -> expect llvmpipe device"
if [ -n "$VKINFO" ]; then
  VK_ICD_FILENAMES="$ICD" VK_DRIVER_FILES="$ICD" "$VKINFO" 2>/dev/null > /var/tmp/vk.p1.txt || true
  if grep -qiE 'llvmpipe|MESA_LLVMPIPE' /var/tmp/vk.p1.txt; then
    ok "lavapipe enumerated: $(grep -iE 'deviceName|driverID' /var/tmp/vk.p1.txt | head -2 | tr '\n' ' ')"
  else
    bad "vulkaninfo did NOT show llvmpipe (head below)"; head -20 /var/tmp/vk.p1.txt | sed 's/^/    /'
  fi
  # ---------- P1 negative control ----------
  echo "[P1-] vulkaninfo with NO ICD (/dev/null) -> expect ZERO devices"
  VK_ICD_FILENAMES=/dev/null VK_DRIVER_FILES=/dev/null "$VKINFO" 2>/var/tmp/vk.p1n.err > /var/tmp/vk.p1n.txt || true
  if grep -qiE 'llvmpipe|MESA_LLVMPIPE' /var/tmp/vk.p1n.txt; then
    bad "NEGATIVE CONTROL BROKEN: a device appears with no ICD -> another ICD is leaking; P1+ is not trustworthy"
  else
    ok "no device without the ICD (negative control holds)"
  fi
else
  bad "no vulkaninfo binary (build Vulkan-Tools, or skip to P2 which needs only the loader)"
fi

# ---------- P2: trivial compute shader ----------
echo; echo "[P2] trivial Vulkan compute shader (out[i]=in[i]*2) on lavapipe"
WD=$(mktemp -d /var/tmp/vkcomp.XXXXXX); cd "$WD"
cat > double.comp <<'GLSL'
#version 450
layout(local_size_x = 64) in;
layout(std430, binding = 0) readonly  buffer In  { uint a[]; };
layout(std430, binding = 1) writeonly buffer Out { uint b[]; };
layout(push_constant) uniform P { uint n; } pc;
void main() { uint i = gl_GlobalInvocationID.x; if (i < pc.n) b[i] = a[i] * 2u; }
GLSL
if [ -x "$GLSLANG" ]; then
  "$GLSLANG" -V double.comp -o double.spv 2>/var/tmp/glsl.err && ok "glslang compiled double.comp -> SPIR-V" \
    || { bad "glslang failed: $(head -3 /var/tmp/glsl.err)"; }
else
  bad "no glslangValidator ($GLSLANG) -- cannot build the compute shader"
fi

# embed the SPIR-V as a C array so the harness is self-contained
if [ -f double.spv ]; then
  python3 - double.spv > spv.h <<'PY'
import sys,struct
d=open(sys.argv[1],'rb').read()
w=struct.unpack('<%dI'%(len(d)//4), d)
print("static const unsigned int SPV[] = {%s};"%(",".join("0x%08x"%x for x in w)))
print("static const unsigned long SPV_LEN = %d;"%len(d))
PY
fi

cat > vkcomp.c <<'CCODE'
/* Minimal headless Vulkan compute: no WSI, no surface. Enumerate the (only,
 * lavapipe) physical device, create a compute queue, upload N uints, dispatch
 * out[i]=in[i]*2, read back, verify. Expected-value is parameterised so a wrong
 * expectation makes the verify step FAIL -- the checker can actually fail. */
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "spv.h"
#define N 1024
#define CK(x) do{ VkResult _r=(x); if(_r!=VK_SUCCESS){ fprintf(stderr,"VK FAIL %s = %d\n", #x, _r); return 3; } }while(0)
static uint32_t memtype(VkPhysicalDevice p, uint32_t bits, VkMemoryPropertyFlags want){
  VkPhysicalDeviceMemoryProperties m; vkGetPhysicalDeviceMemoryProperties(p,&m);
  for(uint32_t i=0;i<m.memoryTypeCount;i++) if((bits&(1u<<i))&&((m.memoryTypes[i].propertyFlags&want)==want)) return i;
  return ~0u;
}
int main(int argc, char**argv){
  unsigned mult = argc>1 ? (unsigned)atoi(argv[1]) : 2; /* expected multiplier for verify */
  VkInstance inst; VkApplicationInfo ai={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.apiVersion=VK_API_VERSION_1_1};
  VkInstanceCreateInfo ici={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&ai};
  if(vkCreateInstance(&ici,0,&inst)!=VK_SUCCESS){ fprintf(stderr,"NO_INSTANCE\n"); return 2; }
  uint32_t nd=0; vkEnumeratePhysicalDevices(inst,&nd,0);
  if(!nd){ fprintf(stderr,"NO_DEVICE\n"); return 2; }   /* negative control: no ICD -> here */
  VkPhysicalDevice*pd=malloc(nd*sizeof*pd); vkEnumeratePhysicalDevices(inst,&nd,pd);
  VkPhysicalDevice p=pd[0];
  VkPhysicalDeviceProperties props; vkGetPhysicalDeviceProperties(p,&props);
  fprintf(stderr,"DEVICE: %s\n", props.deviceName);
  uint32_t nq=0; vkGetPhysicalDeviceQueueFamilyProperties(p,&nq,0);
  VkQueueFamilyProperties*qf=malloc(nq*sizeof*qf); vkGetPhysicalDeviceQueueFamilyProperties(p,&nq,qf);
  uint32_t cq=~0u; for(uint32_t i=0;i<nq;i++) if(qf[i].queueFlags&VK_QUEUE_COMPUTE_BIT){cq=i;break;}
  if(cq==~0u){ fprintf(stderr,"NO_COMPUTE_QUEUE\n"); return 3; }
  float prio=1.0f; VkDeviceQueueCreateInfo qci={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=cq,.queueCount=1,.pQueuePriorities=&prio};
  VkDeviceCreateInfo dci={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.queueCreateInfoCount=1,.pQueueCreateInfos=&qci};
  VkDevice dev; CK(vkCreateDevice(p,&dci,0,&dev));
  VkQueue q; vkGetDeviceQueue(dev,cq,0,&q);
  VkDeviceSize sz=N*sizeof(uint32_t);
  VkBuffer ba,bb; VkBufferCreateInfo bci={.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,.size=sz,.usage=VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,.sharingMode=VK_SHARING_MODE_EXCLUSIVE};
  CK(vkCreateBuffer(dev,&bci,0,&ba)); CK(vkCreateBuffer(dev,&bci,0,&bb));
  VkMemoryRequirements mr; vkGetBufferMemoryRequirements(dev,ba,&mr);
  uint32_t mt=memtype(p,mr.memoryTypeBits,VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
  VkMemoryAllocateInfo mai={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=mr.size,.memoryTypeIndex=mt};
  VkDeviceMemory ma,mb; CK(vkAllocateMemory(dev,&mai,0,&ma)); CK(vkAllocateMemory(dev,&mai,0,&mb));
  CK(vkBindBufferMemory(dev,ba,ma,0)); CK(vkBindBufferMemory(dev,bb,mb,0));
  uint32_t*pa; CK(vkMapMemory(dev,ma,0,sz,0,(void**)&pa)); for(int i=0;i<N;i++) pa[i]=(uint32_t)i; vkUnmapMemory(dev,ma);
  VkShaderModuleCreateInfo smci={.sType=VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,.codeSize=SPV_LEN,.pCode=SPV};
  VkShaderModule sm; CK(vkCreateShaderModule(dev,&smci,0,&sm));
  VkDescriptorSetLayoutBinding b[2]={{0,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1,VK_SHADER_STAGE_COMPUTE_BIT,0},{1,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1,VK_SHADER_STAGE_COMPUTE_BIT,0}};
  VkDescriptorSetLayoutCreateInfo dl={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,.bindingCount=2,.pBindings=b};
  VkDescriptorSetLayout dsl; CK(vkCreateDescriptorSetLayout(dev,&dl,0,&dsl));
  VkPushConstantRange pcr={VK_SHADER_STAGE_COMPUTE_BIT,0,sizeof(uint32_t)};
  VkPipelineLayoutCreateInfo pl={.sType=VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,.setLayoutCount=1,.pSetLayouts=&dsl,.pushConstantRangeCount=1,.pPushConstantRanges=&pcr};
  VkPipelineLayout plo; CK(vkCreatePipelineLayout(dev,&pl,0,&plo));
  VkComputePipelineCreateInfo cpi={.sType=VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,.stage={.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,.stage=VK_SHADER_STAGE_COMPUTE_BIT,.module=sm,.pName="main"},.layout=plo};
  VkPipeline pipe; CK(vkCreateComputePipelines(dev,0,1,&cpi,0,&pipe));
  VkDescriptorPoolSize ps={VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,2};
  VkDescriptorPoolCreateInfo dpi={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,.maxSets=1,.poolSizeCount=1,.pPoolSizes=&ps};
  VkDescriptorPool dp; CK(vkCreateDescriptorPool(dev,&dpi,0,&dp));
  VkDescriptorSetAllocateInfo dsa={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,.descriptorPool=dp,.descriptorSetCount=1,.pSetLayouts=&dsl};
  VkDescriptorSet ds; CK(vkAllocateDescriptorSets(dev,&dsa,&ds));
  VkDescriptorBufferInfo i0={ba,0,sz}, i1={bb,0,sz};
  VkWriteDescriptorSet w[2]={{.sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,.dstSet=ds,.dstBinding=0,.descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.pBufferInfo=&i0},{.sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,.dstSet=ds,.dstBinding=1,.descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.pBufferInfo=&i1}};
  vkUpdateDescriptorSets(dev,2,w,0,0);
  VkCommandPoolCreateInfo cpci={.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,.queueFamilyIndex=cq};
  VkCommandPool cp; CK(vkCreateCommandPool(dev,&cpci,0,&cp));
  VkCommandBufferAllocateInfo cbi={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,.commandPool=cp,.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY,.commandBufferCount=1};
  VkCommandBuffer cb; CK(vkAllocateCommandBuffers(dev,&cbi,&cb));
  VkCommandBufferBeginInfo bi={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
  CK(vkBeginCommandBuffer(cb,&bi));
  vkCmdBindPipeline(cb,VK_PIPELINE_BIND_POINT_COMPUTE,pipe);
  vkCmdBindDescriptorSets(cb,VK_PIPELINE_BIND_POINT_COMPUTE,plo,0,1,&ds,0,0);
  uint32_t n=N; vkCmdPushConstants(cb,plo,VK_SHADER_STAGE_COMPUTE_BIT,0,sizeof n,&n);
  vkCmdDispatch(cb,(N+63)/64,1,1);
  CK(vkEndCommandBuffer(cb));
  VkSubmitInfo si={.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.commandBufferCount=1,.pCommandBuffers=&cb};
  CK(vkQueueSubmit(q,1,&si,0)); CK(vkQueueWaitIdle(q));
  uint32_t*pb; CK(vkMapMemory(dev,mb,0,sz,0,(void**)&pb));
  int ok=1; for(int i=0;i<N;i++){ if(pb[i]!=(uint32_t)i*mult){ if(i<4) fprintf(stderr,"mismatch[%d]=%u want %u\n",i,pb[i],(uint32_t)i*mult); ok=0; } }
  vkUnmapMemory(dev,mb);
  printf("%s\n", ok ? "COMPUTE_VERIFY_PASS" : "COMPUTE_VERIFY_FAIL");
  return ok?0:4;
}
CCODE

if [ -f double.spv ]; then
  "$GCC/bin/gcc" -m64 -O2 -I"$LOADER_PREFIX/include" vkcomp.c -o vkcomp \
    -L"$LOADER_PREFIX/lib" -lvulkan -lsocket -lnsl 2>/var/tmp/cc.err \
    && ok "vkcomp built" || { bad "vkcomp build: $(head -5 /var/tmp/cc.err)"; }
fi

if [ -x ./vkcomp ]; then
  echo "[P2+] dispatch WITH lavapipe ICD, expect out=in*2 verified"
  if VK_ICD_FILENAMES="$ICD" VK_DRIVER_FILES="$ICD" ./vkcomp 2 2>/var/tmp/vkc.err | grep -q COMPUTE_VERIFY_PASS; then
    ok "compute shader ran + verified ($(grep DEVICE: /var/tmp/vkc.err))"
  else
    bad "compute dispatch failed: $(tail -3 /var/tmp/vkc.err)"
  fi
  echo "[P2- ctrl A] dispatch with NO ICD -> expect NO_DEVICE (no silent pass)"
  if VK_ICD_FILENAMES=/dev/null VK_DRIVER_FILES=/dev/null ./vkcomp 2 2>/var/tmp/vkc.n.err | grep -q COMPUTE_VERIFY_PASS; then
    bad "NEG CONTROL BROKEN: compute 'passed' with no ICD (another device leaking)"
  else
    ok "no device without ICD ($(tail -1 /var/tmp/vkc.n.err))"
  fi
  echo "[P2- ctrl B] verify with WRONG expectation (mult=3) -> checker must FAIL"
  if VK_ICD_FILENAMES="$ICD" VK_DRIVER_FILES="$ICD" ./vkcomp 3 2>/dev/null | grep -q COMPUTE_VERIFY_FAIL; then
    ok "checker reports FAIL on wrong expected value (it can actually fail)"
  else
    bad "checker did NOT fail on a wrong expectation -> it proves nothing"
  fi
fi

echo; echo "=== SUMMARY: $pass PASS / $fail FAIL ==="
[ "$fail" -eq 0 ] && echo "LAVAPIPE SOFTWARE-VULKAN: PROVEN (enumerated + compute ran + negative controls held)" || echo "LAVAPIPE PROOF INCOMPLETE"
exit "$fail"
