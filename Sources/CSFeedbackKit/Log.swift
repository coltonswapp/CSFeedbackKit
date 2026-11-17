import os

enum Log {
    static let general = Logger(subsystem: "CSFeedbackKit", category: "general")
    static let fields = Logger(subsystem: "CSFeedbackKit", category: "fields")
    static let delivery = Logger(subsystem: "CSFeedbackKit", category: "delivery")
}
