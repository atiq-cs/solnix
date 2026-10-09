/* OpenBSD config(8) count header. NPCI is 1: the drm core is built with
 * CONFIG_PCI (drm_internal.h otherwise turns drm_pci_set_busid into a static
 * inline that collides with drm_pci.c), as on every OpenBSD amd64 kernel. */
#define NPCI 1
