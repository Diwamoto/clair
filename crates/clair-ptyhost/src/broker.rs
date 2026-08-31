use std::collections::{HashMap, VecDeque};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::thread;

use crate::{SpawnOptions, pty};

const MAGIC: [u8; 2] = *b"CB";
const PROTOCOL_VERSION: u8 = 1;
const HEADER_LENGTH: usize = 8;
const MAX_PAYLOAD_LENGTH: usize = 64 * 1024;
const MAX_PATH_LENGTH: usize = 4 * 1024;
const MAX_SESSION_ID_LENGTH: usize = 64;
const MAX_CATALOG_ENTRIES: usize = 256;
const MAX_JOURNAL_BYTES: usize = 256 * 1024;
const MAX_SUBSCRIBER_BYTES: usize = 256 * 1024;
const IO_BUFFER_LENGTH: usize = 16 * 1024;
const MAX_DIMENSION: u16 = 1_000;
const CATALOG_HEADER: &[u8] = b"clair-session-catalog-v1\n";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
enum FrameKind {
    Attach = 1,
    Input = 2,
    Resize = 3,
    Detach = 4,
    Terminate = 5,
    Attached = 0x81,
    Output = 0x82,
    Gap = 0x83,
    Exit = 0x84,
    Error = 0xff,
}

impl TryFrom<u8> for FrameKind {
    type Error = ProtocolError;

    fn try_from(value: u8) -> Result<Self, ProtocolError> {
        match value {
            1 => Ok(Self::Attach),
            2 => Ok(Self::Input),
            3 => Ok(Self::Resize),
            4 => Ok(Self::Detach),
            5 => Ok(Self::Terminate),
            0x81 => Ok(Self::Attached),
            0x82 => Ok(Self::Output),
            0x83 => Ok(Self::Gap),
            0x84 => Ok(Self::Exit),
            0xff => Ok(Self::Error),
            other => Err(ProtocolError::UnknownFrameKind(other)),
        }
    }
}

#[derive(Debug, Eq, PartialEq)]
enum ProtocolError {
    InvalidMagic,
    UnsupportedVersion(u8),
    UnknownFrameKind(u8),
    PayloadTooLarge(usize),
    InvalidPayloadLength {
        kind: FrameKind,
        expected: &'static str,
        actual: usize,
    },
    InvalidRequest(&'static str),
    InvalidSessionID,
    InvalidDimensions,
    InvalidText,
    InvalidCursor,
}

impl std::fmt::Display for ProtocolError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidMagic => write!(formatter, "invalid broker frame magic"),
            Self::UnsupportedVersion(version) => {
                write!(formatter, "unsupported broker protocol version {version}")
            }
            Self::UnknownFrameKind(kind) => {
                write!(formatter, "unknown broker frame kind 0x{kind:02x}")
            }
            Self::PayloadTooLarge(length) => {
                write!(formatter, "broker payload is too large: {length} bytes")
            }
            Self::InvalidPayloadLength {
                kind,
                expected,
                actual,
            } => write!(
                formatter,
                "invalid payload length for {kind:?}: expected {expected}, got {actual}"
            ),
            Self::InvalidRequest(message) => write!(formatter, "invalid broker request: {message}"),
            Self::InvalidSessionID => write!(formatter, "invalid session ID"),
            Self::InvalidDimensions => write!(formatter, "invalid terminal dimensions"),
            Self::InvalidText => write!(formatter, "broker text contains invalid bytes"),
            Self::InvalidCursor => write!(formatter, "broker cursor is outside the session range"),
        }
    }
}

impl std::error::Error for ProtocolError {}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Frame {
    kind: FrameKind,
    payload: Vec<u8>,
}

impl Frame {
    fn new(kind: FrameKind, payload: Vec<u8>) -> Result<Self, ProtocolError> {
        if payload.len() > MAX_PAYLOAD_LENGTH {
            return Err(ProtocolError::PayloadTooLarge(payload.len()));
        }

        let valid = match kind {
            FrameKind::Resize => payload.len() == 4,
            FrameKind::Detach | FrameKind::Terminate => payload.is_empty(),
            FrameKind::Output => payload.len() >= 8,
            FrameKind::Gap => payload.len() == 16,
            FrameKind::Exit => payload.len() == 9,
            FrameKind::Error => !payload.is_empty(),
            FrameKind::Attach | FrameKind::Input | FrameKind::Attached => true,
        };
        if !valid {
            let expected = match kind {
                FrameKind::Resize => "4 bytes",
                FrameKind::Detach | FrameKind::Terminate => "0 bytes",
                FrameKind::Output => "at least 8 bytes",
                FrameKind::Gap => "16 bytes",
                FrameKind::Exit => "9 bytes",
                FrameKind::Error => "at least 1 byte",
                FrameKind::Attach | FrameKind::Input | FrameKind::Attached => "a valid payload",
            };
            return Err(ProtocolError::InvalidPayloadLength {
                kind,
                expected,
                actual: payload.len(),
            });
        }
        Ok(Self { kind, payload })
    }

    #[cfg(test)]
    fn attach(request: &AttachRequest) -> Result<Self, ProtocolError> {
        validate_session_id(&request.session_id)?;
        let mut payload = Vec::with_capacity(
            1 + 1
                + request.session_id.len()
                + 8
                + 4
                + 2
                + request.cwd.len()
                + 2
                + request.shell.len(),
        );
        payload.push(request.mode as u8);
        append_text_u8(&mut payload, &request.session_id, MAX_SESSION_ID_LENGTH)?;
        payload.extend_from_slice(&request.cursor.to_be_bytes());
        payload.extend_from_slice(&request.rows.to_be_bytes());
        payload.extend_from_slice(&request.columns.to_be_bytes());
        append_text_u16(&mut payload, &request.cwd, MAX_PATH_LENGTH)?;
        append_text_u16(&mut payload, &request.shell, MAX_PATH_LENGTH)?;
        Self::new(FrameKind::Attach, payload)
    }

