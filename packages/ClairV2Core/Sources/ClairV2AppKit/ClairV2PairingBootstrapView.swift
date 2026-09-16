import ClairV2DaemonKit
import ClairV2Transport
import Foundation

#if os(macOS)
  import CoreImage
  import CoreImage.CIFilterBuiltins
  import SwiftUI

  /// N09: the Mac-side half of the pairing bootstrap gap N08 found. This is
  /// deliberately the minimal functional UI the P0 priority contract calls
  /// for — a button, the transport code, a QR rendering of it, the host
  /// fingerprint, and the expiry — with no bespoke visual design. The actual
  /// trust decision still belongs to `ClairPairingAuthority.pair(_:)` on
  /// whichever device scans or pastes this code; this view only issues and
  /// displays it.
  public struct ClairV2PairingBootstrapView: View {
    private let client: ClairDaemonControlClient
    @State private var issuance: ClairDaemonPairingIssuance?
    @State private var errorMessage: String?
    @State private var isIssuing = false

    public init(paths: ClairDaemonPaths = .default) {
      client = ClairDaemonControlClient(paths: paths)
    }

    public var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        Text("Pair a device").font(.headline)
        Button(issuance == nil ? "Pair a device" : "Issue a new code") {
          issue()
        }
        .disabled(isIssuing)

        if let errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
            .font(.callout)
        }

        if let issuance {
          Divider()
          if let cgImage = Self.qrCodeImage(for: issuance.code) {
            Image(decorative: cgImage, scale: 1)
              .interpolation(.none)
              .resizable()
              .frame(width: 180, height: 180)
          }
          Text(issuance.code)
            .font(.footnote.monospaced())
            .textSelection(.enabled)
          Text("Fingerprint: \(issuance.fingerprint.description.prefix(16))…")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
          Text("Expires \(issuance.expiresAt.formatted(date: .omitted, time: .standard))")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("Confirm this fingerprint matches the pairing device before trusting it.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .padding()
    }

    private func issue() {
      isIssuing = true
      errorMessage = nil
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let result = try client.issuePairing()
          DispatchQueue.main.async {
            issuance = result
            isIssuing = false
          }
        } catch {
          DispatchQueue.main.async {
            issuance = nil
            errorMessage = String(describing: error)
            isIssuing = false
          }
        }
      }
    }

    /// A failed QR render (e.g. the CoreImage filter graph is unavailable)
    /// still leaves the copyable text code visible below, so pairing is
    /// never blocked on QR rendering succeeding. Internal (not private) so
    /// it is independently testable via `@testable import`.
    nonisolated static func qrCodeImage(for code: String) -> CGImage? {
      guard !code.isEmpty, let data = code.data(using: .ascii) else { return nil }
      let filter = CIFilter.qrCodeGenerator()
      filter.message = data
      filter.correctionLevel = "M"
      guard let outputImage = filter.outputImage else { return nil }
      let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
      return CIContext().createCGImage(scaled, from: scaled.extent)
    }
  }
#endif
