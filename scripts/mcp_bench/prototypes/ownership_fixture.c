#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

/* This wire model has no cgroup authority and cannot qualify containment. */
enum { RESERVE = 1, COMMIT, STOP, TIMEOUT, RELEASE };
enum { IDLE, RESERVED, RUNNING, CLOSED, HELD };
enum { OK, UNAVAILABLE, FOREIGN, STALE, REPLAY, CAPACITY, STOPPED, RETAINED };
typedef struct { unsigned char token[32]; unsigned generation; int operation; } Request;
#ifdef __linux__
static const char *image;

static void require(int condition, const char *message) {
  if (!condition) { perror(message); exit(1); }
}

static void reap(pid_t pid, int expected) {
  int status;
  require(waitpid(pid, &status, 0) == pid, "waitpid");
  require(WIFEXITED(status) && WEXITSTATUS(status) == expected, "child status");
}
#endif

static int target(const char *marker) {
  int fd = open(marker, O_WRONLY | O_CREAT | O_EXCL, 0600);
  if (fd < 0) return 1;
  int rc = write(fd, "executed\n", 9) == 9 ? 0 : 1;
  if (close(fd)) rc = 1;
  return rc;
}

#ifdef __linux__
static void broker(int channel, pid_t client, const Request *identity,
                   int authority, const char *marker) {
  int enabled = 1, state = IDLE;
  int credentials = setsockopt(channel, SOL_SOCKET, SO_PASSCRED, &enabled, sizeof(enabled)) == 0;
  int ready[] = { credentials, credentials ? 0 : errno };
  require(write(channel, ready, sizeof(ready)) == sizeof(ready), "ready");
  for (;;) {
    Request request;
    char control[CMSG_SPACE(sizeof(struct ucred))] = {0};
    struct iovec io = { &request, sizeof(request) };
    struct msghdr message = {0};
    message.msg_iov = &io; message.msg_iovlen = 1;
    message.msg_control = control; message.msg_controllen = sizeof(control);
    ssize_t count = credentials ? recvmsg(channel, &message, 0) : read(channel, &request, sizeof(request));
    if (!count) break;
    require(count == sizeof(request) && !(message.msg_flags & (MSG_TRUNC | MSG_CTRUNC)),
            "complete request");
    struct ucred *peer = NULL;
    for (struct cmsghdr *c = credentials ? CMSG_FIRSTHDR(&message) : NULL;
         c; c = CMSG_NXTHDR(&message, c))
      if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_CREDENTIALS &&
          c->cmsg_len == CMSG_LEN(sizeof(struct ucred))) peer = (struct ucred *)CMSG_DATA(c);
    int answer;
    if (credentials && (!peer || peer->pid != client || peer->uid != getuid())) answer = FOREIGN;
    else if (!authority) answer = UNAVAILABLE;
    else if (memcmp(request.token, identity->token, sizeof(request.token)) ||
             request.generation != identity->generation) answer = STALE;
    else if (request.operation == STOP) { state = CLOSED; answer = OK; }
    else if (request.operation == TIMEOUT && state == RUNNING) { state = HELD; answer = RETAINED; }
    else if (request.operation == RELEASE && (state == HELD || state == RUNNING)) answer = RETAINED;
    else if (state == CLOSED) answer = STOPPED;
    else if (request.operation == RESERVE) {
      answer = state == IDLE ? OK : CAPACITY;
      if (answer == OK) state = RESERVED;
    } else if (request.operation == COMMIT && state == RESERVED) {
      pid_t pid = fork();
      require(pid >= 0, "target fork");
      if (!pid) { close(channel); execl(image, image, "target", marker, (char *)NULL); _exit(127); }
      reap(pid, 0);
      state = RUNNING; answer = OK;
    } else answer = REPLAY;
    require(write(channel, &answer, sizeof(answer)) == sizeof(answer), "reply");
  }
  close(channel);
  _exit(0);
}

static int rpc(int fd, Request request, int operation) {
  request.operation = operation;
  require(write(fd, &request, sizeof(request)) == sizeof(request), "request");
  int answer;
  require(read(fd, &answer, sizeof(answer)) == sizeof(answer), "response");
  return answer;
}

static void row(const char *name, int condition) {
  require(condition, name);
  printf("{\"name\":\"%s\",\"status\":\"PASS\",\"scope\":\"local-protocol-only\"}\n", name);
  fflush(stdout);
}

