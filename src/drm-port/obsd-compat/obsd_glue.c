/*
 * obsd_glue.c -- the rest of the OpenBSD kernel API that drm and inteldrm
 * link against, on illumos: autoconf (config_found_sm runs drm_attach as
 * OpenBSD's autoconf would), kthreads, kernel FPU, extent, SMBIOS strings,
 * and the rows that are deliberately NOT implemented for rung R1a.
 *
 * Every function below is tagged:
 *   REAL    does what the OpenBSD function does, on an illumos primitive
 *   STUB    returns an error (ENOTSUP/ENXIO/NULL) or does nothing; never a
 *           fake success where the caller would go on to use a result
 * The STUB rows are the R2 (bus_dma, dma-buf/sync_file fds, user mmap),
 * console (wsdisplay/rasops/vga) and ACPI (AML) rows of
 * docs/x1-gpu-route.md 5.4; i915_illumos.c replaces the console attach that
 * would reach them.
 */
#include <sys/types.h>
#include <sys/smbios.h>
#include <obsd_prelude.h>
#include <dev/wscons/wsdisplayvar.h>
#include <dev/rasops/rasops.h>
#include <dev/acpi/acpivar.h>
#include <dev/acpi/dsdt.h>
#include <dev/isa/isareg.h>

/* ------------------------------------------------------------- autoconf */
/*
 * config_found_sm (REAL, for the one child inteldrm creates): OpenBSD's
 * drm_attach_pci calls config_found_sm(self, &drm_attach_args, ...), and
 * autoconf allocates a struct drm_softc (drm_ca.ca_devsize), registers it
 * in drm_cd.cd_devs[unit] and calls drm_attach(parent, child, aux). drmopen
 * and friends find the device through drm_cd.cd_devs[minor & 0xff], so the
 * registration is load-bearing. The submatch callback is drm's own probe.
 */
extern const struct cfattach drm_ca;
extern struct cfdriver drm_cd;
#define OBSD_DRM_MAXUNIT	4
static void *obsd_drm_devs[OBSD_DRM_MAXUNIT];
static long obsd_drm_loc[1] = { -1 };	/* drmdevcf_primary: unknown */
static struct cfdata obsd_drm_cf = { NULL, NULL, 0, obsd_drm_loc };

struct device *
config_found_sm(struct device *parent, void *aux, cfprint_t print,
    cfmatch_t submatch)
{
	struct device *dv;
	int unit;

	(void) print;
	obsd_drm_cf.cf_attach = (struct cfattach *)&drm_ca;
	obsd_drm_cf.cf_driver = &drm_cd;
	if (submatch != NULL && submatch(parent, &obsd_drm_cf, aux) == 0)
		return (NULL);
	if (drm_cd.cd_devs == NULL) {
		drm_cd.cd_devs = obsd_drm_devs;
		drm_cd.cd_ndevs = OBSD_DRM_MAXUNIT;
	}
	for (unit = 0; unit < OBSD_DRM_MAXUNIT; unit++)
		if (drm_cd.cd_devs[unit] == NULL)
			break;
	if (unit == OBSD_DRM_MAXUNIT)
		return (NULL);
	dv = kmem_zalloc(drm_ca.ca_devsize, KM_SLEEP);
	dv->dv_unit = unit;
	dv->dv_parent = parent;
	dv->dv_cfdata = &obsd_drm_cf;
	(void) snprintf(dv->dv_xname, sizeof (dv->dv_xname), "drm%d", unit);
	drm_cd.cd_devs[unit] = dv;
	drm_ca.ca_attach(parent, dv, aux);
	return (dv);
}

/* Undo config_found_sm for a child (i915_illumos.c detach). REAL. */
void
obsd_config_free(struct device *dv)
{
	if (dv == NULL)
		return;
	if (drm_ca.ca_detach != NULL)
		(void) drm_ca.ca_detach(dv, DETACH_FORCE);
	drm_cd.cd_devs[dv->dv_unit] = NULL;
	kmem_free(dv, drm_ca.ca_devsize);
}

/* config_mountroot: OpenBSD defers inteldrm's second attach stage until
 * root is mounted (firmware is on the root fs). A DDI attach runs with
 * root mounted, so the hook runs now. REAL. */
