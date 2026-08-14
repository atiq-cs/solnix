/*
 * CDDL HEADER START
 *
 * The contents of this file are subject to the terms of the
 * Common Development and Distribution License (the "License").
 * You may not use this file except in compliance with the License.
 *
 * You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
 * or http://www.opensolaris.org/os/licensing.
 * See the License for the specific language governing permissions
 * and limitations under the License.
 *
 * When distributing Covered Code, include this CDDL HEADER in each
 * file and include the License file at usr/src/OPENSOLARIS.LICENSE.
 * If applicable, add the following below this CDDL HEADER, with the
 * fields enclosed by brackets "[]" replaced with your own identifying
 * information: Portions Copyright [yyyy] [name of copyright owner]
 *
 * CDDL HEADER END
 */

/*
 * RISC-V %pcrel_hi hash table for the sgs libld EM_RISCV backend.
 *
 * This is the R-P21 upgrade of the R-P20 O(n) list scan: the %pcrel_hi records
 * are now keyed in a chained (open) hash table by the auipc-site address, so a
 * matching %pcrel_lo resolves in O(1) even in a section with thousands of
 * pcrel pairs (glibc/large TUs routinely have many).  binutils uses libiberty
 * htab_t for exactly this (bfd/elfnn-riscv.c riscv_pcrel_relocs.hi_relocs);
 * the illumos gate would use an sgs avl tree or open hash.  Here it is a
 * self-contained power-of-two chained hash so the backend has no external
 * dependency for the standalone build.
 *
 * CRIB PROVENANCE:
 *   - the "record HI, defer LO, resolve LO by HI-address lookup" model +
 *     the diagnostics: binutils-2.44 bfd/elfnn-riscv.c
 *     riscv_record_pcrel_hi_reloc / riscv_record_pcrel_lo_reloc /
 *     riscv_resolve_pcrel_lo_relocs (~2086-2170).
 *   - the hash-table shape (power-of-two buckets, key hashing, chained
 *     collision) is the standard libiberty htab / sgs open-hash idiom.
 */

#ifndef	_RISCV_PCREL_HTAB_H
#define	_RISCV_PCREL_HTAB_H

#include	<stdint.h>
#include	<stdlib.h>
#include	<string.h>

/* One recorded %pcrel_hi (binutils riscv_pcrel_hi_reloc). */
typedef struct riscv_pcrel_hi {
	int64_t			ph_addr;	/* auipc site address (key) */
	int64_t			ph_value;	/* S + A - addr (shared value) */
	uint32_t		ph_type;	/* HI reloc type */
	int			ph_absolute;	/* rewritten non-pcrel */
	struct riscv_pcrel_hi	*ph_chain;	/* hash bucket chain */
} riscv_pcrel_hi_t;

/* One deferred %pcrel_lo (binutils riscv_pcrel_lo_reloc). */
typedef struct riscv_pcrel_lo {
	int64_t			pl_addr;	/* matching auipc address */
	uint32_t		pl_type;	/* LO12_I / LO12_S */
	int64_t			pl_addend;	/* LO reloc addend */
	uint8_t			*pl_dest;	/* LO instruction site */
	struct riscv_pcrel_lo	*pl_next;	/* deferred-LO list */
} riscv_pcrel_lo_t;

/*
 * The per-input-section (or per-file) pairing table.  hi_relocs is a chained
 * hash keyed by ph_addr; lo_relocs is a plain worklist resolved at the end.
 */
typedef struct {
	riscv_pcrel_hi_t	**pt_buckets;	/* hash array */
	uint32_t		pt_nbuckets;	/* power of two */
	uint32_t		pt_nhi;		/* live HI count */
	riscv_pcrel_lo_t	*pt_lo;		/* deferred LOs */
} riscv_pcrel_htab_t;

#define	RISCV_PCREL_INIT_BUCKETS	64

/* Mix the auipc address into a bucket index (Knuth multiplicative hash). */
static inline uint32_t
riscv_pcrel_hash(int64_t addr, uint32_t nbuckets)
{
	uint64_t h = (uint64_t)addr * 0x9E3779B97F4A7C15ULL;
	return ((uint32_t)(h >> 40) & (nbuckets - 1));
}

