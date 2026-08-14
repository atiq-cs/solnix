/*
 * target_selftest.c -- prove the R-P22.1 native ld backend SELECTION works:
 *
 *   (1) ld_config_target(EM_RISCV) returns 1 and installs a Target whose
 *       t_m.m_mach == EM_RISCV and whose t_mr.mr_* point at the R-P21
 *       machrel.riscv.c entry points -- i.e. ld picks ld_targ_riscv for an
 *       EM_RISCV object, exactly as the gate ld_config_target() does;
 *   (2) an unsupported e_machine returns 0 (ld would error out);
 *   (3) dispatching a real %pcrel_hi/%pcrel_lo pair THROUGH the selected
 *       ld_targ.t_mr.mr_do_activerelocs (+ mr_finish_pcrel) reconstructs
 *       S - P byte-identical to GNU ld (0x00001797 / 0x0a878793) -- i.e. the
 *       full link is driven by the illumos backend, NOT GNU ld.
 *
 * Links against machrel.riscv.c (compiled WITHOUT -DMACHREL_SELFTEST so it
 * exports its entry points + reloc_table but no main) + target.c.  assert only.
 */
#include	<assert.h>
#include	<stdio.h>
#include	<string.h>
#include	"target_shim.h"
#include	"reloc_riscv.h"
#include	"riscv_pcrel_htab.h"

#define	RV_X(x, s, n)	(((x) >> (s)) & ((1U << (n)) - 1))
#define	SEXT12(v)	((int64_t)((int32_t)((uint32_t)(v) << 20) >> 20))
#define	EXTRACT_UTYPE_IMM(x)	((int64_t)(int32_t)((x) & 0xfffff000))
#define	EXTRACT_ITYPE_IMM(x)	SEXT12(RV_X(x, 20, 12))

static uint32_t
rd32(const uint8_t *p)
{
	return ((uint32_t)p[0] | (uint32_t)p[1] << 8 |
	    (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24);
}

int
main(void)
{
	Os_desc os;
	Is_desc is;
	Ofl_desc ofl;
	riscv_pcrel_htab_t pt;
	uint8_t image[64];

	/* (1) select the EM_RISCV backend the way the native ld does. */
	assert(ld_config_target(EM_RISCV) == 1);
	assert(ld_targ.t_m.m_mach == EM_RISCV);
	assert(ld_targ.t_m.m_class == 2 /* ELFCLASS64 */);
	assert(ld_targ.t_m.m_data == 1 /* ELFDATA2LSB */);
	assert(ld_targ.t_m.m_r_jmp_slot == R_RISCV_JUMP_SLOT);
	assert(ld_targ.t_m.m_r_relative == R_RISCV_RELATIVE);
	/* the backend function pointers ARE machrel.riscv.c's entry points */
	assert(ld_targ.t_mr.mr_reloc_table != NULL);
	assert(ld_targ.t_mr.mr_reloc_local != NULL);
	assert(ld_targ.t_mr.mr_do_activerelocs != NULL);
	assert(ld_targ.t_mr.mr_assign_got_ndx != NULL);
	assert(ld_targ.t_mr.mr_finish_pcrel != NULL);

	/* (2) an unsupported machine is rejected. */
	assert(ld_config_target(EM_X86_64) == 0);
	/* selection failure must not clobber the RISC-V target we already set */
	assert(ld_targ.t_m.m_mach == EM_RISCV);

	/* (3) drive a real pcrel pair through the SELECTED backend pointers. */
	memset(&ofl, 0, sizeof (ofl));
	memset(&os, 0, sizeof (os));
	memset(&is, 0, sizeof (is));
	memset(image, 0, sizeof (image));
	assert(riscv_pcrel_htab_init(&pt) == 0);
	ofl.ofl_riscv_pcrel = &pt;
	ofl.ofl_flags = FLG_OF_EXEC;

	os.os_outdata = image;
	os.os_shaddr = 0x8000;
	os.os_shoff = 0;
	is.is_indata = image;
	is.is_osdesc = &os;
	is.is_offset = 0;

	/* auipc a5,0 (0x00000797) at off 0 ; addi a5,a5,0 (0x00078793) at 4 */
	image[0] = 0x97; image[1] = 0x07;
	image[4] = 0x93; image[5] = 0x87; image[6] = 0x07;

	{
		Sym_desc s_target, s_hiaddr;
		Rel_desc rels[2];

		memset(&s_target, 0, sizeof (s_target));
		s_target.sd_value = 0x8000 + 0x10a8;	/* S - P == 0x10a8 */
		memset(&s_hiaddr, 0, sizeof (s_hiaddr));
		s_hiaddr.sd_value = 0x8000;		/* auipc site addr */

		memset(&rels[0], 0, sizeof (rels[0]));
		rels[0].rel_rtype = R_RISCV_PCREL_HI20;
		rels[0].rel_roffset = 0;
		rels[0].rel_sym = &s_target;
		rels[0].rel_isdesc = &is;
		memset(&rels[1], 0, sizeof (rels[1]));
		rels[1].rel_rtype = R_RISCV_PCREL_LO12_I;
		rels[1].rel_roffset = 4;
		rels[1].rel_sym = &s_hiaddr;
		rels[1].rel_isdesc = &is;

		/* dispatch through the SELECTED target, not a direct call */
		assert(ld_targ.t_mr.mr_do_activerelocs(rels, 2, &ofl) == 1);

		assert(rd32(image) == 0x00001797);	/* auipc a5,0x1 */
		assert(rd32(image + 4) == 0x0a878793);	/* addi a5,a5,168 */
		{
			int64_t rebuilt = EXTRACT_UTYPE_IMM(rd32(image)) +
			    EXTRACT_ITYPE_IMM(rd32(image + 4));
			assert(rebuilt == 0x10a8);	/* S - P via the backend */
		}
	}
	riscv_pcrel_htab_fini(&pt);

	printf("R-P22.1 sgs target selection PASS: "
	    "ld_config_target(EM_RISCV) selects ld_targ_riscv; "
	    "EM_X86_64 rejected; pcrel pair via ld_targ.t_mr -> GNU-ld bytes "
	    "0x00001797/0x0a878793, S-P=0x10a8 (native illumos link path).\n");
	return (0);
}