    fn attached(attachment: &Attachment) -> Result<Self, ProtocolError> {
        let mut payload = Vec::with_capacity(1 + attachment.session_id.len() + 8 + 8 + 8 + 1);
        append_text_u8(&mut payload, &attachment.session_id, MAX_SESSION_ID_LENGTH)?;
        payload.extend_from_slice(&attachment.epoch.to_be_bytes());
        payload.extend_from_slice(&attachment.current_offset.to_be_bytes());
        payload.extend_from_slice(&attachment.oldest_offset.to_be_bytes());
        payload.push(u8::from(attachment.exited));
        Self::new(FrameKind::Attached, payload)
    }

    fn output(offset: u64, bytes: &[u8]) -> Result<Self, ProtocolError> {
        let mut payload = Vec::with_capacity(8 + bytes.len());
        payload.extend_from_slice(&offset.to_be_bytes());
        payload.extend_from_slice(bytes);
        Self::new(FrameKind::Output, payload)
    }

    fn gap(start: u64, end: u64) -> Result<Self, ProtocolError> {
        let mut payload = Vec::with_capacity(16);
        payload.extend_from_slice(&start.to_be_bytes());
        payload.extend_from_slice(&end.to_be_bytes());
        Self::new(FrameKind::Gap, payload)
    }

    fn exit(status: u8, offset: u64) -> Result<Self, ProtocolError> {
        let mut payload = Vec::with_capacity(9);
        payload.push(status);
        payload.extend_from_slice(&offset.to_be_bytes());
        Self::new(FrameKind::Exit, payload)
    }

    fn error(code: ErrorCode, message: &str) -> Result<Self, ProtocolError> {
        let mut payload = Vec::with_capacity(1 + message.len());
        payload.push(code as u8);
        payload.extend_from_slice(message.as_bytes());
        Self::new(FrameKind::Error, payload)
    }

    fn write_to(&self, writer: &mut impl Write) -> io::Result<()> {
        let length = u32::try_from(self.payload.len())
            .expect("validated broker frame payload fits in a u32")
            .to_be_bytes();
        writer.write_all(&MAGIC)?;
        writer.write_all(&[PROTOCOL_VERSION, self.kind as u8])?;
        writer.write_all(&length)?;
        writer.write_all(&self.payload)?;
        writer.flush()
    }
}

fn read_frame(reader: &mut impl Read) -> Result<Option<Frame>, FrameReadError> {
    let mut header = [0_u8; HEADER_LENGTH];
    match reader.read(&mut header[..1])? {
        0 => return Ok(None),
        1 => {}
        _ => unreachable!("a one-byte read cannot return more than one byte"),
    }
    reader.read_exact(&mut header[1..])?;

    if header[..2] != MAGIC {
        return Err(ProtocolError::InvalidMagic.into());
    }
    if header[2] != PROTOCOL_VERSION {
        return Err(ProtocolError::UnsupportedVersion(header[2]).into());
    }
    let kind = FrameKind::try_from(header[3])?;
    let length = u32::from_be_bytes([header[4], header[5], header[6], header[7]]) as usize;
    if length > MAX_PAYLOAD_LENGTH {
        return Err(ProtocolError::PayloadTooLarge(length).into());
    }
    let mut payload = vec![0_u8; length];
    reader.read_exact(&mut payload)?;
    Ok(Some(Frame::new(kind, payload)?))
}

#[derive(Debug)]
enum FrameReadError {
    Io(io::Error),
    Protocol(ProtocolError),
}

impl std::fmt::Display for FrameReadError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "{error}"),
            Self::Protocol(error) => write!(formatter, "{error}"),
        }
    }
}

impl std::error::Error for FrameReadError {}

impl From<io::Error> for FrameReadError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<ProtocolError> for FrameReadError {
    fn from(error: ProtocolError) -> Self {
        Self::Protocol(error)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
enum AttachMode {
    Create = 1,
    Reattach = 2,
}

impl TryFrom<u8> for AttachMode {
    type Error = ProtocolError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::Create),
            2 => Ok(Self::Reattach),
            _ => Err(ProtocolError::InvalidRequest("unknown attach mode")),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct AttachRequest {
    mode: AttachMode,
    session_id: String,
    cursor: u64,
    rows: u16,
    columns: u16,
    cwd: String,
    shell: String,
}

fn parse_attach(payload: &[u8]) -> Result<AttachRequest, ProtocolError> {
    let mut cursor = 0;
    let mode = AttachMode::try_from(take_u8(payload, &mut cursor)?)?;
    let session_id = take_text_u8(payload, &mut cursor, MAX_SESSION_ID_LENGTH)?;
    validate_session_id(&session_id)?;
    let output_cursor = take_u64(payload, &mut cursor)?;
    let rows = take_u16(payload, &mut cursor)?;
    let columns = take_u16(payload, &mut cursor)?;
    validate_dimensions(rows, columns)?;
    let cwd = take_text_u16(payload, &mut cursor, MAX_PATH_LENGTH)?;
    let shell = take_text_u16(payload, &mut cursor, MAX_PATH_LENGTH)?;
    if cursor != payload.len() {
        return Err(ProtocolError::InvalidRequest("trailing attach payload"));
    }
    Ok(AttachRequest {
        mode,
        session_id,
        cursor: output_cursor,
        rows,
        columns,
        cwd,
        shell,
    })
}

fn take_u8(payload: &[u8], cursor: &mut usize) -> Result<u8, ProtocolError> {
    let value = payload
        .get(*cursor)
        .copied()
        .ok_or(ProtocolError::InvalidRequest("truncated payload"))?;
    *cursor += 1;
    Ok(value)
}

fn take_u16(payload: &[u8], cursor: &mut usize) -> Result<u16, ProtocolError> {
    let bytes = take_bytes(payload, cursor, 2)?;
    Ok(u16::from_be_bytes([bytes[0], bytes[1]]))
}

fn take_u64(payload: &[u8], cursor: &mut usize) -> Result<u64, ProtocolError> {
    let bytes = take_bytes(payload, cursor, 8)?;
    Ok(u64::from_be_bytes([
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
    ]))
}

fn take_bytes<'a>(
    payload: &'a [u8],
    cursor: &mut usize,
    length: usize,
) -> Result<&'a [u8], ProtocolError> {
    let end = cursor
        .checked_add(length)
        .ok_or(ProtocolError::InvalidRequest("payload length overflow"))?;
    let bytes = payload
        .get(*cursor..end)
        .ok_or(ProtocolError::InvalidRequest("truncated payload"))?;
    *cursor = end;
    Ok(bytes)
}

