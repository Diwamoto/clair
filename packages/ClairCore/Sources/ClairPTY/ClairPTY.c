#include "ClairPTY.h"
#include <spawn.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include <TargetConditionals.h>
#if defined(__APPLE__) && !TARGET_OS_IPHONE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

typedef struct { int32_t pid; int32_t error; } ready_message;

static int owned_fd(int fd) {
  if (fd < 0) return -1;
  int result = fcntl(fd, F_DUPFD_CLOEXEC, 10);
  close(fd);
  return result;
}

static int owned_pipe(int fds[2]) {
  int raw[2];
  if (pipe(raw) < 0) return -1;
  fds[0] = owned_fd(raw[0]);
  fds[1] = owned_fd(raw[1]);
  return fds[0] >= 0 && fds[1] >= 0 ? 0 : -1;
}

static int write_all(int fd, const void *buffer, size_t count) {
  const char *bytes = buffer;
  while (count) {
    ssize_t n = write(fd, bytes, count);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return -1;
    bytes += n;
    count -= (size_t)n;
  }
  return 0;
}

static void ignore_signal(int number) {
  struct sigaction action = {0};
  action.sa_handler = SIG_IGN;
  sigemptyset(&action.sa_mask);
  sigaction(number, &action, NULL);
}

static void finish_group(int status, int error) {
  // child has been reaped while this live session leader still pins the PGID.
  // The group kill includes this supervisor. Its daemon parent reaps it.
  clair_pty_exit message = {status, error};
  write_all(4, &message, sizeof(message));
  kill(-getpid(), SIGKILL);
  _exit(127);
}

static void supervise(const char *path, char *const argv[], char *const envp[],
                      int cwd, int slave, int control, int status, int ready,
                      int descriptor_limit) {
  // All source descriptors are >= 10; destinations cannot clobber a source.
  if (fchdir(cwd) < 0 || setsid() < 0 || ioctl(slave, TIOCSCTTY, 0) < 0) {
    ready_message message = {0, errno};
    write_all(ready, &message, sizeof(message));
    _exit(127);
  }
  ignore_signal(SIGTTOU);
  if (tcsetpgrp(slave, getpid()) < 0 || dup2(control, 3) < 0 ||
      dup2(status, 4) < 0 || dup2(ready, 5) < 0 ||
      dup2(slave, 0) < 0 || dup2(slave, 1) < 0 || dup2(slave, 2) < 0) {
    ready_message message = {0, errno};
    write_all(ready, &message, sizeof(message));
    _exit(127);
  }
  // Do not inherit daemon sockets, credentials descriptors, other PTYs or
  // another session's liveness pipe into either supervisor or provider.
  for (int fd = 6; fd < descriptor_limit; ++fd) close(fd);
  int exec_error[2];
  if (pipe(exec_error) < 0) {
    ready_message message = {0, errno};
    write_all(5, &message, sizeof(message));
    _exit(127);
  }
  if (fcntl(exec_error[1], F_SETFD, FD_CLOEXEC) < 0) {
    ready_message message = {0, errno};
    write_all(5, &message, sizeof(message));
    _exit(127);
  }
  ignore_signal(SIGHUP);
  ignore_signal(SIGINT);
  ignore_signal(SIGQUIT);
  ignore_signal(SIGTERM);
  ignore_signal(SIGTSTP);
  ignore_signal(SIGTTIN);
  ignore_signal(SIGPIPE);
  sigset_t empty;
  sigemptyset(&empty);
  sigprocmask(SIG_SETMASK, &empty, NULL);
  pid_t child = fork();
  if (child == 0) {
    close(3); close(4); close(5); close(exec_error[0]);
    struct sigaction action = {0};
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    for (int sig = 1; sig < NSIG; ++sig) sigaction(sig, &action, NULL);
    execve(path, argv, envp);
    int error = errno;
    write_all(exec_error[1], &error, sizeof(error));
    _exit(127);
  }
  close(exec_error[1]);
  if (child < 0) {
    ready_message message = {0, errno};
    write_all(5, &message, sizeof(message));
    _exit(127);
  }
  int launch_error = 0;
  ssize_t n;
  do { n = read(exec_error[0], &launch_error, sizeof(launch_error)); }
  while (n < 0 && errno == EINTR);
  close(exec_error[0]);
  if (n < 0 || (n > 0 && n != sizeof(launch_error))) launch_error = EIO;
  if (launch_error) {
    // Resolve failed exec before reporting it to the daemon. The provider
    // must not become an unreaped orphan in the launch-error rollback race.
    kill(child, SIGKILL);
    int wait_status = 0;
    pid_t waited;
    do { waited = waitpid(child, &wait_status, 0); } while (waited < 0 && errno == EINTR);
    ready_message failed = {child, launch_error};
    write_all(5, &failed, sizeof(failed));
    finish_group(wait_status, waited == child ? 0 : ECHILD);
  }
  ready_message message = {child, launch_error};
  write_all(5, &message, sizeof(message));
  close(5);
  fcntl(3, F_SETFL, O_NONBLOCK);
  for (;;) {
    int wait_status = 0;
    pid_t waited = waitpid(child, &wait_status, WNOHANG);
    if (waited == child) finish_group(wait_status, 0);
    if (waited < 0 && errno != EINTR) finish_group(0, errno);
    struct pollfd pfd = {3, POLLIN | POLLHUP, 0};
    int polled = poll(&pfd, 1, 10);
    if (polled < 0 && errno == EINTR) continue;
    if (polled < 0) {
      kill(child, SIGKILL);
      continue;
    }
    if (polled > 0) {
      unsigned char commands[64];
      ssize_t count = read(3, commands, sizeof(commands));
      if (count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR)) {
        // Daemon death: kill the direct child, reap it, then kill descendants.
        kill(child, SIGKILL);
      }
      for (ssize_t i = 0; i < count; ++i) {
        if (commands[i] == SIGKILL) kill(child, SIGKILL);
        else if (commands[i] == SIGINT || commands[i] == SIGTERM || commands[i] == SIGHUP)
          kill(-getpid(), commands[i]);
      }
    }
  }
}

