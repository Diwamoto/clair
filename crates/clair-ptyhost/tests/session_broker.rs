#![cfg(unix)]

use std::fs;
use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::Duration;

const MAGIC: [u8; 2] = *b"CB";
const VERSION: u8 = 1;
const HEADER_LENGTH: usize = 8;
const MAX_PAYLOAD_LENGTH: usize = 64 * 1024;
const ATTACH: u8 = 1;
const INPUT: u8 = 2;
const ATTACHED: u8 = 0x81;
const OUTPUT: u8 = 0x82;
const GAP: u8 = 0x83;
const EXIT: u8 = 0x84;
const ERROR: u8 = 0xff;
const ERROR_INVALID_REQUEST: u8 = 1;
const ERROR_SESSION_MISSING: u8 = 2;
const ERROR_PROTOCOL: u8 = 4;

static NEXT_FIXTURE_ID: AtomicU64 = AtomicU64::new(1);

struct BrokerHarness {
    root: PathBuf,
    socket: PathBuf,
    child: Child,
}

impl BrokerHarness {
    fn start() -> io::Result<Self> {
        let fixture_id = NEXT_FIXTURE_ID.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "clair-broker-p07-{}-{fixture_id}",
            std::process::id()
        ));
        fs::create_dir(&root)?;
        let socket = root.join("broker.sock");
        let catalog = root.join("sessions.catalog");
        let child = Command::new(env!("CARGO_BIN_EXE_clair-ptyhost"))
            .args([
                "--broker",
                "--socket",
                socket.to_str().ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidInput, "socket path is not UTF-8")
                })?,
                "--catalog",
                catalog.to_str().ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidInput, "catalog path is not UTF-8")
                })?,
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        let mut harness = Self {
            root,
            socket,
            child,
        };

        for _ in 0..100 {
            if harness.socket.exists() {
                return Ok(harness);
            }
            thread::sleep(Duration::from_millis(10));
        }

        let _ = harness.child.kill();
        let _ = harness.child.wait();
        let _ = fs::remove_dir_all(&harness.root);
        Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "session broker did not create its socket",
        ))
    }

    fn connect(&self) -> io::Result<UnixStream> {
        let stream = UnixStream::connect(&self.socket)?;
        stream.set_read_timeout(Some(Duration::from_secs(5)))?;
        stream.set_write_timeout(Some(Duration::from_secs(5)))?;
        Ok(stream)
    }
}

impl Drop for BrokerHarness {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[derive(Debug, Eq, PartialEq)]
struct Attachment {
    session_id: String,
    epoch: u64,
    current_offset: u64,
    oldest_offset: u64,
    exited: bool,
}

fn send_frame(stream: &mut UnixStream, kind: u8, payload: &[u8]) -> io::Result<()> {
    let length = u32::try_from(payload.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "payload is too large"))?;
    stream.write_all(&MAGIC)?;
    stream.write_all(&[VERSION, kind])?;
    stream.write_all(&length.to_be_bytes())?;
    stream.write_all(payload)?;
    stream.flush()
}

fn read_frame(stream: &mut UnixStream) -> io::Result<(u8, Vec<u8>)> {
    let mut header = [0_u8; HEADER_LENGTH];
    stream.read_exact(&mut header)?;
    if header[..2] != MAGIC {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "broker returned an invalid frame magic",
        ));
    }
    if header[2] != VERSION {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "broker returned an unsupported frame version",
        ));
    }
    let length = u32::from_be_bytes([header[4], header[5], header[6], header[7]]) as usize;
    if length > MAX_PAYLOAD_LENGTH {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "broker returned an oversized frame",
        ));
    }
    let mut payload = vec![0_u8; length];
    stream.read_exact(&mut payload)?;
    Ok((header[3], payload))
}

fn attach_payload(mode: u8, session_id: &str, cursor: u64, cwd: &str, shell: &str) -> Vec<u8> {
    let mut payload = Vec::new();
    payload.push(mode);
    payload.push(u8::try_from(session_id.len()).unwrap());
    payload.extend_from_slice(session_id.as_bytes());
    payload.extend_from_slice(&cursor.to_be_bytes());
    payload.extend_from_slice(&24_u16.to_be_bytes());
    payload.extend_from_slice(&80_u16.to_be_bytes());
    payload.extend_from_slice(&u16::try_from(cwd.len()).unwrap().to_be_bytes());
    payload.extend_from_slice(cwd.as_bytes());
    payload.extend_from_slice(&u16::try_from(shell.len()).unwrap().to_be_bytes());
    payload.extend_from_slice(shell.as_bytes());
    payload
}

