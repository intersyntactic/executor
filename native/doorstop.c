// doorstop: the parent of a command is_executor runs.
//
//   doorstop <socket> <command> [args...]    run the command for the host
//   doorstop --probe                         exit 0: this file can be run
//
// The doorstop holds the command unreaped after it exits, so the command's
// pid and process group cannot be reused, and it is the only process that
// signals them. The host (is_executor, in Dart) never signals anything; it
// asks over a unix socket.
//
// Protocol: one line per message, tagged; no order is promised between tags
// except that started comes first, and running or execfailed comes before
// any exited or signalled line.
//   doorstop -> host:
//     started <pid> subreaper <0|1>
//     running | execfailed <errno>                  (the exec, either way)
//     exited <code> | signalled <signal>
//     none-seen | incomplete <n> | unknown         (answers kill)
//     leftovers group <n> adopted <n|-1> | leftovers unknown
//   host -> doorstop:
//     kill        kill the command's process group; answered
//     leftovers   what is still running; answered
//     release     reap the command and exit with its code
//     abandon     the host has stopped waiting: keep killing the group until
//                 none is seen, then reap and exit
// EOF from the host before release or abandon, or a line that cannot be
// sent, means the host is gone: kill everything (on Linux, also orphans
// re-parented here as subreaper) until none is seen, then reap and exit.
//
// Everything a census reports is what could be seen: a scan of processes
// observes, it does not prove (another user's process can be hidden).
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#include <sys/syscall.h>
#else
#include <libproc.h>
#include <sys/proc.h>
#include <sys/proc_info.h>
#endif

// Signals a terminal or a supervisor sends to the host's whole group or
// session. The doorstop ignores them, so host death reaches it only as socket
// EOF; the command gets the defaults back before exec.
static const int kHostSignals[] = {SIGINT, SIGQUIT, SIGHUP, SIGTERM, SIGTSTP, SIGTTIN, SIGTTOU};
#define N_HOST_SIGNALS (sizeof kHostSignals / sizeof kHostSignals[0])

enum {
  kRoundMs = 10,          // between kill rounds while the host waits
  kKillBudgetMs = 1000,   // how long the host's kill waits for an answer
  kCustodyMaxMs = 1000,   // the longest pause between rounds in custody
  kBlindGiveUpMs = 60000, // custody with no census at all ends after this
  kEmptyToSee = 2,        // consecutive empty censuses that make none-seen
};

static int wake[2];
static void on_chld(int sig) { (void)sig; int e = errno; (void)!write(wake[1], "c", 1); errno = e; }

static void set_flags(int fd, int nonblock) {
  fcntl(fd, F_SETFD, FD_CLOEXEC);
  if (nonblock) fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
}

// Monotonic: a wall clock set back would stall every deadline and pause.
static long now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

// Whether this process may signal one running as real uid r, saved uid sv:
// root may; otherwise its real or effective uid must be the target's real or
// saved one. A process that changed user (a setuid program) can be seen but
// not killed, and is counted apart so it cannot hold custody open for ever.
static int may_signal(uid_t r, uid_t sv) {
  uid_t me = getuid(), eme = geteuid();
  return eme == 0 || me == r || me == sv || eme == r || eme == sv;
}

// Set when a line could not be sent: a host that is not reading is going.
static int host_gone = 0;
static int s = -1;  // the socket; -1 once the doorstop stops listening
static void say(const char *fmt, long a, long b) {
  char line[96];
  int n = snprintf(line, sizeof line, fmt, a, b);
  if (n <= 0 || s < 0 || host_gone) return;
  if (send(s, line, (size_t)n, MSG_DONTWAIT) != n) host_gone = 1;
}

// Whether the command itself is still running: 1 yes, 0 exited, -1 cannot tell.
static int c_live(pid_t c) {
  for (;;) {
    siginfo_t si;
    memset(&si, 0, sizeof si);
    if (waitid(P_PID, (id_t)c, &si, WEXITED | WNOHANG | WNOWAIT) == 0) return si.si_pid != c;
    if (errno != EINTR) return -1;
  }
}

// One look at what is running: live members of the command's group (the
// command included, even before it has made the group) and live adopted
// orphans outside the group, each that this process may signal; and those it
// may not (unkillable). failed: the look could not be taken whole.
struct Census { int self, group, adopted, unkillable, adopted_unkillable, failed; };