int clair_pty_spawn(const char *path, char *const argv[], char *const envp[],
                    int cwd_fd, uint16_t rows, uint16_t columns,
                    clair_pty_handle *result) {
  int master = -1, slave = -1;
  int control[2] = {-1, -1}, status[2] = {-1, -1}, ready[2] = {-1, -1};
  int cwd = -1, error = EIO;
  pid_t supervisor = -1;
  struct winsize size = {rows, columns, 0, 0};
  if (openpty(&master, &slave, NULL, NULL, &size) < 0) return errno;
  master = owned_fd(master); slave = owned_fd(slave);
  cwd = fcntl(cwd_fd, F_DUPFD_CLOEXEC, 10);
  if (master < 0 || slave < 0 || cwd < 0 || owned_pipe(control) < 0 ||
      owned_pipe(status) < 0 || owned_pipe(ready) < 0) goto fail;
  // Capture the actual descriptor ceiling before fork (including descriptors
  // opened before a caller lowered RLIMIT_NOFILE).
  int descriptor_limit = 0;
  size_t limit_size = sizeof(descriptor_limit);
  if (sysctlbyname("kern.maxfilesperproc", &descriptor_limit, &limit_size, NULL, 0) < 0 || descriptor_limit <= 0) goto fail;
  supervisor = fork();
  if (supervisor == 0) {
    supervise(path, argv, envp, cwd, slave, control[0], status[1], ready[1], descriptor_limit);
    _exit(127);
  }
  if (supervisor < 0) goto fail;
  close(slave); slave = -1;
  close(cwd); cwd = -1;
  close(control[0]); control[0] = -1;
  close(status[1]); status[1] = -1;
  close(ready[1]); ready[1] = -1;
  struct pollfd pfd = {ready[0], POLLIN, 0};
  int polled;
  do { polled = poll(&pfd, 1, 5000); } while (polled < 0 && errno == EINTR);
  ready_message message = {0, EIO};
  ssize_t count = polled > 0 ? read(ready[0], &message, sizeof(message)) : -1;
  if (count != sizeof(message) || message.error || message.pid <= 0) {
    error = message.error ? message.error : EIO;
    goto fail;
  }
  close(ready[0]); ready[0] = -1;
  if (fcntl(master, F_SETFL, O_NONBLOCK) < 0 ||
      fcntl(control[1], F_SETFL, O_NONBLOCK) < 0 ||
      fcntl(control[1], F_SETNOSIGPIPE, 1) < 0) goto fail;
  *result = (clair_pty_handle){supervisor, message.pid, master, control[1], status[0]};
  return 0;
fail:
  if (supervisor > 0) {
    kill(-supervisor, SIGKILL);
    kill(supervisor, SIGKILL);
    while (waitpid(supervisor, NULL, 0) < 0 && errno == EINTR) {}
  }
  if (master >= 0) close(master);
  if (slave >= 0) close(slave);
  if (cwd >= 0) close(cwd);
  for (int i = 0; i < 2; ++i) {
    if (control[i] >= 0) close(control[i]);
    if (status[i] >= 0) close(status[i]);
    if (ready[i] >= 0) close(ready[i]);
  }
  return error;
}

