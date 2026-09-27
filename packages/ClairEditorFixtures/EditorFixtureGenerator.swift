import Foundation

/// Generates on-disk fixtures for editor performance and correctness tests.
///
/// `E01` owns the generator and the canonical fixture descriptions. Later tasks own
/// the tests that consume the generated files.
public enum EditorFixtureGenerator: Sendable {
  /// Description of a generated fixture.
  public struct Fixture: Sendable {
    public let name: String
    public let byteSize: Int
    public let lineCount: Int
    public let longestLineBytes: Int
    public let note: String

    public init(
      name: String,
      byteSize: Int,
      lineCount: Int,
      longestLineBytes: Int,
      note: String
    ) {
      self.name = name
      self.byteSize = byteSize
      self.lineCount = lineCount
      self.longestLineBytes = longestLineBytes
      self.note = note
    }
  }

  /// Fixtures that must be reproducible on every test machine.
  public static let canonicalFixtures: [Fixture] = [
    Fixture(
      name: "unicode-corpus",
      byteSize: UnicodeCorpus.concatenated.utf8.count,
      lineCount: UnicodeCorpus.namedCases.count,
      longestLineBytes: UnicodeCorpus.namedCases.map { $0.text.utf8.count }.max() ?? 0,
      note: "Embedded Unicode boundary cases"
    ),
    Fixture(
      name: "10mb",
      byteSize: 10 * 1_024 * 1_024,
      lineCount: 200_000,
      longestLineBytes: 60,
      note: "10 MiB Swift-like source, ~50 bytes/line"
    ),
    Fixture(
      name: "long-line",
      byteSize: 1 * 1_024 * 1_024,
      lineCount: 1,
      longestLineBytes: 1 * 1_024 * 1_024,
      note: "1 MiB single line"
    ),
    Fixture(
      name: "1mb-japanese",
      byteSize: 1 * 1_024 * 1_024,
      lineCount: 20_000,
      longestLineBytes: 60,
      note: "1 MiB mostly CJK, ~50 bytes/line"
    ),
  ]

  /// Generate a canonical fixture and write it to `directory`.
  ///
  /// - Returns: The URL of the written file.
  @discardableResult
  public static func generate(_ fixture: Fixture, into directory: URL) throws -> URL {
    let fileURL = directory.appendingPathComponent("\(fixture.name).swift")
    let data: Data
    switch fixture.name {
    case "unicode-corpus":
      data = Data(UnicodeCorpus.concatenated.utf8)
    case "10mb":
      data = generateMixedSource(byteSize: fixture.byteSize, lineCount: fixture.lineCount)
    case "long-line":
      data = generateLongLine(byteSize: fixture.byteSize)
    case "1mb-japanese":
      data = generateJapaneseSource(byteSize: fixture.byteSize, lineCount: fixture.lineCount)
    default:
      throw EditorFixtureError.unknownFixture(fixture.name)
    }
    try data.write(to: fileURL, options: .atomic)
    return fileURL
  }

  /// Generate all canonical fixtures into `directory`.
  public static func generateAll(into directory: URL) throws -> [URL] {
    try canonicalFixtures.map { try generate($0, into: directory) }
  }

  private static func generateMixedSource(byteSize: Int, lineCount: Int) -> Data {
    var output = Data(capacity: byteSize)
    let linePrefix = "    public func example_"
    let suffix = "() -> Int { return 42 }\n"
    var lineNumber = 0
    while output.count < byteSize {
      var line = linePrefix
      line += String(format: "%08d", lineNumber)
      line += suffix
      output.append(Data(line.utf8))
      lineNumber += 1
    }
    return output
  }

  private static func generateLongLine(byteSize: Int) -> Data {
    let block = "abcdefghij"
    var output = Data(capacity: byteSize)
    while output.count < byteSize {
      output.append(Data(block.utf8))
    }
    return output
  }

  private static func generateJapaneseSource(byteSize: Int, lineCount: Int) -> Data {
    var output = Data(capacity: byteSize)
    let words = ["関数", "変数", "返す", "値", "こんにちは", "テスト"]
    var lineNumber = 0
    while output.count < byteSize {
      var line = "// コメント \(lineNumber)\n"
      line += "let 値\(lineNumber) = \""
      for _ in 0..<8 {
        line += words[lineNumber % words.count]
      }
      line += "\"\n"
      output.append(Data(line.utf8))
      lineNumber += 1
    }
    return output
  }
}

public enum EditorFixtureError: Error, Sendable {
  case unknownFixture(String)
}
