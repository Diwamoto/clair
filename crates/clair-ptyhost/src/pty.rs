#![allow(
    unsafe_code,
    reason = "PTY creation and terminal sizing require the macOS libc ABI"
)]

use std::env;
use std::ffi::{CString, c_char};
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd};
use std::path::Path;

use crate::SpawnOptions;

const LOGIN_PATH: &str = "/usr/bin:/bin:/usr/sbin:/sbin";
const INHERITED_ENVIRONMENT_KEYS: &[&str] = &[
    "HOME",
    "USER",
    "LOGNAME",
    "TMPDIR",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "LC_MESSAGES",
    "SSH_AUTH_SOCK",
    "SSH_AGENT_PID",
    "__CF_USER_TEXT_ENCODING",
];

#[derive(Debug)]
pub struct SpawnedPty {
    pub master: File,
    pub pid: libc::pid_t,
}

pub fn spawn(options: &SpawnOptions) -> io::Result<SpawnedPty> {
    let shell = c_string(&options.shell, "shell")?;
    let cwd = c_string(&options.cwd, "working directory")?;
    let login_argument = CString::new("-l").expect("static shell argument has no NUL");
    let environment = child_environment(&options.shell, &options.cwd)?;
    let mut environment_pointers: Vec<*const c_char> =
        environment.iter().map(|value| value.as_ptr()).collect();
    environment_pointers.push(std::ptr::null());
    let shell_arguments = [shell.as_ptr(), login_argument.as_ptr(), std::ptr::null()];
    let mut window = libc::winsize {
        ws_row: options.rows,
        ws_col: options.columns,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let mut master_fd = -1;

    // SAFETY: forkpty initializes the caller-owned master fd and copies the
    // caller-owned winsize. The child immediately execs or exits without
    // returning into Rust's parent-side state.
    let pid = unsafe {
        libc::forkpty(
            &raw mut master_fd,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &raw mut window,
        )
    };
    if pid < 0 {
        return Err(io::Error::last_os_error());
    }

    if pid == 0 {
        // SAFETY: forkpty returned zero, so these calls run in the child
        // before exec. All pointers are NUL-terminated CString values.
        unsafe {
            if libc::chdir(cwd.as_ptr()) != 0 {
                libc::_exit(127);
            }
            libc::execve(
                shell.as_ptr(),
                shell_arguments.as_ptr(),
                environment_pointers.as_ptr(),
            );
            libc::_exit(127);
        }
    }

    if master_fd < 0 {
        return Err(io::Error::other("forkpty returned an invalid master fd"));
    }

    // SAFETY: master_fd is the unique fd returned by forkpty on the parent
    // side and is transferred to this File exactly once.
    let master = unsafe { File::from_raw_fd(master_fd) };
    Ok(SpawnedPty { master, pid })
}

pub fn resize_file<W: AsRawFd>(master: &W, rows: u16, columns: u16) -> io::Result<()> {
    let window = libc::winsize {
        ws_row: rows,
        ws_col: columns,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };

    // SAFETY: ioctl receives a valid PTY master fd and a pointer to a
    // stack-owned winsize with the ABI expected by TIOCSWINSZ.
    let result = unsafe { libc::ioctl(master.as_raw_fd(), libc::TIOCSWINSZ, &raw const window) };
    if result == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

pub fn terminate(pid: libc::pid_t) {
    // forkpty makes the child a session leader, so signal the process group
    // first to avoid leaving a shell child holding the PTY open.
    // SAFETY: kill only receives the process-group id and a constant signal.
    unsafe {
        if libc::kill(-pid, libc::SIGTERM) == -1 {
            let _ = libc::kill(pid, libc::SIGTERM);
        }
    }
}

pub fn wait_for_exit(pid: libc::pid_t) -> io::Result<u8> {
    let mut status = 0;
    loop {
        // SAFETY: waitpid writes to the caller-owned status value for the
        // known child process returned by forkpty.
        let result = unsafe { libc::waitpid(pid, &raw mut status, 0) };
        if result == pid {
            return Ok(exit_status(status));
        }
        if result == -1 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            return Err(error);
        }
    }
}

fn child_environment(shell: &Path, cwd: &Path) -> io::Result<Vec<CString>> {
    let mut entries = Vec::new();
    for key in INHERITED_ENVIRONMENT_KEYS {
        if let Ok(value) = env::var(key) {
            if !value.is_empty() {
                entries.push(env_entry(key, &value)?);
            }
        }
    }
    entries.push(env_entry("TERM", "xterm-256color")?);
    entries.push(env_entry("COLORTERM", "truecolor")?);
    entries.push(env_entry("TERM_PROGRAM", "Clair")?);
    entries.push(env_entry("SHELL", &shell.to_string_lossy())?);
    entries.push(env_entry("PWD", &cwd.to_string_lossy())?);
    entries.push(env_entry("PATH", LOGIN_PATH)?);
    Ok(entries)
}

fn env_entry(key: &str, value: &str) -> io::Result<CString> {
    CString::new(format!("{key}={value}")).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{key} contains an embedded NUL byte"),
        )
    })
}

fn c_string(path: &Path, label: &str) -> io::Result<CString> {
    let value = path.to_string_lossy();
    CString::new(value.as_bytes()).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{label} contains an embedded NUL byte"),
        )
    })
}

fn exit_status(status: libc::c_int) -> u8 {
    if libc::WIFSIGNALED(status) {
        128_u8.saturating_add(u8::try_from(status & 0x7f).unwrap_or(u8::MAX))
    } else {
        u8::try_from((status >> 8) & 0xff).unwrap_or(u8::MAX)
    }
}