#ifdef __linux__
// /proc/<p>/stat: state, ppid, pgrp. 1 read, 0 gone, -1 could not look.
static int proc_stat(pid_t p, char *state, int *ppid, int *pgrp) {
  char path[64], buf[512];
  snprintf(path, sizeof path, "/proc/%d/stat", (int)p);
  int fd = open(path, O_RDONLY);
  if (fd < 0) return (errno == ENOENT || errno == ESRCH) ? 0 : -1;
  ssize_t r = read(fd, buf, sizeof buf - 1);
  int e = errno;
  close(fd);
  if (r < 0) return e == ESRCH ? 0 : -1;
  if (r == 0) return 0;
  buf[r] = 0;
  char *rp = strrchr(buf, ')');  // the command name may hold spaces and parens
  return (rp && sscanf(rp + 2, "%c %d %d", state, ppid, pgrp) == 3) ? 1 : -1;
}

// The doorstop's own children but c, read to EOF from its children list; a
// pid is parsed only when whitespace ends it, so none is ever cut short.
// Every pid in it is the doorstop's unreaped child, so its id is ours.
// Returns how many were written to *out (malloc'd), or -1.
static int adopted_pids(pid_t c, pid_t **out) {
  char path[64];
  snprintf(path, sizeof path, "/proc/self/task/%d/children", (int)getpid());
  int fd = open(path, O_RDONLY);
  if (fd < 0) return -1;
  size_t cap = 4096, len = 0;
  char *buf = malloc(cap);
  for (;;) {
    if (!buf) { close(fd); return -1; }
    if (len == cap) {
      char *nb = realloc(buf, cap * 2);
      if (!nb) { free(buf); close(fd); return -1; }
      buf = nb; cap *= 2;
    }
    ssize_t r = read(fd, buf + len, cap - len);
    if (r < 0) { if (errno == EINTR) continue; free(buf); close(fd); return -1; }
    if (r == 0) break;
    len += (size_t)r;
  }
  close(fd);
  pid_t *pids = malloc((len / 2 + 1) * sizeof *pids);
  if (!pids) { free(buf); return -1; }
  int n = 0;
  size_t i = 0;
  while (i < len) {
    while (i < len && (buf[i] == ' ' || buf[i] == '\n')) i++;
    size_t start = i;
    while (i < len && buf[i] >= '0' && buf[i] <= '9') i++;
    if (i == start) { if (i < len) i++; continue; }
    if (i == len) break;  // no terminator: not a whole pid
    pid_t p = (pid_t)strtol(buf + start, NULL, 10);
    if (p > 0 && p != c) pids[n++] = p;
  }
  free(buf);
  *out = pids;
  return n;
}

// Reaps the adopted orphans that have exited (never c).
static void reap_adopted(pid_t c) {
  pid_t *pids;
  int n = adopted_pids(c, &pids);
  for (int i = 0; i < n; i++) {
    char st; int ppid, pgrp;
    int r = proc_stat(pids[i], &st, &ppid, &pgrp);
    if (r == 0 || (r > 0 && st == 'Z')) waitpid(pids[i], NULL, WNOHANG);
  }
  if (n >= 0) free(pids);
}

// /proc/<p>/status: real and saved uid. 1 read, 0 gone, -1 could not look.
static int proc_uids(pid_t p, uid_t *r, uid_t *sv) {
  char path[64], buf[2048];
  snprintf(path, sizeof path, "/proc/%d/status", (int)p);
  int fd = open(path, O_RDONLY);
  if (fd < 0) return (errno == ENOENT || errno == ESRCH) ? 0 : -1;
  ssize_t n = read(fd, buf, sizeof buf - 1);
  int e = errno;
  close(fd);
  if (n < 0) return e == ESRCH ? 0 : -1;
  if (n == 0) return 0;
  buf[n] = 0;
  char *u = strstr(buf, "\nUid:");
  unsigned long rr, ee, ss;
  if (!u || sscanf(u + 5, "%lu %lu %lu", &rr, &ee, &ss) != 3) return -1;
  *r = (uid_t)rr;
  *sv = (uid_t)ss;
  return 1;
}

