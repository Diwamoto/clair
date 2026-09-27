#ifndef CLAIR_PTY_H
#define CLAIR_PTY_H
#include <stdint.h>

typedef struct {
  int32_t supervisor_pid;
  int32_t provider_pid;
  int32_t master_fd;
  int32_t control_fd;
  int32_t status_fd;
} clair_pty_handle;

typedef struct {
  int32_t wait_status;
  int32_t error;
} clair_pty_exit;

// argv/envp and the validated cwd descriptor are owned by the caller.
// After fork only native async-signal-safe code runs before exec.
int clair_pty_spawn(const char *path, char *const argv[], char *const envp[],
                    int cwd_fd, uint16_t rows, uint16_t columns,
                    clair_pty_handle *result);
int clair_pty_resize(int master_fd, uint16_t rows, uint16_t columns);

// Start a debugger adapter as the leader of its own process group. Killing the
// group also stops debugserver/debuggee children if the adapter hangs or exits.
int clair_spawn_isolated(const char *path, char *const argv[], char *const envp[],
                        const char *cwd, int32_t *pid);
void clair_unregister_isolated(int32_t pid);
#endif