fn take_text_u8(
    payload: &[u8],
    cursor: &mut usize,
    maximum: usize,
) -> Result<String, ProtocolError> {
    let length = usize::from(take_u8(payload, cursor)?);
    take_text(payload, cursor, length, maximum)
}

fn take_text_u16(
    payload: &[u8],
    cursor: &mut usize,
    maximum: usize,
) -> Result<String, ProtocolError> {
    let length = usize::from(take_u16(payload, cursor)?);
    take_text(payload, cursor, length, maximum)
}

fn take_text(
    payload: &[u8],
    cursor: &mut usize,
    length: usize,
    maximum: usize,
) -> Result<String, ProtocolError> {
    if length > maximum {
        return Err(ProtocolError::InvalidRequest("text field is too large"));
    }
    let bytes = take_bytes(payload, cursor, length)?;
    let text = std::str::from_utf8(bytes).map_err(|_| ProtocolError::InvalidText)?;
    if text.is_empty() || text.bytes().any(|byte| byte < 0x20 || byte == 0x7f) {
        return Err(ProtocolError::InvalidText);
    }
    Ok(text.to_owned())
}

fn append_text_u8(payload: &mut Vec<u8>, text: &str, maximum: usize) -> Result<(), ProtocolError> {
    if text.is_empty() || text.len() > maximum || text.len() > u8::MAX as usize {
        return Err(ProtocolError::InvalidRequest("text field is too large"));
    }
    if text.bytes().any(|byte| byte < 0x20 || byte == 0x7f) {
        return Err(ProtocolError::InvalidText);
    }
    let length = u8::try_from(text.len())
        .map_err(|_| ProtocolError::InvalidRequest("text field is too large"))?;
    payload.push(length);
    payload.extend_from_slice(text.as_bytes());
    Ok(())
}

#[cfg(test)]
fn append_text_u16(payload: &mut Vec<u8>, text: &str, maximum: usize) -> Result<(), ProtocolError> {
    if text.is_empty() || text.len() > maximum || text.len() > usize::from(u16::MAX) {
        return Err(ProtocolError::InvalidRequest("text field is too large"));
    }
    if text.bytes().any(|byte| byte < 0x20 || byte == 0x7f) {
        return Err(ProtocolError::InvalidText);
    }
    let length = u16::try_from(text.len())
        .map_err(|_| ProtocolError::InvalidRequest("text field is too large"))?;
    payload.extend_from_slice(&length.to_be_bytes());
    payload.extend_from_slice(text.as_bytes());
    Ok(())
}

fn validate_session_id(session_id: &str) -> Result<(), ProtocolError> {
    let bytes = session_id.as_bytes();
    if bytes.len() != 36
        || bytes[8] != b'-'
        || bytes[13] != b'-'
        || bytes[18] != b'-'
        || bytes[23] != b'-'
        || bytes
            .iter()
            .enumerate()
            .any(|(index, byte)| !matches!(index, 8 | 13 | 18 | 23) && !byte.is_ascii_hexdigit())
    {
        return Err(ProtocolError::InvalidSessionID);
    }
    Ok(())
}

