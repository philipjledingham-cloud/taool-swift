# Adding taool's analytics to an app (for coding agents)

Follow these steps to add TaoolKit's `TaoolAnalytics` product to an iOS or macOS app. It counts the app's users: each Apple Account that opens the app checks in with taool now and then, so the developer sees their users (weekly and monthly, daily with expanded analytics) and the versions they're on, in the taool app. It needs no sign-in, no Subscriptions and no server.

**If the app already has `TaoolPurchases` or `TaoolFlags`** (`.taoolPurchases(key:…)` or `.taoolFlags(key:…)`), stop: each includes TaoolAnalytics and checks in already. Tell the developer nothing more is needed. Adding `.taoolAnalytics` as well would do no harm (it's still one check-in), but it adds nothing.

You need the developer's **taool key**, which looks like `taool_public_` followed by 31 letters and digits (never the server key, `taool_secret_…`, which belongs only on a server). It's usually in the prompt that sent you here. If not, ask for it: it's on the taool app's TaoolKit page. The key is public, so hard-coding it in the app is correct. Don't put it in a secrets file or the Keychain.

## 1. Add the package

- **Xcode project:** add a package dependency on `https://github.com/taoolcom/taool-swift` (Up to Next Major Version from 1.0.0), with the `TaoolAnalytics` product linked to the app target, and to any other app target that ships to the App Store (a separate Mac app). Never to widgets or extensions.
- **SwiftPM:** `.package(url: "https://github.com/taoolcom/taool-swift", from: "1.0.0")` and `.product(name: "TaoolAnalytics", package: "taool-swift")`.
- **The project has the package already** (for another TaoolKit product): only link `TaoolAnalytics`, never add the package again.

The package needs iOS 17, iPadOS 17, watchOS 10, tvOS 17, macOS 14 or visionOS 1. If the app supports older versions, stop and tell the developer.

## 2. Apply the modifier at the root of every scene

Find the `App` struct (`@main`), and put the modifier on the root view inside each `WindowGroup`. In a UIKit app without one, put it on the root SwiftUI view of a `UIHostingController` that stays on screen; if there's none, stop and tell the developer.

```swift
import SwiftUI
import TaoolAnalytics

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .taoolAnalytics(key: "taool_public_REPLACE_ME")
        }
    }
}
```

- If the app has several `WindowGroup`s, or a `Window` that users work in, add it to each. It's still one check-in.
- If the root view switches between sign-in and the main UI, put the modifier outside that switch. Users who aren't signed in count too.
- If the app has accounts, pass who's signed in: `.taoolAnalytics(key: "taool_public_REPLACE_ME", userID: …)`, the app's own ID for the user (a UUID's `uuidString`, or any string up to 128 characters), `nil` while no one is, on every render. If the app also uses `.taoolPurchases` or `.taoolFlags`, pass the same to each.
- If the app's debug builds use a different bundle ID from the App Store app's, pass the App Store one: `.taoolAnalytics(key: "taool_public_REPLACE_ME", bundleID: "com.example.app")`. It's the same ID in release builds, so there's no need for `#if DEBUG`.

## 3. Analytics level and privacy (ask the developer)

The default is standard analytics: the app's version and build, TaoolKit's version, the platform, the App Store country, the language the app runs in, the language the user chose in Settings and the device's region, and which Apple Account this is (StoreKit's signed AppTransaction). Expanded analytics (last opened, opens and the days they were on, OS version, device kind and model) are switched on in the taool app, with no code. Leave `analytics` out (`.automatic`, recommended), so the developer switches between the two in the taool app. Only if the developer wants to promise less, add a code override, which the taool app can't change: `analytics: .minimal` (only which Apple Account this is) or `.standard` (never expanded). The taool app shows which level the app's code sets.

Tell the developer their App Store privacy answers should include a user ID and purchase history (analytics, not used for tracking), which TaoolKit's privacy manifest declares as not linked to the user: Apple's ID for an Apple Account says nothing about who it is. They answer linked only if the app also passes TaoolKit its own user IDs, as `userID`. Expanded analytics aren't in TaoolKit's manifest, since most apps leave them off: only if the developer will turn them on, add product interaction and other diagnostic data (analytics, not used for tracking, linked as above; the device's model is diagnostic data too) to the app's own `PrivacyInfo.xcprivacy`, and tell them to add the same to their App Store privacy answers first.

## 4. Check it

1. Build the app.
2. Run it. In the taool app, the TaoolKit page's Analytics card shows when the app last checked in and the level its code sets; it can take a minute.

## Rules

- Don't add your own network calls, timers or retries around TaoolKit. It checks in at a cold launch, then as the app becomes active or goes to the background once one is due, never on a timer, and keeps what failed for the next time.
- Don't call it from widgets, extensions or App Clips.
- Don't add an analytics SDK's identifiers (IDFA, IDFV) for taool: it never uses them.
- The key is the same for all of the developer's apps. TaoolKit finds the app from its bundle ID.

## What the developer does next

- **Expanded analytics** (taool Pro): in the taool app, TaoolKit → Analytics → the app. Add the privacy answers above first.
- **In-app purchases:** if the app sells anything and should hear from taool who has access, `TaoolPurchases` replaces this modifier (see `integrate-purchases.md`).