int clair_pty_resize(int master_fd, uint16_t rows, uint16_t columns) {
  struct winsize size = {rows, columns, 0, 0};
  return ioctl(master_fd, TIOCSWINSZ, &size);
}
#else
#include <errno.h>
int clair_pty_spawn(const char *p, char *const a[], char *const e[], int c,
                    uint16_t r, uint16_t n, clair_pty_handle *h) { return ENOTSUP; }
int clair_pty_resize(int fd, uint16_t r, uint16_t c) { return -1; }
#endif

// At normal app exit, no debugger process group may outlive Clair. Explicit
// stop unregisters after reaping; the fixed cap also bounds leaked adapters.
static pthread_mutex_t isolated_lock = PTHREAD_MUTEX_INITIALIZER;
static pid_t isolated_pids[32];
static pthread_once_t isolated_once = PTHREAD_ONCE_INIT;
static void stop_isolated_at_exit(void) {
  pthread_mutex_lock(&isolated_lock);
  for (size_t i = 0; i < 32; ++i) if (isolated_pids[i] > 0) kill(-isolated_pids[i], SIGKILL);
  pthread_mutex_unlock(&isolated_lock);
}
static void register_isolated_cleanup(void) { atexit(stop_isolated_at_exit); }

void clair_unregister_isolated(int32_t pid) {
  pthread_mutex_lock(&isolated_lock);
  for (size_t i = 0; i < 32; ++i) if (isolated_pids[i] == pid) isolated_pids[i] = 0;
  pthread_mutex_unlock(&isolated_lock);
}

int clair_spawn_isolated(const char *path, char *const argv[], char *const envp[],
                        const char *cwd, int32_t *pid) {
  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attr;
  int error = posix_spawn_file_actions_init(&actions);
  if (error) return error;
  error = posix_spawnattr_init(&attr);
  if (error) { posix_spawn_file_actions_destroy(&actions); return error; }
  error = posix_spawn_file_actions_addchdir_np(&actions, cwd);
  if (!error) error = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
  if (!error) error = posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
  if (!error) error = posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
  if (!error) error = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
  if (!error) error = posix_spawnattr_setpgroup(&attr, 0);
  if (!error) {
    pid_t child = 0;
    error = posix_spawn(&child, path, &actions, &attr, argv, envp);
    if (!error) {
      pthread_once(&isolated_once, register_isolated_cleanup);
      pthread_mutex_lock(&isolated_lock);
      size_t slot = 0;
      while (slot < 32 && isolated_pids[slot] > 0) ++slot;
      if (slot == 32) {
        kill(-child, SIGKILL);
        waitpid(child, NULL, 0);
        error = ENOSPC;
      } else {
        isolated_pids[slot] = child;
        *pid = (int32_t)child;
      }
      pthread_mutex_unlock(&isolated_lock);
    }
  }
  posix_spawnattr_destroy(&attr);
  posix_spawn_file_actions_destroy(&actions);
  return error;
}
