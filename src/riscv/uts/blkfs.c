/*
 * blkfs.c — illumos riscv64 on-disk writable filesystem + block/buffer cache
 * (R-P12 milestone 2).
 *
 * R-P11's writable FS was in-memory ramfs (a growable kmem buffer per file, no
 * persistence). R-P12 replaces it with a REAL on-disk FS over a dedicated
 * virtio-blk data disk (data.img), fronted by a block/buffer cache — the seed
 * of the illumos bio layer (getblk/bread/bwrite/bdwrite/bflush).
 *
 *   1. Block cache (buf_t): a fixed pool of 512-byte buffers keyed by disk
 *      sector. getblk() finds-or-evicts a buffer for a sector; bread() fills it
 *      from disk (vioblk_fs_read_sector); the write path marks it B_DELWRI
 *      (delayed write); bflush()/snfs_sync() writes every dirty buffer back to
 *      the disk (vioblk_fs_write_sector) — genuine write-back that survives.
 *
 *   2. SNFS ("solnix fs"): a deliberately tiny on-disk layout that a block
 *      cache + a directory of fixed slots can serve, enough to prove
 *      write -> sync -> re-read-after-remount:
 *        sector 0        superblock: magic "SNFS", nslots, first data sector
 *        sector 1        directory: NSLOT fixed entries {name[48], len, dblk}
 *        sector DATA0..  each slot owns SNFS_FBLK contiguous sectors of data
 *      All I/O goes THROUGH the block cache, so a "remount" (snfs_remount:
 *      invalidate the whole cache, re-read the superblock+dir from disk) proves
 *      the bytes reached the platter and come back.
 *
 * NOTE (R-P12 ceiling): fixed NSLOT files, fixed SNFS_FBLK bytes/file, one flat
 * directory, no free-list/fragmentation, write-back only on explicit sync (no
 * periodic fsflush). A real UFS/FFS cylinder-group layout + a proper vnode
 * cache is R-P13. The block cache is single-hash-chain linear scan (NBUF small).
 */

#include "sbi.h"

extern void kputdec(unsigned long v);
extern void kputhex(unsigned long v);

/* vioblk.c: the FS data disk (a dedicated virtio-blk, probed at attach). */
extern int vioblk_data_read_sector(unsigned long sector, void *buf);
extern int vioblk_data_write_sector(unsigned long sector, const void *buf);
extern int vioblk_data_present(void);

/* kernel-side helpers (uproc.c provides these small string ops via extern). */
static int
bstr_eq(const char *a, const char *b)
{
	while (*a && *a == *b) { a++; b++; }
	return (*a == *b);
}

static void
bstr_cpy(char *d, const char *s, unsigned n)
{
	unsigned i;
	for (i = 0; i + 1 < n && s[i]; i++)
		d[i] = s[i];
	d[i] = 0;
}

#define	SECSZ		512

/* ---- block/buffer cache -------------------------------------------------- */

#define	NBUF		16		/* cache buffers */
#define	B_VALID		0x1		/* buffer holds valid disk data */
#define	B_DELWRI	0x2		/* dirty: needs write-back */

typedef struct buf {
	unsigned long	b_sector;
	int		b_flags;
	int		b_used;		/* slot in use (mapped to a sector) */
	unsigned long	b_lru;		/* recency for eviction */
	unsigned char	b_data[SECSZ];
} buf_t;

static buf_t bufpool[NBUF];
static unsigned long buf_clock;		/* monotonic LRU stamp */

/*
 * getblk — return the cache buffer for `sector`, allocating/evicting if needed.
 * Does NOT read from disk (caller does bread if it needs the contents). If the
 * evicted buffer is dirty it is written back first.
 */
