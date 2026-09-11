import AppKit
import CoreImage
import SwiftUI

// MARK: - Workspace Settings Panel

struct WorkspaceSettingsPanel: View {
  @Binding var fontSize: Double
  @Binding var wordWrap: Bool
  @ObservedObject var mobileBridge: MobileControlRuntimeBridge
  let onDismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("設定")
            .font(WorkspaceChrome.chromeFont(size: 15, weight: .semibold))
          Text("エディタの設定")
            .font(WorkspaceChrome.chromeFont(size: 10))
            .foregroundStyle(WorkspaceChrome.textTertiary)
        }
        Spacer()
        Button(action: onDismiss) {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.tactile)
        .foregroundStyle(WorkspaceChrome.textTertiary)
        .background(WorkspaceChrome.surface, in: RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("設定を閉じる")
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 68)

      Divider()
        .background(WorkspaceChrome.border)

      VStack(alignment: .leading, spacing: 14) {
        settingRow(
          title: "フォントサイズ",
          subtitle: "エディタの文字"
        ) {
          Picker("フォントサイズ", selection: $fontSize) {
            Text("11 px").tag(11.0)
            Text("12 px").tag(12.0)
            Text("13 px").tag(13.0)
            Text("14 px").tag(14.0)
            Text("14.5 px").tag(14.5)
            Text("15 px").tag(15.0)
            Text("16 px").tag(16.0)
            Text("17 px").tag(17.0)
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .controlSize(.small)
        }

        settingRow(
          title: "行の折り返し",
          subtitle: "長い行をエディタの幅に合わせて折り返します。"
        ) {
          Toggle("行の折り返し", isOn: $wordWrap)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
      }
      .padding(16)

      Divider()
        .background(WorkspaceChrome.border)

      MobileControlSettingsSection(mobileBridge: mobileBridge)
        .padding(16)

      Divider()
        .background(WorkspaceChrome.border)

      HStack {
        Text("変更はすぐに反映されます")
          .font(WorkspaceChrome.chromeFont(size: 9))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
        Spacer()
        Button("完了", action: onDismiss)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .foregroundStyle(WorkspaceChrome.textPrimary)
    .frame(width: 410)
  }

  private func settingRow<Content: View>(
    title: String,
    subtitle: String,
    @ViewBuilder control: () -> Content
  ) -> some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(WorkspaceChrome.chromeFont(size: 11, weight: .medium))
        Text(subtitle)
          .font(WorkspaceChrome.chromeFont(size: 10))
          .foregroundStyle(WorkspaceChrome.textQuaternary)
      }
      Spacer()
      control()
    }
    .frame(minHeight: 58)
  }
}

