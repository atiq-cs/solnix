/*
 * dgputemp -- the ThinkPad X1 Extreme's dGPU temperature as a kstat, read from
 * the embedded controller, for solnix's nvidia thermal guard.
 *
 *   kstat -p dgputemp:0:ec:gput_C     EC field GPUT (C); -1 when unreadable
 *   kstat -p dgputemp:0:ec:pr3_sta    _STA of the dGPU root port's D3 power
 *                                     resource (\_SB.PC00.PEG1.PXP): 1 = GPU
 *                                     powered, 0 = cut; -1 when unreadable
 *   kstat -p dgputemp:0:ec:tmp0_C     EC field TMP0 (C, the sensor THM0._TMP
 *                                     reads); -1 when unreadable
 *   kstat -p dgputemp:0:ec:psta       \_SB.PC00.PEG1.PSTA(): 1 = the GPU's power
 *                                     GPIO on and its reset released, 0 = not;
 *                                     -1 when unreadable. pr3_sta is a Name the
 *                                     AML sets; PSTA reads the GPIOs (SSDT14)
 *   kstat -p dgputemp:0:ec:reads      ks_update calls that evaluated the EC
 *
 * GPUT is the byte after TMP0 in the EC's ECOR region (BIOS N3JET48W,
 * dsdt.dsl: Offset 0x78 TMP0, GPUT; GSTM(1) returns it, 0x80 when it has no
 * reading). It is the sensor that went 53 -> 94 C in ten minutes with the GPU
 * idling unmanaged, before the EC cut power (scripts/patches/0005). It is the
 * EC's own reading, so it works before and without the nvidia driver. The EC
 * is the HKEY device's parent (\_SB.PC00.LPCB.EC), found by name. Nothing is
 * evaluated until the kstat is read. A misc module: modload, no driver entry.
 */
#include <sys/types.h>
#include <sys/modctl.h>
#include <sys/kstat.h>
#include <sys/sunddi.h>
#include <sys/acpi/acpi.h>
#include <sys/acpica.h>

static char *dgt_ec[] = { "\\_SB.PC00.LPCB.EC", "\\_SB.PCI0.LPCB.EC", NULL };
static char *dgt_pr[] = { "\\_SB.PC00.PEG1.PXP", "\\_SB.PCI0.PEG1.PXP", NULL };
static char *dgt_port[] = { "\\_SB.PC00.PEG1", "\\_SB.PCI0.PEG1", NULL };
static kstat_t *dgt_ks;
static kmutex_t dgt_lock;
static ACPI_HANDLE dgt_ech, dgt_prh, dgt_porth;

static ACPI_HANDLE
dgt_find(char **names)
{
	ACPI_HANDLE h;
	int i;

	for (i = 0; names[i] != NULL; i++)
		if (AcpiGetHandle(NULL, names[i], &h) == AE_OK)
			return (h);
	return (NULL);
}

static int
dgt_update(kstat_t *ksp, int rw)
{
	kstat_named_t *kn = ksp->ks_data;
	int v;

	if (rw == KSTAT_WRITE)
		return (EACCES);
	v = -1;
	if (dgt_ech == NULL || acpica_eval_int(dgt_ech, "GPUT", &v) != AE_OK ||
	    v <= 0 || v >= 0x80)
		v = -1;	/* 0x80: the EC has no reading (GPU off) */
	kn[0].value.i32 = v;
	v = -1;
	if (dgt_prh == NULL || acpica_eval_int(dgt_prh, "_STA", &v) != AE_OK)
		v = -1;
	kn[1].value.i32 = v;
	v = -1;
	if (dgt_ech == NULL || acpica_eval_int(dgt_ech, "TMP0", &v) != AE_OK ||
	    v <= 0 || v >= 0x80)
		v = -1;
	kn[2].value.i32 = v;
	kn[3].value.ui64++;
	v = -1;
	if (dgt_porth == NULL || acpica_eval_int(dgt_porth, "PSTA", &v) != AE_OK)
		v = -1;
	kn[4].value.i32 = v;
	return (0);
}

static struct modlmisc dgt_modlmisc = { &mod_miscops, "dGPU EC temperature kstat" };
static struct modlinkage dgt_modlinkage = { MODREV_1, { &dgt_modlmisc, NULL } };

int
_init(void)
{
	kstat_named_t *kn;
	int e;

	dgt_ech = dgt_find(dgt_ec);
	dgt_prh = dgt_find(dgt_pr);
	dgt_porth = dgt_find(dgt_port);
	if (dgt_ech == NULL)
		return (ENXIO);	/* not a ThinkPad EC this knows */
	mutex_init(&dgt_lock, NULL, MUTEX_DRIVER, NULL);
	dgt_ks = kstat_create("dgputemp", 0, "ec", "misc", KSTAT_TYPE_NAMED, 5, 0);
	if (dgt_ks == NULL) {
		mutex_destroy(&dgt_lock);
		return (ENOMEM);
	}
	kn = dgt_ks->ks_data;
	kstat_named_init(&kn[0], "gput_C", KSTAT_DATA_INT32);
	kstat_named_init(&kn[1], "pr3_sta", KSTAT_DATA_INT32);
	kstat_named_init(&kn[2], "tmp0_C", KSTAT_DATA_INT32);
	kstat_named_init(&kn[3], "reads", KSTAT_DATA_UINT64);
	kstat_named_init(&kn[4], "psta", KSTAT_DATA_INT32);
	dgt_ks->ks_update = dgt_update;
	dgt_ks->ks_lock = &dgt_lock;	/* one EC evaluation at a time */
	kstat_install(dgt_ks);
	if ((e = mod_install(&dgt_modlinkage)) != 0) {
		kstat_delete(dgt_ks);
		mutex_destroy(&dgt_lock);
	}
	return (e);
}

int
_fini(void)
{
	int e;

	if ((e = mod_remove(&dgt_modlinkage)) != 0)
		return (e);
	kstat_delete(dgt_ks);
	mutex_destroy(&dgt_lock);
	return (0);
}

int
_info(struct modinfo *mi)
{
	return (mod_info(&dgt_modlinkage, mi));
}
