import SwiftUI

struct ContentView: View {
  let state: BootstrapState

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      HStack(spacing: 14) {
        Image(systemName: "hammer.fill")
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(.tint)

        VStack(alignment: .leading, spacing: 3) {
          Text(state.profile.displayName)
            .font(.largeTitle.weight(.semibold))
          Text("Native workspace bootstrap")
            .foregroundStyle(.secondary)
        }

        Spacer()

        Text(state.profile.channel.rawValue.uppercased())
          .font(.caption.weight(.bold))
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(.tint.opacity(0.14), in: Capsule())
      }

      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
        detailRow(label: "Bundle", value: state.profile.bundleIdentifier)
        detailRow(label: "Preferences", value: state.profile.preferencesDomain)
        detailRow(label: "Data", value: state.applicationSupportURL?.path ?? "Unavailable")
        detailRow(label: "Rust core", value: rustStatus)
      }
      .textSelection(.enabled)

      if let errorMessage = state.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Label("Swift → Rust smoke path is ready", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      }

      Spacer()
    }
    .padding(32)
    .frame(minWidth: 620, minHeight: 380)
  }

  private var rustStatus: String {
    let value = String(format: "0x%08X", state.rustSmokeValue)
    return state.rustSmokeSucceeded ? "ready (\(value))" : "failed (\(value))"
  }

  @ViewBuilder
  private func detailRow(label: String, value: String) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.body, design: .monospaced))
    }
  }
}
