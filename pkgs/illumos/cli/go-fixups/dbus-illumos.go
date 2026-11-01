//go:build illumos

// godbus/dbus excludes GOOS=solaris (and so illumos) from its unix transport for want of a
// credentials-passing arm; illumos needs none to talk to a local bus: send the NUL byte plainly.
package dbus

import "io"

func (t *unixTransport) SendNullByte() error {
	n, _, err := t.UnixConn.WriteMsgUnix([]byte{0}, nil, nil)
	if err != nil {
		return err
	}
	if n != 1 {
		return io.ErrShortWrite
	}
	return nil
}
