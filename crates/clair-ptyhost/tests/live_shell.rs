#![cfg(unix)]

use std::io::{self, Read, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

const MAGIC: [u8; 2] = *b"CP";
const VERSION: u8 = 1;
const OUTPUT: u8 = 0x81;
const EXIT: u8 = 0x82;
const ERROR: u8 = 0xff;
const MAX_PAYLOAD_LENGTH: usize = 64 * 1024;

struct ShellHarness {
    child: Child,
    stdin: ChildStdin,
    stdout: ChildStdout,
}

impl ShellHarness {
    fn start(rows: u16, columns: u16) -> io::Result<Self> {
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
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| io::Error::other("PTY harness stdin was not piped"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| io::Error::other("PTY harness stdout was not piped"))?;
        Ok(Self {
            child,
            stdin,
            stdout,
        })
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
            let (kind, payload) = read_frame(&mut self.stdout)?;
            match kind {
                OUTPUT => output.extend_from_slice(&payload),
                ERROR => {
                    return Err(io::Error::other(format!(
                        "PTY host reported an error: {}",
                        String::from_utf8_lossy(&payload)
                    )));
                }
                EXIT => break,
                other => {
                    return Err(io::Error::other(format!(
                        "unexpected PTY host frame 0x{other:02x}"
                    )));
                }
            }
        }
        let status = self.child.wait()?;
        if !status.success() {
            return Err(io::Error::other(format!("PTY host exited with {status}")));
        }
        Ok(output)
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
fn shell_command_round_trips_raw_output_and_resize() -> io::Result<()> {
    let mut harness = ShellHarness::start(24, 80)?;
    harness.send(2, &[0, 40, 0, 120])?;
    harness.send(1, b"stty size; printf 'CLAIR_SHELL_OK\\n'; exit\n")?;

    let output = harness.collect_until_exit()?;
    assert!(
        output
            .windows(b"40 120".len())
            .any(|window| window == b"40 120")
    );
    assert!(
        output
            .windows(b"CLAIR_SHELL_OK".len())
            .any(|window| window == b"CLAIR_SHELL_OK")
    );
    Ok(())
}

#[test]
fn shell_preserves_cjk_and_osc_bytes() -> io::Result<()> {
    let mut harness = ShellHarness::start(24, 80)?;
    let cjk_command = "printf '\\033]0;clair\\007CJK-日本語\\n'; exit\n".to_owned();
    harness.send(1, cjk_command.as_bytes())?;

    let output = harness.collect_until_exit()?;
    assert!(
        output
            .windows("CJK-日本語".len())
            .any(|window| window == "CJK-日本語".as_bytes())
    );
    assert!(
        output
            .windows(b"\x1b]0;clair\x07".len())
            .any(|window| window == b"\x1b]0;clair\x07")
    );
    Ok(())
}

#[test]
fn terminal_flood_completes_without_host_crash() -> io::Result<()> {
    let mut harness = ShellHarness::start(24, 80)?;
    harness.send(
        1,
        b"i=0; while [ \"$i\" -lt 100 ]; do printf 'flood-%03d\\n' \"$i\"; i=$((i+1)); done; printf 'FLOOD_END\\n'; exit\n",
    )?;

    let output = harness.collect_until_exit()?;
    assert!(
        output
            .windows(b"flood-099".len())
            .any(|window| window == b"flood-099")
    );
    assert!(
        output
            .windows(b"FLOOD_END".len())
            .any(|window| window == b"FLOOD_END")
    );
    Ok(())
}

#[test]
fn malformed_frame_is_rejected_and_shell_is_reaped() -> io::Result<()> {
    let mut harness = ShellHarness::start(24, 80)?;
    harness.stdin.write_all(&MAGIC)?;
    harness.stdin.write_all(&[VERSION, 1])?;
    harness
        .stdin
        .write_all(&u32::try_from(MAX_PAYLOAD_LENGTH + 1).unwrap().to_be_bytes())?;
    harness.stdin.flush()?;

    let mut saw_error = false;
    loop {
        let (kind, _) = read_frame(&mut harness.stdout)?;
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