// Adds live process p to k as one this process may signal, or may not.
// 0 counted or gone, -1 the look failed.
static int count(pid_t p, int *mayKill, int *mayNot) {
  uid_t r, sv;
  int got = proc_uids(p, &r, &sv);
  if (got < 0) return -1;
  if (got == 0) return 0;
  if (may_signal(r, sv)) (*mayKill)++; else (*mayNot)++;
  return 0;
}

static struct Census census(pid_t c, int kill_adopted) {
  struct Census k = {0, 0, 0, 0, 0, 0};
  int self = c_live(c);
  if (self < 0) { k.failed = 1; return k; }
  k.self = self;
  if (self && count(c, &k.group, &k.unkillable) < 0) { k.failed = 1; return k; }
  DIR *d = opendir("/proc");
  if (!d) { k.failed = 1; return k; }
  struct dirent *e;
  while ((e = readdir(d))) {
    pid_t p = (pid_t)atoi(e->d_name);
    if (p <= 0 || p == c) continue;
    char st; int ppid, pgrp;
    int r = proc_stat(p, &st, &ppid, &pgrp);
    if (r < 0) { k.failed = 1; break; }
    if (r > 0 && pgrp == c && st != 'Z' && count(p, &k.group, &k.unkillable) < 0) { k.failed = 1; break; }
  }
  closedir(d);
  if (k.failed) return k;
  pid_t *pids;
  int n = adopted_pids(c, &pids);
  if (n < 0) { k.failed = 1; return k; }
  for (int i = 0; i < n; i++) {
    char st; int ppid, pgrp;
    int r = proc_stat(pids[i], &st, &ppid, &pgrp);
    if (r < 0) { k.failed = 1; break; }
    if (r == 0 || st == 'Z') { waitpid(pids[i], NULL, WNOHANG); continue; }
    if (pgrp == c) continue;  // counted in the group already
    int before = k.adopted;
    if (count(pids[i], &k.adopted, &k.adopted_unkillable) < 0) { k.failed = 1; break; }
    if (kill_adopted && k.adopted > before) kill(pids[i], SIGKILL);
  }
  free(pids);
  return k;
}

static int set_subreaper(void) { return prctl(PR_SET_CHILD_SUBREAPER, 1) == 0; }

static void close_from(int lowest) {
#ifdef SYS_close_range
  if (syscall(SYS_close_range, (unsigned)lowest, ~0U, 0) == 0) return;
#endif
  long top = sysconf(_SC_OPEN_MAX);
  if (top < 0 || top > 65536) top = 65536;
  for (int fd = lowest; fd < top; fd++) close(fd);
}
#else
static void reap_adopted(pid_t c) { (void)c; }

// macOS: kill(-g, 0) answers EPERM both for a group holding only its zombie
// leader and for a live member that is someone else's, so it cannot count.
// libproc lists the group; the short info call succeeds for any live process
// (another user's included) and fails with ESRCH for a zombie or one gone.
// There is no subreaper: adopted is always 0 here, and leftovers says -1.
// Adds p to k if it is live: as one this process may signal, or may not.
// 0 counted or gone (a zombie included), -1 the look failed.
static int count(pid_t p, int *mayKill, int *mayNot) {
  struct proc_bsdshortinfo si;
  errno = 0;
  if (proc_pidinfo(p, PROC_PIDT_SHORTBSDINFO, 0, &si, sizeof si) != (int)sizeof si) {
    return errno == ESRCH ? 0 : -1;
  }
  if (si.pbsi_status == SZOMB) return 0;
  if (may_signal(si.pbsi_ruid, si.pbsi_svuid)) (*mayKill)++; else (*mayNot)++;
  return 0;
}

static struct Census census(pid_t c, int kill_adopted) {
  (void)kill_adopted;
  struct Census k = {0, 0, 0, 0, 0, 0};
  int self = c_live(c);
  if (self < 0) { k.failed = 1; return k; }
  k.self = self;
  if (self && count(c, &k.group, &k.unkillable) < 0) { k.failed = 1; return k; }
  int cap = 256, n = 0;
  pid_t *pids = NULL;
  for (;;) {
    pid_t *np = realloc(pids, (size_t)cap * sizeof *pids);
    if (!np) { free(pids); k.failed = 1; return k; }
    pids = np;
    // Returns 0, not -1, when the call fails, so 0 alone does not mean
    // empty: the failed call leaves errno set. An empty answer is real
    // before the command has made its group (or if it died before it could).
    errno = 0;
    int bytes = proc_listpids(PROC_PGRP_ONLY, (uint32_t)c, pids, cap * (int)sizeof *pids);
    if (bytes < 0 || (bytes == 0 && errno != 0)) { free(pids); k.failed = 1; return k; }
    n = bytes / (int)sizeof *pids;
    if (n < cap) break;  // room to spare: the list is whole
    cap *= 2;
  }
  for (int i = 0; i < n; i++) {
    if (pids[i] <= 0 || pids[i] == c) continue;
    if (count(pids[i], &k.group, &k.unkillable) < 0) { k.failed = 1; break; }
  }
  free(pids);
  return k;
}