fn parse_attachment(payload: &[u8]) -> io::Result<Attachment> {
    let session_length = *payload
        .first()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing session ID length"))?
        as usize;
    let session_end = 1 + session_length;
    if payload.len() < session_end + 8 + 8 + 8 + 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "truncated attached frame",
        ));
    }
    let session_id = String::from_utf8(payload[1..session_end].to_vec())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "session ID is not UTF-8"))?;
    let epoch = u64::from_be_bytes(payload[session_end..session_end + 8].try_into().unwrap());
    let current_start = session_end + 8;
    let current_offset = u64::from_be_bytes(
        payload[current_start..current_start + 8]
            .try_into()
            .unwrap(),
    );
    let oldest_start = current_start + 8;
    let oldest_offset =
        u64::from_be_bytes(payload[oldest_start..oldest_start + 8].try_into().unwrap());
    let state = payload[oldest_start + 8];
    if state > 1 || oldest_start + 9 != payload.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid attached frame state",
        ));
    }
    Ok(Attachment {
        session_id,
        epoch,
        current_offset,
        oldest_offset,
        exited: state == 1,
    })
}

fn output_payload(payload: &[u8]) -> io::Result<(u64, &[u8])> {
    if payload.len() < 8 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "truncated output frame",
        ));
    }
    let offset = u64::from_be_bytes(payload[..8].try_into().unwrap());
    Ok((offset, &payload[8..]))
}

fn read_output_until(stream: &mut UnixStream, marker: &[u8]) -> io::Result<(Vec<u8>, u64)> {
    let mut output = Vec::new();
    let mut cursor = 0;
    loop {
        let (kind, payload) = read_frame(stream)?;
        match kind {
            OUTPUT => {
                let (offset, bytes) = output_payload(&payload)?;
                cursor = cursor.max(offset.saturating_add(bytes.len() as u64));
                output.extend_from_slice(bytes);
                if output.windows(marker.len()).any(|window| window == marker) {
                    return Ok((output, cursor));
                }
            }
            GAP => {
                return Err(io::Error::other("unexpected output gap before marker"));
            }
            ERROR => {
                return Err(io::Error::other(format!(
                    "broker returned an error: {}",
                    String::from_utf8_lossy(&payload)
                )));
            }
            EXIT => return Err(io::Error::other("session exited before output marker")),
            other => {
                return Err(io::Error::other(format!(
                    "unexpected broker frame 0x{other:02x} before output marker"
                )));
            }
        }
    }
}

fn read_until_exit(stream: &mut UnixStream) -> io::Result<u8> {
    loop {
        let (kind, payload) = read_frame(stream)?;
        match kind {
            EXIT => {
                if payload.len() != 9 {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "invalid exit frame",
                    ));
                }
                return Ok(payload[0]);
            }
            OUTPUT | GAP => {}
            ERROR => {
                return Err(io::Error::other(format!(
                    "broker returned an error: {}",
                    String::from_utf8_lossy(&payload)
                )));
            }
            other => {
                return Err(io::Error::other(format!(
                    "unexpected broker frame 0x{other:02x} while waiting for exit"
                )));
            }
        }
    }
}

