/*
 * libudev.h -- solnix's libudev (libudev-solnix.c): the libudev API that
 * libinput and the Rust udev crate call. MIT, see libudev-solnix.c.
 */
#ifndef	_LIBUDEV_H_
#define	_LIBUDEV_H_

#include <stdarg.h>
#include <sys/types.h>

#ifdef	__cplusplus
extern "C" {
#endif

struct udev;
struct udev_list_entry;
struct udev_device;
struct udev_enumerate;
struct udev_monitor;
struct udev_hwdb;
struct udev_queue;

#define	udev_list_entry_foreach(e, first) \
	for ((e) = (first); (e) != NULL; (e) = udev_list_entry_get_next(e))

struct udev * udev_new(void);
struct udev * udev_ref(struct udev *u);
struct udev * udev_unref(struct udev *u);
struct udev_device * udev_device_new_from_devnum(struct udev *u, char type, dev_t devnum);
struct udev_device * udev_device_new_from_syspath(struct udev *u, const char *syspath);
struct udev_device * udev_device_new_from_subsystem_sysname(struct udev *u, const char *subsys, const char *sysname);
struct udev_device * udev_device_new_from_device_id(struct udev *u, const char *id);
struct udev_device * udev_device_new_from_environment(struct udev *u);
struct udev_device * udev_device_ref(struct udev_device *d);
struct udev_device * udev_device_unref(struct udev_device *d);
struct udev * udev_device_get_udev(struct udev_device *d);
struct udev_device * udev_device_get_parent(struct udev_device *d);
struct udev_device * udev_device_get_parent_with_subsystem_devtype(struct udev_device *d, const char *subsys, const char *devtype);
const char * udev_device_get_devpath(struct udev_device *d);
const char * udev_device_get_subsystem(struct udev_device *d);
const char * udev_device_get_devtype(struct udev_device *d);
const char * udev_device_get_syspath(struct udev_device *d);
const char * udev_device_get_sysname(struct udev_device *d);
const char * udev_device_get_sysnum(struct udev_device *d);
const char * udev_device_get_devnode(struct udev_device *d);
int udev_device_get_is_initialized(struct udev_device *d);
struct udev_list_entry * udev_device_get_devlinks_list_entry(struct udev_device *d);
struct udev_list_entry * udev_device_get_properties_list_entry(struct udev_device *d);
struct udev_list_entry * udev_device_get_tags_list_entry(struct udev_device *d);
struct udev_list_entry * udev_device_get_current_tags_list_entry(struct udev_device *d);
struct udev_list_entry * udev_device_get_sysattr_list_entry(struct udev_device *d);
const char * udev_device_get_property_value(struct udev_device *d, const char *key);
const char * udev_device_get_driver(struct udev_device *d);
dev_t udev_device_get_devnum(struct udev_device *d);
const char * udev_device_get_action(struct udev_device *d);
unsigned long long udev_device_get_seqnum(struct udev_device *d);
unsigned long long udev_device_get_usec_since_initialized(struct udev_device *d);
const char * udev_device_get_sysattr_value(struct udev_device *d, const char *attr);
int udev_device_set_sysattr_value(struct udev_device *d, const char *attr, const char *value);
int udev_device_has_tag(struct udev_device *d, const char *tag);
int udev_device_has_current_tag(struct udev_device *d, const char *tag);
struct udev_list_entry * udev_list_entry_get_next(struct udev_list_entry *e);
struct udev_list_entry * udev_list_entry_get_by_name(struct udev_list_entry *e, const char *name);
const char * udev_list_entry_get_name(struct udev_list_entry *e);
const char * udev_list_entry_get_value(struct udev_list_entry *e);
struct udev_enumerate * udev_enumerate_new(struct udev *u);
struct udev_enumerate * udev_enumerate_ref(struct udev_enumerate *e);
struct udev_enumerate * udev_enumerate_unref(struct udev_enumerate *e);
struct udev * udev_enumerate_get_udev(struct udev_enumerate *e);
int udev_enumerate_add_match_subsystem(struct udev_enumerate *e, const char *s);
int udev_enumerate_add_match_sysname(struct udev_enumerate *e, const char *s);
int udev_enumerate_add_match_property(struct udev_enumerate *e, const char *k, const char *v);
int udev_enumerate_add_match_is_initialized(struct udev_enumerate *e);
int udev_enumerate_add_match_tag(struct udev_enumerate *e, const char *t);
int udev_enumerate_add_match_sysattr(struct udev_enumerate *e, const char *a, const char *v);
int udev_enumerate_add_nomatch_sysattr(struct udev_enumerate *e, const char *a, const char *v);
int udev_enumerate_add_nomatch_subsystem(struct udev_enumerate *e, const char *s);
int udev_enumerate_add_match_parent(struct udev_enumerate *e, struct udev_device *p);
int udev_enumerate_add_syspath(struct udev_enumerate *e, const char *syspath);
int udev_enumerate_scan_devices(struct udev_enumerate *e);
int udev_enumerate_scan_subsystems(struct udev_enumerate *e);
struct udev_list_entry * udev_enumerate_get_list_entry(struct udev_enumerate *e);
struct udev_monitor * udev_monitor_new_from_netlink(struct udev *u, const char *name);
struct udev_monitor * udev_monitor_ref(struct udev_monitor *m);
struct udev_monitor * udev_monitor_unref(struct udev_monitor *m);
struct udev * udev_monitor_get_udev(struct udev_monitor *m);
int udev_monitor_enable_receiving(struct udev_monitor *m);
int udev_monitor_set_receive_buffer_size(struct udev_monitor *m, int size);
int udev_monitor_get_fd(struct udev_monitor *m);
struct udev_device * udev_monitor_receive_device(struct udev_monitor *m);
int udev_monitor_filter_add_match_subsystem_devtype(struct udev_monitor *m, const char *s, const char *t);
int udev_monitor_filter_add_match_tag(struct udev_monitor *m, const char *t);
int udev_monitor_filter_update(struct udev_monitor *m);
int udev_monitor_filter_remove(struct udev_monitor *m);
struct udev_hwdb * udev_hwdb_new(struct udev *u);
struct udev_hwdb * udev_hwdb_ref(struct udev_hwdb *h);
struct udev_hwdb * udev_hwdb_unref(struct udev_hwdb *h);
struct udev_list_entry * udev_hwdb_get_properties_list_entry(struct udev_hwdb *h, const char *m, unsigned flags);
void udev_set_log_fn(struct udev *u, void (*fn)(struct udev *, int, const char *, int, const char *, const char *, va_list));
int udev_get_log_priority(struct udev *u);
void udev_set_log_priority(struct udev *u, int p);
void * udev_get_userdata(struct udev *u);
void udev_set_userdata(struct udev *u, void *d);
struct udev_queue * udev_queue_new(struct udev *u);
struct udev_queue * udev_queue_unref(struct udev_queue *q);
int udev_queue_get_udev_is_active(struct udev_queue *q);
int udev_queue_get_queue_is_empty(struct udev_queue *q);

#ifdef	__cplusplus
}
#endif

#endif	/* _LIBUDEV_H_ */
