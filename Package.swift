// swift-tools-version: 6.0
// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import PackageDescription

// One product per feature, so an app links only what it uses, each with its own privacy manifest: an app with update
// prompts alone never declares what experiments collect. Every product keeps its state in files of its own, so none uses
// a required-reason API.
let package = Package(
    name: "TaoolKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .watchOS(.v10), .tvOS(.v17), .macOS(.v14), .visionOS(.v1)],
    products: [
        .library(name: "TaoolUpdates", targets: ["TaoolUpdates"]),
        .library(name: "TaoolExperiments", targets: ["TaoolExperiments"]),
        .library(name: "TaoolAnalytics", targets: ["TaoolAnalytics"]),
        .library(name: "TaoolPurchases", targets: ["TaoolPurchases"]),
        .library(name: "TaoolFlags", targets: ["TaoolFlags"]),
    ],
    targets: [
        // What the products share, never a product of its own: it sends nothing by itself.
        .target(name: "TaoolCore"),
        // Collects nothing. The string catalog is TaoolKit's own text, in the App Store's languages.
        .target(name: "TaoolUpdates", dependencies: ["TaoolCore"],
                resources: [.copy("PrivacyInfo.xcprivacy"), .process("Localizable.xcstrings")]),
        // Declares product interaction and a user ID (Apple's, or the developer's hashed), for analytics. Not purchase
        // history, though purchases begun after an experiment showed are sent: an app that sells anything declares it
        // itself.
        .target(name: "TaoolExperiments", dependencies: ["TaoolCore"], resources: [.copy("PrivacyInfo.xcprivacy")]),
        // The one check-in, which TaoolPurchases and TaoolFlags go through too. Declares a user ID and purchase history
        // (StoreKit's signed AppTransaction, whose download date counts new users), for analytics, not linked to the user.
        // Expanded analytics are off for most apps, so an app that turns them on declares them itself.
        .target(name: "TaoolAnalytics", dependencies: ["TaoolCore"], resources: [.copy("PrivacyInfo.xcprivacy")]),
        // Declares, on top of TaoolAnalytics', purchase history (StoreKit's signed transactions and renewal info) and the
        // developer's user ID, for app functionality.
        .target(name: "TaoolPurchases", dependencies: ["TaoolAnalytics", "TaoolCore"], resources: [.copy("PrivacyInfo.xcprivacy")]),
        // Declares, on top of TaoolAnalytics', the developer's user ID when the app passes one, for app functionality. What
        // its rules read about the device stays on it.
        .target(name: "TaoolFlags", dependencies: ["TaoolAnalytics", "TaoolCore"], resources: [.copy("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "TaoolUpdatesTests", dependencies: ["TaoolUpdates", "TaoolCore"]),
        .testTarget(name: "TaoolExperimentsTests", dependencies: ["TaoolExperiments", "TaoolCore"]),
        .testTarget(name: "TaoolAnalyticsTests", dependencies: ["TaoolAnalytics", "TaoolCore"]),
        .testTarget(name: "TaoolPurchasesTests", dependencies: ["TaoolPurchases", "TaoolAnalytics", "TaoolCore"]),
        .testTarget(name: "TaoolFlagsTests", dependencies: ["TaoolFlags", "TaoolAnalytics", "TaoolCore"]),
    ]
)
