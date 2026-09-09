/* Unit test: does the DSDT-then-SSDT scan find PCI0's _CRS where metal puts it?
   Replays the REAL metal tables dumped off c6g.metal. */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#define ACPI_LRES_WORD_ADDR 0x88
#define ACPI_LRES_DWORD_ADDR 0x87
#define ACPI_LRES_QWORD_ADDR 0x8a
#define ACPI_RESTYPE_MEMORY 0
#define ACPI_RESTYPE_IO 1
#define RES_IS_PRODUCER(g) (((g) & 0x02) == 0)

static int scan(const unsigned char *p, uint32_t len, int *nwin,
                unsigned long long *mem32, unsigned long long *mem64, int *io)
{
    uint32_t off; *nwin = 0; *mem32 = *mem64 = 0; *io = 0;
    /* Mirror the real algorithm: FIRST find the bus-number WordAddressSpace
       producer that anchors a root-bridge resource template, THEN walk the
       descriptors that follow CONTIGUOUSLY. My first version scanned the whole
       table for any 0x8a/0x87 byte and reported 132 phantom windows in metal's
       DSDT -- stray bytes inside unrelated AML. An unanchored scan is not the
       code under test. */
    uint32_t anchor = 0; int found_bus = 0;
    for (off = 36; off + 3 < len; off++) {
        if (p[off] != ACPI_LRES_WORD_ADDR) continue;
        uint16_t dl2 = p[off+1] | (p[off+2] << 8);
        if (off + 3 + dl2 > len || dl2 < 13) continue;
        if (p[off+3] != 2 /* BUS */) continue;         /* restype == BUS */
        if (!RES_IS_PRODUCER(p[off+4])) continue;
        anchor = off + 3 + dl2; found_bus = 1; break;
    }
    if (!found_bus) return 0;
    for (off = anchor; off + 3 < len; ) {
        unsigned char tag = p[off]; int fw;
        if (tag == ACPI_LRES_DWORD_ADDR) fw = 4;
        else if (tag == ACPI_LRES_QWORD_ADDR) fw = 8;
        else if (tag == ACPI_LRES_WORD_ADDR) fw = 2;
        else break;   /* end of the template -- do NOT keep scanning */
        uint16_t dlen = p[off+1] | (p[off+2] << 8);
        if (off + 3 + dlen > len || dlen < 13) break;
        unsigned char restype = p[off+3], gflags = p[off+4];
        unsigned long long f[5];
        for (int k = 0; k < 5; k++) { f[k] = 0;
            for (int b = 0; b < fw; b++) f[k] |= (unsigned long long)p[off+6+k*fw+b] << (8*b); }
        if (RES_IS_PRODUCER(gflags) && f[4] != 0 &&
            (restype == ACPI_RESTYPE_MEMORY || restype == ACPI_RESTYPE_IO)) {
            (*nwin)++;
            if (restype == ACPI_RESTYPE_IO) *io = 1;
            else if (fw == 8 || (f[1] >> 32)) *mem64 = f[1];
            else *mem32 = f[1];
        }
        off += 3 + dlen;
    }
    return *nwin;
}

static unsigned char *slurp(const char *f, uint32_t *n) {
    FILE *fp = fopen(f, "rb"); if (!fp) return NULL;
    static unsigned char b[65536]; *n = fread(b, 1, sizeof b, fp); fclose(fp); return b;
}

int main(void) {
    uint32_t dl, s1l; int fail = 0;
    unsigned char *d = slurp("a6hw-graviton-metal-DSDT.bin", &dl);
    int nw; unsigned long long m32, m64; int io;

    /* 1. metal DSDT alone -> the OLD behaviour. Must find NO usable windows. */
    scan(d, dl, &nw, &m32, &m64, &io);
    printf("  metal DSDT alone: nwin=%d  (old DSDT-only scan)\n", nw);
    if (nw != 0) { printf("  [FAIL] expected 0 windows in metal's DSDT\n"); fail++; }
    else printf("  [ok] metal DSDT yields no PCIe windows -- old scan WOULD fall back to QEMU consts\n");

    /* 2. SSDT1 -> must find the real metal windows. */
    unsigned char *s1 = malloc(65536); uint32_t t;
    unsigned char *tmp = slurp("a6hw-graviton-metal-SSDT1.bin", &t);
    memcpy(s1, tmp, t); s1l = t;
    scan(s1, s1l, &nw, &m32, &m64, &io);
    printf("  metal SSDT1: nwin=%d mem32=0x%llx mem64=0x%llx io=%d\n", nw, m32, m64, io);
    if (nw < 2) { printf("  [FAIL] expected >=2 windows in SSDT1\n"); fail++; }
    else printf("  [ok] SSDT1 yields the PCIe windows\n");
    if (m32 != 0x80000000ULL) { printf("  [FAIL] mem32 expected 0x80000000\n"); fail++; }
    else printf("  [ok] MEM32 == 0x80000000 (matches the metal firmware table)\n");
    if (m64 != 0x18000000000ULL) { printf("  [FAIL] mem64 expected 0x18000000000\n"); fail++; }
    else printf("  [ok] MEM64 == 0x18000000000 (matches the metal firmware table)\n");
    if (io) { printf("  [FAIL] metal has NO IO window, one was reported\n"); fail++; }
    else printf("  [ok] no IO window, as measured on metal\n");

    /* NEGATIVE CONTROL: corrupt SSDT1's descriptors -> must find nothing. */
    for (uint32_t i = 36; i < s1l; i++) if (s1[i]==0x8a || s1[i]==0x87 || s1[i]==0x88) s1[i]=0x00;
    scan(s1, s1l, &nw, &m32, &m64, &io);
    if (nw != 0) { printf("  [FAIL] NEGATIVE CONTROL: sabotaged SSDT1 still yielded %d windows\n", nw); fail++; }
    else printf("  [ok] NEGATIVE CONTROL: sabotaged SSDT1 yields 0 windows\n");

    printf(fail ? "  SSDT SCAN TEST FAIL (%d)\n" : "  SSDT SCAN TEST: ALL CHECKS PASS\n", fail);
    return fail ? 1 : 0;
}
