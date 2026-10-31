import Foundation

/// Actual native application metadata, separate from the API component version.
/// A standalone unversioned executable may inspect public metadata, but cannot
/// request a ticket through the application-version overload.
public struct NativeClientIdentity: Equatable {
    public enum Platform: String { case macOS, iOS, macCatalyst, otherApple }
    public let applicationVersion: String?
    public let platform: Platform

    public init(applicationVersion: String?, platform: Platform) {
        self.platform = platform
        if let value = applicationVersion, !value.isEmpty, value.utf8.count <= 64 {
            let components = value.split(separator: ".", omittingEmptySubsequences: false)
            self.applicationVersion = (1...4).contains(components.count) && components.allSatisfy {
                !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } &&
                    UInt32($0).map { $0 <= Int32.max } == true
            } ? value : nil
        } else { self.applicationVersion = nil }
    }

    public static var current: NativeClientIdentity {
        #if targetEnvironment(macCatalyst)
        let platform = Platform.macCatalyst
        #elseif os(iOS)
        let platform = Platform.iOS
        #elseif os(macOS)
        let platform = Platform.macOS
        #else
        let platform = Platform.otherApple
        #endif
        return NativeClientIdentity(
            applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            platform: platform)
    }

    public var userAgent: String {
        "D2RMobile-Reimagined/0.1 (native-\(platform.rawValue); app/\(applicationVersion ?? "unversioned"))"
    }
}
