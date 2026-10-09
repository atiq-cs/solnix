/*
 * n80211_symrename.h -- give the module's own copies of kernel-exported names
 * private symbols.
 *
 * krtld binds every non-local symbol of a loading module that the kernel
 * already defines to the KERNEL's definition, even when the module defines
 * it too (uts/common/krtld/kobj.c do_symbols, :3020-3024: kobj_lookup_all ->
 * st_shndx = SHN_ABS, st_value = kernel's). So a module function named
 * taskq_destroy would silently become illumos taskq_destroy(taskq_t *) at
 * every call site, and the OpenBSD MD5/SHA1 contexts would be handed to the
 * kernel's differently-laid-out implementations. Measured on dixi: the
 * linked iwm module defined exactly these 9 kernel-exported names (plus the
 * expected _init/_fini/_info). MD5Init/Update/Final and SHA1Init/Update/Final
 * are renamed in compat/crypto/{md5,sha1}.h instead, where every user of them
 * (including n80211_crypto.c, which takes no prelude) declares them. Renaming
 * the rest here, in a header every OpenBSD
 * translation unit force-includes, renames definitions and callers alike.
 * build-dixi.sh fails the build if the intersection ever grows again.
 */
#ifndef _N80211_SYMRENAME_H
#define _N80211_SYMRENAME_H
#define taskq_destroy		n80211_taskq_destroy
#define suser			n80211_suser
#define etherbroadcastaddr	n80211_etherbroadcastaddr
#define etheranyaddr		n80211_etheranyaddr
#endif /* _N80211_SYMRENAME_H */