static void protocol(const char *directory) {
  const char *cases[] = {"missing_authority", "stale_token", "foreign_token", "foreign_peer",
    "token_replay", "capacity", "admission_kill_race", "channel_loss", "cleanup_retained",
    "admitted_control"};
  for (size_t i = 0; i < sizeof(cases) / sizeof(*cases); ++i) {
    char marker[4096];
    require(snprintf(marker, sizeof(marker), "%s/%s.marker", directory, cases[i]) < (int)sizeof(marker),
            "marker length");
    Request identity = { .generation = 1 };
    int random = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    require(random >= 0, "random open");
    require(read(random, identity.token, sizeof(identity.token)) == sizeof(identity.token), "random token");
    close(random);
    int pair[2];
    require(socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, pair) == 0, "socketpair");
    pid_t client = getpid(), child = fork();
    require(child >= 0, "broker fork");
    if (!child) { close(pair[0]); broker(pair[1], client, &identity, i != 0, marker); }
    close(pair[1]);
    int ready[2];
    require(read(pair[0], ready, sizeof(ready)) == sizeof(ready), "broker ready");
    if (!i) {
      printf("{\"name\":\"credential_auth\",\"status\":\"%s\",\"errno\":%d,\"scope\":\"local-protocol-only\"}\n",
             ready[0] ? "PASS" : "UNAVAILABLE", ready[1]);
      fflush(stdout);
    }
    int result = 0, executed = 0;
    if (i == 0) result = rpc(pair[0], identity, RESERVE) == UNAVAILABLE;
    if (i == 1 || i == 2) {
      Request bad = identity;
      if (i == 1) ++bad.generation; else bad.token[0] ^= 1;
      result = rpc(pair[0], bad, RESERVE) == STALE && rpc(pair[0], bad, COMMIT) == STALE;
    }
    if (i == 3 && ready[0]) {
      pid_t foreign = fork();
      require(foreign >= 0, "foreign fork");
      if (!foreign) _exit(rpc(pair[0], identity, RESERVE) == FOREIGN ? 0 : 1);
      reap(foreign, 0); result = 1;
    }
    if (i >= 4) require(rpc(pair[0], identity, RESERVE) == OK, "reserve");
    if (i == 4 || i == 8 || i == 9) {
      require(rpc(pair[0], identity, COMMIT) == OK, "commit"); executed = 1;
      if (i == 4) result = rpc(pair[0], identity, COMMIT) == REPLAY;
      if (i == 8) result = rpc(pair[0], identity, TIMEOUT) == RETAINED &&
                           rpc(pair[0], identity, RELEASE) == RETAINED &&
                           rpc(pair[0], identity, RESERVE) == CAPACITY;
      if (i == 9) result = 1;
    }
    if (i == 5) result = rpc(pair[0], identity, RESERVE) == CAPACITY;
    if (i == 6) result = rpc(pair[0], identity, STOP) == OK &&
                         rpc(pair[0], identity, COMMIT) == STOPPED;
    if (i == 7) result = 1;
    close(pair[0]); reap(child, 0);
    if (i == 3 && !ready[0]) {
      printf("{\"name\":\"foreign_peer\",\"status\":\"UNAVAILABLE\",\"errno\":%d,\"reason\":\"SO_PASSCRED unavailable; token-only controls cannot authenticate sender\"}\n", ready[1]);
      fflush(stdout);
    } else row(cases[i], result && (access(marker, F_OK) == 0) == executed);
  }
  pid_t unrelated = fork();
  require(unrelated >= 0, "unrelated fork");
  if (!unrelated) _exit(23);
  reap(unrelated, 23);
  row("unrelated_child_status", 1);
  puts("{\"name\":\"local_cleanup\",\"status\":\"PASS\",\"detail\":\"all exact child PIDs reaped; no scopes created\"}");
}
#endif

int main(int argc, char **argv) {
#ifdef __linux__
  image = argv[0];
#endif
  alarm(10);
  if (argc == 3 && !strcmp(argv[1], "target")) return target(argv[2]);
  if (argc == 3 && !strcmp(argv[1], "refuse")) {
    puts("{\"name\":\"pre_spawn_refusal\",\"status\":\"UNAVAILABLE\",\"reason\":\"no protected delegated manager admitted\"}");
    return 77;
  }
#ifdef __linux__
  if (argc == 3 && !strcmp(argv[1], "protocol")) { protocol(argv[2]); return 0; }
  if (argc == 2 && !strcmp(argv[1], "drop-identity")) {
    pid_t child = fork();
    require(child >= 0, "identity fork");
    if (!child) {
      errno = 0;
      int rc = setresuid(65534, 65534, 65534), error = errno;
      printf("{\"setresuid_rc\":%d,\"errno\":%d,\"uid\":%lu,\"euid\":%lu}\n",
             rc, error, (unsigned long)getuid(), (unsigned long)geteuid());
      fflush(stdout); _exit(0);
    }
    reap(child, 0); return 0;
  }
#endif
  fprintf(stderr, "usage: ownership_fixture target|refuse|protocol PATH | drop-identity\n");
  return 2;
}