fn validate_dimensions(rows: u16, columns: u16) -> Result<(), ProtocolError> {
    if rows == 0 || columns == 0 || rows > MAX_DIMENSION || columns > MAX_DIMENSION {
        return Err(ProtocolError::InvalidDimensions);
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
enum ErrorCode {
    InvalidRequest = 1,
    SessionMissing = 2,
    SessionExists = 3,
    Protocol = 4,
    Io = 5,
    StaleCursor = 6,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct CatalogRecord {
    session_id: String,
    cwd: String,
    shell: String,
    rows: u16,
    columns: u16,
    epoch: u64,
}

struct CatalogStore {
    path: PathBuf,
    records: HashMap<String, CatalogRecord>,
}

impl CatalogStore {
    fn load(path: PathBuf) -> io::Result<Self> {
        let mut store = Self {
            path,
            records: HashMap::new(),
        };
        let metadata = match fs::symlink_metadata(&store.path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(store),
            Err(error) => return Err(error),
        };
        if metadata.file_type().is_symlink() || !metadata.file_type().is_file() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "session catalog path is not a regular file",
            ));
        }
        let data = fs::read(&store.path)?;
        if data.is_empty() {
            return Ok(store);
        }
        if !data.starts_with(CATALOG_HEADER) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "session catalog has an unsupported version",
            ));
        }

        for line in std::str::from_utf8(&data[CATALOG_HEADER.len()..])
            .map_err(|_| {
                io::Error::new(io::ErrorKind::InvalidData, "session catalog is not UTF-8")
            })?
            .lines()
        {
            let fields: Vec<&str> = line.split('\t').collect();
            if fields.len() != 6 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "session catalog record is malformed",
                ));
            }
            let session_id = hex_decode(fields[0]).map_err(catalog_data_error)?;
            let session_id = String::from_utf8(session_id)
                .map_err(|error| catalog_data_error(error.to_string()))?;
            validate_session_id(&session_id)
                .map_err(|error| catalog_data_error(error.to_string()))?;
            let cwd = String::from_utf8(hex_decode(fields[1]).map_err(catalog_data_error)?)
                .map_err(|error| catalog_data_error(error.to_string()))?;
            let shell = String::from_utf8(hex_decode(fields[2]).map_err(catalog_data_error)?)
                .map_err(|error| catalog_data_error(error.to_string()))?;
            if cwd.is_empty() || shell.is_empty() {
                return Err(catalog_data_error("session catalog path is empty"));
            }
            let rows = fields[3]
                .parse::<u16>()
                .map_err(|error| catalog_data_error(error.to_string()))?;
            let columns = fields[4]
                .parse::<u16>()
                .map_err(|error| catalog_data_error(error.to_string()))?;
            validate_dimensions(rows, columns)
                .map_err(|error| catalog_data_error(error.to_string()))?;
            let epoch = fields[5]
                .parse::<u64>()
                .map_err(|error| catalog_data_error(error.to_string()))?;
            if epoch == 0 || store.records.len() >= MAX_CATALOG_ENTRIES {
                return Err(catalog_data_error(
                    "session catalog contains too many records",
                ));
            }
            store.records.insert(
                session_id.clone(),
                CatalogRecord {
                    session_id,
                    cwd,
                    shell,
                    rows,
                    columns,
                    epoch,
                },
            );
        }
        Ok(store)
    }

    fn upsert(&mut self, record: CatalogRecord) -> io::Result<()> {
        if !self.records.contains_key(&record.session_id)
            && self.records.len() >= MAX_CATALOG_ENTRIES
        {
            return Err(io::Error::other("session catalog is full"));
        }
        self.records.insert(record.session_id.clone(), record);
        self.save()
    }

    fn remove(&mut self, session_id: &str) -> io::Result<()> {
        self.records.remove(session_id);
        self.save()
    }

    fn epoch_for(&self, session_id: &str) -> u64 {
        self.records
            .get(session_id)
            .map_or(1, |record| record.epoch.saturating_add(1).max(1))
    }

    fn save(&self) -> io::Result<()> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        let temporary = self.path.with_file_name(format!(
            ".{}.tmp-{}",
            self.path
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("sessions-v1.catalog"),
            std::process::id()
        ));
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&temporary)?;
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
        file.write_all(CATALOG_HEADER)?;
        let mut records: Vec<&CatalogRecord> = self.records.values().collect();
        records.sort_by(|left, right| left.session_id.cmp(&right.session_id));
        for record in records {
            writeln!(
                file,
                "{}\t{}\t{}\t{}\t{}\t{}",
                hex_encode(record.session_id.as_bytes()),
                hex_encode(record.cwd.as_bytes()),
                hex_encode(record.shell.as_bytes()),
                record.rows,
                record.columns,
                record.epoch
            )?;
        }
        file.sync_all()?;
        drop(file);
        fs::rename(temporary, &self.path)?;
        fs::set_permissions(&self.path, fs::Permissions::from_mode(0o600))
    }
}

fn catalog_data_error(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

fn hex_encode(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(DIGITS[usize::from(byte >> 4)] as char);
        encoded.push(DIGITS[usize::from(byte & 0x0f)] as char);
    }
    encoded
}

fn hex_decode(value: &str) -> Result<Vec<u8>, &'static str> {
    if value.len() % 2 != 0 {
        return Err("hex field has odd length");
    }
    let mut decoded = Vec::with_capacity(value.len() / 2);
    let bytes = value.as_bytes();
    for pair in bytes.chunks_exact(2) {
        let high = hex_digit(pair[0]).ok_or("hex field has invalid digit")?;
        let low = hex_digit(pair[1]).ok_or("hex field has invalid digit")?;
        decoded.push((high << 4) | low);
    }
    Ok(decoded)
}

