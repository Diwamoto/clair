import Foundation

struct NativeEditorFileProfile: Equatable {
    let utf8Bytes: Int
    let utf16Length: Int
    let maximumLineUTF16Length: Int

    init(text: String) {
        utf8Bytes = text.utf8.count
        utf16Length = text.utf16.count
        maximumLineUTF16Length = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.utf16.count }
            .max() ?? 0
    }
}

enum NativeEditorMode: String, Equatable {
    case synchronousNative
    case asynchronousNative
    case webFallback
}

enum NativeEditorFallbackReason: String, Equatable {
    case utf8Bytes
    case utf16Length
    case maximumLineLength
}

struct NativeEditorDecision: Equatable {
    let mode: NativeEditorMode
    let fallbackReason: NativeEditorFallbackReason?
}

enum NativeEditorPolicy {
    // These are product-safety gates for the PoC, not a claim of universal editor limits.
    static let maximumNativeUTF8Bytes = 10_000_000
    static let maximumNativeUTF16Length = 10_000_000
    static let maximumNativeLineUTF16Length = 1_000_000
    static let maximumSynchronousUTF16Length = 250_000

    static func decide(text: String) -> NativeEditorDecision {
        let profile = NativeEditorFileProfile(text: text)
        if profile.utf8Bytes > maximumNativeUTF8Bytes {
            return .init(mode: .webFallback, fallbackReason: .utf8Bytes)
        }
        if profile.utf16Length > maximumNativeUTF16Length {
            return .init(mode: .webFallback, fallbackReason: .utf16Length)
        }
        if profile.maximumLineUTF16Length > maximumNativeLineUTF16Length {
            return .init(mode: .webFallback, fallbackReason: .maximumLineLength)
        }
        let mode = profile.utf16Length > maximumSynchronousUTF16Length
            ? NativeEditorMode.asynchronousNative
            : NativeEditorMode.synchronousNative
        return .init(mode: mode, fallbackReason: nil)
    }
}