void
config_mountroot(struct device *dv, void (*fn)(struct device *))
{
	fn(dv);
}

/* STUB: suspend/resume reaches the driver as DDI_SUSPEND/DDI_RESUME. */
int
config_suspend(struct device *dv, int act)
{
	(void) dv; (void) act;
	return (ENOTSUP);
}

/* cdevsw[major].d_mmap == drmmmap is drm_gem.c's "is this a drm node"
 * test; one entry per major the module is bound to would be the full map.
 * STUB: an empty table makes the test fail (that path is user mmap, R2). */
struct obsd_cdevsw obsd_cdevsw[1];

/* ------------------------------------------------------------- kthreads */
/*
 * kthread_create (REAL): an illumos kernel thread in p0 running fn(arg).
 * *pp is the thread's OpenBSD proc shadow, which drm's kthread_run uses as
 * a wait channel and to look the thread up again.
 */
struct obsd_kthr {
	void		(*fn)(void *);
	void		*arg;
	struct proc	**pp;
	kmutex_t	lock;
	kcondvar_t	cv;
	int		ready;
};

static void
obsd_kthread_main(void *a)
{
	struct obsd_kthr *k = a;
	void (*fn)(void *) = k->fn;
	void *arg = k->arg;

	mutex_enter(&k->lock);
	*k->pp = curproc;		/* creates this thread's shadow */
	k->ready = 1;
	cv_signal(&k->cv);
	mutex_exit(&k->lock);
	fn(arg);
	thread_exit();
}

int
kthread_create(void (*fn)(void *), void *arg, struct proc **pp,
    const char *name)
{
	struct obsd_kthr *k = kmem_zalloc(sizeof (*k), KM_SLEEP);
	struct proc *dummy;

	(void) name;
	k->fn = fn;
	k->arg = arg;
	k->pp = pp != NULL ? pp : &dummy;
	mutex_init(&k->lock, NULL, MUTEX_DRIVER, NULL);
	cv_init(&k->cv, NULL, CV_DRIVER, NULL);
	(void) thread_create(NULL, 0, obsd_kthread_main, k, 0, &p0, TS_RUN,
	    minclsyspri);
	mutex_enter(&k->lock);
	while (!k->ready)
		cv_wait(&k->cv, &k->lock);
	mutex_exit(&k->lock);
	cv_destroy(&k->cv);
	mutex_destroy(&k->lock);
	kmem_free(k, sizeof (*k));
	return (0);
}

void
kthread_exit(int status)
{
	(void) status;
	thread_exit();
}

/* ------------------------------------------------------------ kernel FPU */
/* The installed proto has no sys/kfpu.h; prototypes and flag values from
 * illumos-gate uts/common/sys/kfpu.h (kernel_fpu_begin/end are exported by
 * the running unix, measured). */
typedef struct kfpu_state kfpu_state_t;
extern void kernel_fpu_begin(kfpu_state_t *, uint_t);
extern void kernel_fpu_end(kfpu_state_t *, uint_t);
#define KFPU_NO_STATE	0x01
/* REAL: i915_memcpy's SSE4.1 movntdqa path. KFPU_NO_STATE requires
 * preemption off for the duration (illumos fpu.c), as OpenBSD's
 * fpu_kernel_enter does with its own critical section. */
void
fpu_kernel_enter(void)
{
	kpreempt_disable();
	kernel_fpu_begin(NULL, KFPU_NO_STATE);
}

void
fpu_kernel_exit(void)
{
	kernel_fpu_end(NULL, KFPU_NO_STATE);
	kpreempt_enable();
}

/* ------------------------------------------------------------- extent(9) */
/*
 * STUB: i915's only extent use is intel_gmch.c allocating a free MMIO
 * window for MCHBAR when the BIOS left it disabled, from pa_memex, which
 * i915_illumos.c leaves NULL. With memex NULL, intel_gmch.c returns -ENOMEM
 * before calling extent_alloc, as on an OpenBSD machine whose MCHBAR is
 * already enabled. These are never reached; they fail if they are.
 */
