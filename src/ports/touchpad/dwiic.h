/*
 * dwiic.h -- the one private interface dwiic exports to ihid (ISC, see dwiic.c).
 */
#ifndef _DWIIC_H
#define	_DWIIC_H

#include <sys/types.h>
#include <sys/sunddi.h>

/* returns an i2c_ctrl_error_t; I2C_CTRL_E_OK (0) on success */
extern int dwiic_xfer(dev_info_t *, uint16_t, const uint8_t *, uint32_t,
    uint8_t *, uint32_t);

#endif /* _DWIIC_H */
