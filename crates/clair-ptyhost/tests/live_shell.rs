#![cfg(unix)]

use std::fmt::Write as _;
use std::io::{self, Read, Write};
use std::process::{Child, ChildStdin, Command, Stdio};

const MAGIC: [u8; 2] = *b"CP";
const VERSION: u8 = 1;
const OUTPUT: u8 = 0x81;
const EXIT: u8 = 0x82;
const ERROR: u8 = 0xff;
const MAX_PAYLOAD_LENGTH: usize = 64 * 1024;

struct ShellHarness {
    child: Child,
    stdin: ChildStdin,
    frames: std::sync::mpsc::Receiver<io::Result<(u8, Vec<u8>)>>,
}

impl ShellHarness {
    fn start(rows: u16, columns: u16, environment: &[(&str, &str)]) -> io::Result<Self> {
        let mut child = Command::new(env!("CARGO_BIN_EXE_clair-ptyhost"))
            .args([
                "--spawn",
                "--cwd",
                env!("CARGO_MANIFEST_DIR"),
                "--shell",
                "/bin/sh",
                "--rows",
                &rows.to_string(),
                "--cols",
                &columns.to_string(),
            ])
            .envs(environment.iter().copied())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let stdin = child.stdin.take().expect("piped stdin");
        let mut stdout = child.stdout.take().expect("piped stdout");
        let (sender, frames) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            loop {
                let frame = read_frame(&mut stdout);
                let done = frame.is_err() || matches!(&frame, Ok((EXIT, _)));
                if sender.send(frame).is_err() || done {
                    break;
                }
            }
        });
        Ok(Self {
            child,
            stdin,
            frames,
        })
    }

    fn next_frame(&self) -> io::Result<(u8, Vec<u8>)> {
        self.frames
            .recv_timeout(std::time::Duration::from_secs(5))
            .map_err(|error| io::Error::new(io::ErrorKind::TimedOut, error))?
    }

    fn send(&mut self, kind: u8, payload: &[u8]) -> io::Result<()> {
        let length = u32::try_from(payload.len())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "payload is too large"))?;
        self.stdin.write_all(&MAGIC)?;
        self.stdin.write_all(&[VERSION, kind])?;
        self.stdin.write_all(&length.to_be_bytes())?;
        self.stdin.write_all(payload)?;
        self.stdin.flush()
    }

    fn collect_until_exit(mut self) -> io::Result<Vec<u8>> {
        let mut output = Vec::new();
        loop {
            let (kind, payload) = self.next_frame()?;
            match kind {
                OUTPUT => output.extend_from_slice(&payload),
                ERROR => {
                    return Err(io::Error::other(
                        String::from_utf8_lossy(&payload).into_owned(),
                    ));
                }
                EXIT => break,
                other => return Err(io::Error::other(format!("unexpected frame {other}"))),
            }
        }
        if !self.child.wait()?.success() {
            return Err(io::Error::other("PTY host failed"));
        }
        Ok(output)
    }
}

impl Drop for ShellHarness {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn read_frame(reader: &mut impl Read) -> io::Result<(u8, Vec<u8>)> {
    let mut header = [0_u8; 8];
    reader.read_exact(&mut header)?;
    if header[..2] != MAGIC {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "PTY host returned an invalid frame magic",
        ));
    }
    if header[2] != VERSION {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "PTY host returned an unsupported frame version",
        ));
    }
    let length = u32::from_be_bytes([header[4], header[5], header[6], header[7]]) as usize;
    if length > MAX_PAYLOAD_LENGTH {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "PTY host returned an oversized frame",
        ));
    }
    let mut payload = vec![0_u8; length];
    reader.read_exact(&mut payload)?;
    Ok((header[3], payload))
}

#[test]
fn shell_preserves_raw_output_and_applies_resize() -> io::Result<()> {
    let mut harness = ShellHarness::start(24, 80, &[])?;
    harness.send(2, &[0, 40, 0, 120])?;
    // Disable echo before sending the payload so input echo cannot satisfy assertions.
    harness.send(1, b"stty -echo; printf 'READY_'\"FOR_INPUT\\n\"\n")?;
    let mut ready = Vec::new();
    while !ready
        .windows(b"READY_FOR_INPUT".len())
        .any(|w| w == b"READY_FOR_INPUT")
    {
        let (kind, bytes) = harness.next_frame()?;
        if kind != OUTPUT {
            return Err(io::Error::other("shell failed before ready"));
        }
        ready.extend_from_slice(&bytes);
    }
    harness.send(1, "stty size; printf '\\033]0;clair\\007CJK-日本語\\n'; i=0; while [ \"$i\" -lt 4096 ]; do printf 'raw-%04d\\n' \"$i\"; i=$((i+1)); done; exit\n".as_bytes())?;
    let output = harness.collect_until_exit()?;
    assert!(output.windows(b"40 120".len()).any(|w| w == b"40 120"));
    assert!(
        output
            .windows("CJK-日本語".len())
            .any(|w| w == "CJK-日本語".as_bytes())
    );
    assert!(
        output
            .windows(b"\x1b]0;clair\x07".len())
            .any(|w| w == b"\x1b]0;clair\x07")
    );
    let mut expected = String::new();
    for index in 0..4096 {
        write!(&mut expected, "raw-{index:04}\r\n").expect("write to String");
    }
    assert!(
        output
            .windows(expected.len())
            .any(|w| w == expected.as_bytes())
    );
    Ok(())
}

#[test]
fn shell_rebuilds_terminal_environment_without_inheriting_host_values() -> io::Result<()> {
    let mut harness = ShellHarness::start(
        24,
        80,
        &[
            ("CLAIR_SHOULD_NOT_LEAK", "stale"),
            ("ZDOTDIR", "/tmp/clair-should-not-use"),
        ],
    )?;
    harness.send(1, b"printf 'CLAIR_ENV:%s:%s:%s:%s:%s:%s:%s\\n' \"$TERM\" \"$COLORTERM\" \"$SHELL\" \"${ZDOTDIR-unset}\" \"$TERM_PROGRAM\" \"$PWD\" \"${CLAIR_SHOULD_NOT_LEAK-unset}\"; exit\n")?;
    let output = harness.collect_until_exit()?;
    let expected = format!(
        "CLAIR_ENV:xterm-256color:truecolor:/bin/sh:unset:Clair:{}:unset",
        env!("CARGO_MANIFEST_DIR")
    );
    assert!(
        output
            .windows(expected.len())
            .any(|w| w == expected.as_bytes()),
        "{}",
        String::from_utf8_lossy(&output)
    );
    Ok(())
}

#[test]
fn malformed_frame_is_rejected_and_shell_is_reaped() -> io::Result<()> {
    let mut harness = ShellHarness::start(24, 80, &[])?;
    harness.stdin.write_all(&MAGIC)?;
    harness.stdin.write_all(&[VERSION, 1])?;
    harness
        .stdin
        .write_all(&u32::try_from(MAX_PAYLOAD_LENGTH + 1).unwrap().to_be_bytes())?;
    harness.stdin.flush()?;

    let mut saw_error = false;
    loop {
        let (kind, _) = harness.next_frame()?;
        match kind {
            ERROR => saw_error = true,
            EXIT => break,
            OUTPUT => {}
            other => {
                return Err(io::Error::other(format!(
                    "unexpected frame after malformed input: 0x{other:02x}"
                )));
            }
        }
    }
    let status = harness.child.wait()?;
    assert!(status.success());
    assert!(saw_error);
    Ok(())
}