int
extent_alloc_subregion(struct extent *ex, u_long a, u_long b, u_long c,
    u_long d, u_long e, u_long f, int g, u_long *r)
{
	(void) ex; (void) a; (void) b; (void) c; (void) d; (void) e;
	(void) f; (void) g; (void) r;
	return (ENOTSUP);
}

int
extent_alloc(struct extent *ex, u_long a, u_long b, u_long c, u_long d,
    int e, u_long *r)
{
	(void) ex; (void) a; (void) b; (void) c; (void) d; (void) e; (void) r;
	return (ENOTSUP);
}

int
extent_free(struct extent *ex, u_long a, u_long b, int c)
{
	(void) ex; (void) a; (void) b; (void) c;
	return (ENOTSUP);
}

/* -------------------------------------------------- sysctl hw.* strings */
/* REAL: drm_linux.c's DMI quirk matching (dmi_check_system) compares these
 * with the panel/board quirk tables. Filled from SMBIOS type 1 at init. */
char *hw_vendor, *hw_prod, *hw_ver;
int cpuspeed;			/* MHz, intel_llc.c ring frequency table */
static char obsd_hw_buf[3][64];

void
obsd_glue_init(void)
{
	smbios_system_t sys;
	smbios_info_t si;
	id_t id;

	if (ksmbios != NULL &&
	    (id = smbios_info_system(ksmbios, &sys)) != SMB_ERR &&
	    smbios_info_common(ksmbios, id, &si) != SMB_ERR) {
		(void) strlcpy(obsd_hw_buf[0], si.smbi_manufacturer, 64);
		(void) strlcpy(obsd_hw_buf[1], si.smbi_product, 64);
		(void) strlcpy(obsd_hw_buf[2], si.smbi_version, 64);
		hw_vendor = obsd_hw_buf[0];
		hw_prod = obsd_hw_buf[1];
		hw_ver = obsd_hw_buf[2];
	}
	cpuspeed = CPU->cpu_type_info.pi_clock;
}

/* MTRRs: illumos maps write-combining per mapping (PAT, HAT_MERGING_OK in
 * bus_space_map), so there is no range to set. REAL no-op, as on a PAT
 * OpenBSD kernel the call is redundant. */
int
mem_range_attr_set(struct mem_range_desc *mr, int *arg)
{
	(void) mr; (void) arg;
	return (0);
}

/* The legacy VGA BIOS window (0xc0000, 64 KB) for intel_rom.c's VBT scan.
 * REAL: mapped uncached through psm_map_phys_new; mapped once. */
extern caddr_t psm_map_phys_new(paddr_t, size_t, int);
void *
obsd_isa_hole_vaddr(paddr_t pa)
{
	static caddr_t hole;

	if (pa < 0xa0000 || pa >= 0x100000)
		return (NULL);
	if (hole == NULL)
		hole = psm_map_phys_new(0xa0000, 0x60000, PROT_READ);
	return (hole == NULL ? NULL : hole + (pa - 0xa0000));
}

/* ------------------------------------------------- kqueue / select */
/* selwakeup (REAL): the i915 cdev's chpoll(9E) hands poll the selinfo's
 * pollhead (i915_drmglue.c), so a drm event wakes poll(2)/port waiters.
 * kqueue filters stay STUB: illumos has no kqueue. */
void selwakeup(struct selinfo *si) { pollwakeup(&si->si_ph, POLLIN | POLLRDNORM); }
void knote_locked(struct klist *kl, long hint) { (void) kl; (void) hint; }
void klist_insert_locked(struct klist *kl, struct knote *kn)
{ (void) kl; (void) kn; }
void klist_remove_locked(struct klist *kl, struct knote *kn)
{ (void) kl; (void) kn; }

/* ------------------------------------------------ file descriptors */
/* dma-buf / sync_file fds: REAL, obsd_file.c (falloc + spec vnode). */

/* --------------------------------------------------------- bus_dma: STUB */
/* GEM DMA objects (drm_dmamem_alloc, dma_alloc_coherent, ttm_pool): R2,
 * over ddi_dma_alloc_handle/ddi_dma_mem_alloc. Every create/alloc fails. */
int bus_dmamap_create(bus_dma_tag_t t, bus_size_t a, int b, bus_size_t c,
    bus_size_t d, int e, bus_dmamap_t *m)
{ (void) t; (void) a; (void) b; (void) c; (void) d; (void) e; *m = NULL;
  return (ENOTSUP); }
