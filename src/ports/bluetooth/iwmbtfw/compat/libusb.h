/*
 * The libusb-1.0 subset the vendored iwmbtfw calls, implemented over illumos
 * ugen(4D) nodes (solnix, new code; CDDL-compatible, no libusb code copied).
 *
 * One "device" only: the ugen directory given on the command line
 * (e.g. /dev/usb/8087.33/0). Endpoint addresses map to ugen node names through
 * the interface number passed in ugen_usb_open (iwmbtfw only uses interface 0).
 */
#ifndef _SOLNIX_LIBUSB_H
#define	_SOLNIX_LIBUSB_H

#include <stdint.h>
#include <sys/types.h>

#define	LIBUSB_SUCCESS			0
#define	LIBUSB_ERROR_IO			(-1)
#define	LIBUSB_ERROR_INVALID_PARAM	(-2)
#define	LIBUSB_ERROR_ACCESS		(-3)
#define	LIBUSB_ERROR_NO_DEVICE		(-4)
#define	LIBUSB_ERROR_NOT_FOUND		(-5)
#define	LIBUSB_ERROR_TIMEOUT		(-7)
#define	LIBUSB_ERROR_OVERFLOW		(-8)
#define	LIBUSB_ERROR_PIPE		(-9)
#define	LIBUSB_ERROR_NOT_SUPPORTED	(-12)
#define	LIBUSB_ERROR_OTHER		(-99)

#define	LIBUSB_REQUEST_TYPE_CLASS	(0x01 << 5)
#define	LIBUSB_RECIPIENT_DEVICE		0x00
#define	LIBUSB_ENDPOINT_IN		0x80

typedef struct libusb_context libusb_context;
typedef struct libusb_device libusb_device;
typedef struct libusb_device_handle libusb_device_handle;

struct libusb_device_descriptor {
	uint8_t		bLength;
	uint8_t		bDescriptorType;
	uint16_t	bcdUSB;
	uint8_t		bDeviceClass;
	uint8_t		bDeviceSubClass;
	uint8_t		bDeviceProtocol;
	uint8_t		bMaxPacketSize0;
	uint16_t	idVendor;
	uint16_t	idProduct;
	uint16_t	bcdDevice;
	uint8_t		iManufacturer;
	uint8_t		iProduct;
	uint8_t		iSerialNumber;
	uint8_t		bNumConfigurations;
};

int libusb_init(libusb_context **);
void libusb_exit(libusb_context *);
ssize_t libusb_get_device_list(libusb_context *, libusb_device ***);
void libusb_free_device_list(libusb_device **, int);
libusb_device *libusb_ref_device(libusb_device *);
void libusb_unref_device(libusb_device *);
uint8_t libusb_get_bus_number(libusb_device *);
uint8_t libusb_get_device_address(libusb_device *);
int libusb_get_device_descriptor(libusb_device *,
    struct libusb_device_descriptor *);
int libusb_open(libusb_device *, libusb_device_handle **);
void libusb_close(libusb_device_handle *);
int libusb_kernel_driver_active(libusb_device_handle *, int);
int libusb_reset_device(libusb_device_handle *);
int libusb_control_transfer(libusb_device_handle *, uint8_t, uint8_t,
    uint16_t, uint16_t, unsigned char *, uint16_t, unsigned int);
int libusb_bulk_transfer(libusb_device_handle *, unsigned char,
    unsigned char *, int, int *, unsigned int);
int libusb_interrupt_transfer(libusb_device_handle *, unsigned char,
    unsigned char *, int, int *, unsigned int);
const char *libusb_strerror(int);

/* solnix: which ugen directory libusb_get_device_list() reports (one device). */
int ugen_usb_set_dir(const char *dir);
/* solnix: 1 = do not reset the interrupt-IN toggle at open (negative control). */
void ugen_usb_set_noclear(int);
/* solnix: 1 = no diagnostic line on an interrupt-IN timeout (polling callers). */
void ugen_usb_set_quiet(int);
/* solnix: print ugen device + endpoint status without blocking (diagnostics). */
void ugen_usb_diag(libusb_device_handle *, const char *why);

#endif
