/*
 * libudev for solnix (illumos): the part of libudev that libinput's path
 * backend and COSMIC need, answered from /dev/input/event* and the driver's
 * devinfo properties, with no udevd, no sysfs and no netlink.
 *
 * Devices: every /dev/input/event<N> link. Its "syspath" is the /devices
 * node it points to (illumos has no /sys); subsystem "input"; sysname
 * event<N>; devnode the /dev/input path; properties from the
 * "udev-properties" string-array devinfo property of the node's driver
 * (ihid sets ID_INPUT=1, ID_INPUT_TOUCHPAD=1), plus ID_INPUT=1, DEVNAME and
 * SUBSYSTEM. Read with libdevinfo (no open of the node: an evdev open
 * switches the touchpad's mode).
 *
 * Enumeration filters on subsystem, sysname and property. A monitor is a
 * pipe that never becomes readable (no hotplug, as the illumos smithay udev
 * arm). hwdb, sysattr writes and the rest return NULL / -ENOSYS (STUB).
 *
 * The exported API and its semantics are libudev's (systemd, LGPL-2.1+);
 * this file is a new implementation, MIT licensed, like libinput.
 */
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/mkdev.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <libdevinfo.h>
#include <limits.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "libudev.h"

#define	EV_DIR	"/dev/input"
/* tests point this at a scratch dir (the negative control: no node there) */
#define	EV_DIR_ENV	"LIBUDEV_SOLNIX_INPUT_DIR"
#define	NPROP	16

struct udev {
	int	refs;
};

struct udev_list_entry {
	struct udev_list_entry	*next;
	char			*name, *value;
};

struct udev_device {
	int			refs;
	struct udev		*udev;
	char			*syspath, *devnode, *sysname, *devpath;
	dev_t			devnum;
	struct udev_list_entry	*props;
	struct udev_device	*parent;	/* lazily: none, ever */
};

struct udev_enumerate {
	int			refs;
	struct udev		*udev;
	char			*subsys[4], *sysname[4];
	int			nsubsys, nsysname;
	char			*pkey[4], *pval[4];
	int			nprop;
	struct udev_list_entry	*list;
};

struct udev_monitor {
	int		refs;
	struct udev	*udev;
	int		fd[2];
};

static char *
xstrdup(const char *s)
{
	return (s == NULL ? NULL : strdup(s));
}

static void
list_free(struct udev_list_entry *e)
{
	while (e != NULL) {
		struct udev_list_entry *n = e->next;
		free(e->name);
		free(e->value);
		free(e);
		e = n;
	}
}

/* append (keeps order: libudev lists are in insertion order) */
static int
list_add(struct udev_list_entry **head, const char *name, const char *value)
{
	struct udev_list_entry *e = calloc(1, sizeof (*e)), **pp;

	if (e == NULL || (e->name = strdup(name)) == NULL) {
		free(e);
		return (-1);
	}
	e->value = xstrdup(value);
	for (pp = head; *pp != NULL; pp = &(*pp)->next)
		;
	*pp = e;
	return (0);
}

static const char *
list_get(struct udev_list_entry *e, const char *name)
{
	for (; e != NULL; e = e->next)
		if (strcmp(e->name, name) == 0)
			return (e->value);
	return (NULL);
}

static void
prop_set(struct udev_list_entry **head, const char *kv)
{
	char k[128];
	const char *eq = strchr(kv, '=');
	size_t n;

	if (eq == NULL || (n = eq - kv) == 0 || n >= sizeof (k))
		return;
	memcpy(k, kv, n);
	k[n] = '\0';
	if (list_get(*head, k) == NULL)
		(void) list_add(head, k, eq + 1);
}

struct udev *
udev_new(void)
{
	struct udev *u = calloc(1, sizeof (*u));

	if (u != NULL)
		u->refs = 1;
	return (u);
}

struct udev *
udev_ref(struct udev *u)
{
	if (u != NULL)
		u->refs++;
	return (u);
}

struct udev *
udev_unref(struct udev *u)
{
	if (u != NULL && --u->refs == 0)
		free(u);
	return (NULL);
}