void bus_dmamap_destroy(bus_dma_tag_t t, bus_dmamap_t m) { (void) t; (void) m; }
int bus_dmamap_load(bus_dma_tag_t t, bus_dmamap_t m, void *b, bus_size_t s,
    struct proc *p, int f)
{ (void) t; (void) m; (void) b; (void) s; (void) p; (void) f;
  return (ENOTSUP); }
int bus_dmamap_load_raw(bus_dma_tag_t t, bus_dmamap_t m,
    bus_dma_segment_t *sg, int n, bus_size_t s, int f)
{ (void) t; (void) m; (void) sg; (void) n; (void) s; (void) f;
  return (ENOTSUP); }
void bus_dmamap_unload(bus_dma_tag_t t, bus_dmamap_t m) { (void) t; (void) m; }
int bus_dmamem_alloc(bus_dma_tag_t t, bus_size_t s, bus_size_t a,
    bus_size_t b, bus_dma_segment_t *sg, int n, int *r, int f)
{ (void) t; (void) s; (void) a; (void) b; (void) sg; (void) n; (void) r;
  (void) f; return (ENOTSUP); }
void bus_dmamem_free(bus_dma_tag_t t, bus_dma_segment_t *sg, int n)
{ (void) t; (void) sg; (void) n; }
int bus_dmamem_map(bus_dma_tag_t t, bus_dma_segment_t *sg, int n, size_t s,
    caddr_t *k, int f)
{ (void) t; (void) sg; (void) n; (void) s; (void) k; (void) f;
  return (ENOTSUP); }
void bus_dmamem_unmap(bus_dma_tag_t t, caddr_t k, size_t s)
{ (void) t; (void) k; (void) s; }
paddr_t bus_dmamem_mmap(bus_dma_tag_t t, bus_dma_segment_t *sg, int n,
    off_t o, int p, int f)
{ (void) t; (void) sg; (void) n; (void) o; (void) p; (void) f;
  return ((paddr_t)-1); }

/* -------------------------------------------------- i2c bit-bang: STUB */
/* GMBUS hardware i2c is the path for DDC on CFL; the GPIO bit-bang
 * fallback (intel_gmbus.c force_bit) and the generic iic_exec front end
 * fail. The eDP panel's EDID comes over DP-AUX, not i2c. */
int iic_exec(i2c_tag_t t, i2c_op_t op, i2c_addr_t a, const void *c, size_t cl,
    void *b, size_t l, int f)
{ (void) t; (void) op; (void) a; (void) c; (void) cl; (void) b; (void) l;
  (void) f; return (ENOTSUP); }
int i2c_bitbang_send_start(void *v, int f, i2c_bitbang_ops_t o)
{ (void) v; (void) f; (void) o; return (ENOTSUP); }
int i2c_bitbang_send_stop(void *v, int f, i2c_bitbang_ops_t o)
{ (void) v; (void) f; (void) o; return (ENOTSUP); }
int i2c_bitbang_initiate_xfer(void *v, i2c_addr_t a, int f,
    i2c_bitbang_ops_t o)
{ (void) v; (void) a; (void) f; (void) o; return (ENOTSUP); }
int i2c_bitbang_read_byte(void *v, uint8_t *b, int f, i2c_bitbang_ops_t o)
{ (void) v; (void) b; (void) f; (void) o; return (ENOTSUP); }
int i2c_bitbang_write_byte(void *v, uint8_t b, int f, i2c_bitbang_ops_t o)
{ (void) v; (void) b; (void) f; (void) o; return (ENOTSUP); }

/* ---------------------------------------------------------- ACPI: STUB */
/* acpi_softc NULL: drm_linux_init and inteldrm_activate skip ACPI, and
 * the OpRegion VBT comes from the ASLS mailbox (bus_space_map), not AML. */
