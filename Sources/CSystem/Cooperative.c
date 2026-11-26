#include "CSystem.h"
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <time.h>
#include <stddef.h>

static int64_t ms_millis(void) {
 struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
 return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}
static int ms_wait(int fd, short events, int64_t deadline) {
 for (;;) {
  int64_t left = deadline - ms_millis();
  if (left <= 0) return -1;
  struct pollfd item = {fd, events, 0};
  int result = poll(&item, 1, (int)left);
  if (result < 0 && errno == EINTR) continue;
  return result > 0 && (item.revents & events) ? 0 : -1;
 }
}
static int ms_same_peer(int fd, int32_t pid, uint32_t uid, uint64_t sec, uint64_t usec) {
 pid_t peer = -1, effective = -1; uid_t owner = -1; gid_t group;
 socklen_t length = sizeof(peer);
 if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &length) || length != sizeof(peer) || peer != pid) return 0;
 length = sizeof(effective);
 if (getsockopt(fd, SOL_LOCAL, LOCAL_PEEREPID, &effective, &length) || length != sizeof(effective) || effective != pid) return 0;
 if (getpeereid(fd, &owner, &group) || owner != uid) return 0;
 MSProcess process;
 return ms_process(pid, &process) && process.uid == uid && process.start_sec == sec && process.start_usec == usec;
}
int ms_cooperative_query(const char *path, int32_t pid, uint32_t uid,
 uint64_t sec, uint64_t usec, const char *request, char *response, int capacity) {
 if (!path || !request || !response || capacity < 2 || capacity > 4096) return -1;
 size_t path_length = strlen(path), request_length = strlen(request);
 if (!path_length || path[0] != '/' || path_length >= sizeof(((struct sockaddr_un *)0)->sun_path) ||
     request_length > 2048 || request_length == 0) return -1;
 struct stat attributes;
 if (lstat(path, &attributes) || !S_ISSOCK(attributes.st_mode) || attributes.st_uid != uid || (attributes.st_mode & 077) != 0) return -2;
 char parent[104]; memcpy(parent, path, path_length + 1);
 char *slash = strrchr(parent, '/'); if (!slash || slash == parent) return -1; *slash = 0;
 if (lstat(parent, &attributes) || !S_ISDIR(attributes.st_mode) || attributes.st_uid != uid || (attributes.st_mode & 077) != 0) return -3;
 int fd = socket(AF_UNIX, SOCK_STREAM, 0); if (fd < 0) return -1;
 int result = -1; int64_t deadline = ms_millis() + 1000;
 int flags = fcntl(fd, F_GETFL), one = 1;
 if (flags < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 ||
     setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one))) goto done;
 struct sockaddr_un address = {0}; address.sun_family = AF_UNIX;
 address.sun_len = (unsigned char)(offsetof(struct sockaddr_un, sun_path) + path_length + 1);
 memcpy(address.sun_path, path, path_length + 1);
 result = -4;
 if (connect(fd, (struct sockaddr *)&address, address.sun_len) < 0) {
  if (errno != EINPROGRESS || ms_wait(fd, POLLOUT, deadline)) goto done;
  int error = 0; socklen_t length = sizeof(error);
  if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) || error) goto done;
 }
 result = -5;
 if (!ms_same_peer(fd, pid, uid, sec, usec)) goto done;
 result = -6;
 for (size_t sent = 0; sent < request_length;) {
  if (ms_wait(fd, POLLOUT, deadline)) goto done;
  ssize_t amount = send(fd, request + sent, request_length - sent, 0);
  if (amount < 0 && (errno == EINTR || errno == EAGAIN)) continue;
  if (amount <= 0) goto done; sent += (size_t)amount;
 }
 result = -7; int count = 0;
 while (count < capacity - 1) {
  if (ms_wait(fd, POLLIN, deadline)) goto done;
  ssize_t amount = recv(fd, response + count, (size_t)(capacity - 1 - count), 0);
  if (amount < 0 && (errno == EINTR || errno == EAGAIN)) continue;
  if (amount <= 0) goto done; count += (int)amount;
  char *newline = memchr(response, '\n', (size_t)count);
  if (newline) {
   count = (int)(newline - response); response[count] = 0;
   result = -8;
   if (ms_same_peer(fd, pid, uid, sec, usec)) result = count;
   goto done;
  }
 }
done:
 close(fd); return result;
}
