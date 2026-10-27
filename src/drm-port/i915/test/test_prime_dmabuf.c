/* gpu3 6a: dma-buf fd unit test on card0. PASS = HANDLE_TO_FD fd>=0, FD_TO_HANDLE round-trips to the same GEM object,
 * mmap(fd) reads what a dumb-buffer write put there, lseek(SEEK_END)=size, poll ready, DMA_BUF_IOCTL_SYNC 0, close ok. */
#include <stdio.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <poll.h>
#include <sys/mman.h>
#include <xf86drm.h>
struct dma_buf_sync { uint64_t flags; };
#define DMA_BUF_IOCTL_SYNC (0x40000000u | (sizeof(struct dma_buf_sync) << 16) | ('b' << 8) | 0)	/* Linux _IOW */
static int ok, n, bad;
#define CHECK(c, ...) do { n++; if (c) ok++; else bad++; printf("%s ", (c) ? "ok  " : "FAIL"); printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while (0)
int main(void) {
	int fd = open("/dev/dri/card0", O_RDWR);
	struct drm_mode_create_dumb cd = { .width = 256, .height = 64, .bpp = 32 };
	CHECK(drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd) == 0, "CREATE_DUMB handle %u size %llu", cd.handle, (unsigned long long)cd.size);
	struct drm_mode_map_dumb md = { .handle = cd.handle };
	drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md);
	uint32_t *px = mmap(0, cd.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, md.offset);
	CHECK(px != MAP_FAILED, "dumb mmap");
	if (px == MAP_FAILED) return 1;
	for (uint64_t i = 0; i < cd.size / 4; i++) px[i] = 0xc0de0000u | (uint32_t)i;
	int pfd = -1; errno = 0;
	int rc = drmPrimeHandleToFD(fd, cd.handle, DRM_CLOEXEC | DRM_RDWR, &pfd);
	CHECK(rc == 0 && pfd >= 0, "PRIME_HANDLE_TO_FD rc=%d errno=%d fd=%d", rc, rc ? errno : 0, pfd);
	if (pfd < 0) { printf("%d/%d ok\n", ok, n); return 1; }
	CHECK((fcntl(pfd, F_GETFD) & FD_CLOEXEC) != 0, "FD_CLOEXEC set");
	off_t sz = lseek(pfd, 0, SEEK_END);
	CHECK(sz == (off_t)cd.size, "lseek(SEEK_END)=%lld want %llu", (long long)sz, (unsigned long long)cd.size);
	lseek(pfd, 0, SEEK_SET);
	uint32_t h2 = 0; rc = drmPrimeFDToHandle(fd, pfd, &h2);
	CHECK(rc == 0 && h2 == cd.handle, "FD_TO_HANDLE rc=%d handle %u (same fd's own export -> same handle %u)", rc, h2, cd.handle);
	int fd2 = open("/dev/dri/renderD128", O_RDWR); uint32_t h3 = 0;
	rc = drmPrimeFDToHandle(fd2, pfd, &h3);
	CHECK(rc == 0 && h3 != 0, "FD_TO_HANDLE on a 2nd open (renderD128) rc=%d errno=%d handle %u", rc, rc ? errno : 0, h3);
	uint32_t *dp = mmap(0, cd.size, PROT_READ | PROT_WRITE, MAP_SHARED, pfd, 0);
	CHECK(dp != MAP_FAILED, "mmap(dma-buf fd) %s", dp == MAP_FAILED ? strerror(errno) : "");
	if (dp != MAP_FAILED) {
		int same = 1; for (uint64_t i = 0; i < cd.size / 4; i++) if (dp[i] != (0xc0de0000u | (uint32_t)i)) { same = 0; printf("  first diff at %llu: 0x%x\n", (unsigned long long)i, dp[i]); break; }
		CHECK(same, "dma-buf map reads the dumb-buffer pattern (dp[1]=0x%x dp[last]=0x%x)", dp[1], dp[cd.size / 4 - 1]);
		dp[7] = 0x12345678; CHECK(px[7] == 0x12345678, "write via dma-buf map seen via dumb map: 0x%x", px[7]);
		munmap(dp, cd.size);
	}
	struct pollfd pf = { .fd = pfd, .events = POLLIN | POLLOUT };
	CHECK(poll(&pf, 1, 100) == 1, "poll revents 0x%x", pf.revents);
	struct dma_buf_sync sy = { .flags = 3 | 0 };
	CHECK(ioctl(pfd, DMA_BUF_IOCTL_SYNC, &sy) == 0, "DMA_BUF_IOCTL_SYNC errno=%d", errno);
	errno = 0; { int r_ = close(pfd); CHECK(r_ == 0, "close(dma-buf fd) rc=%d errno=%d", r_, errno); }
	struct drm_gem_close gc = { .handle = h3 }; drmIoctl(fd2, DRM_IOCTL_GEM_CLOSE, &gc); close(fd2);
	int pfd2 = -1; rc = drmPrimeHandleToFD(fd, cd.handle, DRM_CLOEXEC, &pfd2);
	CHECK(rc == 0 && pfd2 >= 0, "second export after close: fd=%d", pfd2);
	if (pfd2 >= 0) close(pfd2);
	munmap(px, cd.size);
	struct drm_mode_destroy_dumb dd = { .handle = cd.handle };
	errno = 0; { int r_ = drmIoctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &dd); CHECK(r_ == 0, "DESTROY_DUMB rc=%d errno=%d", r_, errno); }
	printf("%d/%d ok, %d FAIL\n", ok, n, bad); return bad == 0 ? 0 : 1;
}
