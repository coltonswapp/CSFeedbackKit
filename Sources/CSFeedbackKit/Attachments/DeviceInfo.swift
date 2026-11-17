import Foundation

enum DeviceInfo {
    static func app(environment: FeedbackEnvironment, bundle: Bundle = .main) -> FeedbackPayload.AppInfo {
        FeedbackPayload.AppInfo(
            bundleId: bundle.bundleIdentifier ?? "unknown",
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            environment: environment
        )
    }

    static func device() -> FeedbackPayload.DeviceInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var os = "iOS \(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { os += ".\(version.patchVersion)" }
        return FeedbackPayload.DeviceInfo(
            model: modelIdentifier(),
            os: os,
            locale: Locale.current.identifier,
            timeZone: TimeZone.current.identifier
        )
    }

    /// Hardware id like `iPhone17,1`. The simulator reports its simulated model.
    private static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(simulated) (Simulator)"
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