static int set_subreaper(void) { return 0; }

static void close_from(int lowest) {
  // /dev/fd lists what is open; collect first, since closing changes it.
  int fds[1024], n = 0;
  DIR *d = opendir("/dev/fd");
  if (d) {
    struct dirent *e;
    while ((e = readdir(d)) && n < 1024) {
      int fd = atoi(e->d_name);
      if (fd >= lowest && fd != dirfd(d)) fds[n++] = fd;
    }
    closedir(d);
    for (int i = 0; i < n; i++) close(fds[i]);
    if (n < 1024) return;
  }
  long top = sysconf(_SC_OPEN_MAX);
  if (top < 0 || top > 65536) top = 65536;
  for (int fd = lowest; fd < top; fd++) close(fd);
}
#endif

// Killing, advanced one round per poll tick so the socket is still read while
// it runs. While the host waits (answer set) it is bounded by kKillBudgetMs;
// in custody (after abandon, or with the host gone) it goes on, pausing
// longer each round, until none is seen.
struct Killing {
  int active, subtree, answer, custody;
  long deadline, next, pause, blind_since;
  int empties;
};

static int kill_tick(pid_t c, struct Killing *k) {
  kill(c, SIGKILL);   // the doorstop's unreaped child; before setsid there is no group yet
  kill(-c, SIGKILL);  // POSIX: no other group can have c's id while c exists
  struct Census seen = census(c, k->subtree);
  // What signalling can still end, and what it cannot (another user's): only
  // the first keeps killing going; both keep the answer from none-seen.
  int left = seen.group + (k->subtree ? seen.adopted : 0);
  int stuck = seen.unkillable + (k->subtree ? seen.adopted_unkillable : 0);
  long now = now_ms();
  if (seen.failed) {
    k->empties = 0;
    if (!k->blind_since) k->blind_since = now;
  } else {
    k->blind_since = 0;
    k->empties = left == 0 ? k->empties + 1 : 0;
  }
  if (k->answer) {
    if (seen.failed) { say("unknown\n", 0, 0); k->answer = 0; }
    else if (k->empties >= kEmptyToSee && stuck) { say("incomplete %ld\n", stuck, 0); k->answer = 0; }
    else if (k->empties >= kEmptyToSee) { say("none-seen\n", 0, 0); k->answer = 0; }
    else if (now >= k->deadline) { say("incomplete %ld\n", left + stuck, 0); k->answer = 0; }
    if (!k->answer && !k->custody) { k->active = 0; return 1; }
  }
  if (k->custody) {
    if (k->empties >= kEmptyToSee) { k->active = 0; return 1; }
    if (k->blind_since && now - k->blind_since >= kBlindGiveUpMs) { k->active = 0; return 1; }
    k->pause = k->pause * 2 > kCustodyMaxMs ? kCustodyMaxMs : k->pause * 2;
  }
  k->next = now + (k->custody ? k->pause : kRoundMs);
  return 0;
}

extern char **environ;