/* the driver's udev-properties, from the devinfo snapshot of one node */
static void
devinfo_props(const char *devpath, struct udev_list_entry **props)
{
	di_node_t root, node;
	char *p, path[PATH_MAX];
	int n, i;

	(void) strlcpy(path, devpath, sizeof (path));
	if ((p = strrchr(path, ':')) != NULL)	/* minor name */
		*p = '\0';
	root = di_init(path, DINFOSUBTREE | DINFOPROP);
	if (root == DI_NODE_NIL)
		return;
	node = root;
	n = di_prop_lookup_strings(DDI_DEV_T_ANY, node, "udev-properties", &p);
	for (i = 0; i < n && i < NPROP; i++) {
		prop_set(props, p);
		p += strlen(p) + 1;
	}
	di_fini(root);
}

/* build a device from a /dev/input/event<N> path */
static struct udev_device *
dev_from_node(struct udev *u, const char *devnode)
{
	struct udev_device *d;
	char sp[PATH_MAX], *rp, num[32];
	const char *base = strrchr(devnode, '/');
	struct stat st;

	if (base == NULL || strncmp(base + 1, "event", 5) != 0 ||
	    stat(devnode, &st) != 0 || !S_ISCHR(st.st_mode))
		return (NULL);
	if ((rp = realpath(devnode, sp)) == NULL || strncmp(rp, "/devices/", 9))
		return (NULL);
	if ((d = calloc(1, sizeof (*d))) == NULL)
		return (NULL);
	d->refs = 1;
	d->udev = udev_ref(u);
	d->syspath = strdup(rp);
	d->devpath = strdup(rp + 8);		/* "/pci@0,0/..." */
	d->devnode = strdup(devnode);
	d->sysname = strdup(base + 1);
	d->devnum = st.st_rdev;
	devinfo_props(rp + 8, &d->props);
	prop_set(&d->props, "ID_INPUT=1");
	(void) list_add(&d->props, "SUBSYSTEM", "input");
	(void) list_add(&d->props, "DEVNAME", devnode);
	(void) snprintf(num, sizeof (num), "%lu", (ulong_t)major(st.st_rdev));
	(void) list_add(&d->props, "MAJOR", num);
	(void) snprintf(num, sizeof (num), "%lu", (ulong_t)minor(st.st_rdev));
	(void) list_add(&d->props, "MINOR", num);
	if (d->syspath == NULL || d->devpath == NULL || d->devnode == NULL ||
	    d->sysname == NULL)
		return (udev_device_unref(d));
	return (d);
}

/* call fn for each /dev/input/event* link; stop when fn returns non-zero */
static int
each_node(int (*fn)(const char *, void *), void *arg)
{
	const char *dn = getenv(EV_DIR_ENV) != NULL ? getenv(EV_DIR_ENV) : EV_DIR;
	DIR *dir = opendir(dn);
	struct dirent *de;
	char p[PATH_MAX];
	int r = 0;

	if (dir == NULL)
		return (0);
	while (r == 0 && (de = readdir(dir)) != NULL) {
		if (strncmp(de->d_name, "event", 5) != 0)
			continue;
		(void) snprintf(p, sizeof (p), "%s/%s", dn, de->d_name);
		r = fn(p, arg);
	}
	(void) closedir(dir);
	return (r);
}

/*
 * An evdev open of ihid clones: the fd's minor is node minor | client << 8
 * (ihid.c IHID_EV_BIT), so libinput's fstat()-then-new_from_devnum (its
 * same-syspath check) must find the node from a client minor too.
 */
static int
devnum_match(dev_t fd, dev_t node)
{
	return (fd == node || (major(fd) == major(node) &&
	    (minor(fd) & 0xff) == minor(node)));
}

struct find {
	struct udev	*u;
	dev_t		devnum;
	const char	*syspath, *sysname;
	struct udev_device *found;
};

static int
find_cb(const char *node, void *arg)
{
	struct find *f = arg;
	struct udev_device *d = dev_from_node(f->u, node);

	if (d == NULL)
		return (0);
	if ((f->syspath != NULL && strcmp(f->syspath, d->syspath) == 0) ||
	    (f->sysname != NULL && strcmp(f->sysname, d->sysname) == 0) ||
	    (f->syspath == NULL && f->sysname == NULL &&
	    devnum_match(f->devnum, d->devnum))) {
		f->found = d;
		return (1);
	}
	(void) udev_device_unref(d);
	return (0);
}

