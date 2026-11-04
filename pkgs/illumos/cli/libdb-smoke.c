/* libdb-smoke.c -- the in-build smoke test for cli/c-libdb.nix: a transactional env, 10000 put/get, close, reopen, verify the
 * data, then DB->verify. argv[1] = env home (created empty by the caller). Exit 0 only if every step passed. */
#include <db.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

#define N 10000
#define CK(x) do { int r_ = (x); if (r_ != 0) { fprintf(stderr, "FAIL %s: %s\n", #x, db_strerror(r_)); return 1; } } while (0)

static int open_env(DB_ENV **e, const char *home)
{
	CK(db_env_create(e, 0));
	CK((*e)->open(*e, home, DB_CREATE | DB_INIT_MPOOL | DB_INIT_LOCK | DB_INIT_LOG | DB_INIT_TXN | DB_RECOVER, 0600));
	return 0;
}

static int check(DB *db, int *n)
{
	DBT k, d; char kb[16], vb[32]; int i;
	for (*n = 0, i = 0; i < N; i++) {
		memset(&k, 0, sizeof k); memset(&d, 0, sizeof d);
		snprintf(kb, sizeof kb, "k%05d", i); snprintf(vb, sizeof vb, "value-%d", i * 7);
		k.data = kb; k.size = strlen(kb) + 1;
		CK(db->get(db, NULL, &k, &d, 0));
		if (d.size != strlen(vb) + 1 || memcmp(d.data, vb, d.size) != 0) { fprintf(stderr, "FAIL value of %s\n", kb); return 1; }
		(*n)++;
	}
	return 0;
}

int main(int argc, char **argv)
{
	DB_ENV *e; DB *db; DBT k, d; char kb[16], vb[32]; int i, n;
	if (argc != 2) { fprintf(stderr, "usage: %s home\n", argv[0]); return 2; }
	if (open_env(&e, argv[1])) return 1;
	CK(db_create(&db, e, 0));
	CK(db->set_pagesize(db, 4096));   /* fixed, so the caller's corruption control knows where page 3 is */
	CK(db->open(db, NULL, "smoke.db", NULL, DB_BTREE, DB_CREATE | DB_AUTO_COMMIT, 0600));
	for (i = 0; i < N; i++) {
		memset(&k, 0, sizeof k); memset(&d, 0, sizeof d);
		snprintf(kb, sizeof kb, "k%05d", i); snprintf(vb, sizeof vb, "value-%d", i * 7);
		k.data = kb; k.size = strlen(kb) + 1; d.data = vb; d.size = strlen(vb) + 1;
		CK(db->put(db, NULL, &k, &d, DB_AUTO_COMMIT));
	}
	if (check(db, &n)) return 1;
	printf("put/get %d\n", n);
	CK(db->close(db, 0)); CK(e->close(e, 0));
	/* reopen: recovery runs (DB_RECOVER), and every committed record must still be there */
	if (open_env(&e, argv[1])) return 1;
	CK(db_create(&db, e, 0));
	CK(db->open(db, NULL, "smoke.db", NULL, DB_BTREE, DB_AUTO_COMMIT, 0));
	if (check(db, &n)) return 1;
	printf("reopen %d\n", n);
	CK(db->close(db, 0));
	CK(db_create(&db, e, 0));
	CK(db->verify(db, "smoke.db", NULL, NULL, 0));   /* verify consumes the handle */
	CK(e->close(e, 0));
	printf("verify ok\n%s\n", db_version(NULL, NULL, NULL));
	{	/* the region signature the LIBRARY stamps (env_region.c), to compare with dist/env_sig_print.sh's */
		unsigned (*sig)(void) = (unsigned (*)(void))dlsym(RTLD_DEFAULT, "__env_struct_sig");
		if (sig != NULL) printf("library signature 0x%08x\n", sig()); else printf("library signature n/a\n");
	}
	return 0;
}
