# You're at `solnix console login:` on the X1 — what to do next

## Log in

```
login: root
```

Press **Enter** at the password prompt. The live media sets root's password to **empty** and
`PASSREQ=NO` (`oi-make-livecd.sh:1057-1060`). Shell is `ksh93`.

## First: the big win in that boot

Your NVMe SSD attached. From the console:

```
/pci@0,0/pci8086,a340@1b/pci15b7,5009@0/blkdev@w001B448B485502D1,0 (blkdev0) online
```

`pci15b7,5009` is the SanDisk/WD NVMe controller. **`blkdev0` came online** — the failure I had
flagged as most likely (illumos not seeing the drive) did not happen. The kernel also completed a full
device-tree attach.

## But do NOT run the installer yet

Two errors in that boot block installation:

```
internal error: failed to initialize ZFS
svc:/system/filesystem/local:default: WARNING: /usr/sbin/zfs mount -a failed: exit status 1
```

`libzfs` failed to initialise on the live media, and `solnix-install` needs ZFS to create `rpool`.
Running it now would likely fail partway — possibly *after* it has begun writing to the disk.

## Please run these four commands and send the output

```
# 1. does ZFS work at all?
zpool list
zfs list

# 2. WHY did libzfs fail? this is the key one
ldd /usr/sbin/zfs | grep -i 'not found'

# 3. is the kernel module actually loaded?
modinfo | grep -i zfs

# 4. does the installer see your disk?
format </dev/null
```

`format` lists disks and exits on Ctrl-D; it should show your NVMe as something like `c1t...d0`.
Note the exact name — that is the argument `solnix-install` takes.

## What the `ldd` output will tell us

If it prints missing libraries, the live ramdisk is missing part of the ZFS userland closure — the
same class of bug as the `readlink` defect that silently dropped 13 `/dev` nodes. That is a media
build fix, and a quick one.

## Also seen, lower priority

* `ttymon: open /dev/sad/user failed` — the STREAMS autopush device is absent, so `ttymon` is
  degraded. Login still works.
* `Invalid Report Descriptor` (repeated, `pci17aa,2267`) — a USB HID device the driver dislikes.
  Harmless noise.
* `WARNING: Failed to convert socket to TPI (err=2)` — also seen on our EC2 boots; not X1-specific.

## Do not reboot yet

Everything above is readable from the live session. Once we know why `libzfs` failed, the fix is a
media rebuild and one more reflash.