struct udev_device *
udev_device_new_from_devnum(struct udev *u, char type, dev_t devnum)
{
	struct find f = { u, devnum, NULL, NULL, NULL };

	if (u == NULL || type != 'c') {
		errno = EINVAL;
		return (NULL);
	}
	(void) each_node(find_cb, &f);
	if (f.found == NULL)
		errno = ENODEV;
	return (f.found);
}

struct udev_device *
udev_device_new_from_syspath(struct udev *u, const char *syspath)
{
	struct find f = { u, 0, syspath, NULL, NULL };

	if (u == NULL || syspath == NULL) {
		errno = EINVAL;
		return (NULL);
	}
	(void) each_node(find_cb, &f);
	if (f.found == NULL)
		errno = ENODEV;
	return (f.found);
}

struct udev_device *
udev_device_new_from_subsystem_sysname(struct udev *u, const char *subsys,
    const char *sysname)
{
	struct find f = { u, 0, NULL, sysname, NULL };

	if (u == NULL || subsys == NULL || sysname == NULL ||
	    strcmp(subsys, "input") != 0) {
		errno = ENODEV;
		return (NULL);
	}
	(void) each_node(find_cb, &f);
	if (f.found == NULL)
		errno = ENODEV;
	return (f.found);
}

struct udev_device *
udev_device_new_from_device_id(struct udev *u, const char *id)
{
	(void) u;
	(void) id;
	errno = ENOSYS;		/* STUB */
	return (NULL);
}

struct udev_device *
udev_device_new_from_environment(struct udev *u)
{
	(void) u;
	errno = ENOSYS;		/* STUB */
	return (NULL);
}

struct udev_device *
udev_device_ref(struct udev_device *d)
{
	if (d != NULL)
		d->refs++;
	return (d);
}

struct udev_device *
udev_device_unref(struct udev_device *d)
{
	if (d == NULL || --d->refs > 0)
		return (NULL);
	free(d->syspath);
	free(d->devpath);
	free(d->devnode);
	free(d->sysname);
	list_free(d->props);
	(void) udev_unref(d->udev);
	free(d);
	return (NULL);
}

struct udev *
udev_device_get_udev(struct udev_device *d)
{
	return (d == NULL ? NULL : d->udev);
}

/* no parent devices: libinput walks parents only for optional props */
struct udev_device *
udev_device_get_parent(struct udev_device *d)
{
	(void) d;
	errno = ENOENT;
	return (NULL);
}

struct udev_device *
udev_device_get_parent_with_subsystem_devtype(struct udev_device *d,
    const char *subsys, const char *devtype)
{
	(void) d;
	(void) subsys;
	(void) devtype;
	errno = ENOENT;
	return (NULL);
}

const char *
udev_device_get_devpath(struct udev_device *d)
{
	return (d == NULL ? NULL : d->devpath);
}

const char *
udev_device_get_subsystem(struct udev_device *d)
{
	return (d == NULL ? NULL : "input");
}

const char *
udev_device_get_devtype(struct udev_device *d)
{
	(void) d;
	return (NULL);
}

const char *
udev_device_get_syspath(struct udev_device *d)
{
	return (d == NULL ? NULL : d->syspath);
}

const char *
udev_device_get_sysname(struct udev_device *d)
{
	return (d == NULL ? NULL : d->sysname);
}

const char *
udev_device_get_sysnum(struct udev_device *d)
{
	return (d == NULL ? NULL : d->sysname + 5);
}

const char *
udev_device_get_devnode(struct udev_device *d)
{
	return (d == NULL ? NULL : d->devnode);
}

int
udev_device_get_is_initialized(struct udev_device *d)
{
	return (d != NULL);
}

struct udev_list_entry *
udev_device_get_devlinks_list_entry(struct udev_device *d)
{
	(void) d;
	return (NULL);
}

struct udev_list_entry *
udev_device_get_properties_list_entry(struct udev_device *d)
{
	return (d == NULL ? NULL : d->props);
}

