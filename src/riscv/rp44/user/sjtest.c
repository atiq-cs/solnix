/*
 * sjtest.c -- standalone self-test of the solnix riscv64 setjmp/longjmp asm.
 * setjmp saves the callee-saved regs; a longjmp(env, 42) must unwind back to
 * the setjmp call site and make it return 42.  Also exercises local vars held
 * in callee-saved registers across the longjmp (they must survive), and the
 * val==0 -> returns 1 rule.  Prints PASS/FAIL lines the boot log asserts.
 */
#include <setjmp.h>
#include <stdio.h>

static jmp_buf env;

static void deeper(int v)
{
	/* burn some stack + a call, then jump back over it */
	volatile int pad[16];
	for (int i = 0; i < 16; i++) pad[i] = i;
	longjmp(env, v);
}

int main(void)
{
	/* r is kept live across setjmp; mark volatile so the compiler doesn't
	   assume it's unchanged after a longjmp path. */
	volatile int marker = 12345;
	int rc = setjmp(env);
	if (rc == 0) {
		/* first return from setjmp: go jump back with 42 */
		deeper(42);
		printf("SJTEST FAIL: fell through after longjmp\n");
		return 1;
	}
	/* second arrival: via longjmp(env,42) */
	if (rc == 42 && marker == 12345)
		printf("SJTEST PASS: longjmp returned 42, stack intact (marker=%d)\n", marker);
	else
		printf("SJTEST FAIL: rc=%d marker=%d\n", rc, marker);

	/* val==0 rule: longjmp(env,0) must make setjmp return 1 */
	int rc2 = setjmp(env);
	if (rc2 == 0) {
		longjmp(env, 0);
		return 1;
	}
	if (rc2 == 1)
		printf("SJTEST PASS: longjmp(env,0) returned 1\n");
	else
		printf("SJTEST FAIL: zero-val rc2=%d\n", rc2);
	return 0;
}
