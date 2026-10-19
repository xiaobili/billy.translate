#define _GNU_SOURCE
#include <sys/socket.h>
#include <sys/uio.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stddef.h>

ssize_t sendmsg(int fd, const struct msghdr *msg, int flags) {
  static ssize_t (*real)(int, const struct msghdr *, int) = NULL;
  if (!real) real = dlsym(RTLD_NEXT, "sendmsg");
  if (msg && msg->msg_iovlen > 0) {
    const unsigned char *p = msg->msg_iov[0].iov_base;
    size_t n = msg->msg_iov[0].iov_len;
    if (n >= 8) {
      fprintf(stderr, "SENDMSG fd=%d len=%zu:", fd, n);
      for (size_t i = 0; i < n && i < 40; i++) fprintf(stderr, " %02x", p[i]);
      fprintf(stderr, "\n");
    }
  }
  return real(fd, msg, flags);
}
