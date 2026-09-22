import Foundation
import SwiftUI

/// Toast replacement for Android Toast (deferMessage path).
public enum ToastCenter {
    public static var show: (String) -> Void = { _ in }
}

/// Debug log store (gated by DebugOverlay). Mirrors Android DebugLogStore.
public struct LogLine: Identifiable, Equatable {
    public let id = UUID()
    public var tag: String
    public var msg: String
}

public final class DebugLogStore: ObservableObject {
    public static let shared = DebugLogStore()
    @Published public var lines: [LogLine] = []
    public static func log(_ tag: String, _ msg: String) {
        DispatchQueue.main.async { shared.lines.append(LogLine(tag: tag, msg: msg)) }
    }
    public static func clear() { DispatchQueue.main.async { shared.lines.removeAll() } }
}
