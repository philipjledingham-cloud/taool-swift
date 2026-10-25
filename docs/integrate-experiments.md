# Adding taool's experiments to an app (for coding agents)

Follow these steps to add TaoolKit's `TaoolExperiments` product to an iOS or macOS app. Each user gets one variant of an experiment, taool counts the users who see each variant and the goals they reach afterwards (the developer's own goals, and free trials and payments), and the developer reads the results and picks a winner in the taool app, which everyone then sees without an app update.

You need the developer's **taool key**, which looks like `taool_public_` followed by 31 letters and digits (never the server key, `taool_secret_…`, which belongs only on a server). It's usually in the prompt that sent you here. If not, ask for it: it's on the taool app's TaoolKit page. The key is public, so hard-coding it in the app is correct.

**Ask the developer which screen to test, its variants and the goals that matter**, if the prompt that sent you doesn't say.

## 1. Add the package

- **Xcode project:** add a package dependency on `https://github.com/taoolcom/taool-swift` (Up to Next Major Version from 1.0.0), with the `TaoolExperiments` product linked to the app target, and to any other app target that ships to the App Store (a separate Mac app). Never to widgets or extensions.
- **SwiftPM:** `.package(url: "https://github.com/taoolcom/taool-swift", from: "1.0.0")` and `.product(name: "TaoolExperiments", package: "taool-swift")`.
- **The project has the package already** (for another TaoolKit product): only link `TaoolExperiments`, never add the package again.

The package needs iOS 17, iPadOS 17, watchOS 10, tvOS 17, macOS 14 or visionOS 1. If the app supports older versions, stop and tell the developer.

## 2. Apply the modifier at the root of every scene

Find the `App` struct (`@main`), and put the modifier on the root view inside each `WindowGroup`, outside any switch between signed-out and signed-in UI. In a UIKit app without one, put it on the root SwiftUI view of a `UIHostingController` that stays on screen; if there's none, stop and tell the developer.

```swift
import SwiftUI
import TaoolExperiments

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .taoolExperiments(key: "taool_public_REPLACE_ME")
        }
    }
}
```

- **Who a user is:** by default their Apple Account, Apple's ID for it in the app, the same on all their devices and after a reinstall, with nothing to set up. If the app has its own accounts, pass the signed-in user's stable ID as `userID`, and `nil` while no one is signed in, read from wherever the app keeps its session so the modifier sees sign-ins and sign-outs: `.taoolExperiments(key: "taool_public_REPLACE_ME", userID: session.userID)`. Ask the developer if it isn't clear which ID that is.
- **Debug builds with their own bundle ID:** pass the App Store app's, `bundleID: "com.example.app"`. It's the same ID in release builds, so there's no need for `#if DEBUG`.

## 3. Declare each experiment

A String enum conforming to `TaoolExperiment`, with at most 10 cases: an experiment with more isn't counted, and TaoolKit logs why. The first case is the control, and the raw values are the names the taool app shows. The experiment's name is the type's name with the types it's nested in, without the module (`PaywallButton`, or `PaywallView.Variant` for an enum inside `PaywallView`), unless it sets `static let key`, which keeps it and its results when the type is renamed or moved:

```swift
enum PaywallButton: String, TaoolExperiment {
    case control
    case freeTrial
}
```

## 4. Read the variant where it's shown

In `body`, where the variant is on screen. Reading it counts the user for that variant, so never read it ahead of time. Every part of the screen that differs reads the same variant:

```swift
var body: some View {
    let button = PaywallButton.variant
    Text(button == .freeTrial ? "Try Pro free for 7 days" : "Unlock Pro")
    Button(button == .freeTrial ? "Start Free Trial" : "Continue") { buy() }
}
```

Or a view per variant: `switch PaywallButton.variant { case .control: ClassicPaywall() case .freeTrial: TrialPaywall() }`.

## 5. Record the goals

Where each goal the experiment is meant to move happens, with a name of letters, digits, `.`, `_` or `-`, up to 64:

```swift
TaoolExperiments.record("feature-used")
```

Call it every time the goal happens; it's sent once per experiment shown. A goal counts for every variant the user saw before reaching it.

## 6. Purchases

Free trials and payments are built-in goals. After a purchase made in the app, record it, so it counts at once:

```swift
let result = try await product.purchase()
TaoolExperiments.record(result)
// The app's existing handling stays: verify, unlock, and finish the transaction.
```

TaoolExperiments also reads StoreKit's history once a launch, so a purchase that isn't recorded (from StoreKit's own views, another device, a renewal) counts late, never not at all.

## 7. Check it

1. Build the app.
2. In a debug build only, `TaoolExperiments.force(PaywallButton.freeTrial)` shows that variant without counting it (inside `#if DEBUG`; it does nothing in release builds). Check each variant's UI that way, then **remove the call**.
3. Run it. The experiment appears in the taool app (the app → Experiments) once a user sees it. Results from TestFlight, development and Xcode builds are kept apart from the App Store's.

## Privacy

Tell the developer what TaoolExperiments sends: the user's ID (Apple's ID for their Apple Account, or a SHA-256 of the `userID` the app passes), which variant they saw and when, the names of the goals they reached, and their purchases as StoreKit signed them. Reports wait on the device until StoreKit says who the user is; only a debug build, when StoreKit can't say, reports as the install. Its privacy manifest declares product interaction and a user ID, for analytics, not used for tracking; the App Store privacy answers should include them, as linked to the user if the app passes its own `userID`. Purchase history isn't in the package's manifest: if the app sells anything, add purchase history (analytics, not used for tracking) to the app's own `PrivacyInfo.xcprivacy` and its App Store privacy answers.

## Rules

- Don't add your own network calls, caching or retries around TaoolExperiments. Variants are worked out on the device and need no network; reports wait until taool can be reached.
- Don't read `variant` outside the screen that shows it, in a view model's init, say: it counts the user.
- Don't call it from widgets, extensions or App Clips.
- The key is the same for all of the developer's apps. TaoolKit finds the app from its bundle ID.