fn hex_digit(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Attachment {
    session_id: String,
    epoch: u64,
    current_offset: u64,
    oldest_offset: u64,
    exited: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum Outbound {
    Output { offset: u64, bytes: Vec<u8> },
    Gap { start: u64, end: u64 },
    Exit { status: u8, offset: u64 },
    Error { code: ErrorCode, message: String },
}

impl Outbound {
    fn into_frame(self) -> Result<Frame, ProtocolError> {
        match self {
            Self::Output { offset, bytes } => Frame::output(offset, &bytes),
            Self::Gap { start, end } => Frame::gap(start, end),
            Self::Exit { status, offset } => Frame::exit(status, offset),
            Self::Error { code, message } => Frame::error(code, &message),
        }
    }

    fn output_range(&self) -> Option<(u64, u64)> {
        match self {
            Self::Output { offset, bytes } => {
                let end = offset.saturating_add(bytes.len() as u64);
                Some((*offset, end))
            }
            Self::Gap { start, end } => Some((*start, *end)),
            Self::Exit { .. } | Self::Error { .. } => None,
        }
    }

    fn byte_length(&self) -> usize {
        match self {
            Self::Output { bytes, .. } => bytes.len(),
            Self::Gap { .. } | Self::Exit { .. } | Self::Error { .. } => 0,
        }
    }
}

struct QueueState {
    items: VecDeque<Outbound>,
    pending_gap: Option<(u64, u64)>,
    queued_bytes: usize,
    closed: bool,
}

struct SubscriberQueue {
    state: Mutex<QueueState>,
    wake: Condvar,
}

impl SubscriberQueue {
    fn new() -> Self {
        Self {
            state: Mutex::new(QueueState {
                items: VecDeque::new(),
                pending_gap: None,
                queued_bytes: 0,
                closed: false,
            }),
            wake: Condvar::new(),
        }
    }

    fn push_output(&self, offset: u64, bytes: Vec<u8>) {
        if bytes.is_empty() {
            return;
        }
        let end = offset.saturating_add(bytes.len() as u64);
        let mut state = self.state.lock().expect("subscriber queue lock poisoned");
        if state.closed {
            return;
        }

        if bytes.len() > MAX_SUBSCRIBER_BYTES {
            let start = earliest_queued_offset(&state).unwrap_or(offset);
            state.items.clear();
            state.queued_bytes = 0;
            merge_gap(&mut state.pending_gap, start, end);
            drop(state);
            self.wake.notify_one();
            return;
        } else if state.queued_bytes.saturating_add(bytes.len()) > MAX_SUBSCRIBER_BYTES {
            let start = earliest_queued_offset(&state).unwrap_or(offset);
            let dropped_end = offset;
            state.items.clear();
            state.queued_bytes = 0;
            if start < dropped_end {
                merge_gap(&mut state.pending_gap, start, dropped_end);
            }
        }

        state.queued_bytes = state.queued_bytes.saturating_add(bytes.len());
        state.items.push_back(Outbound::Output { offset, bytes });
        drop(state);
        self.wake.notify_one();
    }

    fn push_control(&self, item: Outbound) {
        let mut state = self.state.lock().expect("subscriber queue lock poisoned");
        if state.closed {
            return;
        }
        state.items.push_back(item);
        drop(state);
        self.wake.notify_one();
    }

    fn pop(&self) -> Option<Outbound> {
        let mut state = self.state.lock().expect("subscriber queue lock poisoned");
        loop {
            if let Some((start, end)) = state.pending_gap.take() {
                return Some(Outbound::Gap { start, end });
            }
            if let Some(item) = state.items.pop_front() {
                state.queued_bytes = state.queued_bytes.saturating_sub(item.byte_length());
                return Some(item);
            }
            if state.closed {
                return None;
            }
            state = self
                .wake
                .wait(state)
                .expect("subscriber queue lock poisoned");
        }
    }

    fn close(&self) {
        let mut state = self.state.lock().expect("subscriber queue lock poisoned");
        state.closed = true;
        state.items.clear();
        state.pending_gap = None;
        state.queued_bytes = 0;
        drop(state);
        self.wake.notify_all();
    }

    #[cfg(test)]
    fn queued_bytes(&self) -> usize {
        self.state
            .lock()
            .expect("subscriber queue lock poisoned")
            .queued_bytes
    }
}

fn earliest_queued_offset(state: &QueueState) -> Option<u64> {
    state
        .items
        .iter()
        .find_map(Outbound::output_range)
        .map(|range| range.0)
}

fn merge_gap(gap: &mut Option<(u64, u64)>, start: u64, end: u64) {
    if start >= end {
        return;
    }
    match gap {
        Some((existing_start, existing_end)) => {
            *existing_start = (*existing_start).min(start);
            *existing_end = (*existing_end).max(end);
        }
        None => *gap = Some((start, end)),
    }
}

#[derive(Clone, Debug)]
struct JournalChunk {
    offset: u64,
    bytes: Vec<u8>,
}

struct SessionStreamState {
    dimensions: (u16, u16),
    next_offset: u64,
    journal: VecDeque<JournalChunk>,
    journal_bytes: usize,
    subscribers: HashMap<u64, Arc<SubscriberQueue>>,
    exited: Option<u8>,
}

struct Session {
    id: String,
    epoch: u64,
    master: Mutex<File>,
    pid: libc::pid_t,
    stream: Mutex<SessionStreamState>,
}

impl Session {
    fn new(id: String, epoch: u64, options: &SpawnOptions) -> io::Result<(Arc<Self>, File)> {
        let spawned = pty::spawn(options)?;
        let reader = spawned.master.try_clone()?;
        let session = Arc::new(Self {
            id,
            epoch,
            master: Mutex::new(spawned.master),
            pid: spawned.pid,
            stream: Mutex::new(SessionStreamState {
                dimensions: (options.rows, options.columns),
                next_offset: 0,
                journal: VecDeque::new(),
                journal_bytes: 0,
                subscribers: HashMap::new(),
                exited: None,
            }),
        });
        Ok((session, reader))
    }

    fn start_reader(self: &Arc<Self>, reader: File, broker: Weak<BrokerState>) {
        let session = Arc::clone(self);
        thread::Builder::new()
            .name(format!("clair-broker-pty-{}", &self.id[..8]))
            .spawn(move || {
                let status = read_pty_output(&session, reader);
                session.finish(status);
                if let Some(broker) = broker.upgrade() {
                    broker.session_exited(&session.id, &session);
                }
            })
            .expect("broker PTY output thread must start");
    }

    fn attach(
        &self,
        subscriber_id: u64,
        queue: Arc<SubscriberQueue>,
        cursor: u64,
    ) -> Result<Attachment, ProtocolError> {
        let mut stream = self.stream.lock().expect("session stream lock poisoned");
        let current_offset = stream.next_offset;
        if cursor > current_offset {
            return Err(ProtocolError::InvalidCursor);
        }
        let oldest_offset = stream
            .journal
            .front()
            .map_or(current_offset, |chunk| chunk.offset);
        if cursor < oldest_offset {
            queue.push_control(Outbound::Gap {
                start: cursor,
                end: oldest_offset,
            });
        }
        let replay_from = cursor.max(oldest_offset);
        for chunk in &stream.journal {
            let chunk_end = chunk.offset.saturating_add(chunk.bytes.len() as u64);
            if chunk_end <= replay_from {
                continue;
            }
            let start = usize::try_from(replay_from.saturating_sub(chunk.offset))
                .map_err(|_| ProtocolError::InvalidCursor)?;
            queue.push_output(
                chunk.offset.saturating_add(start as u64),
                chunk.bytes[start..].to_vec(),
            );
        }
        let exited = stream.exited.is_some();
        if let Some(status) = stream.exited {
            queue.push_control(Outbound::Exit {
                status,
                offset: current_offset,
            });
        } else {
            stream.subscribers.insert(subscriber_id, queue);
        }
        Ok(Attachment {
            session_id: self.id.clone(),
            epoch: self.epoch,
            current_offset,
            oldest_offset,
            exited,
        })
    }

    fn remove_subscriber(&self, subscriber_id: u64) {
        let mut stream = self.stream.lock().expect("session stream lock poisoned");
        if let Some(queue) = stream.subscribers.remove(&subscriber_id) {
            queue.close();
        }
    }

    fn forget_subscriber(&self, subscriber_id: u64) {
        self.stream
            .lock()
            .expect("session stream lock poisoned")
            .subscribers
            .remove(&subscriber_id);
    }

    fn write_input(&self, bytes: &[u8]) -> io::Result<()> {
        if bytes.is_empty() {
            return Ok(());
        }
        let stream = self.stream.lock().expect("session stream lock poisoned");
        if stream.exited.is_some() {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "session has exited",
            ));
        }
        let mut master = self.master.lock().expect("session master lock poisoned");
        master.write_all(bytes)
    }

    fn resize(&self, rows: u16, columns: u16) -> io::Result<()> {
        validate_dimensions(rows, columns)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error.to_string()))?;
        let master = self.master.lock().expect("session master lock poisoned");
        pty::resize_file(&*master, rows, columns)?;
        drop(master);
        self.stream
            .lock()
            .expect("session stream lock poisoned")
            .dimensions = (rows, columns);
        Ok(())
    }

    fn terminate(&self) {
        pty::terminate(self.pid);
    }

    fn record_output(&self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        let (offset, subscribers) = {
            let mut stream = self.stream.lock().expect("session stream lock poisoned");
            if stream.exited.is_some() {
                return;
            }
            let offset = stream.next_offset;
            stream.next_offset = stream.next_offset.saturating_add(bytes.len() as u64);
            stream.journal_bytes = stream.journal_bytes.saturating_add(bytes.len());
            stream.journal.push_back(JournalChunk {
                offset,
                bytes: bytes.to_owned(),
            });
            while stream.journal_bytes > MAX_JOURNAL_BYTES {
                if let Some(chunk) = stream.journal.pop_front() {
                    stream.journal_bytes = stream.journal_bytes.saturating_sub(chunk.bytes.len());
                } else {
                    break;
                }
            }
            (
                offset,
                stream.subscribers.values().cloned().collect::<Vec<_>>(),
            )
        };
        for subscriber in subscribers {
            subscriber.push_output(offset, bytes.to_owned());
        }
    }

    fn finish(&self, status: u8) {
        let subscribers = {
            let mut stream = self.stream.lock().expect("session stream lock poisoned");
            if stream.exited.replace(status).is_some() {
                return;
            }
            let offset = stream.next_offset;
            stream
                .subscribers
                .values()
                .cloned()
                .map(|subscriber| (subscriber, offset))
                .collect::<Vec<_>>()
        };
        for (subscriber, offset) in subscribers {
            subscriber.push_control(Outbound::Exit { status, offset });
        }
    }
}