struct udev_list_entry *
udev_device_get_tags_list_entry(struct udev_device *d)
{
	(void) d;
	return (NULL);
}

struct udev_list_entry *
udev_device_get_current_tags_list_entry(struct udev_device *d)
{
	(void) d;
	return (NULL);
}

struct udev_list_entry *
udev_device_get_sysattr_list_entry(struct udev_device *d)
{
	(void) d;
	return (NULL);
}

const char *
udev_device_get_property_value(struct udev_device *d, const char *key)
{
	return (d == NULL || key == NULL ? NULL : list_get(d->props, key));
}

const char *
udev_device_get_driver(struct udev_device *d)
{
	(void) d;
	return (NULL);
}

dev_t
udev_device_get_devnum(struct udev_device *d)
{
	return (d == NULL ? 0 : d->devnum);
}

const char *
udev_device_get_action(struct udev_device *d)
{
	(void) d;
	return (NULL);
}

unsigned long long
udev_device_get_seqnum(struct udev_device *d)
{
	(void) d;
	return (0);
}

unsigned long long
udev_device_get_usec_since_initialized(struct udev_device *d)
{
	(void) d;
	return (0);
}

const char *
udev_device_get_sysattr_value(struct udev_device *d, const char *attr)
{
	(void) d;
	(void) attr;
	return (NULL);
}

int
udev_device_set_sysattr_value(struct udev_device *d, const char *attr,
    const char *value)
{
	(void) d;
	(void) attr;
	(void) value;
	return (-ENOSYS);	/* STUB */
}

int
udev_device_has_tag(struct udev_device *d, const char *tag)
{
	(void) d;
	(void) tag;
	return (0);
}

int
udev_device_has_current_tag(struct udev_device *d, const char *tag)
{
	(void) d;
	(void) tag;
	return (0);
}

/* list entries */
struct udev_list_entry *
udev_list_entry_get_next(struct udev_list_entry *e)
{
	return (e == NULL ? NULL : e->next);
}

struct udev_list_entry *
udev_list_entry_get_by_name(struct udev_list_entry *e, const char *name)
{
	for (; e != NULL; e = e->next)
		if (strcmp(e->name, name) == 0)
			return (e);
	return (NULL);
}

const char *
udev_list_entry_get_name(struct udev_list_entry *e)
{
	return (e == NULL ? NULL : e->name);
}

const char *
udev_list_entry_get_value(struct udev_list_entry *e)
{
	return (e == NULL ? NULL : e->value);
}

/* enumeration */
struct udev_enumerate *
udev_enumerate_new(struct udev *u)
{
	struct udev_enumerate *e;

	if (u == NULL) {
		errno = EINVAL;
		return (NULL);
	}
	if ((e = calloc(1, sizeof (*e))) == NULL)
		return (NULL);
	e->refs = 1;
	e->udev = udev_ref(u);
	return (e);
}

struct udev_enumerate *
udev_enumerate_ref(struct udev_enumerate *e)
{
	if (e != NULL)
		e->refs++;
	return (e);
}

struct udev_enumerate *
udev_enumerate_unref(struct udev_enumerate *e)
{
	int i;

	if (e == NULL || --e->refs > 0)
		return (NULL);
	for (i = 0; i < e->nsubsys; i++)
		free(e->subsys[i]);
	for (i = 0; i < e->nsysname; i++)
		free(e->sysname[i]);
	for (i = 0; i < e->nprop; i++) {
		free(e->pkey[i]);
		free(e->pval[i]);
	}
	list_free(e->list);
	(void) udev_unref(e->udev);
	free(e);
	return (NULL);
}

struct udev *
udev_enumerate_get_udev(struct udev_enumerate *e)
{
	return (e == NULL ? NULL : e->udev);
}

int
udev_enumerate_add_match_subsystem(struct udev_enumerate *e, const char *s)
{
	if (e == NULL || s == NULL)
		return (-EINVAL);
	if (e->nsubsys == 4)
		return (-ENOMEM);
	e->subsys[e->nsubsys++] = strdup(s);
	return (0);
}

