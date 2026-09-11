import AppKit
import CoreGraphics
import CoreText
import Foundation
import XCTest

@testable import ClairApp

@MainActor
final class TextDisplayWidthTests: XCTestCase {
  func testFullWidthClustersOccupyTwoCellsAndAsciiOccupiesOne() {
    XCTAssertEqual(TextDisplayWidth.columns(for: Character("a")), 1)
    XCTAssertEqual(TextDisplayWidth.columns(for: Character("あ")), 2)
    XCTAssertEqual(TextDisplayWidth.columns(for: Character("日")), 2)
    XCTAssertEqual(TextDisplayWidth.columns(for: Character("Ａ")), 2)
    XCTAssertEqual(TextDisplayWidth.columns(in: "ab日本"), 6)
  }

  func testFamilyEmojiAndCombiningMarksStayOneCluster() {
    let family = "👨‍👩‍👧‍👦"
    XCTAssertEqual(TextDisplayWidth.clusters(in: family).count, 1)
    XCTAssertEqual(TextDisplayWidth.columns(in: family), 2)

    let combining = "e\u{0301}\u{0323}"
    XCTAssertEqual(TextDisplayWidth.clusters(in: combining).count, 1)
    XCTAssertEqual(TextDisplayWidth.columns(in: combining), 1)

    let flag = "🇯🇵"
    XCTAssertEqual(TextDisplayWidth.clusters(in: flag).count, 1)
    XCTAssertEqual(TextDisplayWidth.columns(in: flag), 2)
  }

  func testStandaloneCombiningMarkAndControlCharactersTakeNoCell() {
    XCTAssertEqual(TextDisplayWidth.columns(for: Character("\u{0301}")), 0)
    XCTAssertEqual(TextDisplayWidth.columns(for: Character("\u{0007}")), 0)
  }

  func testColumnOfClusterAccountsForFullWidthPredecessors() {
    XCTAssertEqual(TextDisplayWidth.column(ofClusterAt: 0, in: "日本語abc"), 0)
    XCTAssertEqual(TextDisplayWidth.column(ofClusterAt: 3, in: "日本語abc"), 6)
    XCTAssertEqual(TextDisplayWidth.column(ofClusterAt: 5, in: "日本語abc"), 8)
  }
}

@MainActor
final class TextRunClassifierTests: XCTestCase {
  func testSingleWidthAsciiRowsTakeTheFastPath() {
    XCTAssertEqual(
      TextRunClassifier.path(for: "let value = source.row(at: 12)", ligaturesEnabled: false),
      .fastASCII
    )
    XCTAssertEqual(TextRunClassifier.path(for: "", ligaturesEnabled: true), .fastASCII)
  }

  func testNonAsciiRowsTakeTheCoreTextPath() {
    for text in ["日本語の行", "emoji 🙂 tail", "e\u{0301} combining", "half ｶﾅ"] {
      XCTAssertEqual(
        TextRunClassifier.path(for: text, ligaturesEnabled: false),
        .coreText,
        "\(text) must be shaped by CoreText"
      )
    }
  }

  func testLigatureCandidatesTakeTheCoreTextPathOnlyWhenLigaturesAreEnabled() {
    XCTAssertEqual(TextRunClassifier.path(for: "a -> b", ligaturesEnabled: true), .coreText)
    XCTAssertEqual(TextRunClassifier.path(for: "a -> b", ligaturesEnabled: false), .fastASCII)
    XCTAssertEqual(TextRunClassifier.path(for: "a != b", ligaturesEnabled: true), .coreText)
  }
}

@MainActor
final class TextSurfaceDamageTests: XCTestCase {
  func testDamageMergesOverlappingAndAdjacentRanges() {
    let damage = TextSurfaceDamage(rowRanges: [4..<6, 0..<2, 2..<3, 9..<10])
    XCTAssertEqual(damage.rowRanges, [0..<3, 4..<6, 9..<10])
    XCTAssertEqual(damage.rowCount, 6)
    XCTAssertTrue(damage.contains(row: 5))
    XCTAssertFalse(damage.contains(row: 3))
  }

  func testDamageIntersectionClampsToTheExposedWindow() {
    let damage = TextSurfaceDamage(rowRanges: [0..<4, 20..<40])
    XCTAssertEqual(damage.intersection(with: 2..<25).rowRanges, [2..<4, 20..<25])
    XCTAssertTrue(damage.intersection(with: 100..<120).isEmpty)
    XCTAssertTrue(TextSurfaceDamage.empty.isEmpty)
  }

  func testFixtureSourceReportsOnlyTheEditedRows() {
    let source = TextFixtureSource(lines: ["one", "two", "three", "four"])
    let observer = RecordingSurfaceObserver()
    source.observer = observer

    source.replace(row: 2, with: "THREE")
    source.replace(rows: 0..<2, with: ["ONE", "TWO"])

    XCTAssertEqual(observer.damages.map(\.rowRanges), [[2..<3], [0..<2]])
    XCTAssertEqual(source.row(at: 2)?.text, "THREE")
  }
}