// execve of argv[0], looked for on PATH as a shell does when it has no `/`,
// but with no shell behind it: execvp runs a file with no #! line through
// /bin/sh (ENOEXEC), and argv here is argv, never a shell. Returns only on
// failure, with errno: EACCES if any candidate was found but refused, else
// the last error.
static void exec_on_path(char **args) {
  const char *name = args[0];
  if (strchr(name, '/')) { execve(name, args, environ); return; }
  const char *path = getenv("PATH");
  if (!path) path = "/usr/bin:/bin";
  size_t nlen = strlen(name);
  int denied = 0, last = ENOENT;
  const char *p = path;
  for (;;) {
    const char *end = strchr(p, ':');
    size_t dlen = end ? (size_t)(end - p) : strlen(p);
    char full[4096];
    // An empty entry is the current folder, as POSIX has it.
    if (dlen == 0) { if (nlen + 1 > sizeof full) break; memcpy(full, name, nlen + 1); }
    else {
      if (dlen + 1 + nlen + 1 > sizeof full) { last = ENAMETOOLONG; goto next; }
      memcpy(full, p, dlen);
      full[dlen] = '/';
      memcpy(full + dlen + 1, name, nlen + 1);
    }
    execve(full, args, environ);
    if (errno == EACCES) denied = 1;
    else if (errno != ENOENT && errno != ENOTDIR) { last = errno; break; }
  next:
    if (!end) break;
    p = end + 1;
  }
  errno = denied ? EACCES : last;
}

static void start_custody(struct Killing *k, int subtree) {
  long now = now_ms();
  if (!k->active) { *k = (struct Killing){0}; k->next = now; }
  k->active = 1;
  k->custody = 1;
  k->subtree |= subtree;
  k->pause = kRoundMs;
  k->empties = 0;
}