static buf_t *
getblk(unsigned long sector)
{
	int i, victim = -1;
	unsigned long oldest = ~0UL;

	for (i = 0; i < NBUF; i++)
		if (bufpool[i].b_used && bufpool[i].b_sector == sector) {
			bufpool[i].b_lru = ++buf_clock;
			return (&bufpool[i]);
		}
	/* Not cached: find a free slot, else evict the LRU. */
	for (i = 0; i < NBUF; i++)
		if (!bufpool[i].b_used) { victim = i; break; }
	if (victim < 0) {
		for (i = 0; i < NBUF; i++)
			if (bufpool[i].b_lru < oldest) {
				oldest = bufpool[i].b_lru;
				victim = i;
			}
		/* Write back a dirty victim before reuse. */
		if (bufpool[victim].b_flags & B_DELWRI)
			vioblk_data_write_sector(bufpool[victim].b_sector,
			    bufpool[victim].b_data);
	}
	bufpool[victim].b_used = 1;
	bufpool[victim].b_sector = sector;
	bufpool[victim].b_flags = 0;
	bufpool[victim].b_lru = ++buf_clock;
	return (&bufpool[victim]);
}

/* bread — getblk + fill from disk if not already valid. Returns buffer or 0. */
static buf_t *
bread(unsigned long sector)
{
	buf_t *b = getblk(sector);

	if (!(b->b_flags & B_VALID)) {
		if (!vioblk_data_read_sector(sector, b->b_data))
			return (0);
		b->b_flags |= B_VALID;
	}
	return (b);
}

/* bdwrite — mark a buffer for delayed write-back (dirty). */
static void
bdwrite(buf_t *b)
{
	b->b_flags |= (B_DELWRI | B_VALID);
}

/* bflush — write every dirty cache buffer back to disk. Returns #written. */
static int
bflush(void)
{
	int i, n = 0;

	for (i = 0; i < NBUF; i++)
		if (bufpool[i].b_used && (bufpool[i].b_flags & B_DELWRI)) {
			if (vioblk_data_write_sector(bufpool[i].b_sector,
			    bufpool[i].b_data)) {
				bufpool[i].b_flags &= ~B_DELWRI;
				n++;
			}
		}
	return (n);
}

/* binval — invalidate the whole cache (simulate a remount: force re-read). */
static void
binval(void)
{
	int i;
	for (i = 0; i < NBUF; i++)
		bufpool[i].b_used = bufpool[i].b_flags = 0;
}

/* ---- SNFS on-disk layout ------------------------------------------------- */

#define	SNFS_MAGIC0	'S'
#define	SNFS_MAGIC1	'N'
#define	SNFS_MAGIC2	'F'
#define	SNFS_MAGIC3	'S'
#define	SNFS_NSLOT	8		/* fixed files */
#define	SNFS_NAMELEN	48
#define	SNFS_FBLK	8		/* sectors of data per file (4 KiB) */
#define	SNFS_SB_SEC	0		/* superblock sector */
#define	SNFS_DIR_SEC	1		/* directory sector */
#define	SNFS_DATA0	2		/* first data sector */

struct snfs_super {
	unsigned char	s_magic[4];
	unsigned int	s_nslot;
	unsigned int	s_fblk;
	unsigned int	s_data0;
};

struct snfs_dirent {
	char		d_name[SNFS_NAMELEN];
	unsigned int	d_len;		/* bytes (0 = empty slot) */
	unsigned int	d_dblk;		/* first data sector of this file */
};	/* 56 bytes; 8 fit in 512, exactly NSLOT */

static int snfs_ready;

int
snfs_ready_p(void)
{
	return (snfs_ready);
}

/* Data sector for slot i. */
static unsigned long
snfs_slot_dblk(int slot)
{
	return (SNFS_DATA0 + (unsigned long)slot * SNFS_FBLK);
}

/*
 * snfs_mkfs — format the data disk: write a superblock + an empty directory.
 * Called once at boot if the disk does not already carry an SNFS superblock,
 * so the on-disk FS exists to be written to. Returns 1 on success.
 */
