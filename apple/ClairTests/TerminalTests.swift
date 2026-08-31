import Foundation
import XCTest

@testable import ClairApp

final class TerminalProtocolTests: XCTestCase {
  func testDecoderAcceptsPartialFramesAndPreservesBinaryInput() throws {
    let input = try TerminalFrame.input("printf '日本語\\n'\n")
    let resize = try TerminalFrame.resize(rows: 40, columns: 120)
    var decoder = TerminalFrameDecoder()

    XCTAssertEqual(try decoder.append(Data(input.encoded.prefix(3))), [])

    var remainder = Data(input.encoded.dropFirst(3))
    remainder.append(resize.encoded)
    let frames = try decoder.append(remainder)

    XCTAssertEqual(frames, [input, resize])
    XCTAssertEqual(frames[0].payload, Data("printf '日本語\\n'\n".utf8))
    XCTAssertEqual(frames[1].dimensions?.rows, 40)
    XCTAssertEqual(frames[1].dimensions?.columns, 120)
  }

  func testFrameValidationRejectsInvalidDimensionsAndOversizedPayloads() throws {
    XCTAssertThrowsError(try TerminalFrame.resize(rows: 0, columns: 80)) { error in
      XCTAssertEqual(error as? TerminalProtocolError, .invalidDimensions)
    }

    var decoder = TerminalFrameDecoder()
    let oversizedLength = UInt32(TerminalFrame.maxPayloadLength + 1).bigEndian
    var header = Data([0x43, 0x50, TerminalFrame.protocolVersion, TerminalFrameKind.input.rawValue])
    withUnsafeBytes(of: oversizedLength) { header.append(contentsOf: $0) }

    XCTAssertThrowsError(try decoder.append(header)) { error in
      XCTAssertEqual(
        error as? TerminalProtocolError,
        .payloadTooLarge(TerminalFrame.maxPayloadLength + 1)
      )
    }
  }

  func testSanitizerHandlesSplitEscapeSequencesAndKeepsUtf8Text() {
    var sanitizer = TerminalOutputSanitizer()
    var firstChunk = Data("日本語".utf8)
    firstChunk.append(contentsOf: [0x1b, 0x5b, 0x33])
    XCTAssertEqual(String(decoding: sanitizer.filter(firstChunk), as: UTF8.self), "日本語")

    var secondChunk = Data("1mvisible".utf8)
    secondChunk.append(contentsOf: [0x1b, 0x5d])
    secondChunk.append(contentsOf: Data("window title".utf8))
    secondChunk.append(contentsOf: [0x07])
    secondChunk.append(contentsOf: Data("\n".utf8))
    XCTAssertEqual(String(decoding: sanitizer.filter(secondChunk), as: UTF8.self), "visible\n")
  }

  func testTranscriptBufferCapsAtUtf8Boundary() {
    var buffer = TerminalTranscriptBuffer(maximumBytes: 5)
    buffer.append(Data("a🙂bcd".utf8))

    XCTAssertLessThanOrEqual(buffer.byteCount, 5)
    XCTAssertEqual(buffer.string, "bcd")
  }

  func testSessionBrokerDecoderAcceptsPartialAndBatchedFrames() throws {
    let sessionID = try XCTUnwrap(UUID(uuidString: "12345678-90ab-cdef-1234-567890abcdef"))
    let attach = try SessionBrokerFrame.attach(
      mode: .create,
      sessionID: sessionID,
      cursor: 17,
      dimensions: TerminalDimensions(rows: 30, columns: 100),
      cwd: "/tmp",
      shell: "/bin/sh"
    )
    let input = try SessionBrokerFrame.input(Data([0x00, 0xff, 0x7f]))
    var decoder = SessionBrokerFrameDecoder()

    let encoded = attach.encoded + input.encoded
    XCTAssertEqual(try decoder.append(Data(encoded.prefix(5))), [])
    XCTAssertEqual(try decoder.append(Data(encoded.dropFirst(5))), [attach, input])
  }

