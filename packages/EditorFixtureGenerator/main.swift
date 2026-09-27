import ClairEditorFixtures
import Foundation

@main
struct EditorFixtureGeneratorMain {
  static func main() throws {
    let arguments = CommandLine.arguments.dropFirst()
    guard let directory = arguments.first else {
      print("usage: EditorFixtureGenerator <output-directory>")
      throw ExitCode.failure
    }
    let url = URL(fileURLWithPath: directory)
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    let urls = try EditorFixtureGenerator.generateAll(into: url)
    for fixtureURL in urls {
      let attributes = try FileManager.default.attributesOfItem(atPath: fixtureURL.path)
      let size = attributes[.size] as? Int ?? 0
      print("\(fixtureURL.lastPathComponent): \(size) bytes")
    }
  }
}

enum ExitCode: Error {
  case failure
}
