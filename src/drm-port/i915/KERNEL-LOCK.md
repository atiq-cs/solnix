# What KERNEL_LOCK protected, and what stands in for it

The OpenBSD drm code runs every drm ioctl under the kernel big lock. Parts of
its Linux compat layer depend on that: `drm_linux.c`'s idr asserts
`KERNEL_ASSERT_LOCKED()`, its comment says "we rely on the kernel lock to make
this work", and `rcu_read_lock()` is a no-op (`kfree_rcu` and `call_rcu` free
right away). In this port `KERNEL_LOCK` is a no-op (`obsd-compat/obsd_kern.h`)
and `i915_il_ioctl` calls `drmioctl` with no lock held. So ioctls from threads
that share one drm fd (Mesa's GL threads, cosmic-comp's threads) run in
parallel through code that OpenBSD only ever runs one thread at a time.

## The panic this caused (lixi, BE solnix-51, vmdump.4)

`kernel heap corruption detected ... cache: drmobj`. In the dump, one GEM
object had been over-released: something dropped a reference it did not own.
After that, every unconditional `kref_get` took the count from 0 to 1 and the
next put took it back to 0. OpenBSD's `kref_get` is a plain atomic increment,
so each cycle queued the object for freeing again. The free worker freed it
about 10.5 M times, and each time kmem handed the buffer to a new allocation
(cosmic-comp's new context ring) and then destroyed that allocation live.
cosmic-comp was the first victim, not the cause. A non-debug dump cannot name
the first bad put. Three races in this file can produce one. They are listed
below, and this change fixes all three.

## Why not one lock across the whole ioctl

OpenBSD gives up the big lock whenever a thread sleeps (`mi_switch`), so an
ioctl blocked in `rw_enter`, `tsleep` or a GPU wait lets the others run. The
port's blocking primitives are illumos mutexes and condition variables, which
release nothing. A device lock held across `drmioctl` would therefore
serialise every GPU wait behind every other one, and it would deadlock
whenever one ioctl waits for work that another ioctl has to do. So the fix
gives each data structure the protection the big lock gave it.

## Every structure that relied on it, and what covers it now

`obsd-idrlock.patch` (`drm_linux.c`): `obsd_idr_mtx` is a leaf mutex. It is
held around every `SPLAY_*` call on an idr or xarray tree, and around the
shared idr preload entry. Nothing allocates, frees, sleeps or calls out while
holding it.

| structure | the unlocked race | covered by |
|---|---|---|
| `idr_entry_cache` (one global preload entry) | `idr_preload`/`idr_alloc` read it, then clear it. Two threads (on any two files) can take the same entry and insert it into two trees, so file A's handle points at file B's object, and A's GEM_CLOSE or file close puts B's object | `obsd_idr_mtx` (take it and clear it in one step) |
| every idr/xarray splay tree | `SPLAY_FIND`/`SPLAY_MIN`/`SPLAY_NEXT` rotate the tree, so every lookup also writes. `idr_find` on `file->object_idr` from `i915_gem_object_lookup` (no lock) runs against the table_lock-held alloc/replace/remove: the tree corrupts and a handle names the wrong object | `obsd_idr_mtx` in `idr_*`, `__xa_*`, `xa_get_next`, `xa_destroy` |
| `idr_for_each` callbacks | they ran inside the tree walk | the walk visits one entry at a time with a lower-bound lookup, and the callback runs unlocked |

`obsd-rculookup.patch` (i915 gem). These lookups rely on RCU to keep the
object alive between the lookup and the reference. With no RCU, they take the
lock their writers hold instead:

| lookup | before | now |
|---|---|---|
| `i915_gem_object_lookup` (`i915_gem_object.h`) | `idr_find` + `kref_get_unless_zero` under `rcu_read_lock` only, racing GEM_CLOSE's final put and free | `file->table_lock` (the lock `drm_gem_handle_delete` holds while it removes the handle, as `drm_gem_objects_lookup` already does) |
| `i915_gem_busy_ioctl`, `i915_gem_get_caching_ioctl`, `i915_gem_get_tiling_ioctl` | `i915_gem_object_lookup_rcu`: they used the object with **no** reference | take a reference with `i915_gem_object_lookup` and put it afterwards |
| `__context_lookup`, `i915_gem_throttle_ioctl` (`context_xa`) | `xa_load`/`xa_for_each` + `kref_get_unless_zero` under RCU only | `xa_lock(&context_xa)` (xa_store/xa_erase hold it) |
| `eb_lookup_vma` (`ctx->handles_vma`, every execbuf) | `radix_tree_lookup` + `i915_vma_tryget` under RCU only | `ctx->lut_mutex` (every insert and delete holds it) |
| `__i915_gem_object_page_iter_get_sg` lookup path | `radix_tree_lookup` under RCU against inserts under `iter->lock` (an insert grows `rnode` and then `height`, in two steps) | `iter->lock` (the function already sleeps: `might_sleep`) |

## Already covered by their own locks (checked; no change)

`dev->files` (`drm_find_file_by_minor`, a splay tree): every caller holds
`dev->filelist_mutex` (drm_drv.c, drm_ioctl.c, drm_gem.c, i915_drmglue.c,
nvidia_drm_glue.c). `drm_gem_objects_lookup` and `drm_show_memory_stats`,
`i915_drm_client` fdinfo: `table_lock`. `object_name_idr`:
`object_name_lock`. `mode_config.object_idr` and `tile_idr`: `idr_mutex`.
`syncobj_idr`: `syncobj_table_lock`. `magic_map`: `master_mutex`.
`proto_context_xa`, `vm_xa`: `proto_context_lock` / `xa_lock`.
`drm_minors_xa`: `xa_lock`. `execbuffer.c` `__eb_add_lut`'s `idr_find`: under
`obj->lut_lock`, and the tree itself under `obsd_idr_mtx` now.

## Known remaining (not fixed here)

- `perf->metrics_idr` (`i915_perf_get_oa_config`, `i915_query` x3) looks up an
  object under RCU only, and its writers hold `metrics_lock`. The tree is safe
  now, but the lifetime is not. Only the OA perf interface reaches it, and no
  desktop client uses that.
- dma-resv's unlocked fence iteration (`dma_resv_iter_*_unlocked`, used by
  busy) relies on RCU to keep `dma_resv_list` alive, and the compat's
  `kfree_rcu` frees it at once. That one needs real RCU (or a deferred free).
