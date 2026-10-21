/*
 * solnix-cputemp -- print the CPU package temperature and the hottest core, in
 * whole degrees C, from the coretemp(4D) ksensors under /dev/sensors (the only
 * interface coretemp has: SENSOR_IOCTL_SCALAR; there is no kstat, and fmtopo
 * needs the whole topo tree). Output, one line: "pkg <C> cores-max <C>", with
 * "-" for a reading that is not there (no coretemp: a VM, a non-Intel CPU).
 * "-t" runs the self-test of the unit conversion and exits.
 */
#include <sys/types.h>
#include <sys/sensors.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define	DIR_CPU	"/dev/sensors/temperature/cpu"

/* the reading in whole degrees C, or -1000 when it is not Celsius */
static long
to_celsius(const sensor_ioctl_scalar_t *s)
{
	long v = (long)s->sis_value;

	if (s->sis_unit != SENSOR_UNIT_CELSIUS)
		return (-1000);
	if (s->sis_gran > 1)
		return (v / s->sis_gran);
	if (s->sis_gran < -1)
		return (v * -s->sis_gran);
	return (v);
}

static int
selftest(void)
{
	sensor_ioctl_scalar_t s = { SENSOR_UNIT_CELSIUS, 10, 0, 0, 455 };

	if (to_celsius(&s) != 45)
		return (1);
	s.sis_gran = -2; s.sis_value = 30;
	if (to_celsius(&s) != 60)
		return (1);
	s.sis_gran = 1; s.sis_value = 71;
	if (to_celsius(&s) != 71)
		return (1);
	s.sis_unit = SENSOR_UNIT_KELVIN;
	if (to_celsius(&s) != -1000)
		return (1);
	(void) printf("solnix-cputemp self-test OK\n");
	return (0);
}

int
main(int argc, char **argv)
{
	long pkg = -1000, core = -1000, c;
	char path[512];
	struct dirent *de;
	sensor_ioctl_scalar_t s;
	DIR *d;
	int fd;

	if (argc > 1 && strcmp(argv[1], "-t") == 0)
		return (selftest());
	if ((d = opendir(DIR_CPU)) != NULL) {
		/* names: chip0 (package), chip0.core3 (a core) */
		while ((de = readdir(d)) != NULL) {
			if (strncmp(de->d_name, "chip", 4) != 0)
				continue;
			(void) snprintf(path, sizeof (path), "%s/%s", DIR_CPU,
			    de->d_name);
			if ((fd = open(path, O_RDONLY)) < 0)
				continue;
			(void) memset(&s, 0, sizeof (s));
			if (ioctl(fd, SENSOR_IOCTL_SCALAR, &s) == 0 &&
			    (c = to_celsius(&s)) > -1000) {
				if (strchr(de->d_name, '.') == NULL) {
					if (c > pkg)
						pkg = c;
				} else if (c > core) {
					core = c;
				}
			}
			(void) close(fd);
		}
		(void) closedir(d);
	}
	if (pkg > -1000)
		(void) printf("pkg %ld", pkg);
	else
		(void) printf("pkg -");
	if (core > -1000)
		(void) printf(" cores-max %ld\n", core);
	else
		(void) printf(" cores-max -\n");
	return (0);
}
