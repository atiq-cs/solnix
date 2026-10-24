#!/bin/sh
# aa64e-diag.sh : output-only boot diagnostics to the console (/dev/msglog), three rounds.
# Round 3 (t+450 s): if ena0 has no IPv4 address, plumb DHCP (STUB, not a fix) and re-run the IMDS key fetch.
PATH=/usr/sbin:/usr/bin:/sbin
exec >/dev/msglog 2>&1
dump() {
	echo "=== AA64E-DIAG round $1 $(date -u +%H:%M:%S) up $(uptime | sed 's/.* up/up/')"
	echo "--- ldd svccfg / sshd (missing libs)"
	ldd /usr/sbin/svccfg 2>&1 | grep -i "not found"; ldd /usr/sbin/sshd 2>&1 | grep -i "not found"; echo "ldd-done"
	echo "--- svccfg apply generic.xml (stderr shown)"
	/usr/sbin/svccfg apply /etc/svc/profile/generic.xml 2>&1 | head -12; echo "apply-rc-done"
	echo "--- svcs -xv"
	svcs -xv 2>&1 | head -60
	echo "--- svcs ssh/physical/ec2-key/manifest-import"
	svcs -l network/ssh 2>&1 | head -12
	svcs network/physical:default site/aa64-ec2-key system/manifest-import milestone/multi-user-server 2>&1
	echo "--- dladm show-phys / show-link"
	dladm show-phys 2>&1; dladm show-link 2>&1
	echo "--- ipadm"
	ipadm show-if 2>&1; ipadm show-addr 2>&1
	echo "--- kstat ena"
	kstat -m ena -p 2>&1 | grep -E "link|state|reset|ring|_err|intr" | head -30
	echo "--- ec2-key log"
	tail -15 /var/log/aa64-ec2-key.log 2>&1
	echo "--- ps sshd/dhcp"
	ps -ef | grep -E "sshd|dhcpagent|nwamd|ipmgmtd" | grep -v grep
	echo "=== AA64E-DIAG end round $1"
}
dump 1
( sleep 150; dump 2
  sleep 300; dump 3
  if ! ipadm show-addr -p -o addr ena0/ 2>/dev/null | grep -q "[0-9]"; then
	echo "=== AA64E-DIAG STUB: ena0 has no address -> plumb DHCP"
	# aa64f: ena0 is in the persistent ipadm.conf, so enable-if (not create-if) is the
	# recovery; ifconfig plumb is the control that bypasses ipmgmtd persistence.
	ls -l /dev/net 2>&1; ipadm show-if -o all 2>&1
	ipadm enable-if -t ena0 2>&1; echo "AA64F enable-if rc=$?"
	ipadm show-addr 2>&1
	if ! ipadm show-if ena0 >/dev/null 2>&1; then
		ifconfig ena0 plumb 2>&1; echo "AA64F ifconfig-plumb rc=$?"
		ifconfig ena0 dhcp start 2>&1; echo "AA64F ifconfig-dhcp rc=$?"
	fi
	ipadm create-if ena0 2>&1; echo "AA64F create-if rc=$?"
	sleep 30; ipadm show-addr 2>&1
	/usr/lib/aa64/aa64-ec2-key.sh; tail -6 /var/log/aa64-ec2-key.log 2>&1
	svcadm enable -s network/ssh 2>&1; svcs network/ssh 2>&1
	dump 4
  fi ) </dev/null >/dev/msglog 2>&1 &
exit 0