static inline int
riscv_pcrel_htab_init(riscv_pcrel_htab_t *t)
{
	t->pt_nbuckets = RISCV_PCREL_INIT_BUCKETS;
	t->pt_buckets = calloc(t->pt_nbuckets, sizeof (riscv_pcrel_hi_t *));
	t->pt_nhi = 0;
	t->pt_lo = NULL;
	return (t->pt_buckets == NULL ? -1 : 0);
}

static inline void
riscv_pcrel_htab_fini(riscv_pcrel_htab_t *t)
{
	uint32_t i;
	riscv_pcrel_lo_t *l, *ln;

	for (i = 0; t->pt_buckets != NULL && i < t->pt_nbuckets; i++) {
		riscv_pcrel_hi_t *h = t->pt_buckets[i], *hn;
		while (h != NULL) {
			hn = h->ph_chain;
			free(h);
			h = hn;
		}
	}
	free(t->pt_buckets);
	for (l = t->pt_lo; l != NULL; l = ln) {
		ln = l->pl_next;
		free(l);
	}
	t->pt_buckets = NULL;
	t->pt_nbuckets = 0;
	t->pt_nhi = 0;
	t->pt_lo = NULL;
}

/* Grow + rehash when the load factor passes ~0.75 (keeps chains short). */
static inline int
riscv_pcrel_htab_grow(riscv_pcrel_htab_t *t)
{
	uint32_t nb = t->pt_nbuckets << 1, i;
	riscv_pcrel_hi_t **nbk = calloc(nb, sizeof (riscv_pcrel_hi_t *));

	if (nbk == NULL)
		return (-1);
	for (i = 0; i < t->pt_nbuckets; i++) {
		riscv_pcrel_hi_t *h = t->pt_buckets[i], *hn;
		while (h != NULL) {
			uint32_t b = riscv_pcrel_hash(h->ph_addr, nb);
			hn = h->ph_chain;
			h->ph_chain = nbk[b];
			nbk[b] = h;
			h = hn;
		}
	}
	free(t->pt_buckets);
	t->pt_buckets = nbk;
	t->pt_nbuckets = nb;
	return (0);
}

/* Insert a recorded HI (assumes no duplicate key; binutils asserts uniqueness). */
static inline riscv_pcrel_hi_t *
riscv_pcrel_htab_insert(riscv_pcrel_htab_t *t, int64_t addr, int64_t value,
    uint32_t rtype)
{
	riscv_pcrel_hi_t *e;
	uint32_t b;

	if ((t->pt_nhi + 1) > (t->pt_nbuckets - (t->pt_nbuckets >> 2))) {
		if (riscv_pcrel_htab_grow(t) != 0)
			return (NULL);
	}
	if ((e = malloc(sizeof (*e))) == NULL)
		return (NULL);
	e->ph_addr = addr;
	e->ph_value = value;
	e->ph_type = rtype;
	e->ph_absolute = 0;
	b = riscv_pcrel_hash(addr, t->pt_nbuckets);
	e->ph_chain = t->pt_buckets[b];
	t->pt_buckets[b] = e;
	t->pt_nhi++;
	return (e);
}

/* O(1) lookup of a recorded HI by auipc address. */
static inline riscv_pcrel_hi_t *
riscv_pcrel_htab_find(riscv_pcrel_htab_t *t, int64_t addr)
{
	uint32_t b = riscv_pcrel_hash(addr, t->pt_nbuckets);
	riscv_pcrel_hi_t *h;

	for (h = t->pt_buckets[b]; h != NULL; h = h->ph_chain)
		if (h->ph_addr == addr)
			return (h);
	return (NULL);
}

/* Defer a LO onto the worklist. */
static inline int
riscv_pcrel_htab_defer_lo(riscv_pcrel_htab_t *t, int64_t hi_addr,
    uint32_t rtype, int64_t addend, uint8_t *dest)
{
	riscv_pcrel_lo_t *e = malloc(sizeof (*e));

	if (e == NULL)
		return (-1);
	e->pl_addr = hi_addr;
	e->pl_type = rtype;
	e->pl_addend = addend;
	e->pl_dest = dest;
	e->pl_next = t->pt_lo;
	t->pt_lo = e;
	return (0);
}

#endif	/* _RISCV_PCREL_HTAB_H */
