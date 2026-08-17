#!/usr/bin/env bash
# gpu-bringup.sh — the one-command launch-to-runtime flow for the moment the
# GPU quota grants. The ACCELERATED SOFTWARE STACK IS COMPILE-COMPLETE
# (src/drm-port ~9k LOC: DRM/KMS + Mesa + Vulkan + amdgpu, zero phantom
# symbols). This wires it to real hardware: launch a g4ad (AMD Radeon Pro V520,
# the fully-open amdgpu/ROCm path, boots normally as a Nitro VM — no metal/kvm),
# then run the 9-step amdgpu bring-up + the accelerated-compute parity proof.
#
# NORTH STAR: GPU/TPU/accelerator support AS FAST AS LINUX on similar hardware.
# CPU LLM inference was only a beachhead. Vulkan-compute is the lead vector
# (one llama.cpp GGML_VULKAN reaches every vendor once a DRM render node runs).
#
# ⚠️ HARD SECURITY RULE enforced by sg-guard: NEVER open any SG to 0.0.0.0/0.
# Usage: AWS_PROFILE=fred ./scripts/gpu-bringup.sh <region> [instance-type]
#   default region us-east-2, default type g4ad.xlarge (4 vCPU, 1x V520).
set -euo pipefail
REGION="${1:-us-east-2}"
ITYPE="${2:-g4ad.xlarge}"

case "$REGION" in
  us-east-2) SG=sg-074eddb1fd24663e6; SUBNET=subnet-0bf6b544c7ade866a; AMI=ami-01f92696a3c816147 ;;
  us-west-2) SG=sg-0398776749512a2bc; SUBNET=; AMI=ami-07ea683bff41089b3 ;;
  us-east-1) SG=sg-06c5b7160839f8484; SUBNET=subnet-025542d1257767bd3; AMI= ;;
  *) echo "unknown region $REGION"; exit 2 ;;
esac

echo "=== 0. preflight: quota + SG safety ==="
Q=$(aws service-quotas get-service-quota --region "$REGION" --service-code ec2 \
      --quota-code L-DB2E81BA --query 'Quota.Value' --output text 2>/dev/null)
echo "  G-instance vCPU quota in $REGION: $Q"
awk "BEGIN{exit !($Q+0 >= 4)}" || { echo "  quota < 4 vCPU — GPU launch will fail. Wait for the increase."; exit 3; }
bash "$(dirname "$0")/sg-guard.sh" preflight "$REGION"   # refuses if any 0.0.0.0/0 rule exists
bash "$(dirname "$0")/harness-sg-heal.sh"                # authorize the current egress /24 (never world-open)

echo "=== 1. launch the g4ad (fully-open AMD V520; boots normally as a Nitro VM) ==="
ID=$(aws ec2 run-instances --region "$REGION" --image-id "$AMI" --instance-type "$ITYPE" \
  --key-name fred-key --security-group-ids "$SG" ${SUBNET:+--subnet-id "$SUBNET"} \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=120,VolumeType=gp3,DeleteOnTermination=true}' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=solnix-gpu-bringup}]' \
  --query 'Instances[0].InstanceId' --output text)
echo "  launched $ID — waiting for running + SSH…"
aws ec2 wait instance-running --region "$REGION" --instance-ids "$ID"
IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$ID" \
      --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "  $ID @ $IP"

echo "=== 2. THE 9-STEP amdgpu BRING-UP (see docs/design-gpu-amdgpu.md) ==="
cat <<'STEPS'
  On the node (guest/hardware-only — never modload into a live host kernel):
   1. lspci: confirm the V520 (1002:7362) is PCI-passed to the guest.
   2. amdgpu attach: PCI/BAR map + MSI-X (C3-amdgpu-a) — /dev/dri/renderD128 appears.
   3. firmware load: PSP fw-auth of the GFX/SDMA/GMC/PSP microcode (firmware(9F)).
   4. GMC/GART: VRAM (BAR0) + GTT (ddi_dma) page tables online (C3-amdgpu-b/c).
   5. rings: GFX + SDMA ring rptr/wptr + BAR2 doorbell map; IH ring WPTR/RPTR live (C3-amdgpu-c/d).
   6. hw_init: per-IP-block .hw_init (common/GMC/GFX/SDMA/IH) reaches ring-test PASS.
   7. Mesa: radeonsi Gallium on the render node — glxinfo/OSMesa renders on-GPU (C2/C3a).
   8. Vulkan: RADV — libvulkan_radeon.so (COMPILED, zero-phantom, src/drm-port/radv/) + its ICD;
      vulkaninfo enumerates the V520 queue. The full AMD Vulkan stack (DRM->amdgpu->libdrm_amdgpu->
      RADV+ACO->ICD->loader) already compiles on illumos; this is the runtime activation on the V520.
   9. accelerated proof: llama.cpp GGML_VULKAN inference ON THE GPU — measure tok/s
      vs the 70 tok/s CPU baseline vs Linux on the same g4ad. THE PARITY NUMBER.
  10. ROCm/HIP compute (the deepest path): /dev/kfd + the KFD compute ioctls (COMPILED, zero-phantom,
      src/drm-port/amdkfd/) -> libhsakmt (HSA thunk) -> ROCr -> HIP -> rocBLAS/the ML runtime. The
      C3-amdgpu-d live MQD/HWS-runlist + doorbell BAR2 mmap-fault activate the compute queues on the V520.
STEPS
echo "  Node IP recorded. Run the bring-up steps (each is a bounded port already compiling)."
echo "  ⚠️ TERMINATE when done: aws ec2 terminate-instances --region $REGION --instance-ids $ID"
echo "$REGION $ID $IP" > .infra/gpu-bringup-node.txt 2>/dev/null || true
