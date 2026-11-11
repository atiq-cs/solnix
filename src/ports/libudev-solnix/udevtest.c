/*
 * udevtest.c -- check libudev-solnix the way its two callers use it.
 *   udevtest            libinput path backend + cosmic-settings
 *                       system_has_touchpad() on /dev/input
 * Prints "touchpad yes|no"; exit 0 = yes. Negative control:
 *   LIBUDEV_SOLNIX_INPUT_DIR=/nonexistent udevtest  -> "touchpad no", exit 1
 */
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/mkdev.h>
#include "libudev.h"

/* cosmic-settings 1.11 pages/input/mod.rs system_has_touchpad() */
static int
has_touchpad(void)
{
	struct udev *u = udev_new();
	struct udev_enumerate *e;
	struct udev_list_entry *l;
	int yes = 0;

	if (u == NULL || (e = udev_enumerate_new(u)) == NULL)
		return (0);
	(void) udev_enumerate_add_match_subsystem(e, "input");
	if (udev_enumerate_scan_devices(e) < 0)
		return (0);
	udev_list_entry_foreach(l, udev_enumerate_get_list_entry(e)) {
		/* the Rust crate builds each device from its syspath */
		struct udev_device *d = udev_device_new_from_syspath(u,
		    udev_list_entry_get_name(l));
		const char *v;

		if (d == NULL)
			continue;
		v = udev_device_get_property_value(d, "ID_INPUT_TOUCHPAD");
		printf("device %s sysname %s devnode %s ID_INPUT_TOUCHPAD=%s\n",
		    udev_device_get_syspath(d), udev_device_get_sysname(d),
		    udev_device_get_devnode(d), v ? v : "(none)");
		yes |= v != NULL && strcmp(v, "1") == 0;
		udev_device_unref(d);
	}
	udev_enumerate_unref(e);
	udev_unref(u);
	return (yes);
}

/* libinput path-seat.c udev_device_from_devnode() + evdev.c lookups */
static void
path_backend(const char *node)
{
	struct udev *u = udev_new();
	struct udev_device *d;
	struct stat st;

	if (stat(node, &st) != 0) {
		printf("path %s: absent\n", node);
		return;
	}
	d = udev_device_new_from_devnum(u, 'c', st.st_rdev);
	if (d == NULL) {
		printf("path %s: new_from_devnum FAILED\n", node);
		return;
	}
	printf("path %s: init %d sysname %s ID_INPUT %s ID_SEAT %s "
	    "parent %p\n", node, udev_device_get_is_initialized(d),
	    udev_device_get_sysname(d),
	    udev_device_get_property_value(d, "ID_INPUT"),
	    udev_device_get_property_value(d, "ID_SEAT") ?: "(none)",
	    (void *)udev_device_get_parent(d));
	udev_device_unref(d);
	udev_unref(u);
}

/* libinput evdev_device_have_same_syspath(): fstat of an open (clone) fd */
#include <fcntl.h>
#include <unistd.h>
static int
same_syspath(const char *node)
{
	struct udev *u = udev_new();
	struct udev_device *a, *b;
	struct stat st;
	int fd, ok;

	if (stat(node, &st) != 0 || (a = udev_device_new_from_devnum(u, 'c',
	    st.st_rdev)) == NULL)
		return (-1);
	if ((fd = open(node, O_RDWR | O_NONBLOCK)) < 0 || fstat(fd, &st) != 0)
		return (-1);
	b = udev_device_new_from_devnum(u, 'c', st.st_rdev);
	ok = b != NULL && strcmp(udev_device_get_syspath(a),
	    udev_device_get_syspath(b)) == 0;
	printf("same_syspath %s (fd minor 0x%lx)\n", ok ? "yes" : "NO",
	    (unsigned long)minor(st.st_rdev));
	close(fd);
	return (ok);
}

int
main(int argc, char **argv)
{
	int y;

	if (argc > 1)		/* opens the node: run as root */
		return (same_syspath(argv[1]) == 1 ? 0 : 1);
	path_backend("/dev/input/event0");
	y = has_touchpad();
	printf("touchpad %s\n", y ? "yes" : "no");
	return (!y);
}
