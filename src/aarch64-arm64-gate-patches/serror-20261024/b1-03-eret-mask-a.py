#!/usr/bin/env python3
# b1-03-eret-mask-a.py <gate> : aa64f boot 1, concern 3.  Apply after b1-02.
# Once A is unmasked in the kernel (b1-02), an SError taken between "msr elr/spsr" and
# eret would clobber ELR/SPSR.  Mask A together with I before every restore, and
# re-unmask it where a return path goes back into C (syscall post, AST, kpreempt).
import sys
G = sys.argv[1] + '/usr/src/uts/'

def edit(path, fn):
    s = open(G + path).read(); t = fn(s)
    assert t != s, path; open(G + path, 'w').write(t)

def rep(s, a, b, n=1):
    assert s.count(a) == n, (a[:60], s.count(a))
    return s.replace(a, b)

IA = '#(DAIF_SETCLEAR_IRQ | DAIF_SETCLEAR_SERROR)'
MA = '\tmsr\tDAIFSet, #DAIF_SETCLEAR_SERROR\t// aa64f\n'

def exc(s):
    for h in ('from_current_el_sync_handler', 'from_current_el_error_handler'):
        s = rep(s, '1:\n\t__RESTORE_REGS_EL1\n\teret\n\tSET_SIZE(%s)\n' % h,
                '1:\n' + MA + '\t__RESTORE_REGS_EL1\n\teret\n\tSET_SIZE(%s)\n' % h)
    # syscall return, and its post_syscall detour (EL0 origin: A was 0)
    s = rep(s, '\tmsr\tDAIFSet, #DAIF_SETCLEAR_IRQ\n\n\tldr\tw9, [x21, #T_POST_SYS_AST]\n',
            '\tmsr\tDAIFSet, %s\n\n\tldr\tw9, [x21, #T_POST_SYS_AST]\n' % IA)
    s = rep(s, '_syscall_post:\n\tmsr\tDAIFClr, #DAIF_SETCLEAR_IRQ\n',
            '_syscall_post:\n\tmsr\tDAIFClr, %s\n' % IA)
    # user_rtt, and its AST detour into trap()
    s = rep(s, '_user_rtt:\n\tmsr\tDAIFSet, #(DAIF_SETCLEAR_IRQ | DAIF_SETCLEAR_DEBUG)\n',
            '_user_rtt:\n\tmsr\tDAIFSet, #(DAIF_SETCLEAR_IRQ | DAIF_SETCLEAR_DEBUG | DAIF_SETCLEAR_SERROR)\n')
    s = rep(s, '3:\n\tmov\tx0, #T_AST\n',
            '3:\n\tmsr\tDAIFClr, #DAIF_SETCLEAR_SERROR\t// aa64f\n\tmov\tx0, #T_AST\n')
    # fasttrap return
    s = rep(s, '\tblr\tx9\n\tmsr\tDAIFSet, #DAIF_SETCLEAR_IRQ\n',
            '\tblr\tx9\n\tmsr\tDAIFSet, %s\n' % IA)
    # kernel return (_sys_rtt) and kpreempt: unmask A only if the interrupted ctx had A=0
    s = rep(s, '\tb.eq\tuser_rtt\n\n\tmsr\tDAIFSet, #DAIF_SETCLEAR_IRQ\n',
            '\tb.eq\tuser_rtt\n\n\tmsr\tDAIFSet, %s\n' % IA)
    s = rep(s, '\tmsr\tDAIFClr, #DAIF_SETCLEAR_IRQ\n\tbl\tkpreempt\n\tmsr\tDAIFSet, #DAIF_SETCLEAR_IRQ\n',
            '\tldr\tx9, [sp, #REGOFF_SPSR]\t// aa64f\n\ttbnz\tx9, #8, 7f\n'
            '\tmsr\tDAIFClr, #DAIF_SETCLEAR_SERROR\n7:\n'
            '\tmsr\tDAIFClr, #DAIF_SETCLEAR_IRQ\n\tbl\tkpreempt\n\tmsr\tDAIFSet, %s\n' % IA)
    return s
edit('armv8/ml/exceptions.S', exc)
print('b1-03 OK')
