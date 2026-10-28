/*
 * t_p10.c : model of ena_admin_poll_for_resp() with an injected oversleep (aa64h o4: one delay(1 ms)
 * returned after 685 ms, the response already in the CQ).  OLD = gate loop, NEW = gate loop + p10.
 * Time is simulated.  Case A: the device completes 1 ms after submit, the 1st sleep lasts 685 ms.
 * Case B: the device never completes (a real timeout must still be reported).
 * Case C: no oversleep, completes at 3 ms.  cc -DNEW / without; run.sh compares.
 */
#include <stdio.h>
#include <stdbool.h>
typedef long long hrtime_t;
static hrtime_t now, done_at, oversleep;
static bool pending, slept_once;
static void process_responses(void) { if (now >= done_at) pending = false; }
static void delay_1ms(void) { now += slept_once ? 1000000 : oversleep; slept_once = true; }
static int poll(hrtime_t timeout)
{
	hrtime_t expire = now + timeout;
	for (;;) {
		process_responses();
		if (!pending)
			break;
		delay_1ms();
		if (now > expire) {
#ifdef NEW
			process_responses();
			if (!pending)
				break;
#endif
			return (5);	/* EIO: "timed out waiting for admin response" */
		}
	}
	return (0);
}
static int run(hrtime_t d, hrtime_t o)
{
	now = 0; done_at = d; oversleep = o; pending = true; slept_once = false;
	return (poll(500000000LL));
}
int main(void)
{
	int a = run(1000000LL, 685000000LL), b = run(1LL << 60, 685000000LL), c = run(3000000LL, 1000000LL);
	printf("A oversleep, completed: rc=%d (want 0)\nB never completes: rc=%d (want 5)\nC normal: rc=%d (want 0)\n", a, b, c);
	printf("%s\n", (a == 0 && b == 5 && c == 0) ? "PASS" : "FAIL");
	return (!(a == 0 && b == 5 && c == 0));
}
