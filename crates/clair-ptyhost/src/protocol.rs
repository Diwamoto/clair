use std::fmt;
use std::io::{self, Read, Write};

pub const PROTOCOL_VERSION: u8 = 1;
pub const MAX_PAYLOAD_LENGTH: usize = 64 * 1024;
const HEADER_LENGTH: usize = 8;
const MAGIC: [u8; 2] = *b"CP";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum FrameKind {
    Input = 1,
    Resize = 2,
    Close = 3,
    Output = 0x81,
    Exit = 0x82,
    Error = 0xff,
}

impl TryFrom<u8> for FrameKind {
    type Error = ProtocolError;

    fn try_from(value: u8) -> Result<Self, ProtocolError> {
        match value {
            1 => Ok(Self::Input),
            2 => Ok(Self::Resize),
            3 => Ok(Self::Close),
            0x81 => Ok(Self::Output),
            0x82 => Ok(Self::Exit),
            0xff => Ok(Self::Error),
            other => Err(ProtocolError::UnknownFrameKind(other)),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProtocolError {
    InvalidMagic,
    UnsupportedVersion(u8),
    UnknownFrameKind(u8),
    PayloadTooLarge(usize),
    InvalidPayloadLength {
        kind: FrameKind,
        expected: usize,
        actual: usize,
    },
    InvalidDimensions,
}

impl fmt::Display for ProtocolError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidMagic => formatter.write_str("invalid PTY frame magic"),
            Self::UnsupportedVersion(version) => {
                write!(formatter, "unsupported PTY protocol version {version}")
            }
            Self::UnknownFrameKind(kind) => {
                write!(formatter, "unknown PTY frame kind 0x{kind:02x}")
            }
            Self::PayloadTooLarge(length) => {
                write!(formatter, "PTY frame payload is too large: {length} bytes")
            }
            Self::InvalidPayloadLength {
                kind,
                expected,
                actual,
            } => write!(
                formatter,
                "invalid {kind:?} payload length: expected {expected}, got {actual}"
            ),
            Self::InvalidDimensions => formatter.write_str("PTY dimensions must be non-zero"),
        }
    }
}

impl std::error::Error for ProtocolError {}

#[derive(Debug)]
pub enum FrameReadError {
    Io(io::Error),
    Protocol(ProtocolError),
}

impl fmt::Display for FrameReadError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "PTY transport I/O failed: {error}"),
            Self::Protocol(error) => error.fmt(formatter),
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Frame {
    pub kind: FrameKind,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn new(kind: FrameKind, payload: Vec<u8>) -> Result<Self, ProtocolError> {
        if payload.len() > MAX_PAYLOAD_LENGTH {
            return Err(ProtocolError::PayloadTooLarge(payload.len()));
        }

        let expected_length = match kind {
            FrameKind::Resize => Some(4),
            FrameKind::Close => Some(0),
            FrameKind::Exit => Some(1),
            FrameKind::Input | FrameKind::Output | FrameKind::Error => None,
        };
        if let Some(expected) = expected_length
            && payload.len() != expected
        {
            return Err(ProtocolError::InvalidPayloadLength {
                kind,
                expected,
                actual: payload.len(),
            });
        }

        if kind == FrameKind::Resize {
            let rows = u16::from_be_bytes([payload[0], payload[1]]);
            let columns = u16::from_be_bytes([payload[2], payload[3]]);
            if rows == 0 || columns == 0 {
                return Err(ProtocolError::InvalidDimensions);
            }
        }

        Ok(Self { kind, payload })
    }

    pub fn output(payload: Vec<u8>) -> Result<Self, ProtocolError> {
        Self::new(FrameKind::Output, payload)
    }

    pub fn exit(status: u8) -> Self {
        Self {
            kind: FrameKind::Exit,
            payload: vec![status],
        }
    }

    pub fn error(message: impl Into<Vec<u8>>) -> Result<Self, ProtocolError> {
        Self::new(FrameKind::Error, message.into())
    }

    pub fn dimensions(&self) -> Result<(u16, u16), ProtocolError> {
        if self.kind != FrameKind::Resize {
            return Err(ProtocolError::InvalidPayloadLength {
                kind: self.kind,
                expected: 4,
                actual: self.payload.len(),
            });
        }
        let rows = u16::from_be_bytes([self.payload[0], self.payload[1]]);
        let columns = u16::from_be_bytes([self.payload[2], self.payload[3]]);
        if rows == 0 || columns == 0 {
            return Err(ProtocolError::InvalidDimensions);
        }
        Ok((rows, columns))
    }

    pub fn write_to<W: Write>(&self, writer: &mut W) -> io::Result<()> {
        let length = u32::try_from(self.payload.len())
            .expect("validated PTY frame payload fits in a u32")
            .to_be_bytes();
        writer.write_all(&MAGIC)?;
        writer.write_all(&[PROTOCOL_VERSION, self.kind as u8])?;
        writer.write_all(&length)?;
        writer.write_all(&self.payload)?;
        writer.flush()
    }
}

pub fn read_frame<R: Read>(reader: &mut R) -> Result<Option<Frame>, FrameReadError> {
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

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::{Frame, FrameKind, FrameReadError, MAX_PAYLOAD_LENGTH, ProtocolError, read_frame};

    #[test]
    fn frame_round_trip_preserves_binary_input() {
        let frame = Frame::new(FrameKind::Input, vec![0, 0xff, 0x1b, b'\n']).unwrap();
        let mut encoded = Vec::new();
        frame.write_to(&mut encoded).unwrap();

        assert_eq!(read_frame(&mut Cursor::new(encoded)).unwrap(), Some(frame));
    }

    #[test]
    fn partial_header_is_reported_without_accepting_a_frame() {
        let error = read_frame(&mut Cursor::new(b"CP\x01".to_vec())).unwrap_err();
        assert!(
            matches!(error, FrameReadError::Io(io_error) if io_error.kind() == std::io::ErrorKind::UnexpectedEof)
        );
    }

    #[test]
    fn oversized_frame_is_rejected_before_payload_allocation() {
        let length = u32::try_from(MAX_PAYLOAD_LENGTH + 1).unwrap();
        let bytes = [
            b"CP".as_slice(),
            &[1, FrameKind::Input as u8],
            &length.to_be_bytes(),
        ]
        .concat();

        let error = read_frame(&mut Cursor::new(bytes)).unwrap_err();
        assert!(matches!(
            error,
            FrameReadError::Protocol(ProtocolError::PayloadTooLarge(length))
                if length == MAX_PAYLOAD_LENGTH + 1
        ));
    }

    #[test]
    fn resize_rejects_zero_dimensions() {
        assert_eq!(
            Frame::new(FrameKind::Resize, vec![0, 0, 0, 80]),
            Err(ProtocolError::InvalidDimensions)
        );
        assert_eq!(
            Frame::new(FrameKind::Resize, vec![0, 24, 0, 0]),
            Err(ProtocolError::InvalidDimensions)
        );
        assert_eq!(
            Frame::new(FrameKind::Resize, vec![0, 0, 0]),
            Err(ProtocolError::InvalidPayloadLength {
                kind: FrameKind::Resize,
                expected: 4,
                actual: 3,
            })
        );
    }

    #[test]
    fn control_frame_payload_lengths_are_checked() {
        assert!(matches!(
            Frame::new(FrameKind::Close, vec![1]),
            Err(ProtocolError::InvalidPayloadLength { .. })
        ));
        assert!(matches!(
            Frame::new(FrameKind::Exit, Vec::new()),
            Err(ProtocolError::InvalidPayloadLength { .. })
        ));
    }
}