fn read_pty_output(session: &Session, mut reader: File) -> u8 {
    let mut buffer = vec![0_u8; IO_BUFFER_LENGTH];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => break,
            Ok(length) => session.record_output(&buffer[..length]),
            Err(error) if error.raw_os_error() == Some(libc::EIO) => break,
            Err(_) => break,
        }
    }
    pty::wait_for_exit(session.pid).unwrap_or(1)
}

struct BrokerState {
    sessions: Mutex<HashMap<String, Arc<Session>>>,
    catalog: Mutex<CatalogStore>,
    next_subscriber_id: AtomicU64,
}

impl BrokerState {
    fn new(catalog: CatalogStore) -> Self {
        Self {
            sessions: Mutex::new(HashMap::new()),
            catalog: Mutex::new(catalog),
            next_subscriber_id: AtomicU64::new(1),
        }
    }

    fn attach(
        self: &Arc<Self>,
        request: &AttachRequest,
    ) -> Result<(Arc<Session>, u64, Arc<SubscriberQueue>, Attachment), BrokerError> {
        let session = match request.mode {
            AttachMode::Create => {
                let mut sessions = self.sessions.lock().expect("broker sessions lock poisoned");
                if sessions.contains_key(&request.session_id) {
                    return Err(BrokerError::new(
                        ErrorCode::SessionExists,
                        "session ID is already active",
                    ));
                }
                let epoch = self
                    .catalog
                    .lock()
                    .expect("broker catalog lock poisoned")
                    .epoch_for(&request.session_id);
                let options = SpawnOptions {
                    cwd: PathBuf::from(&request.cwd),
                    shell: PathBuf::from(&request.shell),
                    rows: request.rows,
                    columns: request.columns,
                };
                let (session, reader) = Session::new(request.session_id.clone(), epoch, &options)
                    .map_err(|error| {
                    BrokerError::new(ErrorCode::Io, format!("could not spawn session: {error}"))
                })?;
                sessions.insert(request.session_id.clone(), Arc::clone(&session));
                session.start_reader(reader, Arc::downgrade(self));
                drop(sessions);
                let record = CatalogRecord {
                    session_id: request.session_id.clone(),
                    cwd: request.cwd.clone(),
                    shell: request.shell.clone(),
                    rows: request.rows,
                    columns: request.columns,
                    epoch,
                };
                self.catalog
                    .lock()
                    .expect("broker catalog lock poisoned")
                    .upsert(record)
                    .map_err(|error| {
                        BrokerError::new(
                            ErrorCode::Io,
                            format!("could not save session catalog: {error}"),
                        )
                    })?;
                session
            }
            AttachMode::Reattach => self
                .sessions
                .lock()
                .expect("broker sessions lock poisoned")
                .get(&request.session_id)
                .cloned()
                .ok_or_else(|| {
                    let _ = self
                        .catalog
                        .lock()
                        .expect("broker catalog lock poisoned")
                        .remove(&request.session_id);
                    BrokerError::new(ErrorCode::SessionMissing, "session is not available")
                })?,
        };

        let subscriber_id = self.next_subscriber_id.fetch_add(1, Ordering::Relaxed);
        let queue = Arc::new(SubscriberQueue::new());
        let attachment = session
            .attach(subscriber_id, Arc::clone(&queue), request.cursor)
            .map_err(|error| match error {
                ProtocolError::InvalidCursor => {
                    BrokerError::new(ErrorCode::StaleCursor, "cursor is ahead of the session")
                }
                other => BrokerError::new(ErrorCode::Protocol, other.to_string()),
            })?;
        Ok((session, subscriber_id, queue, attachment))
    }