int main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "--probe")) return 0;
  if (argc < 3) { fprintf(stderr, "usage: doorstop <socket> <command> [args...] | --probe\n"); return 125; }
  close_from(3);  // whatever the host left open beyond stdio is not ours to hold
  s = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un a;
  memset(&a, 0, sizeof a);
  a.sun_family = AF_UNIX;
  if (s < 0 || strlen(argv[1]) >= sizeof a.sun_path) { fprintf(stderr, "doorstop: bad socket path\n"); return 125; }
  strcpy(a.sun_path, argv[1]);
  if (connect(s, (struct sockaddr *)&a, sizeof a) != 0) { perror("doorstop: connect"); return 125; }
  set_flags(s, 1);

  // Out of the host's group and session: a terminal's Ctrl-C or hangup, or a
  // signal to the host's group, does not reach the doorstop.
  setsid();
  struct sigaction ign;
  memset(&ign, 0, sizeof ign);
  ign.sa_handler = SIG_IGN;
  for (size_t i = 0; i < N_HOST_SIGNALS; i++) sigaction(kHostSignals[i], &ign, NULL);
  sigaction(SIGPIPE, &ign, NULL);
  int subreaper = set_subreaper();
  int ep[2];
  if (pipe(wake) != 0 || pipe(ep) != 0) return 125;
  set_flags(wake[0], 1); set_flags(wake[1], 1);
  set_flags(ep[0], 1); set_flags(ep[1], 0);
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_chld;
  sa.sa_flags = SA_RESTART | SA_NOCLDSTOP;
  sigaction(SIGCHLD, &sa, NULL);

  pid_t me = getpid();
  pid_t c = fork();
  if (c < 0) return 125;
  if (c == 0) {
    // The doorstop's ends are not the command's: holding the socket would
    // hide the host's EOF from the doorstop for as long as exec takes.
    close(s); close(wake[0]); close(wake[1]); close(ep[0]);
#ifdef __linux__
    // The doorstop killed from outside takes the command with it (unless
    // the command changes credentials, which clears this).
    prctl(PR_SET_PDEATHSIG, SIGKILL);
    if (getppid() != me) _exit(125);
#endif
    // Ignored dispositions survive exec: give the command the defaults.
    struct sigaction dfl;
    memset(&dfl, 0, sizeof dfl);
    dfl.sa_handler = SIG_DFL;
    for (size_t i = 0; i < N_HOST_SIGNALS; i++) sigaction(kHostSignals[i], &dfl, NULL);
    sigaction(SIGPIPE, &dfl, NULL);
    sigaction(SIGCHLD, &dfl, NULL);
    if (setsid() < 0) { int e = errno; (void)!write(ep[1], &e, sizeof e); _exit(126); }
    exec_on_path(argv + 2);
    int e = errno;
    (void)!write(ep[1], &e, sizeof e);
    _exit(e == ENOENT ? 127 : 126);
  }
  (void)me;
  close(ep[1]);
  // The command has the stdio and the folder now. Holding copies of the
  // pipes would keep them open after the command and what it left are gone;
  // holding the folder would keep it from being removed.
  int nul = open("/dev/null", O_RDWR);
  dup2(nul, 0); dup2(nul, 1); dup2(nul, 2);
  if (nul > 2) close(nul);
  if (chdir("/") != 0) {}
  say("started %ld subreaper %ld\n", (long)c, subreaper);

  int reported = 0, released = 0, ep_open = 1;
  char line[64];
  size_t len = 0;
  struct Killing k = {0};
  for (;;) {
    if (host_gone && s >= 0) {
      // The host is gone: everything, until none is seen.
      close(s); s = -1;
      start_custody(&k, 1);
    }
    long timeout = -1;
    if (k.active) { timeout = k.next - now_ms(); if (timeout < 0) timeout = 0; }
    struct pollfd p[3] = {{s, POLLIN, 0}, {wake[0], POLLIN, 0}, {ep_open ? ep[0] : -1, POLLIN, 0}};
    int r = poll(p, 3, (int)timeout);
    if (r < 0 && errno != EINTR) break;
    if (r > 0 && ep_open && p[2].revents) {
      int e;
      ssize_t got = read(ep[0], &e, sizeof e);
      if (got == (ssize_t)sizeof e) say("execfailed %ld\n", e, 0);
      else if (got == 0) say("running\n", 0, 0);  // EOF: the exec closed it
      if (got >= 0 || errno != EAGAIN) { close(ep[0]); ep_open = 0; }
    }
    if (r > 0 && p[1].revents) {
      char b[64];
      while (read(wake[0], b, sizeof b) > 0) {}
      reap_adopted(c);
    }
    // Asked on every pass, not only on a wake: a cheap call, and no wake can
    // be missed. Only once the exec-error pipe is done, which the command
    // writes before it exits, so execfailed comes before its exited line.
    if (!reported && !ep_open) {
      siginfo_t si;
      memset(&si, 0, sizeof si);
      // WNOWAIT: read the status, leave the zombie, keep the ids pinned.
      if (waitid(P_PID, (id_t)c, &si, WEXITED | WNOHANG | WNOWAIT) == 0 && si.si_pid == c) {
        say(si.si_code == CLD_EXITED ? "exited %ld\n" : "signalled %ld\n", si.si_status, 0);
        reported = 1;
      }
    }
    if (r > 0 && s >= 0 && p[0].revents) {
      char b[64];
      ssize_t n = read(s, b, sizeof b);
      if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) { host_gone = 1; continue; }
      for (ssize_t i = 0; i < n; i++) {
        if (b[i] != '\n') { if (len < sizeof line - 1) line[len++] = b[i]; continue; }
        line[len] = 0;
        len = 0;
        if (!strcmp(line, "kill")) {
          // Asked: the group, as the host's kill always has. One already
          // running answers once.
          if (!k.active) { k = (struct Killing){0}; k.active = 1; k.next = now_ms(); }
          if (!k.custody) { k.answer = 1; k.deadline = now_ms() + kKillBudgetMs; }
        } else if (!strcmp(line, "leftovers")) {
          struct Census seen = census(c, 0);
          if (seen.failed) say("leftovers unknown\n", 0, 0);
          // Everything still running, killable or not; the command itself
          // (counted in one or the other while it lives) is not a leftover.
#ifdef __linux__
          else say("leftovers group %ld adopted %ld\n", seen.group + seen.unkillable - seen.self,
                   seen.adopted + seen.adopted_unkillable);
#else
          else say("leftovers group %ld adopted %ld\n", seen.group + seen.unkillable - seen.self, -1);
#endif
        } else if (!strcmp(line, "release")) {
          released = 1;
        } else if (!strcmp(line, "abandon")) {
          // The host has stopped waiting, and closing its end is not its
          // death: stop listening, keep killing the group.
          close(s); s = -1;
          start_custody(&k, 0);
          break;
        }
      }
      if (released) break;
    }
    if (k.active && now_ms() >= k.next && kill_tick(c, &k) && k.custody) break;
    // With the socket closed, the doorstop has nothing to do but custody.
    if (s < 0 && !k.active) break;
  }
  // Reap only a command that has ended: one still running here (custody gave
  // up on it, or could not see) must not hold the doorstop in a wait for
  // ever. It is left to its new parent, and the doorstop says so by 125.
  if (c_live(c) != 0) return 125;
  int st;
  while (waitpid(c, &st, 0) < 0 && errno == EINTR) {}
  return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
}
