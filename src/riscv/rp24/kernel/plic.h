/*
 * plic.h -- R-P24 qemu-virt PLIC interface.
 */
#ifndef	_RP24_PLIC_H
#define	_RP24_PLIC_H

#ifdef __cplusplus
extern "C" {
#endif

extern void plic_init(void);
extern unsigned int plic_claim(void);
extern void plic_complete(unsigned int src);
extern void plic_provoke_uart(void);
extern void plic_quiesce_uart(void);

#ifdef __cplusplus
}
#endif

#endif	/* _RP24_PLIC_H */