#[test]
fn broker_rejects_bounded_frames_and_reports_missing_sessions() -> io::Result<()> {
    let harness = BrokerHarness::start()?;

    let mut malformed = harness.connect()?;
    malformed.write_all(&MAGIC)?;
    malformed.write_all(&[VERSION, INPUT])?;
    malformed.write_all(&u32::try_from(MAX_PAYLOAD_LENGTH + 1).unwrap().to_be_bytes())?;
    malformed.flush()?;
    let (kind, payload) = read_frame(&mut malformed)?;
    assert_eq!(kind, ERROR);
    assert_eq!(payload.first().copied(), Some(ERROR_PROTOCOL));
    let _ = malformed.shutdown(Shutdown::Both);

    let mut missing = harness.connect()?;
    let session_id = "01234567-89ab-cdef-0123-456789abcdef";
    let cwd = env!("CARGO_MANIFEST_DIR");
    send_frame(
        &mut missing,
        ATTACH,
        &attach_payload(2, session_id, 0, cwd, "/bin/sh"),
    )?;
    let (kind, payload) = read_frame(&mut missing)?;
    assert_eq!(kind, ERROR);
    assert_eq!(payload.first().copied(), Some(ERROR_SESSION_MISSING));
    let _ = missing.shutdown(Shutdown::Both);

    Ok(())
}

#[test]
fn broker_reports_protocol_errors_after_attach() -> io::Result<()> {
    let harness = BrokerHarness::start()?;
    let mut client = harness.connect()?;
    let session_id = format!(
        "01234567-89ab-cdef-0123-{:012x}",
        NEXT_FIXTURE_ID.fetch_add(1, Ordering::Relaxed)
    );
    let cwd = env!("CARGO_MANIFEST_DIR");
    send_frame(
        &mut client,
        ATTACH,
        &attach_payload(1, &session_id, 0, cwd, "/bin/sh"),
    )?;
    let (kind, _) = read_frame(&mut client)?;
    assert_eq!(kind, ATTACHED);

    send_frame(&mut client, OUTPUT, &[0; 8])?;
    // The shell may emit its prompt before the broker processes the invalid request.
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "missing broker error",
            ));
        }
        client.set_read_timeout(Some(remaining))?;
        let (kind, payload) = read_frame(&mut client)?;
        if kind == OUTPUT {
            output_payload(&payload)?;
            continue;
        }
        assert_eq!(kind, ERROR);
        assert_eq!(payload.first().copied(), Some(ERROR_INVALID_REQUEST));
        break;
    }

    Ok(())
}

#[test]
fn broker_reattaches_running_pty_after_client_disconnect() -> io::Result<()> {
    let harness = BrokerHarness::start()?;
    let session_id = format!(
        "01234567-89ab-cdef-0123-{:012x}",
        NEXT_FIXTURE_ID.fetch_add(1, Ordering::Relaxed)
    );
    let cwd = env!("CARGO_MANIFEST_DIR");
    let command = b"printf 'P07_'\"REATTACH_ONE\\n\"; read reply; printf 'P07_REATTACH_TWO:'\"$reply\\n\"; exit\n";

    let mut first = harness.connect()?;
    send_frame(
        &mut first,
        ATTACH,
        &attach_payload(1, &session_id, 0, cwd, "/bin/sh"),
    )?;
    let (kind, payload) = read_frame(&mut first)?;
    assert_eq!(kind, ATTACHED);
    let first_attachment = parse_attachment(&payload)?;
    assert_eq!(first_attachment.session_id, session_id);
    assert_eq!(first_attachment.epoch, 1);
    assert!(!first_attachment.exited);
    send_frame(&mut first, INPUT, command)?;
    let (_, cursor) = read_output_until(&mut first, b"P07_REATTACH_ONE")?;
    first.shutdown(Shutdown::Both)?;
    drop(first);

    let mut second = harness.connect()?;
    send_frame(
        &mut second,
        ATTACH,
        &attach_payload(2, &session_id, cursor, cwd, "/bin/sh"),
    )?;
    let (kind, payload) = read_frame(&mut second)?;
    assert_eq!(kind, ATTACHED);
    let second_attachment = parse_attachment(&payload)?;
    assert_eq!(second_attachment.session_id, session_id);
    assert_eq!(second_attachment.epoch, first_attachment.epoch);
    assert!(second_attachment.current_offset >= cursor);
    assert!(!second_attachment.exited);

    send_frame(&mut second, INPUT, b"hello\n")?;
    let (second_output, _) = read_output_until(&mut second, b"P07_REATTACH_TWO:hello")?;
    assert!(
        !second_output
            .windows(b"P07_REATTACH_ONE".len())
            .any(|window| window == b"P07_REATTACH_ONE")
    );
    assert_eq!(read_until_exit(&mut second)?, 0);

    Ok(())
}
