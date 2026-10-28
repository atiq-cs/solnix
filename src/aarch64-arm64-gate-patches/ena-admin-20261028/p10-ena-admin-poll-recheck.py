#!/usr/bin/env python3
# p10-ena-admin-poll-recheck.py <gate> : ena_admin_poll_for_resp() (same code as upstream illumos-gate) reads
# the admin CQ, sleeps delay(1 ms), then judges the deadline without reading the CQ again.  One sleep that
# overruns ea_cmd_timeout_ns (500 ms on EC2) therefore turns a command the device has already completed into
# "timed out waiting for admin response", a device reset and a failed attach.  Measured (aa64h o4, c6gd.metal):
# Create CQ id 17, one delay() returned after 685.6 ms (lbolt +686), the response was already in the CQ
# (head 113->114 = SQ tail 114, DEV_STS ready), console holds <= 1 ms.  Fix: when the deadline has passed,
# process the CQ once more and succeed if the command completed; only then report the timeout.  The 500 ms
# timeout is unchanged.  Idempotent.
import sys
P = sys.argv[1] + '/usr/src/uts/common/io/ena/ena_admin.c'
s = open(P).read()
if 'solnix: one last look at the CQ' in s:
    print('p10 already applied'); sys.exit(0)
a = '\t\tif (gethrtime() > expire) {\n\t\t\t/*\n\t\t\t * We have no visibility into the device to\n'
b = ('\t\tif (gethrtime() > expire) {\n'
     '\t\t\t/*\n'
     '\t\t\t * solnix: one last look at the CQ.  The deadline is judged\n'
     '\t\t\t * after the sleep, and a single sleep can overrun it (measured:\n'
     '\t\t\t * one delay(1 ms) returned after 685 ms on c6gd.metal while the\n'
     '\t\t\t * response was already in the CQ).  Without this re-read a\n'
     '\t\t\t * completed command is reported as a timeout and the device is\n'
     '\t\t\t * reset.\n'
     '\t\t\t */\n'
     '\t\t\tena_admin_process_responses(ena);\n'
     '\t\t\tif (!ctx->ectx_pending)\n'
     '\t\t\t\tbreak;\n\n'
     '\t\t\t/*\n\t\t\t * We have no visibility into the device to\n')
assert s.count(a) == 1, 'anchor'
open(P, 'w').write(s.replace(a, b, 1))
print('p10 ok')