    fn session_exited(&self, session_id: &str, expected: &Arc<Session>) {
        let removed = {
            let mut sessions = self.sessions.lock().expect("broker sessions lock poisoned");
            if sessions
                .get(session_id)
                .is_some_and(|session| Arc::ptr_eq(session, expected))
            {
                sessions.remove(session_id);
                true
            } else {
                false
            }
        };
        if removed {
            let _ = self
                .catalog
                .lock()
                .expect("broker catalog lock poisoned")
                .remove(session_id);
        }
    }
}

#[derive(Debug)]
struct BrokerError {
    code: ErrorCode,
    message: String,
}

impl BrokerError {
    fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

pub struct BrokerOptions {
    pub socket: PathBuf,
    pub catalog: PathBuf,
}

pub fn run(options: &BrokerOptions) -> Result<(), String> {
    let listener = prepare_listener(&options.socket).map_err(|error| error.to_string())?;
    let _cleanup = SocketCleanup {
        path: options.socket.clone(),
    };
    let catalog = CatalogStore::load(options.catalog.clone()).map_err(|error| error.to_string())?;
    let state = Arc::new(BrokerState::new(catalog));

    for incoming in listener.incoming() {
        match incoming {
            Ok(stream) => {
                let state = Arc::clone(&state);
                thread::Builder::new()
                    .name("clair-broker-client".to_owned())
                    .spawn(move || handle_connection(stream, state))
                    .map_err(|error| error.to_string())?;
            }
            Err(error) => return Err(format!("broker listener failed: {error}")),
        }
    }
    Ok(())
}

fn prepare_listener(path: &Path) -> io::Result<UnixListener> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            if !metadata.file_type().is_socket() {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    "broker socket path is not a Unix socket",
                ));
            }
            match UnixStream::connect(path) {
                Ok(_) => {
                    return Err(io::Error::new(
                        io::ErrorKind::AddrInUse,
                        "broker socket is already active",
                    ));
                }
                Err(_) => fs::remove_file(path)?,
            }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let listener = UnixListener::bind(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

struct SocketCleanup {
    path: PathBuf,
}

impl Drop for SocketCleanup {
    fn drop(&mut self) {
        if let Ok(metadata) = fs::symlink_metadata(&self.path) {
            if metadata.file_type().is_socket() {
                let _ = fs::remove_file(&self.path);
            }
        }
    }
}

#[allow(
    clippy::needless_pass_by_value,
    clippy::too_many_lines,
    reason = "the connection thread owns its shared broker handle and handles the full client state machine"
)]
fn handle_connection(mut stream: UnixStream, state: Arc<BrokerState>) {
    let Ok(mut reader) = stream.try_clone() else {
        return;
    };
    let first = match read_frame(&mut reader) {
        Ok(Some(frame)) => frame,
        Ok(None) => return,
        Err(error) => {
            let _ = send_direct_error(&mut stream, ErrorCode::Protocol, &error.to_string());
            return;
        }
    };
    if first.kind != FrameKind::Attach {
        let _ = send_direct_error(
            &mut stream,
            ErrorCode::InvalidRequest,
            "first broker frame must be attach",
        );
        return;
    }
    let request = match parse_attach(&first.payload) {
        Ok(request) => request,
        Err(error) => {
            let _ = send_direct_error(&mut stream, ErrorCode::Protocol, &error.to_string());
            return;
        }
    };
    let (session, subscriber_id, queue, attachment) = match state.attach(&request) {
        Ok(attachment) => attachment,
        Err(error) => {
            let _ = send_direct_error(&mut stream, error.code, &error.message);
            return;
        }
    };
    let attached = match Frame::attached(&attachment) {
        Ok(frame) => frame,
        Err(error) => {
            session.remove_subscriber(subscriber_id);
            let _ = send_direct_error(&mut stream, ErrorCode::Protocol, &error.to_string());
            return;
        }
    };
    if attached.write_to(&mut stream).is_err() {
        session.remove_subscriber(subscriber_id);
        return;
    }

    let Ok(mut writer_stream) = stream.try_clone() else {
        session.remove_subscriber(subscriber_id);
        return;
    };
    let writer_queue = Arc::clone(&queue);
    let writer = thread::Builder::new()
        .name("clair-broker-subscriber".to_owned())
        .spawn(move || write_queue(&mut writer_stream, writer_queue))
        .ok();

    let mut close_after_error = false;
    loop {
        match read_frame(&mut reader) {
            Ok(Some(frame)) => match frame.kind {
                FrameKind::Input => {
                    if let Err(error) = session.write_input(&frame.payload) {
                        queue.push_control(Outbound::Error {
                            code: ErrorCode::Io,
                            message: format!("could not write PTY input: {error}"),
                        });
                        close_after_error = true;
                        break;
                    }
                }
                FrameKind::Resize => {
                    if let Ok((rows, columns)) = parse_dimensions(&frame.payload) {
                        if let Err(error) = session.resize(rows, columns) {
                            queue.push_control(Outbound::Error {
                                code: ErrorCode::Io,
                                message: format!("could not resize PTY: {error}"),
                            });
                            close_after_error = true;
                            break;
                        }
                    } else {
                        queue.push_control(Outbound::Error {
                            code: ErrorCode::Protocol,
                            message: "invalid resize dimensions".to_owned(),
                        });
                        close_after_error = true;
                        break;
                    }
                }
                FrameKind::Detach => break,
                FrameKind::Terminate => {
                    session.terminate();
                }
                FrameKind::Attach
                | FrameKind::Attached
                | FrameKind::Output
                | FrameKind::Gap
                | FrameKind::Exit
                | FrameKind::Error => {
                    queue.push_control(Outbound::Error {
                        code: ErrorCode::InvalidRequest,
                        message: "client sent a host-only or attach-only frame".to_owned(),
                    });
                    close_after_error = true;
                    break;
                }
            },
            Ok(None) => break,
            Err(error) => {
                queue.push_control(Outbound::Error {
                    code: ErrorCode::Protocol,
                    message: error.to_string(),
                });
                close_after_error = true;
                break;
            }
        }
    }

    if close_after_error {
        session.forget_subscriber(subscriber_id);
        if let Some(writer) = writer {
            let _ = writer.join();
        }
        queue.close();
    } else {
        session.remove_subscriber(subscriber_id);
        queue.close();
        let _ = stream.shutdown(Shutdown::Both);
        if let Some(writer) = writer {
            let _ = writer.join();
        }
    }
}

