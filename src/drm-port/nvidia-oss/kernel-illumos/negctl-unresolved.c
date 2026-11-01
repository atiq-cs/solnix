/*
 * Negative control for the nvidia-oss unresolved/load gates: a minimal misc
 * module that references a symbol no illumos kernel exports. The unresolved
 * check must count 1 for it, and modload must refuse it.
 */
#include <sys/modctl.h>

extern int solnix_negctl_no_such_symbol(void);

static struct modlmisc negctl_modlmisc = { &mod_miscops, "solnix nvidia-oss negctl" };
static struct modlinkage negctl_modlinkage = { MODREV_1, { &negctl_modlmisc, NULL } };

int
_init(void)
{
	(void) solnix_negctl_no_such_symbol();
	return (mod_install(&negctl_modlinkage));
}

int
_fini(void)
{
	return (mod_remove(&negctl_modlinkage));
}

int
_info(struct modinfo *mi)
{
	return (mod_info(&negctl_modlinkage, mi));
}
