mod broker;
mod protocol;
mod pty;

use std::env;
use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::mpsc::{self, SyncSender};
use std::thread;

use protocol::{Frame, FrameKind, ProtocolError, read_frame};

const SMOKE_RESPONSE: &str = "clair-ptyhost/0 smoke=ok";
const IO_BUFFER_LENGTH: usize = 16 * 1024;
const DEFAULT_ROWS: u16 = 24;
const DEFAULT_COLUMNS: u16 = 80;
const MAX_DIMENSION: u16 = 1_000;

#[derive(Clone, Debug, Eq, PartialEq)]
struct SpawnOptions {
    cwd: PathBuf,
    shell: PathBuf,
    rows: u16,
    columns: u16,
}

impl Default for SpawnOptions {
    fn default() -> Self {
        Self {
            cwd: env::current_dir().unwrap_or_else(|_| PathBuf::from("/")),
            shell: PathBuf::from(env::var_os("SHELL").unwrap_or_else(|| "/bin/zsh".into())),
            rows: DEFAULT_ROWS,
            columns: DEFAULT_COLUMNS,
        }
    }
}

enum HostEvent {
    Output(Vec<u8>),
    ClientFrame(Frame),
    ClientClosed,
    ClientProtocolError(String),
    PtyClosed,
    PtyReadError(String),
}

fn smoke_response() -> &'static str {
    SMOKE_RESPONSE
}

fn main() -> ExitCode {
    let arguments: Vec<String> = env::args().skip(1).collect();
    match run(&arguments) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("clair-ptyhost: {error}");
            ExitCode::from(1)
        }
    }
}