- `i915_gem_mman.c`'s mmap offset lookups take `get_rcu` inside
  `drm_vma_offset_lock_lookup`, which is the Linux pattern, and they are safe
  under that lock.

## Defence in depth: Linux refcount_t semantics

`obsd-refcount.patch` (`linux/kref.h`, `linux/refcount.h`) plus
`obsd_refcount_warn` in `obsd-compat/obsd_kern.c`. Linux's kref is a
`refcount_t`: an increment from 0 or a decrement below 0 prints a WARN and
pins the count at `REFCOUNT_SATURATED`, so the object leaks instead of being
released twice. OpenBSD's kref has no such check. The port now does what Linux
does. The first event logs the caller's stack (`getpcstack` +
`kobj_getsymname`) to /var/adm/messages, so the next stray put names its
culprit instead of corrupting the heap.

`make -C src/drm-port/i915 test-kref OBSD=...` builds the two headers as the
driver build patches them and runs the vmdump.4 sequence through them: a
stray put to 0, then a get from 0 and a put. It must release the object once
and report. The negative control, the headers without obsd-refcount.patch,
releases the object twice and must fail.

## Test

`src/drm-port/i915/test/test_idr_race.c` (`make -C src/drm-port/i915
test-idr OBSD=...`) compiles the idr/xarray section of the patched
`drm_linux.c` into a userland program and hammers it from threads sharing one
idr: handle alloc/find/remove, `idr_for_each`, and two other "files" sharing
the preload entry. The negative control is the same test built from the
unpatched `drm_linux.c`, and it must fail (a lost or duplicated entry, a handle
that names another file's object, or a broken tree).
