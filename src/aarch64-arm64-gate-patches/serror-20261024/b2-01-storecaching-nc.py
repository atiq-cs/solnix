#!/usr/bin/env python3
# b2-01-storecaching-nc.py <gate> : aa64f boot 2, the fix.
# Boot 1 (out/m1-c1.txt): [AA64F-KSERR] cpu23 esr 0xbe000411 elr ena_llq_write_to_dev+0xa8
# right after the 16 64-bit stores to the ena0 LLQ BAR, which rootnex mapped with
# DDI_STORECACHING_OK_ACC -> HAT_STORECACHING_OK -> PTE_ATTR_NORMEM = MAIR 0xff
# (Normal Inner/Outer Write-Back, measured by AT S1E1R: PAR attr 0xff).  A cacheable
# mapping of a PCIe BAR is wrong on arm64.  Linux maps the same BAR with ioremap_wc =
# MT_NORMAL_NC (MAIR 0x44).  Here that is HAT_MERGING_OK -> PTE_ATTR_NORMEM_UC
# (MAIR slot 4 = 0x44 in this kernel's MAIR 0x844bbff0400).  rootnex is where device
# registers get mapped, so fix it there for every driver; leave the hat and RAM mappings alone.
import sys
G = sys.argv[1] + '/usr/src/uts/'

def edit(path, fn):
    s = open(G + path).read(); t = fn(s)
    assert t != s, path; open(G + path, 'w').write(t)

def rep(s, a, b, n=1):
    assert s.count(a) == n, (a[:60], s.count(a))
    return s.replace(a, b)

WHY = ('\t\t\t/* aa64f: device regs are never cacheable on arm64: */\n'
       '\t\t\t/* write-combining = Normal-NC, as Linux ioremap_wc */\n')

def rootnex(s):
    s = rep(s, '\t\tcase DDI_STORECACHING_OK_ACC:\n\t\t\that_acc_flags = HAT_STORECACHING_OK;\n',
            '\t\tcase DDI_STORECACHING_OK_ACC:\n' + WHY +
            '\t\t\that_acc_flags = HAT_MERGING_OK;\n')
    return rep(s, '\tcase DDI_STORECACHING_OK_ACC:\n\t\thp->ah_hat_flags |= HAT_STORECACHING_OK;\n',
               '\tcase DDI_STORECACHING_OK_ACC:\n' + WHY.replace('\t\t\t', '\t\t') +
               '\t\thp->ah_hat_flags |= HAT_MERGING_OK;\n')
edit('armv8/io/rootnex.c', rootnex)
print('b2-01 OK')
