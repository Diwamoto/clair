import Foundation
import Testing
import ClairWorkspace

@Suite("DAP framing") struct DAPProtocolTests {
  @Test func fragmentedAndCoalescedMessages() throws {
    let a = try DAPFrameParser.encode(Data(#"{"seq":1,"type":"event"}"#.utf8))
    let b = try DAPFrameParser.encode(Data(#"{"seq":2,"type":"response"}"#.utf8))
    var parser = DAPFrameParser()
    #expect(try parser.append(a.prefix(7)) == [])
    #expect(try parser.append(a.dropFirst(7) + b) == [Data(#"{"seq":1,"type":"event"}"#.utf8), Data(#"{"seq":2,"type":"response"}"#.utf8)])
  }

  @Test func rejectsMissingOrOversizedLength() throws {
    var parser = DAPFrameParser()
    #expect(throws: DAPFrameParser.Failure.malformedHeader) {
      try parser.append(Data("Other: 1\r\n\r\n{}".utf8))
    }
    var oversized = DAPFrameParser()
    #expect(throws: DAPFrameParser.Failure.oversizedMessage) {
      try oversized.append(Data("Content-Length: 8388609\r\n\r\n".utf8))
    }
  }
}
