#!/usr/bin/env python3
# p8-ena-cleanup-drain.py <gate>: ena_cleanup_device_init list_destroy()ed ea_cmd_ctxs_free while
# ena_create_cmd_ctx() had put ENA_ADMINQ_DEPTH contexts on it (and ea_cmd_ctxs_used may hold pending ones
# after an admin timeout). On a DEBUG kernel a failed attach then panics at list.c:88 instead of failing.
# The contexts are elements of the ea_cmd_ctxs array (kmem_free'd right after), so draining is just unlinking.
import sys
P = sys.argv[1] + '/usr/src/uts/common/io/ena/ena.c'
s = open(P).read()
a = '''	list_destroy(&aq->ea_cmd_ctxs_free);
	list_destroy(&aq->ea_cmd_ctxs_used);
	kmem_free(aq->ea_cmd_ctxs, sizeof (ena_cmd_ctx_t) * aq->ea_qlen);'''
b = '''	/*
	 * solnix: unlink every context before list_destroy. They are elements of
	 * ea_cmd_ctxs (freed below), so nothing else to free; a failed attach
	 * (e.g. an admin timeout) then fails instead of tripping list.c:88.
	 */
	while (list_remove_head(&aq->ea_cmd_ctxs_free) != NULL)
		;
	while (list_remove_head(&aq->ea_cmd_ctxs_used) != NULL)
		;
	list_destroy(&aq->ea_cmd_ctxs_free);
	list_destroy(&aq->ea_cmd_ctxs_used);
	kmem_free(aq->ea_cmd_ctxs, sizeof (ena_cmd_ctx_t) * aq->ea_qlen);'''
if 'solnix: unlink every context before list_destroy' in s:
    print('p8 already applied'); sys.exit(0)
assert s.count(a) == 1, 'anchor'
open(P, 'w').write(s.replace(a, b, 1))
print('p8 ok')