  func testSessionBrokerDecoderAllowsLargeCompleteBatchesAndBoundsPayloads() throws {
    let first = try SessionBrokerFrame.input(
      Data(repeating: 0x61, count: SessionBrokerFrame.maxPayloadLength)
    )
    let second = try SessionBrokerFrame.input(
      Data(repeating: 0x62, count: SessionBrokerFrame.maxPayloadLength)
    )
    var decoder = SessionBrokerFrameDecoder()
    XCTAssertEqual(try decoder.append(first.encoded + second.encoded), [first, second])

    XCTAssertThrowsError(
      try SessionBrokerFrame.input(
        Data(repeating: 0x63, count: SessionBrokerFrame.maxPayloadLength + 1)
      )
    ) { error in
      XCTAssertEqual(
        error as? SessionBrokerProtocolError,
        .payloadTooLarge(SessionBrokerFrame.maxPayloadLength + 1)
      )
    }
  }

  func testSessionBrokerPayloadFramesDecodeAndRejectInvalidRanges() throws {
    let sessionID = try XCTUnwrap(UUID(uuidString: "12345678-90ab-cdef-1234-567890abcdef"))
    var attachedPayload = Data([UInt8(sessionID.uuidString.utf8.count)])
    attachedPayload.append(contentsOf: sessionID.uuidString.utf8)
    appendUInt64(3, to: &attachedPayload)
    appendUInt64(12, to: &attachedPayload)
    appendUInt64(4, to: &attachedPayload)
    attachedPayload.append(0)
    let attachment = try SessionBrokerAttachment(
      frame: SessionBrokerFrame(kind: .attached, payload: attachedPayload)
    )
    XCTAssertEqual(attachment.sessionID, sessionID)
    XCTAssertEqual(attachment.epoch, 3)
    XCTAssertEqual(attachment.currentOffset, 12)
    XCTAssertEqual(attachment.oldestOffset, 4)
    XCTAssertFalse(attachment.isExited)

    var outputPayload = Data()
    appendUInt64(12, to: &outputPayload)
    outputPayload.append(contentsOf: Data("output".utf8))
    let output = try SessionBrokerOutput(
      frame: SessionBrokerFrame(kind: .output, payload: outputPayload)
    )
    XCTAssertEqual(output.offset, 12)
    XCTAssertEqual(output.data, Data("output".utf8))

    var errorPayload = Data([SessionBrokerErrorCode.sessionMissing.rawValue])
    errorPayload.append(contentsOf: Data("not found".utf8))
    let brokerError = try SessionBrokerErrorFrame(
      frame: SessionBrokerFrame(kind: .error, payload: errorPayload)
    )
    XCTAssertEqual(brokerError.code, .sessionMissing)
    XCTAssertEqual(brokerError.message, "not found")

    var invalidGap = Data()
    appendUInt64(8, to: &invalidGap)
    appendUInt64(8, to: &invalidGap)
    XCTAssertThrowsError(
      try SessionBrokerGap(frame: SessionBrokerFrame(kind: .gap, payload: invalidGap))
    ) { error in
      XCTAssertEqual(error as? SessionBrokerProtocolError, .invalidState)
    }
  }

  func testTerminalTabPersistsStableSessionID() throws {
    let sessionID = try XCTUnwrap(UUID(uuidString: "12345678-90ab-cdef-1234-567890abcdef"))
    let tab = ProjectPaneTab.terminal(id: sessionID)
    let encoded = try JSONEncoder().encode(tab)
    let decoded = try JSONDecoder().decode(ProjectPaneTab.self, from: encoded)

    XCTAssertEqual(decoded, tab)
    XCTAssertEqual(decoded.sessionID, sessionID)
  }

  private func appendUInt64(_ value: UInt64, to data: inout Data) {
    for shift in stride(from: 56, through: 0, by: -8) {
      data.append(UInt8((value >> UInt64(shift)) & 0xff))
    }
  }
}