static int
snfs_mkfs(void)
{
	buf_t *sb = getblk(SNFS_SB_SEC);
	buf_t *dir;
	struct snfs_super *s;
	int i;

	if (sb == 0)
		return (0);
	for (i = 0; i < SECSZ; i++)
		sb->b_data[i] = 0;
	s = (struct snfs_super *)sb->b_data;
	s->s_magic[0] = SNFS_MAGIC0; s->s_magic[1] = SNFS_MAGIC1;
	s->s_magic[2] = SNFS_MAGIC2; s->s_magic[3] = SNFS_MAGIC3;
	s->s_nslot = SNFS_NSLOT;
	s->s_fblk = SNFS_FBLK;
	s->s_data0 = SNFS_DATA0;
	bdwrite(sb);

	dir = getblk(SNFS_DIR_SEC);
	if (dir == 0)
		return (0);
	for (i = 0; i < SECSZ; i++)
		dir->b_data[i] = 0;		/* all slots empty (d_len=0) */
	bdwrite(dir);

	bflush();
	return (1);
}

/*
 * snfs_init — probe the data disk. If it holds a valid SNFS superblock, mount
 * it; otherwise format it (mkfs). Returns 1 if an SNFS FS is available.
 */
int
snfs_init(void)
{
	buf_t *sb;
	struct snfs_super *s;

	if (!vioblk_data_present()) {
		sbi_console_puts("[blkfs] no data disk; on-disk FS unavailable\n");
		snfs_ready = 0;
		return (0);
	}
	sb = bread(SNFS_SB_SEC);
	if (sb == 0) {
		sbi_console_puts("[blkfs] data-disk read FAILED\n");
		return (0);
	}
	s = (struct snfs_super *)sb->b_data;
	if (s->s_magic[0] == SNFS_MAGIC0 && s->s_magic[1] == SNFS_MAGIC1 &&
	    s->s_magic[2] == SNFS_MAGIC2 && s->s_magic[3] == SNFS_MAGIC3) {
		sbi_console_puts("[blkfs] SNFS mounted (nslot ");
		kputdec(s->s_nslot);
		sbi_console_puts(", fblk ");
		kputdec(s->s_fblk);
		sbi_console_puts(")\n");
	} else {
		sbi_console_puts("[blkfs] no SNFS superblock; mkfs...\n");
		if (!snfs_mkfs())
			return (0);
		sbi_console_puts("[blkfs] SNFS formatted on data disk\n");
	}
	snfs_ready = 1;
	return (1);
}

/* Find the directory slot for `name`, or -1. dir must be a bread'd buffer. */
static int
snfs_find(buf_t *dir, const char *name)
{
	struct snfs_dirent *de = (struct snfs_dirent *)dir->b_data;
	int i;

	for (i = 0; i < SNFS_NSLOT; i++)
		if (de[i].d_len != 0 || de[i].d_name[0] != 0)
			if (bstr_eq(de[i].d_name, name))
				return (i);
	return (-1);
}

/* Find a free slot, or -1. */
static int
snfs_free_slot(buf_t *dir)
{
	struct snfs_dirent *de = (struct snfs_dirent *)dir->b_data;
	int i;

	for (i = 0; i < SNFS_NSLOT; i++)
		if (de[i].d_name[0] == 0)
			return (i);
	return (-1);
}

/*
 * snfs_open — resolve/create `name`, returning a slot index (>=0) and its
 * length via *lenp. If create!=0 and the file does not exist, allocate a slot.
 * Returns -1 on failure. All access goes through the block cache.
 */
int
snfs_open(const char *name, int create, unsigned long *lenp)
{
	buf_t *dir;
	struct snfs_dirent *de;
	int slot;

	if (!snfs_ready)
		return (-1);
	dir = bread(SNFS_DIR_SEC);
	if (dir == 0)
		return (-1);
	de = (struct snfs_dirent *)dir->b_data;
	slot = snfs_find(dir, name);
	if (slot < 0) {
		if (!create)
			return (-1);
		slot = snfs_free_slot(dir);
		if (slot < 0)
			return (-1);
		bstr_cpy(de[slot].d_name, name, SNFS_NAMELEN);
		de[slot].d_len = 0;
		de[slot].d_dblk = (unsigned int)snfs_slot_dblk(slot);
		bdwrite(dir);
	}
	if (lenp != 0)
		*lenp = de[slot].d_len;
	return (slot);
}