@MainActor
final class TextFontMetricsTests: XCTestCase {
  func testMetricsProduceAPositiveCellAndAsciiGlyphTable() {
    let metrics = TextFontMetrics(configuration: .terminal)
    XCTAssertGreaterThan(metrics.cellSize.width, 0)
    XCTAssertGreaterThan(metrics.cellSize.height, metrics.ascent)
    XCTAssertNotNil(metrics.asciiGlyph(for: "A", bold: false))
    XCTAssertNotNil(metrics.asciiGlyph(for: "~", bold: true))
    XCTAssertNil(metrics.asciiGlyph(for: "日", bold: false))
    XCTAssertGreaterThan(metrics.baselineOffset, 0)
    XCTAssertLessThanOrEqual(metrics.baselineOffset, metrics.cellSize.height)
  }

  func testFallbackResolutionIsCachedPerCluster() {
    let metrics = TextFontMetrics(configuration: .editor)
    XCTAssertTrue(metrics.covers("abc", bold: false))

    let first = metrics.font(for: "🙂", bold: false)
    let second = metrics.font(for: "🙂", bold: false)
    XCTAssertEqual(metrics.fallbackResolutionCount, 2)
    XCTAssertEqual(metrics.fallbackCacheHitCount, 1)
    XCTAssertTrue(first === second)

    _ = metrics.font(for: "abc", bold: false)
    XCTAssertEqual(metrics.fallbackResolutionCount, 2, "covered text must not resolve a fallback")
  }

  func testRunCacheReusesShapedLinesAndEvictsTheOldest() {
    let cache = TextRunCache(capacity: 2)
    let style = TextCellStyle.plain(TextSurfaceTheme.oneDark.foreground)
    var made = 0

    for text in ["a", "b", "a", "c", "b"] {
      _ = cache.line(for: TextRunCache.Key(text: text, style: style)) {
        made += 1
        return CTLineCreateWithAttributedString(
          NSAttributedString(string: text) as CFAttributedString
        )
      }
    }

    XCTAssertEqual(made, 4, "only the repeated \"a\" is served from the cache")
    XCTAssertEqual(cache.hitCount, 1)
    XCTAssertEqual(cache.count, 2)
  }
}

@MainActor
final class TextSurfaceRendererTests: XCTestCase {
  private func makeRenderer() -> TextSurfaceRenderer {
    TextSurfaceRenderer(
      metrics: TextFontMetrics(configuration: .editor),
      theme: .oneDark,
      contentInset: .zero
    )
  }

  func testRowsAreSplitIntoRunsThatKeepFullWidthClustersOnTheGrid() {
    let renderer = makeRenderer()
    let style = TextCellStyle.plain(TextSurfaceTheme.oneDark.foreground)
    let row = TextSurfaceRow(index: 0, text: "ab日c", style: style)

    let segments = renderer.segments(for: row)
    XCTAssertEqual(segments.map(\.text), ["ab", "日", "c"])
    XCTAssertEqual(segments.map(\.column), [0, 2, 4])
    XCTAssertEqual(segments.map(\.columnWidth), [2, 2, 1])
    XCTAssertEqual(segments.map(\.path), [.fastASCII, .coreText, .fastASCII])
  }

  func testStyleBoundariesSplitRunsAndLigatureRunsAreShaped() {
    let renderer = makeRenderer()
    let plain = TextCellStyle.plain(TextSurfaceTheme.oneDark.foreground)
    var bold = plain
    bold.isBold = true
    let row = TextSurfaceRow(
      index: 0,
      spans: [
        TextSurfaceSpan(text: "let ", style: plain),
        TextSurfaceSpan(text: "a -> b", style: bold),
      ]
    )

    let segments = renderer.segments(for: row)
    XCTAssertEqual(segments.map(\.text), ["let ", "a -> b"])
    XCTAssertEqual(segments.map(\.path), [.fastASCII, .coreText])
    XCTAssertEqual(segments.map(\.column), [0, 4])
  }

  func testPlanOnlyContainsDamagedRowsInsideTheExposedRectangle() throws {
    let renderer = makeRenderer()
    let source = TextFixtureSource(lines: (0..<200).map { "line \($0)" })
    let cellHeight = renderer.metrics.cellSize.height
    let viewport = CGRect(x: 0, y: cellHeight * 10, width: 400, height: cellHeight * 5)

    let inside = renderer.plan(
      damage: TextSurfaceDamage(rowRanges: [3..<4, 11..<13, 120..<160]),
      in: viewport,
      viewportWidth: 400,
      source: source
    )
    XCTAssertEqual(inside.rowIndexes, [11, 12])
    let firstRect = try XCTUnwrap(inside.rects.first)
    XCTAssertEqual(firstRect.height, cellHeight)
    XCTAssertEqual(firstRect.minY, cellHeight * 11)

    let outside = renderer.plan(
      damage: TextSurfaceDamage(rows: 40..<60),
      in: viewport,
      viewportWidth: 400,
      source: source
    )
    XCTAssertTrue(outside.isEmpty, "damage outside the exposed rectangle must not be drawn")
  }

