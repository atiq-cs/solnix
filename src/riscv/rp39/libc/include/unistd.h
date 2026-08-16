#ifndef _UNISTD_H
#define _UNISTD_H
#include <stddef.h>
#include <sys/types.h>
#define STDIN_FILENO  0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2
ssize_t read(int fd, void *buf, size_t n);
ssize_t write(int fd, const void *buf, size_t n);
int close(int fd);
off_t lseek(int fd, off_t off, int whence);
pid_t getpid(void);
int chdir(const char *path);
int unlink(const char *path);
int rmdir(const char *path);
int dup(int fd);
int dup2(int o, int n);
void *sbrk(long incr);
#endif
