//go:build illumos

// duf on illumos (solnix): mounts from /etc/mnttab (mnttab(5): special, mount point, fstype, options, time,
// tab-separated), sizes from statvfs(2). duf upstream has Linux/BSD/macOS/Windows backends only.
package main

import (
	"bufio"
	"os"
	"strings"

	"golang.org/x/sys/unix"
)

func (m *Mount) Stat() unix.Statvfs_t { return m.Metadata.(unix.Statvfs_t) }

func mounts() ([]Mount, []string, error) {
	f, err := os.Open("/etc/mnttab")
	if err != nil {
		return nil, nil, err
	}
	defer f.Close() //nolint:errcheck
	var ret []Mount
	var warnings []string
	s := bufio.NewScanner(f)
	for s.Scan() {
		x := strings.Split(s.Text(), "\t")
		if len(x) < 4 {
			continue
		}
		var st unix.Statvfs_t
		if err := unix.Statvfs(x[1], &st); err != nil {
			warnings = append(warnings, x[1]+": "+err.Error())
			continue
		}
		d := Mount{Device: x[0], Mountpoint: x[1], Fstype: x[2], Type: x[2], Opts: x[3], Metadata: st,
			Total: st.Blocks * st.Frsize, Free: st.Bavail * st.Frsize, Used: (st.Blocks - st.Bfree) * st.Frsize,
			Inodes: st.Files, InodesFree: st.Ffree, InodesUsed: st.Files - st.Ffree, Blocks: st.Blocks, BlockSize: st.Frsize}
		d.DeviceType = deviceType(d)
		ret = append(ret, d)
	}
	return ret, warnings, s.Err()
}

func isFuseFs(m Mount) bool { return strings.HasPrefix(m.Fstype, "fuse") }

func isNetworkFs(m Mount) bool { return m.Fstype == "nfs" || m.Fstype == "smbfs" }

func isSpecialFs(m Mount) bool {
	switch m.Fstype {
	case "proc", "mntfs", "ctfs", "objfs", "sharefs", "fd", "dev", "devfs", "autofs", "bootfs":
		return true
	}
	return false
}

func isHiddenFs(m Mount) bool { return false }