int
udev_enumerate_add_match_sysname(struct udev_enumerate *e, const char *s)
{
	if (e == NULL || s == NULL)
		return (-EINVAL);
	if (e->nsysname == 4)
		return (-ENOMEM);
	e->sysname[e->nsysname++] = strdup(s);
	return (0);
}

int
udev_enumerate_add_match_property(struct udev_enumerate *e, const char *k,
    const char *v)
{
	if (e == NULL || k == NULL)
		return (-EINVAL);
	if (e->nprop == 4)
		return (-ENOMEM);
	e->pkey[e->nprop] = strdup(k);
	e->pval[e->nprop++] = xstrdup(v);
	return (0);
}

/* matches that this shim accepts and ignores (every device qualifies) */
int
udev_enumerate_add_match_is_initialized(struct udev_enumerate *e)
{
	return (e == NULL ? -EINVAL : 0);
}

int
udev_enumerate_add_match_tag(struct udev_enumerate *e, const char *t)
{
	(void) t;
	return (e == NULL ? -EINVAL : 0);
}

int
udev_enumerate_add_match_sysattr(struct udev_enumerate *e, const char *a,
    const char *v)
{
	(void) a;
	(void) v;
	return (e == NULL ? -EINVAL : 0);
}

int
udev_enumerate_add_nomatch_sysattr(struct udev_enumerate *e, const char *a,
    const char *v)
{
	(void) a;
	(void) v;
	return (e == NULL ? -EINVAL : 0);
}

int
udev_enumerate_add_nomatch_subsystem(struct udev_enumerate *e, const char *s)
{
	(void) s;
	return (e == NULL ? -EINVAL : 0);
}

int
udev_enumerate_add_match_parent(struct udev_enumerate *e,
    struct udev_device *p)
{
	(void) p;
	return (e == NULL ? -EINVAL : 0);
}

int
udev_enumerate_add_syspath(struct udev_enumerate *e, const char *syspath)
{
	if (e == NULL || syspath == NULL)
		return (-EINVAL);
	return (list_add(&e->list, syspath, NULL) == 0 ? 0 : -ENOMEM);
}

static int
fnmatch_simple(const char *pat, const char *s)
{
	/* '*' suffix only: enough for "event*" and exact names */
	size_t n = strlen(pat);

	if (n > 0 && pat[n - 1] == '*')
		return (strncmp(pat, s, n - 1) == 0);
	return (strcmp(pat, s) == 0);
}

static int
scan_cb(const char *node, void *arg)
{
	struct udev_enumerate *e = arg;
	struct udev_device *d = dev_from_node(e->udev, node);
	int i, ok = 1;

	if (d == NULL)
		return (0);
	for (i = 0, ok = e->nsubsys == 0; i < e->nsubsys; i++)
		ok |= strcmp(e->subsys[i], "input") == 0;
	if (ok && e->nsysname > 0) {
		for (i = 0, ok = 0; i < e->nsysname; i++)
			ok |= fnmatch_simple(e->sysname[i], d->sysname);
	}
	if (ok && e->nprop > 0) {
		for (i = 0, ok = 0; i < e->nprop; i++) {
			const char *v = list_get(d->props, e->pkey[i]);
			ok |= v != NULL && (e->pval[i] == NULL ||
			    fnmatch_simple(e->pval[i], v));
		}
	}
	if (ok && list_get(e->list, d->syspath) == NULL)
		(void) list_add(&e->list, d->syspath, NULL);
	(void) udev_device_unref(d);
	return (0);
}

int
udev_enumerate_scan_devices(struct udev_enumerate *e)
{
	if (e == NULL)
		return (-EINVAL);
	(void) each_node(scan_cb, e);
	return (0);
}

int
udev_enumerate_scan_subsystems(struct udev_enumerate *e)
{
	if (e == NULL)
		return (-EINVAL);
	return (list_add(&e->list, "/devices/input", NULL) == 0 ? 0 : -ENOMEM);
}

struct udev_list_entry *
udev_enumerate_get_list_entry(struct udev_enumerate *e)
{
	return (e == NULL ? NULL : e->list);
}

