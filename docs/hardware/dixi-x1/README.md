# dixi (ThinkPad X1 / P-series) hardware inventory

Measured 2026-10-04 over SSH from the live installer + the installed system, root@192.168.1.124.
Raw dumps are in this directory (prtconf-dv.txt, cfgadm-lav.txt, usb-vidpid-raw.txt, etc.).
This is the reference for driver work (wifi, fingerprint, GPU) on the real target.

## Platform
- Lenovo ThinkPad (subsystem-vendor 17aa, subsystem 2267 throughout).
- CPU: Intel Core i7-8850H @ 2.60GHz (Coffee Lake, 6c/12t).
- RAM: 64 GiB (prtconf: 64957 MB).
- Chipset: Intel Cannon Lake-H / CM246 PCH (pci8086,a340 root complex).
- NVMe root disk: c1t001B448B485502D1d0, 931.51 GB (blkdev; exposes p0, not s0, until labeled;
  iostat -En all-zeros = healthy; every prior pool fault was install-caused).

## PCI devices (vendor:device)
| Device | ID | illumos driver | Notes |
|--------|-----|----------------|-------|
| Host/PCIe bridges | 8086,1901 / a340 / a32c | pcieb | fine |
| Thunderbolt (JHL6540) | 8086,15ea x5 | pcieb | TB3 ports |
| **Wi-Fi (AX201 CNVi)** | **8086,a370** | **NONE (driver not attached)** | at _SB_.PCI0.CNVW. CNVi = MAC in PCH, RF companion (CRF) on M.2. NOT the discrete AX200 PCIe form (2723/2725/02f0) the iwx port assumed. |
| Intel UHD Graphics 630 (iGPU) | 8086,3e9b | (vgatext only) | no i915 on illumos; llvmpipe ceiling |
| **NVIDIA GP107M (GTX 1050 Ti Mobile)** | **10de,1c8c** | **NONE** | discrete GPU (Optimus). + HD-audio fn 10de,fb9. The real GPU-parity target on this box. |
| SATA/AHCI, SMBus, etc. | 8086,a3xx | stock | fine |

## USB devices (VID:PID) -- the internal hub is pci17aa,2267@14
| Port | Device | VID:PID | Driver target |
|------|--------|---------|---------------|
| usb1/8  | Chicony Integrated Camera | 04f2:b614 | UVC (usbvc) |
| **usb1/9** | **Synaptics fingerprint reader** | **06cb:009a** | **NONE** -- Synaptics Prometheus/Metallica (match-on-chip). The fingerprint-driver target. libfprint's `synaptics` driver speaks to 06cb:009a. |
| usb1/10 | Wacom Pen + multitouch | 056a:5193 | usbhid / hid |
| usb1/12 | SunplusIT Integrated IR Camera | 04f2:b615 | UVC (IR, Windows-Hello cam) |
| usb1/14 | Intel device | 8087:0aaa | Bluetooth (CNVi BT companion to the a370 Wi-Fi) |
| internal | ELAN/unparseable HID keyboard | -- | hid.c:2156 flood; quieted by set hid:hid_errlevel=0 in /etc/system |

## Driver-work implications (ACTIONABLE)
1. **Wi-Fi is CNVi (a370), not discrete AX200.** The iwx port (src/wifi-port) + its firmware staging
   target the discrete PCIe ids (2723/2725/02f0). CNVi binds under the PCH id a370 at _SB_.PCI0.CNVW,
   with the MAC in the PCH and only the RF/CRF on M.2 -- OpenBSD's iwx DOES support CNVi but via a
   different attach/PNVM path. The driver's device match + firmware selection + attach must handle
   a370 CNVi, not just the discrete ids. The installer's have_intel_ax2xx() now detects a370 (fixed).
   The 8087:0aaa on usb1/14 is the paired CNVi Bluetooth.
2. **Fingerprint reader = Synaptics 06cb:009a** (USB, match-on-chip). A driver would mirror libfprint's
   synaptics backend; it is a USB device (usb1/9), so a userland libusb-style driver is feasible
   without kernel work. Serial 9dc1a40f947c.
3. **Two GPUs**: Intel UHD 630 (iGPU, vgatext/llvmpipe only on illumos) + NVIDIA GTX 1050 Ti (10de,1c8c,
   discrete, no driver). The GPU-parity effort has a real discrete NVIDIA to target here, not just the iGPU.
4. **Internal keyboard HID descriptor is unparseable** (hid.c:2156 flood) -- already mitigated by
   hid_errlevel=0; a proper fix is a HID descriptor quirk/shim for this ELAN device.

## Network (working path)
- e1000g0 = ASIX AX88772 USB-Ethernet dongle, 1000/full, up, DHCP 192.168.1.124/24. This is the
  working network until the a370 CNVi wifi driver lands.