fn parse_dimensions(payload: &[u8]) -> Result<(u16, u16), ProtocolError> {
    if payload.len() != 4 {
        return Err(ProtocolError::InvalidPayloadLength {
            kind: FrameKind::Resize,
            expected: "4 bytes",
            actual: payload.len(),
        });
    }
    let rows = u16::from_be_bytes([payload[0], payload[1]]);
    let columns = u16::from_be_bytes([payload[2], payload[3]]);
    validate_dimensions(rows, columns)?;
    Ok((rows, columns))
}

fn send_direct_error(writer: &mut UnixStream, code: ErrorCode, message: &str) -> io::Result<()> {
    Frame::error(code, message)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.to_string()))?
        .write_to(writer)
}

#[allow(
    clippy::needless_pass_by_value,
    reason = "the writer thread owns the subscriber queue until the connection closes"
)]
fn write_queue(writer: &mut UnixStream, queue: Arc<SubscriberQueue>) {
    while let Some(item) = queue.pop() {
        let is_terminal = matches!(item, Outbound::Exit { .. } | Outbound::Error { .. });
        let Ok(frame) = item.into_frame() else {
            break;
        };
        if frame.write_to(writer).is_err() {
            break;
        }
        if is_terminal {
            let _ = writer.shutdown(Shutdown::Both);
            return;
        }
    }
    let _ = writer.shutdown(Shutdown::Both);
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::{
        AttachMode, AttachRequest, Frame, FrameKind, FrameReadError, MAX_PAYLOAD_LENGTH,
        MAX_SUBSCRIBER_BYTES, Outbound, ProtocolError, SubscriberQueue, parse_attach, read_frame,
    };

    fn request() -> AttachRequest {
        AttachRequest {
            mode: AttachMode::Create,
            session_id: "01234567-89ab-cdef-0123-456789abcdef".to_owned(),
            cursor: 0,
            rows: 24,
            columns: 80,
            cwd: "/tmp".to_owned(),
            shell: "/bin/sh".to_owned(),
        }
    }

    #[test]
    fn attach_frame_round_trips_bounded_session_metadata() {
        let frame = Frame::attach(&request()).unwrap();
        let mut bytes = Vec::new();
        frame.write_to(&mut bytes).unwrap();
        let decoded = read_frame(&mut Cursor::new(bytes)).unwrap().unwrap();
        assert_eq!(decoded, frame);
        assert_eq!(parse_attach(&decoded.payload).unwrap(), request());
    }

    #[test]
    fn malformed_broker_frame_is_rejected_before_payload_allocation() {
        let length = u32::try_from(MAX_PAYLOAD_LENGTH + 1).unwrap().to_be_bytes();
        let bytes = [b"CB".as_slice(), &[1, FrameKind::Input as u8], &length].concat();
        let error = read_frame(&mut Cursor::new(bytes)).unwrap_err();
        assert!(matches!(
            error,
            FrameReadError::Protocol(ProtocolError::PayloadTooLarge(length))
                if length == MAX_PAYLOAD_LENGTH + 1
        ));
    }

    #[test]
    fn partial_broker_header_is_not_accepted() {
        let error = read_frame(&mut Cursor::new(b"CB\x01".to_vec())).unwrap_err();
        assert!(matches!(
            error,
            FrameReadError::Io(error) if error.kind() == std::io::ErrorKind::UnexpectedEof
        ));
    }

    #[test]
    fn attach_rejects_invalid_session_id_and_dimensions() {
        let mut invalid_id = request();
        invalid_id.session_id = "not-a-session".to_owned();
        assert!(matches!(
            Frame::attach(&invalid_id),
            Err(ProtocolError::InvalidSessionID)
        ));

        let mut invalid_dimensions = request();
        invalid_dimensions.rows = 0;
        let frame = Frame::attach(&invalid_dimensions).unwrap();
        assert!(matches!(
            parse_attach(&frame.payload),
            Err(ProtocolError::InvalidDimensions)
        ));
    }

    #[test]
    fn slow_subscriber_stays_bounded_and_reports_gap() {
        let queue = SubscriberQueue::new();
        let chunk = vec![b'x'; 16 * 1024];
        for index in 0..64_u64 {
            queue.push_output(index * chunk.len() as u64, chunk.clone());
        }
        assert!(queue.queued_bytes() <= MAX_SUBSCRIBER_BYTES);
        assert!(matches!(queue.pop(), Some(Outbound::Gap { .. })));
        assert!(matches!(queue.pop(), Some(Outbound::Output { .. })));
    }

    #[test]
    fn oversized_subscriber_chunk_becomes_gap_without_queue_growth() {
        let queue = SubscriberQueue::new();
        queue.push_output(10, vec![b'x'; MAX_SUBSCRIBER_BYTES + 1]);
        assert_eq!(queue.queued_bytes(), 0);
        assert_eq!(
            queue.pop(),
            Some(Outbound::Gap {
                start: 10,
                end: 10 + (MAX_SUBSCRIBER_BYTES + 1) as u64,
            })
        );
    }
}