/* monitor: a pipe that never becomes readable (no hotplug) */
struct udev_monitor *
udev_monitor_new_from_netlink(struct udev *u, const char *name)
{
	struct udev_monitor *m;

	(void) name;
	if (u == NULL || (m = calloc(1, sizeof (*m))) == NULL)
		return (NULL);
	if (pipe(m->fd) != 0) {
		free(m);
		return (NULL);
	}
	(void) fcntl(m->fd[0], F_SETFD, FD_CLOEXEC);
	(void) fcntl(m->fd[1], F_SETFD, FD_CLOEXEC);
	(void) fcntl(m->fd[0], F_SETFL, O_NONBLOCK);
	m->refs = 1;
	m->udev = udev_ref(u);
	return (m);
}

struct udev_monitor *
udev_monitor_ref(struct udev_monitor *m)
{
	if (m != NULL)
		m->refs++;
	return (m);
}

struct udev_monitor *
udev_monitor_unref(struct udev_monitor *m)
{
	if (m == NULL || --m->refs > 0)
		return (NULL);
	(void) close(m->fd[0]);
	(void) close(m->fd[1]);
	(void) udev_unref(m->udev);
	free(m);
	return (NULL);
}

struct udev *
udev_monitor_get_udev(struct udev_monitor *m)
{
	return (m == NULL ? NULL : m->udev);
}

int
udev_monitor_enable_receiving(struct udev_monitor *m)
{
	return (m == NULL ? -EINVAL : 0);
}

int
udev_monitor_set_receive_buffer_size(struct udev_monitor *m, int size)
{
	(void) size;
	return (m == NULL ? -EINVAL : 0);
}

int
udev_monitor_get_fd(struct udev_monitor *m)
{
	return (m == NULL ? -EINVAL : m->fd[0]);
}

struct udev_device *
udev_monitor_receive_device(struct udev_monitor *m)
{
	(void) m;
	errno = EAGAIN;
	return (NULL);
}

int
udev_monitor_filter_add_match_subsystem_devtype(struct udev_monitor *m,
    const char *s, const char *t)
{
	(void) s;
	(void) t;
	return (m == NULL ? -EINVAL : 0);
}

int
udev_monitor_filter_add_match_tag(struct udev_monitor *m, const char *t)
{
	(void) t;
	return (m == NULL ? -EINVAL : 0);
}

int
udev_monitor_filter_update(struct udev_monitor *m)
{
	return (m == NULL ? -EINVAL : 0);
}

int
udev_monitor_filter_remove(struct udev_monitor *m)
{
	return (m == NULL ? -EINVAL : 0);
}

/* hwdb: none (STUB) */
struct udev_hwdb *
udev_hwdb_new(struct udev *u)
{
	(void) u;
	errno = ENOSYS;
	return (NULL);
}

struct udev_hwdb *
udev_hwdb_ref(struct udev_hwdb *h)
{
	return (h);
}

struct udev_hwdb *
udev_hwdb_unref(struct udev_hwdb *h)
{
	(void) h;
	return (NULL);
}

struct udev_list_entry *
udev_hwdb_get_properties_list_entry(struct udev_hwdb *h, const char *m,
    unsigned flags)
{
	(void) h;
	(void) m;
	(void) flags;
	return (NULL);
}

/* logging and queue: accepted, unused */
void
udev_set_log_fn(struct udev *u, void (*fn)(struct udev *, int, const char *,
    int, const char *, const char *, va_list))
{
	(void) u;
	(void) fn;
}

int
udev_get_log_priority(struct udev *u)
{
	(void) u;
	return (0);
}

void
udev_set_log_priority(struct udev *u, int p)
{
	(void) u;
	(void) p;
}

void *
udev_get_userdata(struct udev *u)
{
	(void) u;
	return (NULL);
}

void
udev_set_userdata(struct udev *u, void *d)
{
	(void) u;
	(void) d;
}

struct udev_queue *
udev_queue_new(struct udev *u)
{
	(void) u;
	errno = ENOSYS;
	return (NULL);
}

struct udev_queue *
udev_queue_unref(struct udev_queue *q)
{
	(void) q;
	return (NULL);
}

int
udev_queue_get_udev_is_active(struct udev_queue *q)
{
	(void) q;
	return (0);
}

int
udev_queue_get_queue_is_empty(struct udev_queue *q)
{
	(void) q;
	return (1);
}
