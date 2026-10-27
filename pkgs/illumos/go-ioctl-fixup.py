#!/usr/bin/env python3
# go-ioctl-fixup.py <file> <pkg> [extra-go]: illumos has no syscall.SYS_IOCTL (Go's solaris syscalls go through
# libc), so vendored terminal code that calls syscall.Syscall*(syscall.SYS_IOCTL, fd, req, ptr, ...)
# does not compile. Rewrite each such call to hlcliIoctl(fd, req, ptr) and add an illumos-only file
# with hlcliIoctl on golang.org/x/sys/unix (ioctl via libc), plus a !illumos one that keeps the
# original syscall. Fails if the file has no such call (an upstream change must not no-op this).
import re, sys, os
path, pkg = sys.argv[1], sys.argv[2]
extra = sys.argv[3] if len(sys.argv) > 3 else ''  # Go source appended to the illumos file
s = open(path).read()
pat = re.compile(r'syscall\.Syscall6?\(\s*syscall\.SYS_IOCTL\s*,\s*([^,]+?)\s*,\s*([^,]+?)\s*,\s*(uintptr\(unsafe\.Pointer\([^)]*\)\)|[^,)]+?)\s*(?:,\s*0\s*,\s*0\s*,\s*0\s*)?\)')
s2, n = pat.subn(lambda m: 'hlcliIoctl(%s, %s, %s)' % (m.group(1), m.group(2), m.group(3)), s)
if n == 0: sys.exit("FATAL: no syscall.SYS_IOCTL call in %s" % path)
open(path, 'w').write(s2)
d = os.path.dirname(path)
# x/sys/unix on solarish exports only typed ioctls (via libc): termios get/set and winsize set.
# syscall.Termios and unix.Termios have the same layout there; dispatch on the request.
open(os.path.join(d, 'zz_hlcli_ioctl_illumos.go'), 'w').write(
'''//go:build illumos

package %s

import (
	"syscall"
	"unsafe"

	"golang.org/x/sys/unix"
)

func hlcliIoctl(fd, req, arg uintptr) (uintptr, uintptr, syscall.Errno) {
	var err error
	switch req {
	case unix.TCGETS, unix.TCGETA:
		var t *unix.Termios
		if t, err = unix.IoctlGetTermios(int(fd), int(req)); err == nil {
			*(*unix.Termios)(unsafe.Pointer(arg)) = *t
		}
	case unix.TCSETS, unix.TCSETSW, unix.TCSETSF, unix.TCSETA:
		err = unix.IoctlSetTermios(int(fd), int(req), (*unix.Termios)(unsafe.Pointer(arg)))
	case unix.TIOCSWINSZ:
		err = unix.IoctlSetWinsize(int(fd), int(req), (*unix.Winsize)(unsafe.Pointer(arg)))
	case unix.TIOCGWINSZ:
		var w *unix.Winsize
		if w, err = unix.IoctlGetWinsize(int(fd), int(req)); err == nil {
			*(*unix.Winsize)(unsafe.Pointer(arg)) = *w
		}
	default:
		return 0, 0, syscall.ENOTSUP
	}
	if e, ok := err.(syscall.Errno); ok {
		return 0, 0, e
	} else if err != nil {
		return 0, 0, syscall.EINVAL
	}
	return 0, 0, 0
}
''' % pkg + extra + "\n")
open(os.path.join(d, 'zz_hlcli_ioctl_other.go'), 'w').write(
'''//go:build !illumos && !windows

package %s

import "syscall"

func hlcliIoctl(fd, req, arg uintptr) (uintptr, uintptr, syscall.Errno) {
	return syscall.Syscall(syscall.SYS_IOCTL, fd, req, arg)
}
''' % pkg)
print("go-ioctl-fixup: %s: %d call(s)" % (path, n), file=sys.stderr)
