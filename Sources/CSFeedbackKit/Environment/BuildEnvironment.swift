import Foundation
import StoreKit

/// Works out where this build came from. Fails closed: anything unknown is `appstore`,
/// so a build promoted from TestFlight to the App Store stays inert.
enum BuildEnvironment {
    static func detect() async -> FeedbackEnvironment {
        #if DEBUG || targetEnvironment(simulator)
        return .xcode
        #else
        do {
            let transaction: AppTransaction
            switch try await AppTransaction.shared {
            case .verified(let value): transaction = value
            case .unverified(let value, _): transaction = value
            }
            switch transaction.environment {
            case .xcode: return .xcode
            case .sandbox: return .testflight
            case .production: return .appstore
            default: return .appstore
            }
        } catch {
            Log.general.error("Build environment unknown (\(error.localizedDescription, privacy: .public)); treating as appstore")
            return .appstore
        }
        #endif
    }
}

extension Optional where Wrapped == [FeedbackEnvironment] {
    /// `nil` means every environment.
    func allows(_ environment: FeedbackEnvironment) -> Bool {
        self?.contains(environment) ?? true
    }
}