struct MobileControlSettingsSection: View {
  @ObservedObject var mobileBridge: MobileControlRuntimeBridge
  @State private var didCopyPairingLink = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Circle()
          .fill(mobileBridge.isEnabled ? Color.green : WorkspaceChrome.textQuaternary)
          .frame(width: 7, height: 7)
        VStack(alignment: .leading, spacing: 2) {
          Text("モバイル操作")
            .font(WorkspaceChrome.chromeFont(size: 12, weight: .semibold))
          Text(
            mobileBridge.isEnabled
              ? "このMacの作業をプライベート接続から操作できます。"
              : "Macを閉じてもセッションを残す接続を準備します。"
          )
          .font(WorkspaceChrome.chromeFont(size: 10))
          .foregroundStyle(WorkspaceChrome.textTertiary)
        }
        Spacer()
        Button(mobileBridge.isEnabled ? "無効化" : "有効化") {
          mobileBridge.setEnabled(!mobileBridge.isEnabled)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      if mobileBridge.isEnabled {
        VStack(alignment: .leading, spacing: 8) {
          settingValueRow(title: "ローカル endpoint", value: mobileBridge.endpointDescription)
          settingValueRow(
            title: "ホスト fingerprint",
            value: mobileBridge.hostIdentity?.fingerprint ?? "未生成"
          )

          Text("Cloudflare / Tailscale の private route をこの endpoint に向けてから、モバイルと接続してください。")
            .font(WorkspaceChrome.chromeFont(size: 9))
            .foregroundStyle(WorkspaceChrome.textQuaternary)

          HStack(spacing: 8) {
            Button("QRリンクを生成") {
              mobileBridge.createPairingLink()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            if mobileBridge.pairingLink != nil {
              Button("閉じる") {
                mobileBridge.clearPairingLink()
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
            }
          }

          if let pairingURL = mobileBridge.pairingURLString {
            HStack(alignment: .top, spacing: 12) {
              MobilePairingCodeView(payload: pairingURL)
                .frame(width: 116, height: 116)
                .background(.white, in: RoundedRectangle(cornerRadius: 6))

              VStack(alignment: .leading, spacing: 7) {
                Text("1回限りのペアリングリンク")
                  .font(WorkspaceChrome.chromeFont(size: 10, weight: .medium))
                Text(pairingURL)
                  .font(.system(size: 8, design: .monospaced))
                  .foregroundStyle(WorkspaceChrome.textTertiary)
                  .lineLimit(4)
                  .truncationMode(.middle)
                  .textSelection(.enabled)
                Button(didCopyPairingLink ? "コピーしました" : "リンクをコピー") {
                  NSPasteboard.general.clearContents()
                  NSPasteboard.general.setString(pairingURL, forType: .string)
                  didCopyPairingLink = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(WorkspaceChrome.surface, in: RoundedRectangle(cornerRadius: 7))
          }

          if !mobileBridge.devices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
              Text("ペアリング済み端末")
                .font(WorkspaceChrome.chromeFont(size: 10, weight: .medium))
              ForEach(mobileBridge.devices) { device in
                HStack(spacing: 8) {
                  Image(systemName: "iphone")
                    .foregroundStyle(WorkspaceChrome.textTertiary)
                  VStack(alignment: .leading, spacing: 1) {
                    Text(device.displayName)
                      .font(WorkspaceChrome.chromeFont(size: 10))
                    Text(device.scopes.map(\.rawValue).sorted().joined(separator: " / "))
                      .font(WorkspaceChrome.chromeFont(size: 8))
                      .foregroundStyle(WorkspaceChrome.textQuaternary)
                  }
                  Spacer()
                  Button("解除") {
                    mobileBridge.revoke(device)
                  }
                  .buttonStyle(.tactile)
                  .controlSize(.small)
                  .foregroundStyle(.red.opacity(0.8))
                }
              }
            }
            .padding(.top, 2)
          }
        }
      }

      if let error = mobileBridge.lastErrorMessage {
        Text(error)
          .font(WorkspaceChrome.chromeFont(size: 9))
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .onChange(of: mobileBridge.pairingLink) { _, newValue in
      if newValue == nil {
        didCopyPairingLink = false
      }
    }
  }

  private func settingValueRow(title: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title)
        .font(WorkspaceChrome.chromeFont(size: 9))
        .foregroundStyle(WorkspaceChrome.textQuaternary)
      Spacer(minLength: 8)
      Text(value)
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(WorkspaceChrome.textTertiary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }
}

struct MobilePairingCodeView: View {
  let payload: String

  var body: some View {
    if let image = Self.makeImage(payload: payload) {
      Image(nsImage: image)
        .resizable()
        .interpolation(.none)
        .antialiased(false)
        .scaledToFit()
        .padding(8)
    } else {
      Image(systemName: "qrcode")
        .font(.system(size: 42))
        .foregroundStyle(.black)
    }
  }

  private static func makeImage(payload: String) -> NSImage? {
    guard
      let data = payload.data(using: .utf8),
      let filter = CIFilter(name: "CIQRCodeGenerator")
    else {
      return nil
    }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else {
      return nil
    }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    let representation = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: representation.size)
    image.addRepresentation(representation)
    return image
  }
}
