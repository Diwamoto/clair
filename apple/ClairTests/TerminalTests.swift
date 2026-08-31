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
}