fn run(arguments: &[String]) -> Result<(), String> {
    match arguments.first().map(String::as_str) {
        Some("--smoke") => {
            println!("{}", smoke_response());
            Ok(())
        }
        Some("--help" | "-h") => {
            print_usage();
            Ok(())
        }
        Some("--spawn") => {
            let options = parse_spawn_options(&arguments[1..])?;
            run_spawn(&options)
        }
        Some("--broker") => {
            let options = parse_broker_options(&arguments[1..])?;
            broker::run(&options)
        }
        Some("--version") | None => {
            println!("clair-ptyhost {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        Some(argument) => Err(format!("unknown argument: {argument}\n{}", usage_text())),
    }
}

fn parse_spawn_options(arguments: &[String]) -> Result<SpawnOptions, String> {
    let mut options = SpawnOptions::default();
    let mut index = 0;
    while index < arguments.len() {
        let argument = arguments[index].as_str();
        match argument {
            "--cwd" => {
                options.cwd = PathBuf::from(required_value(arguments, &mut index, argument)?);
            }
            "--shell" => {
                options.shell = PathBuf::from(required_value(arguments, &mut index, argument)?);
            }
            "--rows" => {
                let value = required_value(arguments, &mut index, argument)?;
                options.rows = parse_dimension(&value, argument)?;
            }
            "--cols" | "--columns" => {
                let value = required_value(arguments, &mut index, argument)?;
                options.columns = parse_dimension(&value, argument)?;
            }
            "--help" | "-h" => return Err(usage_text().to_owned()),
            other => return Err(format!("unknown spawn argument: {other}\n{}", usage_text())),
        }
        index += 1;
    }
    Ok(options)
}

fn parse_broker_options(arguments: &[String]) -> Result<broker::BrokerOptions, String> {
    let mut socket = None;
    let mut catalog = None;
    let mut index = 0;
    while index < arguments.len() {
        let argument = arguments[index].as_str();
        match argument {
            "--socket" => {
                socket = Some(PathBuf::from(required_value(
                    arguments, &mut index, argument,
                )?));
            }
            "--catalog" => {
                catalog = Some(PathBuf::from(required_value(
                    arguments, &mut index, argument,
                )?));
            }
            "--help" | "-h" => return Err(usage_text().to_owned()),
            other => {
                return Err(format!(
                    "unknown broker argument: {other}\n{}",
                    usage_text()
                ));
            }
        }
        index += 1;
    }
    let socket = socket.ok_or_else(|| format!("--broker requires --socket\n{}", usage_text()))?;
    let catalog =
        catalog.ok_or_else(|| format!("--broker requires --catalog\n{}", usage_text()))?;
    Ok(broker::BrokerOptions { socket, catalog })
}

fn required_value(
    arguments: &[String],
    index: &mut usize,
    argument: &str,
) -> Result<String, String> {
    *index += 1;
    arguments
        .get(*index)
        .cloned()
        .ok_or_else(|| format!("{argument} requires a value"))
}

fn parse_dimension(value: &str, argument: &str) -> Result<u16, String> {
    let dimension = value
        .parse::<u16>()
        .map_err(|_| format!("{argument} must be an integer between 1 and {MAX_DIMENSION}"))?;
    if dimension == 0 || dimension > MAX_DIMENSION {
        return Err(format!("{argument} must be between 1 and {MAX_DIMENSION}"));
    }
    Ok(dimension)
}

fn run_spawn(options: &SpawnOptions) -> Result<(), String> {
    let spawned = pty::spawn(options).map_err(|error| format!("could not spawn PTY: {error}"))?;
    let reader = spawned
        .master
        .try_clone()
        .map_err(|error| format!("could not clone PTY master: {error}"))?;
    let mut writer = spawned.master;
    let child_pid = spawned.pid;
    let (sender, receiver) = mpsc::sync_channel(64);

    spawn_pty_reader(reader, sender.clone());
    spawn_client_reader(sender);

    let stdout = io::stdout();
    let mut stdout = stdout.lock();
    let mut close_requested = false;

    loop {
        let event = receiver
            .recv()
            .map_err(|_| "PTY event channel closed unexpectedly".to_owned())?;
        match event {
            HostEvent::Output(bytes) => {
                let frame = Frame::output(bytes).map_err(protocol_to_string)?;
                frame
                    .write_to(&mut stdout)
                    .map_err(|error| format!("could not write PTY output: {error}"))?;
            }
            HostEvent::ClientFrame(frame) => {
                if let Err(error) = handle_client_frame(
                    &frame,
                    &mut writer,
                    child_pid,
                    &mut stdout,
                    &mut close_requested,
                ) {
                    send_error(&mut stdout, &error)?;
                    if !close_requested {
                        pty::terminate(child_pid);
                        close_requested = true;
                    }
                }
            }
            HostEvent::ClientClosed => {
                if !close_requested {
                    pty::terminate(child_pid);
                    close_requested = true;
                }
            }
            HostEvent::ClientProtocolError(error) | HostEvent::PtyReadError(error) => {
                send_error(&mut stdout, &error)?;
                if !close_requested {
                    pty::terminate(child_pid);
                    close_requested = true;
                }
            }
            HostEvent::PtyClosed => {
                let status = pty::wait_for_exit(child_pid)
                    .map_err(|error| format!("could not reap shell: {error}"))?;
                Frame::exit(status)
                    .write_to(&mut stdout)
                    .map_err(|error| format!("could not write PTY exit: {error}"))?;
                return Ok(());
            }
        }
    }
}

fn handle_client_frame(
    frame: &Frame,
    writer: &mut std::fs::File,
    child_pid: libc::pid_t,
    stdout: &mut impl Write,
    close_requested: &mut bool,
) -> Result<(), String> {
    match frame.kind {
        FrameKind::Input => writer
            .write_all(&frame.payload)
            .map_err(|error| format!("could not write PTY input: {error}")),
        FrameKind::Resize => {
            let (rows, columns) = frame.dimensions().map_err(protocol_to_string)?;
            pty::resize_file(writer, rows, columns)
                .map_err(|error| format!("could not resize PTY to {rows}x{columns}: {error}"))
        }
        FrameKind::Close => {
            if !frame.payload.is_empty() {
                return Err(protocol_to_string(ProtocolError::InvalidPayloadLength {
                    kind: FrameKind::Close,
                    expected: 0,
                    actual: frame.payload.len(),
                }));
            }
            pty::terminate(child_pid);
            *close_requested = true;
            Ok(())
        }
        FrameKind::Output | FrameKind::Exit | FrameKind::Error => {
            send_error(stdout, "client sent a host-only PTY frame")
        }
    }
}

fn spawn_pty_reader(reader: std::fs::File, sender: SyncSender<HostEvent>) {
    thread::Builder::new()
        .name("clair-ptyhost-output".to_owned())
        .spawn(move || read_pty_output(reader, sender))
        .expect("PTY output thread must start");
}

#[allow(
    clippy::needless_pass_by_value,
    reason = "the output thread must own its channel sender"
)]
fn read_pty_output(mut reader: std::fs::File, sender: SyncSender<HostEvent>) {
    let mut buffer = vec![0_u8; IO_BUFFER_LENGTH];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => {
                let _ = sender.send(HostEvent::PtyClosed);
                return;
            }
            Ok(length) => {
                if sender
                    .send(HostEvent::Output(buffer[..length].to_vec()))
                    .is_err()
                {
                    return;
                }
            }
            Err(error) if error.raw_os_error() == Some(libc::EIO) => {
                let _ = sender.send(HostEvent::PtyClosed);
                return;
            }
            Err(error) => {
                let _ = sender.send(HostEvent::PtyReadError(error.to_string()));
                let _ = sender.send(HostEvent::PtyClosed);
                return;
            }
        }
    }
}

