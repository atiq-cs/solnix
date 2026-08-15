/*
 * ramfs.c -- R-P27 sub-task 2: a minimal in-memory filesystem (ramfs) seeded
 * from an initramfs blob linked into the kernel (.incbin).  This replaces the
 * R-P26 embedded-per-program .incbin (where exec ignored the path and always
 * ran the one embedded execee) with a real lookup-by-path: exec("/bin/hello")
 * resolves the ELF bytes out of the archive.
 *
 * The archive (built by user/mkinitramfs.py) is a flat sequence of
 * name+size+bytes records:
 *   magic "SOLRAMFS", then repeated { u32 namelen; u32 datalen; name; data;
 *   pad-to-8 }, terminated by u32 namelen==0.  ramfs_lookup walks it and
 *   returns the (bytes,len) of the matching path -- the reduced vfs lookuppn:
 *   no directories, no inodes, no mounts, just an exact-name match over the
 *   linked-in image.
 *
 * CRIB PROVENANCE: reading a name/size/bytes archive straight out of memory to
 * resolve a boot path is the illumos boot_archive (a ufs/hsfs image the loader
 * hands the kernel) + Linux initramfs (newc cpio) reduced to a flat records
 * scan; exec-by-path over it is illumos vfs lookuppn / vn_open reduced to an
 * exact-name match with no directory hierarchy.
 */

#include "sbi.h"

extern const unsigned char initramfs_start[];
extern const unsigned char initramfs_end[];

/* read a little-endian u32 from a byte pointer (no alignment assumption). */
static unsigned int
rd_u32(const unsigned char *p)
{
	return ((unsigned int)p[0] | ((unsigned int)p[1] << 8) |
	    ((unsigned int)p[2] << 16) | ((unsigned int)p[3] << 24));
}

static int
name_eq(const unsigned char *a, unsigned int alen, const char *b)
{
	unsigned int i;
	for (i = 0; i < alen; i++) {
		if (b[i] == 0 || (unsigned char)b[i] != a[i])
			return (0);
	}
	return (b[alen] == 0);		/* both ended together */
}

/*
 * ramfs_lookup -- resolve `path` to its bytes in the initramfs.  On success
 * stores the data pointer + length through *out / *outlen and returns 0;
 * returns -1 if the path is not present or the archive magic is wrong.
 */
int
ramfs_lookup(const char *path, const unsigned char **out, unsigned long *outlen)
{
	const unsigned char *p = initramfs_start;
	const unsigned char *end = initramfs_end;

	if (end - p < 8 ||
	    p[0] != 'S' || p[1] != 'O' || p[2] != 'L' || p[3] != 'R' ||
	    p[4] != 'A' || p[5] != 'M' || p[6] != 'F' || p[7] != 'S')
		return (-1);
	p += 8;

	for (;;) {
		unsigned int namelen, datalen;
		if (p + 4 > end)
			return (-1);
		namelen = rd_u32(p);
		if (namelen == 0)
			return (-1);	/* terminator: not found */
		if (p + 8 > end)
			return (-1);
		datalen = rd_u32(p + 4);
		p += 8;
		if (p + namelen + datalen > end)
			return (-1);	/* truncated archive */
		if (name_eq(p, namelen, path)) {
			*out = p + namelen;
			*outlen = datalen;
			return (0);
		}
		/* advance past name + data, padded to 8 bytes. */
		{
			unsigned long adv = (unsigned long)namelen + datalen;
			adv = (adv + 7UL) & ~7UL;
			p += adv;
		}
	}
}

/*
 * ramfs_dump -- boot proof: print the archive's file names + sizes, so the log
 * shows the ramfs was populated and is walkable by path (the fs-backed exec
 * substrate).
 */
void
ramfs_dump(void)
{
	const unsigned char *p = initramfs_start;
	const unsigned char *end = initramfs_end;
	extern void putdec_pub(unsigned long);

	if (end - p < 8) {
		sbi_console_puts("  ramfs: EMPTY (no archive)\n");
		return;
	}
	p += 8;					/* skip magic (validated in lookup) */
	for (;;) {
		unsigned int namelen, datalen, i;
		if (p + 4 > end || (namelen = rd_u32(p)) == 0)
			break;
		datalen = rd_u32(p + 4);
		p += 8;
		sbi_console_puts("    ");
		for (i = 0; i < namelen; i++)
			sbi_console_putchar((int)p[i]);
		sbi_console_puts("  (");
		putdec_pub(datalen);
		sbi_console_puts(" bytes)\n");
		{
			unsigned long adv = (unsigned long)namelen + datalen;
			adv = (adv + 7UL) & ~7UL;
			p += adv;
		}
	}
}