  func testPlanNeverExceedsTheExposedViewportForLargeDamage() {
    let renderer = makeRenderer()
    let source = TextFixtureSource(lines: (0..<100_000).map { "row \($0)" })
    let cellHeight = renderer.metrics.cellSize.height
    let viewport = CGRect(x: 0, y: 0, width: 600, height: cellHeight * 40)

    let plan = renderer.plan(
      damage: TextSurfaceDamage(rows: 0..<100_000),
      in: viewport,
      viewportWidth: 600,
      source: source
    )
    XCTAssertEqual(plan.rows.count, 40)
    XCTAssertEqual(plan.rowIndexes.last, 39)
  }

  func testDrawingTouchesOnlyTheDamagedRowBand() throws {
    let renderer = makeRenderer()
    let source = TextFixtureSource(lines: ["alpha", "bravo", "charlie", "delta"])
    let cellHeight = renderer.metrics.cellSize.height
    let width = 240
    let height = Int((cellHeight * 4).rounded(.up))
    let context = try XCTUnwrap(
      CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
      )
    )
    // Flipped drawing space, matching the surface view.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

    let dirtyRect = CGRect(x: 0, y: cellHeight, width: CGFloat(width), height: cellHeight)
    let plan = renderer.plan(
      damage: TextSurfaceDamage(row: 1),
      in: dirtyRect,
      viewportWidth: CGFloat(width),
      source: source
    )
    XCTAssertEqual(plan.rowIndexes, [1])
    renderer.draw(plan, source: source, in: context)

    let sentinel = try XCTUnwrap(pixel(in: context, x: 4, y: height - 4))
    let repainted = try XCTUnwrap(pixel(in: context, x: 4, y: Int(cellHeight * 1.5)))
    XCTAssertEqual(sentinel.red, 255, "rows outside the damage must keep the sentinel fill")
    XCTAssertLessThan(repainted.red, 255, "the damaged row must be repainted")
  }

  private func pixel(
    in context: CGContext,
    x: Int,
    y: Int
  ) -> (red: Int, green: Int, blue: Int)? {
    guard let data = context.data, x >= 0, y >= 0, x < context.width, y < context.height else {
      return nil
    }
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    let offset = y * context.bytesPerRow + x * 4
    return (Int(bytes[offset + 1]), Int(bytes[offset + 2]), Int(bytes[offset + 3]))
  }
}

@MainActor
final class TextSurfaceViewTests: XCTestCase {
  func testInvalidationDirtiesOnlyTheDamagedRowsAndDrawsThem() {
    let metrics = TextFontMetrics(configuration: .terminal)
    let renderer = TextSurfaceRenderer(metrics: metrics, theme: .oneDark, contentInset: .zero)
    let source = TextFixtureSource(lines: (0..<40).map { "row \($0)" })
    let view = TextSurfaceView(source: source, renderer: renderer)
    view.setFrameSize(
      renderer.contentSize(rowCount: source.rowCount, columnCount: source.columnCount)
    )

    source.replace(row: 7, with: "row 7 edited")

    XCTAssertEqual(view.pendingDamage.rowRanges, [7..<8])
    let rects = renderer.rects(for: view.pendingDamage, width: view.bounds.width)
    XCTAssertEqual(rects.count, 1)
    XCTAssertEqual(rects[0].minY, metrics.cellSize.height * 7)
    XCTAssertEqual(rects[0].height, metrics.cellSize.height)
    XCTAssertGreaterThan(view.bounds.width, 0)

    let plan = renderer.plan(
      damage: view.pendingDamage,
      in: rects[0],
      viewportWidth: view.bounds.width,
      source: source
    )
    XCTAssertEqual(plan.rowIndexes, [7])
  }

  func testSwitchingFixturesKeepsTheSurfaceBoundToTheNewSource() {
    let renderer = TextSurfaceRenderer(metrics: TextFontMetrics(configuration: .editor))
    let first = TextSurfaceFixture.asciiCode.makeSource()
    let view = TextSurfaceView(source: first, renderer: renderer)
    let second = TextSurfaceFixture.japanese.makeSource()

    view.setSource(second)
    second.replace(row: 0, with: "差し替えた行")

    XCTAssertEqual(ObjectIdentifier(view.source), ObjectIdentifier(second))
    XCTAssertEqual(view.pendingDamage.rowRanges, [0..<1])
    XCTAssertGreaterThan(view.frame.height, 0)
  }

  func testEveryHarnessFixtureProducesRowsForTheSurface() {
    for fixture in TextSurfaceFixture.allCases {
      let source = fixture.makeSource()
      XCTAssertGreaterThan(source.rowCount, 0, "\(fixture.title) must provide rows")
      XCTAssertGreaterThan(source.columnCount, 0, "\(fixture.title) must provide columns")
      XCTAssertNotNil(source.row(at: 0))
      XCTAssertNil(source.row(at: source.rowCount))
    }
  }
}

@MainActor
private final class RecordingSurfaceObserver: TextSurfaceSourceObserver {
  private(set) var damages: [TextSurfaceDamage] = []

  func textSurfaceSource(
    _ source: any TextSurfaceSource,
    didInvalidate damage: TextSurfaceDamage
  ) {
    damages.append(damage)
  }
}