fn spawn_client_reader(sender: SyncSender<HostEvent>) {
    thread::Builder::new()
        .name("clair-ptyhost-input".to_owned())
        .spawn(move || read_client_frames(sender))
        .expect("PTY input thread must start");
}

#[allow(
    clippy::needless_pass_by_value,
    reason = "the input thread must own its channel sender"
)]
fn read_client_frames(sender: SyncSender<HostEvent>) {
    let stdin = io::stdin();
    let mut reader = stdin.lock();
    loop {
        match read_frame(&mut reader) {
            Ok(Some(frame)) => {
                if sender.send(HostEvent::ClientFrame(frame)).is_err() {
                    return;
                }
            }
            Ok(None) => {
                let _ = sender.send(HostEvent::ClientClosed);
                return;
            }
            Err(error) => {
                let _ = sender.send(HostEvent::ClientProtocolError(error.to_string()));
                return;
            }
        }
    }
}

fn send_error(writer: &mut impl Write, message: &str) -> Result<(), String> {
    Frame::error(message.as_bytes().to_vec())
        .map_err(protocol_to_string)?
        .write_to(writer)
        .map_err(|error| format!("could not write PTY error: {error}"))
}

fn protocol_to_string(error: ProtocolError) -> String {
    error.to_string()
}

fn usage_text() -> &'static str {
    "usage: clair-ptyhost [--smoke|--version|--spawn [--cwd PATH] [--shell PATH] [--rows N] [--cols N]|--broker --socket PATH --catalog PATH]"
}

fn print_usage() {
    println!("{}", usage_text());
    println!(
        "  --spawn  start a login shell and exchange bounded binary PTY frames on stdin/stdout"
    );
    println!("  --broker  own detached local PTY sessions behind a bounded Unix socket");
    println!("  --smoke  print the stable process smoke marker");
}

#[cfg(test)]
mod tests {
    use super::{
        DEFAULT_COLUMNS, DEFAULT_ROWS, SpawnOptions, parse_broker_options, parse_dimension,
        parse_spawn_options, smoke_response,
    };

    #[test]
    fn smoke_response_is_versioned_and_stable() {
        assert_eq!(smoke_response(), "clair-ptyhost/0 smoke=ok");
    }

    #[test]
    fn spawn_options_have_a_safe_terminal_default() {
        let options = SpawnOptions::default();
        assert_eq!(options.rows, DEFAULT_ROWS);
        assert_eq!(options.columns, DEFAULT_COLUMNS);
    }

    #[test]
    fn dimensions_are_bounded() {
        assert!(parse_dimension("24", "--rows").is_ok());
        assert!(parse_dimension("0", "--rows").is_err());
        assert!(parse_dimension("1001", "--rows").is_err());
    }

    #[test]
    fn spawn_options_parse_working_directory_shell_and_size() {
        let options = parse_spawn_options(&[
            "--cwd".to_owned(),
            "/tmp".to_owned(),
            "--shell".to_owned(),
            "/bin/sh".to_owned(),
            "--rows".to_owned(),
            "40".to_owned(),
            "--cols".to_owned(),
            "120".to_owned(),
        ])
        .unwrap();

        assert_eq!(options.cwd, std::path::Path::new("/tmp"));
        assert_eq!(options.shell, std::path::Path::new("/bin/sh"));
        assert_eq!(options.rows, 40);
        assert_eq!(options.columns, 120);
    }

    #[test]
    fn broker_options_require_explicit_socket_and_catalog_paths() {
        let options = parse_broker_options(&[
            "--socket".to_owned(),
            "/tmp/clair.sock".to_owned(),
            "--catalog".to_owned(),
            "/tmp/clair.catalog".to_owned(),
        ])
        .unwrap();
        assert_eq!(options.socket, std::path::Path::new("/tmp/clair.sock"));
        assert_eq!(options.catalog, std::path::Path::new("/tmp/clair.catalog"));
        assert!(
            parse_broker_options(&["--socket".to_owned(), "/tmp/clair.sock".to_owned()]).is_err()
        );
    }
}
