// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CSFeedbackKit",
    platforms: [
        .iOS("16.4"),
    ],
    products: [
        .library(name: "CSFeedbackKit", targets: ["CSFeedbackKit"]),
        .library(name: "CSFeedbackKitUI", targets: ["CSFeedbackKitUI"]),
    ],
    targets: [
        .target(name: "CSFeedbackKit"),
        .target(name: "CSFeedbackKitUI", dependencies: ["CSFeedbackKit"]),
    ]
)
