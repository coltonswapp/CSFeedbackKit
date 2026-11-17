//
//  FeedbackSetup.swift
//
//  CSFeedbackKit starter. Copy this file and Feedback.json into your app target, then:
//    1. Add the CSFeedbackKitUI package product to the target.
//    2. Create FeedbackSecrets.plist (gitignored, in the app target) with
//       FEEDBACK_URL and FEEDBACK_SECRET. Or put FEEDBACK_URL in Info.plist via an xcconfig.
//    3. Call FeedbackSetup.start() at launch (AppDelegate / SceneDelegate / App.init).
//    4. Edit the TODOs below.
//

import UIKit
import CSFeedbackKitUI

enum FeedbackSetup {
    @MainActor
    static func start() {
        Feedback.start(
            config: .bundled("Feedback"),
            // Values for ${NAME} in Feedback.json. Anything missing here falls back to
            // the scheme environment (DEBUG) and then Info.plist.
            variables: secrets(),
            // Names used by destinations[].auth, e.g. "auth": "user". Runs before every attempt.
            auth: [:],
            // Names used by enabledWhen, e.g. "enabledWhen": "isEmployee".
            checks: [:]
        )
        // Lets "triggers" in Feedback.json open the composer (screenshot prompt).
        Feedback.installTriggers()

        // App-wide field values, read when the composer opens. Every key must be declared in "fields".
        Feedback.session.provide("userEmail") { () -> String? in
            nil // TODO: e.g. AuthStore.shared.currentUser?.email
        }

        // Optional: match the app's look.
        // Feedback.appearance = FeedbackAppearance(sendButton: .blue)
    }

    /// Reads FeedbackSecrets.plist from the bundle, if present. Keep it out of git.
    private static func secrets() -> [String: String] {
        guard let url = Bundle.main.url(forResource: "FeedbackSecrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return plist.compactMapValues { $0 as? String }.filter { !$0.value.isEmpty }
    }
}

// Screen values: conform any view controller that knows something useful.
// The key must be declared in Feedback.json "fields" with "screen" in its sources.
//
// extension OrderDetailViewController: FeedbackContextProvider {
//     func feedbackValues() -> FeedbackValues { ["orderId": .string(order.id)] }
// }
//
// SwiftUI: OrderDetailView(order: order).feedbackContext(["orderId": .string(order.id)])
//
// Open the composer by hand (a debug menu, a button):
//     Feedback.present(from: self)          // UIKit
//     FeedbackButton()                       // SwiftUI
// See notes that failed or are waiting:
//     navigationController?.pushViewController(Feedback.makeQueueViewController(), animated: true)