struct acpi_softc *acpi_softc;
struct aml_node *acpi_find_pci(pci_chipset_tag_t pc, pcitag_t tag)
{ (void) pc; (void) tag; return (NULL); }
struct aml_node *aml_searchname(struct aml_node *n, const void *s)
{ (void) n; (void) s; return (NULL); }
const char *aml_nodename(struct aml_node *n) { (void) n; return (""); }
int aml_evalnode(struct acpi_softc *sc, struct aml_node *n, int c,
    struct aml_value *a, struct aml_value *r)
{ (void) sc; (void) n; (void) c; (void) a; (void) r; return (ENOTSUP); }
void aml_freevalue(struct aml_value *v) { (void) v; }
void aml_register_notify(struct aml_node *n, const char *s,
    int (*f)(struct aml_node *, int, void *), void *a, int p)
{ (void) n; (void) s; (void) f; (void) a; (void) p; }

/* ---------------------------------------- console (wsdisplay): STUB */
/*
 * inteldrm's OpenBSD attach hands the screen to wsdisplay/rasops. On
 * illumos the console stays gfxp_bitmap/vgatext (see the load plan), and
 * i915_illumos.c does not call that attach. The backlight path still
 * calls ws_get_param/ws_set_param through these pointers: NULL means "no
 * wsdisplay", which inteldrm checks (i915_driver.c: if (ws_get_param &&
 * ...)) except in inteldrm_backlight_*, reached only when a firmware
 * backlight is registered, which it is not with ws_get_param NULL.
 */
int (*ws_get_param)(struct wsdisplay_param *);
int (*ws_set_param)(struct wsdisplay_param *);
int vga_console_attached;
int vga_is_console(bus_space_tag_t t, int type)
{ (void) t; (void) type; return (0); }
void wsdisplay_cnattach(const struct wsscreen_descr *d, void *c, int x,
    int y, uint32_t a)
{ (void) d; (void) c; (void) x; (void) y; (void) a; }
int wsemuldisplaydevprint(void *a, const char *p)
{ (void) a; (void) p; return (UNCONF); }
int wsemuldisplaydevsubmatch(struct device *p, void *m, void *a)
{ (void) p; (void) m; (void) a; return (0); }
/*
 * rasops_init (STUB with metrics): inteldrm_attachhook ignores the return
 * value and reads ri->ri_font->fontwidth/fontheight right after the call,
 * so a NULL ri_font is a NULL dereference on the first successful
 * i915_driver_probe. The font below has metrics and no glyphs: its only
 * readers are that copy into inteldrm_stdscreen and the wsdisplay
 * accessops, and wsdisplay never attaches here (wsemuldisplaydevsubmatch
 * returns 0). ri_ops stays zeroed; its one caller (pack_attr) runs only
 * when dev_priv->console is set, which needs vga_is_console or efifb,
 * both 0 on illumos. The illumos console is gfxp_fb, never rasops.
 */
static struct wsdisplay_font obsd_rasops_font = {
	.name = "obsd-metrics-8x16",
	.fontwidth = 8,
	.fontheight = 16,
	.stride = 1,
};
int rasops_init(struct rasops_info *ri, int r, int c)
{
	(void) r; (void) c;
	ri->ri_font = &obsd_rasops_font;
	ri->ri_cols = ri->ri_width / obsd_rasops_font.fontwidth;
	ri->ri_rows = ri->ri_height / obsd_rasops_font.fontheight;
	ri->ri_caps = 0;
	return (ENOTSUP);
}
int rasops_alloc_screen(void *v, void **c, int *x, int *y, uint32_t *a)
{ (void) v; (void) c; (void) x; (void) y; (void) a; return (ENOTSUP); }
void rasops_free_screen(void *v, void *c) { (void) v; (void) c; }
int rasops_show_screen(void *v, void *c, int w, void (*cb)(void *, int, int),
    void *a)
{ (void) v; (void) c; (void) w; (void) cb; (void) a; return (ENOTSUP); }
int rasops_load_font(void *v, void *c, struct wsdisplay_font *f)
{ (void) v; (void) c; (void) f; return (ENOTSUP); }
int rasops_list_font(void *v, struct wsdisplay_font *f)
{ (void) v; (void) f; return (ENOTSUP); }
int rasops_getchar(void *v, int r, int c, struct wsdisplay_charcell *cc)
{ (void) v; (void) r; (void) c; (void) cc; return (ENOTSUP); }
void rasops_scrollback(void *v, void *c, int l) { (void) v; (void) c; (void) l; }