/* Current length of a slot (re-reads dir through the cache). */
unsigned long
snfs_len(int slot)
{
	buf_t *dir;
	struct snfs_dirent *de;

	if (!snfs_ready || slot < 0 || slot >= SNFS_NSLOT)
		return (0);
	dir = bread(SNFS_DIR_SEC);
	if (dir == 0)
		return (0);
	de = (struct snfs_dirent *)dir->b_data;
	return (de[slot].d_len);
}

/*
 * snfs_read — read up to n bytes from slot at byte offset `off` into kbuf
 * (kernel buffer). Returns bytes read (0 at EOF). Goes through the block cache.
 */
long
snfs_read(int slot, unsigned long off, unsigned char *kbuf, unsigned long n)
{
	unsigned long len, dblk, got = 0;

	if (!snfs_ready || slot < 0 || slot >= SNFS_NSLOT)
		return (-1);
	len = snfs_len(slot);
	if (off >= len)
		return (0);
	if (off + n > len)
		n = len - off;
	dblk = snfs_slot_dblk(slot);
	while (got < n) {
		unsigned long fpos = off + got;
		unsigned long sec = dblk + fpos / SECSZ;
		unsigned long soff = fpos % SECSZ;
		unsigned long chunk = SECSZ - soff;
		buf_t *b;
		unsigned long i;

		if (chunk > n - got)
			chunk = n - got;
		b = bread(sec);
		if (b == 0)
			break;
		for (i = 0; i < chunk; i++)
			kbuf[got + i] = b->b_data[soff + i];
		got += chunk;
	}
	return ((long)got);
}

/*
 * snfs_write — write n bytes from kbuf into slot at byte offset `off`, growing
 * the file's recorded length. Marks touched data blocks + the directory dirty
 * (delayed write; snfs_sync flushes). Bounded to SNFS_FBLK sectors. Returns
 * bytes written.
 */
long
snfs_write(int slot, unsigned long off, const unsigned char *kbuf,
    unsigned long n)
{
	unsigned long dblk, put = 0, maxbytes;
	buf_t *dir;
	struct snfs_dirent *de;

	if (!snfs_ready || slot < 0 || slot >= SNFS_NSLOT)
		return (-1);
	maxbytes = (unsigned long)SNFS_FBLK * SECSZ;
	if (off >= maxbytes)
		return (0);
	if (off + n > maxbytes)
		n = maxbytes - off;
	dblk = snfs_slot_dblk(slot);
	while (put < n) {
		unsigned long fpos = off + put;
		unsigned long sec = dblk + fpos / SECSZ;
		unsigned long soff = fpos % SECSZ;
		unsigned long chunk = SECSZ - soff;
		buf_t *b;
		unsigned long i;

		if (chunk > n - put)
			chunk = n - put;
		/* Read-modify-write only if partial; else getblk fresh. */
		if (soff == 0 && chunk == SECSZ)
			b = getblk(sec);
		else
			b = bread(sec);
		if (b == 0)
			break;
		for (i = 0; i < chunk; i++)
			b->b_data[soff + i] = kbuf[put + i];
		bdwrite(b);
		put += chunk;
	}
	/* Grow the recorded length. */
	dir = bread(SNFS_DIR_SEC);
	if (dir != 0) {
		de = (struct snfs_dirent *)dir->b_data;
		if (off + put > de[slot].d_len) {
			de[slot].d_len = (unsigned int)(off + put);
			bdwrite(dir);
		}
	}
	return ((long)put);
}

/* snfs_sync — flush all dirty buffers to disk. Returns #sectors written. */
int
snfs_sync(void)
{
	int n = bflush();
	sbi_console_puts("[blkfs] sync: ");
	kputdec((unsigned long)n);
	sbi_console_puts(" dirty block(s) written back to disk\n");
	return (n);
}

/*
 * snfs_remount — drop the entire block cache and re-mount from disk. Proves
 * write-back persistence: after this, reads MUST come from the platter (the
 * cache is empty), not from a still-dirty buffer. Returns 1 on success.
 */
int
snfs_remount(void)
{
	binval();
	sbi_console_puts("[blkfs] remount: block cache invalidated, "
	    "re-reading superblock from disk\n");
	snfs_ready = 0;
	return (snfs_init());
}
