#!/usr/bin/env python3
# p3-wscons-notem.py <gate> : wcuwsrv() with no tem (aa64g).
# On aarch64 _HAVE_TEM_FIRMWARE is not defined, so wcuwsrv() always takes the tem path and frees
# the text when wc_get_screen_tem() is NULL: every userland/SMF console write (console login,
# svc.startd messages) was dropped on a headless box (measured aa64e: |W| echoes, 13070 chars).
# Send it down the PROM output path instead, as the CONS_FW deferred-output branch does
# (console_puts -> prom_writestr -> sysp_putchar), which p2 backs with the boot UART.
import sys
G = sys.argv[1] + '/usr/src/uts/'

def edit(path, fn):
    s = open(G + path).read(); t = fn(s)
    assert t != s, path; open(G + path, 'w').write(t)

def rep(s, a, b, n=1):
    assert s.count(a) == n, (a[:60], s.count(a))
    return s.replace(a, b)

edit('common/io/wscons.c', lambda s: rep(s,
    '\t\t\tif (ptem == NULL) {\n\t\t\t\tfreemsg(mp);\n\t\t\t\tcontinue;\n\t\t\t}\n',
    '\t\t\tif (ptem == NULL) {\n#if defined(__aarch64__)\n'
    '\t\t\t\t/* no tem: the PROM output path (boot UART) */\n'
    '\t\t\t\tfor (mblk_t *nbp = mp; nbp != NULL;\n\t\t\t\t    nbp = nbp->b_cont) {\n'
    '\t\t\t\t\tif (nbp->b_wptr > nbp->b_rptr)\n\t\t\t\t\t\tconsole_puts(\n'
    '\t\t\t\t\t\t    (const char *)nbp->b_rptr,\n'
    '\t\t\t\t\t\t    nbp->b_wptr - nbp->b_rptr);\n\t\t\t\t}\n#endif\n'
    '\t\t\t\tfreemsg(mp);\n\t\t\t\tcontinue;\n\t\t\t}\n'))
print('p3 wscons OK')
