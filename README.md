# TaoolKit

The Swift package for [taool](https://taool.com). One package, one product per feature, so your app links only what it uses:

- **TaoolUpdates**, update prompts and What's New, a modifier each, for either or both: tells your app when it's out of date, so you never have to bump a version number on your server after a release, and shows your What's New page for a version once to everyone who had the app before it.
- **TaoolExperiments**, A/B tests: shows each user one variant of a screen and tells you which variant gets more users to do what you're after, from starting a trial to trying a feature.
- **TaoolAnalytics**, your users: each Apple Account that opens your app checks in now and then, so taool counts your users (weekly and monthly, daily with expanded analytics) and the versions they're on, with no sign-in, Subscriptions or server needed.
- **TaoolFlags**, feature flags: features you turn on from the taool app with no app update, for a few users while you test, in TestFlight, then for everyone, at once or a step at a time. It includes TaoolAnalytics.
- **TaoolPurchases**, in-app purchases: who has access to what (subscriptions, lifetime unlocks and other non-consumables), StoreKit's answer the moment your app starts, kept right by taool (grants you give, a subscription that moved to another of your users), with your own StoreKit code doing the buying. It includes TaoolAnalytics.

## Install

In Xcode: File → Add Package Dependencies, enter `https://github.com/taoolcom/taool-swift`, keep the rule at Up to Next Major Version from 1.0.0, and add the products you want to your app target.

Or in `Package.swift`:

```swift
.package(url: "https://github.com/taoolcom/taool-swift", from: "1.0.0")
// and in the target's dependencies:
.product(name: "TaoolUpdates", package: "taool-swift")
.product(name: "TaoolExperiments", package: "taool-swift")
.product(name: "TaoolAnalytics", package: "taool-swift")
.product(name: "TaoolPurchases", package: "taool-swift")   // includes TaoolAnalytics
.product(name: "TaoolFlags", package: "taool-swift")       // includes TaoolAnalytics
```

The package supports iOS 17, iPadOS 17, watchOS 10, tvOS 17, macOS 14 and visionOS 1 or later (TaoolUpdates iOS, iPadOS and macOS alone), and has no dependencies. On tvOS, TaoolKit keeps what it knows in Caches, which the system may empty when the Apple TV runs low on space: it then starts as on a fresh install, checking in at the next launch, flags off until that launch's fetch, and each user's experiment variant the same, since it comes from who they are.

Every product uses the same key, from the taool app's TaoolKit page. It identifies your account. It's not a secret, so it's fine to ship inside your app.

**Two keys, two hosts, never mixed.** TaoolKit in your app calls `kit.taool.com` with that public key (`taool_public_…`). Your server, if you have one, calls `api.taool.com` with the app's server key (`taool_secret_…`, from the app's Server Keys in the taool app), kept in its secrets, never in the app. No request takes both.

## Update prompts (TaoolUpdates)

`iOS` `iPadOS` `macOS`

taool watches your app on the App Store. When a new version goes live, every install learns about it. In the taool app you can also set a **minimum version** (with taool Pro): installs below it are asked to update before they carry on.

```swift
import SwiftUI
import TaoolUpdates

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .taoolUpdatePrompts(key: "taool_public_…")
        }
    }
}
```

What the user sees:

- **Update available:** a banner at the top with an Update button, the app's content moving down for it, or at the bottom with `placement: .bottom`. With `placement: .inline` it shows only where you put `TaoolUpdates.Banner()`, such as the top of your home screen's scroll view, scrolling with it. The user can close it, and it stays closed for that version.
- **Update required:** a screen covers the app until the user updates.
- **No update possible on this device:** when the device can't run any version at or above your minimum, the screen says which OS version to update to.

The inline banner can be drawn in your own design, like your app's other cards. TaoolKit still decides when it shows and what it says: its words in your app's language, or your own message from the taool app, with no app update.

```swift
TaoolUpdates.Banner { update in
    MyCard {
        Text(update.title)                              // "Update Available"
        Text(update.message)                            // "Version 2.0 is on the App Store."
        Button(update.button, action: update.open)      // "Update", to the App Store
        Button(update.notNow, action: update.dismiss)   // "Not Now", closed for this version
    }
}
```

The update-required screen can be your own too: put `.taoolUpdateRequiredScreen` once after the modifiers, and it's used wherever `.taoolUpdatePrompts` covers the app, a paywall's full-screen cover included. TaoolKit still decides when it covers the app and what it says, lays your screen over the whole window, and there's no closing it.

```swift
ContentView()
    .taoolUpdatePrompts(key: "taool_public_…")
    .taoolUpdateRequiredScreen { required in
        MyScreen {
            Text(required.title)                        // "Update Required"
            Text(required.message)                      // why, and the version to update to
            if let button = required.button {           // nil when no version runs on this OS
                Button(button, action: required.open)   // "Update", to the App Store
            }
        }
    }
```

The update screen covers the view you put the modifier on. A full-screen cover or sheet sits above it, so add the modifier to the root of any one users can't close, such as a hard paywall or onboarding (a sheet users can close, or a screen your root view switches to, needs nothing). It's still one check:

```swift
ContentView()
    .fullScreenCover(isPresented: $store.showsPaywall) {
        Paywall()
            .taoolUpdatePrompts(key: "taool_public_…")   // the update screen covers the paywall too
    }
    .taoolUpdatePrompts(key: "taool_public_…")
```

The Update button and the icons are in your app's accent color (its asset catalog's AccentColor), the button's label black on a light accent and white on a dark one, so it reads in both appearances. For other colors, add `.taoolTint` after the modifiers:

```swift
ContentView()
    .taoolUpdatePrompts(key: "taool_public_…")
    .taoolTint(.orange)                    // the label white or black, whichever reads
 // .taoolTint(.yellow, label: .white)     // the label as given
```

Asset catalog colors with a dark appearance follow the appearance, the label's too. It covers What's New's Update button as well.

The text is TaoolKit's own, in 37 of the App Store's languages, and follows the language the app runs in, not the device's: an app only in English shows it in English on a Swedish iPhone. In the taool app you can lock it to one language, for an app whose bundle doesn't say which it's in, and on taool Pro write your own message for the banner and the update-required screen, for every version or one, in as many languages as you like. Messages and language arrive with the update check, so changing them needs no app update.

To build your own UI instead, ask for the status:

```swift
let status = await TaoolUpdates.status(key: "taool_public_…")
switch status {
case .current: break
case .available(let release): …      // release.version, release.appStoreURL
case .required(let release): …
case .unsupported(let requiredOSVersion): …
}
// What TaoolKit's own UI would say, on the main actor: your message or TaoolKit's, in the right language.
// .unsupported has no button: nothing on the App Store runs on this OS.
status.text?.title; status.text?.message; status.text?.button
```

To see the UI without a real release, use `simulating: .available`, `.required` or `.unsupported`. Simulations only work in debug builds.

**If your server refuses old versions** (see [docs/integrate-updates.md](docs/integrate-updates.md#your-server-optional)), send `TaoolUpdates.appVersion` with each request, in an `X-App-Version` header, and call `TaoolUpdates.serverRequiredUpdate()` when it answers 426. `.taoolUpdatePrompts(key:)` covers the app with the same update-required screen at once, without asking taool first: your server already did.

### How it works

- The package asks `https://kit.taool.com/v1/updates/{bundle ID}/{ios|macos}?key=…` as the app comes to the foreground: once per launch, then at most once an hour. It saves the answer on the device and shows what it saved from the first frame, so a version below your minimum is covered at once and the banner is already there; taool's answer changes the prompts only where it differs. Another window, or coming back from Control Center, isn't the app coming to the foreground. The same answer carries the What's New page, so with both modifiers it's still one request. What's New waits for taool's answer at a launch, 3 seconds at most, then shows the saved page, so a page you fix or take down stops showing within minutes.
- The answer lists the app's recent versions, the minimum OS each one needs, and your minimum version. The device decides for itself, against the version that's running, so the moment a user has updated, the prompts are gone, saved answer or not:
  - **Available:** a newer version exists that this device can install. On an older OS, that's the newest release that still supports it, which is also what the App Store offers.
  - **Required:** this version is below your minimum, and a version at or above it installs on this device.
  - **Unsupported:** an update is required, but no version at or above the minimum runs on this OS.
- **It never gets in the way.** If taool can't be reached, the package uses the last answer it saved. With no saved answer, the install counts as current. The same goes for an app or key taool doesn't know.
- **What's sent:** the key, the bundle ID and the platform. Nothing about the user or the device.

### Servers

If your app has a backend, it can read the same answer and refuse clients that are too old. It can also receive an authenticated webhook when a new version goes live. See [docs/integrate-updates.md](docs/integrate-updates.md#your-server-optional).

### What's New (with taool Pro)

Upload a page of your own design for a version in the taool app (TaoolKit → What's New → the app): one HTML file, or a folder with `index.html` and its images (or its zip). taool hosts it, as a draft only you see until it's published: by you once that version is on the App Store, or on its own the moment it is. Then `.taoolWhatsNew(key:)` shows it once, in a sheet, to everyone who had the app before that version, whether or not they've updated yet: on an older version, a bar at the bottom offers the update. Users who first got the app after that version never see it, since nothing in it is new to them.

```swift
ContentView()
    .taoolWhatsNew(key: "taool_public_…")
```

**Held while your own screens are up.** `mode: .held` keeps the page back, say while your hard paywall or onboarding shows, and it shows the moment you go back to `.automatic`. Nothing is lost meanwhile: it counts as seen only once it shows, even if the app quits first. Tie it to your own state:

```swift
// A hard paywall: the page waits until the user has access.
Group {
    if store.hasPro { ContentView() } else { Paywall() }
}
.taoolUpdatePrompts(key: "taool_public_…")
.taoolWhatsNew(key: "taool_public_…", mode: store.hasPro ? .automatic : .held)

// Onboarding: the page waits until it's done.
ContentView()
    .taoolWhatsNew(key: "taool_public_…", mode: hasOnboarded ? .automatic : .held)
```

`.taoolWhatsNew` stays on the root view, never on a full-screen cover.

**Again from your settings.** `TaoolUpdates.showWhatsNew()` shows the page again, even to a user who closed it, and `TaoolUpdates.hasWhatsNew` says whether there is one (from this launch's answer, so no request, and false while What's New waits for it as the app opens):

```swift
// A row in your settings:
if TaoolUpdates.hasWhatsNew {
    Button("What's New") { TaoolUpdates.showWhatsNew() }
}
```

`mode: .manual` shows the page only from `showWhatsNew()`, for an app that picks the moment itself.

**Your own What's New screen.** An app that already has one keeps it: put `.taoolWhatsNewScreen` once after the modifiers, and TaoolKit still decides when it shows (once per version, to users who had the app before it, held, never over the update screen, TestFlight first) while the sheet shows your screen in place of the page. Upload a page for each version all the same: it's what tells TaoolKit the version has news. For a version your build knows nothing about, such as a newer one, `TaoolUpdates.WhatsNewPageSheet` shows the page:

```swift
ContentView()
    .taoolWhatsNew(key: "taool_public_…")
    .taoolWhatsNewScreen { whatsNew in
        if let release = MyReleases[whatsNew.version] {
            MyWhatsNew(release)                          // whatsNew.updateTo, .updateMessage, .button, .open()
        } else {
            TaoolUpdates.WhatsNewPageSheet(whatsNew)
        }
    }
```

- **Once per version, on each device.** Uploading a page again for a version already shown (to fix a typo), or deleting a newer page so an older one is live again, doesn't show it again.
- **In TestFlight before the App Store.** Turn on Show in TestFlight for a page in the taool app, and TestFlight builds on its version or newer show it right away, before it's live on the App Store (the newest such page at or below the build's version, when it's newer than the live one). App Store installs never see it until it's published, and a tester who saw it doesn't see it again once it is. Builds from Xcode count as TestFlight, so you can check it while developing.
- It works with or without update prompts. It never shows while this version must update, so never over the update screen: it waits until the user has updated.
- **Pages load nothing from anywhere else.** taool adds a Content-Security-Policy to every page: its own files and inline code only, no web fonts, scripts, images or analytics from other sites. Links open outside the app, in the App Store, Mail or the browser.
- **What the page can read:** after the `#` in its address, read with `location.hash`: `version`, the app version the user is running; `language`, the one your app runs in (or the one you locked in the taool app), as your app names it, so a page in several languages can show yours, even one TaoolKit's own text isn't in; and `update=1` when the user hasn't updated to the version the page is about yet. A page about 2.0 opened in 1.2 in Swedish gets `#version=1.2&language=sv&update=1`. Browsers never send what's after the `#`, so none of it leaves the device.
- **Nothing is kept or sent.** The web view keeps no cookies or storage between visits. To skip users who got the app later, the package reads when this user first got it from StoreKit's app transaction, on the device, and never sends it anywhere.

## A/B tests (TaoolExperiments)

`iOS` `iPadOS` `watchOS` `tvOS` `macOS` `visionOS`

An experiment is an enum of up to 10 variants: one with more isn't counted, and TaoolKit logs why. The first case is the control, and taool shows each variant by its raw value.

```swift
import TaoolExperiments

enum PaywallButton: String, TaoolExperiment {
    case control
    case freeTrial
}
```

Put the modifier on the root view of each scene, once:

```swift
WindowGroup {
    ContentView()
        .taoolExperiments(key: "taool_public_…")
}
```

taool counts **users**, not devices. By default a user is their Apple Account, by Apple's `appTransactionID`: the same on all their devices and after they reinstall, with or without purchases, and nothing for you to set up. If your app has accounts, pass the signed-in user's own ID as `userID` instead, and `nil` while no one is:

```swift
.taoolExperiments(key: "taool_public_…", userID: session.userID)
```

Read the variant where it shows. Every part of the screen that differs reads the same one:

```swift
var body: some View {
    let button = PaywallButton.variant
    VStack {
        Text(button == .freeTrial ? "Try Pro free for 7 days" : "Unlock Pro")
        Button(button == .freeTrial ? "Start Free Trial" : "Continue") { buy() }
    }
}
```

Or show a different view per variant:

```swift
switch PaywallButton.variant {
case .control: ClassicPaywall()
case .freeTrial: TrialPaywall()
}
```

Then record the goals the experiment is meant to move, wherever they happen. A goal is any name you choose:

```swift
TaoolExperiments.record("feature-used")        // an onboarding test: who starts using the feature?
```

Purchases are goals too, and need nothing from you beyond one line after a purchase in your app, so it counts at once:

```swift
let result = try await product.purchase()
TaoolExperiments.record(result)
```

The experiment appears in the taool app (your app → Experiments) as soon as a user sees it. For each variant you see how many users saw it and every goal they reached afterwards: free trials, payments and your own goals, each with how many users reached it, the conversion, and the chance it beats the control. Nothing has to be declared up front: judge each experiment by the goal it was for. When you've seen enough, end it with a winner: every device shows the winner from the next time the app comes to the foreground, without an app update, never in the middle of a screen.

To check each variant's UI while developing, call `TaoolExperiments.force(PaywallButton.freeTrial)`. It only works in debug builds, and doesn't count.

### How it works

- **Variants are decided on the device.** The user's ID is hashed with the experiment's name into a variant, so the split is even and the same user gets the same variant on every device, with or without a network. A device keeps a variant once shown, even when a later build adds variants. Where another of the user's devices saw a different one first (they signed in, or the app was reinstalled), taool says which counts, and the device shows it from the next time the app comes to the foreground, never in the middle of a screen. The experiment's name is its type's name with the types it's nested in, without the module (`PaywallButton`, or `PaywallView.Variant` for an enum inside `PaywallView`); set `static let key = "…"` to keep it (and its results) when the type is renamed or moved.
- **Who a user is:** the `userID` you pass; otherwise Apple's `appTransactionID`. Only a SHA-256 of your ID leaves the device. StoreKit hands over Apple's ID a moment after launch, so the very first screens of a first launch may be decided by the install; if that user already had another variant somewhere else, taool says so and the device shows that one from the next time the app comes to the foreground. When a user signs in, what they did while signed out moves over to them, and their variants win where they differ. Signing out or switching accounts never merges anyone.
- **Reading `variant` counts the user**, once, for that variant. So read it where the variant shows, not ahead of time.
- **Goals** count for every variant the user saw before reaching them. Call `record` every time the goal happens; it's sent once per experiment shown, not every time. Goal names, like experiment keys, are letters, digits, `.`, `_` and `-`, up to 64; anything else is logged and not counted.
- **Purchases** are two built-in goals, a free trial and a payment. They count for a user's variants when they began after the user first saw one: a trial started after, and its renewals, count; renewing a subscription from before doesn't. `TaoolExperiments.record` sends one right away. The package also reads StoreKit's history once a launch, which catches a trial's first renewal (it became paid), purchases on other devices, and any purchase `record` missed; it sends a purchase's first transaction and one renewal, never every month's.
- **Testing never skews results.** Users on TestFlight, development and Xcode StoreKit testing builds are counted apart from users on the App Store, so you can try it all before release.
- **As the app comes to the foreground**, the package asks taool which experiments have ended (at each launch, then at most hourly) and sends what it hasn't sent yet. Another window, or coming back from Control Center, isn't the app coming to the foreground. Reports wait on the device until taool can be reached.
- **What's sent:** the key, the bundle ID, the user's ID (Apple's `appTransactionID` or a SHA-256 of your `userID`), which variant they saw and when, the names of the goals they reached and when, and their purchases as StoreKit signed them. No names, emails or anything else about the user. Reports wait on the device until StoreKit says who the user is; only a debug build, when StoreKit can't say, reports as the install. The package's privacy manifest declares product interaction and a user ID, for analytics, not linked to the user and not used for tracking. Your App Store privacy answers should include them too, as linked to the user if you pass your own `userID`. **Purchase history isn't in the package's manifest:** if your app sells anything, add purchase history (analytics, not used for tracking) to your app's own `PrivacyInfo.xcprivacy` and App Store privacy answers, since purchases made after a user saw an experiment are sent.

## Feature flags (TaoolFlags)

`iOS` `iPadOS` `watchOS` `tvOS` `macOS` `visionOS`

Make the flag in the taool app first (the TaoolKit page, your app, Flags), then read it by its key. Copy Swift there writes the enum for you:

```swift
import TaoolFlags

enum Flags: String, TaoolFlag {
    case newOnboarding = "new-onboarding"
}
```

Put the modifier on the root view of each scene, once, with your own ID for the signed-in user if your app has accounts:

```swift
WindowGroup {
    ContentView()
        .taoolFlags(key: "taool_public_…", userID: session.userID)
}
```

Then ask where it decides something:

```swift
if Flags.newOnboarding.isOn { NewOnboarding() } else { Onboarding() }
```

**Remote config:** a flag can hold text, a number or JSON instead of on and off, for values your app reads: a headline, a trial's length, a block of settings. Read it with what it falls back to until the device has heard from taool:

```swift
Text(Flags.paywallHeadline.string(default: "Unlock Pro"))
let days = Flags.trialDays.int(default: 7)
let plans = Flags.plans.value(as: [Plan].self, default: Plan.all)   // any Decodable
```

A date in a JSON flag is an ISO 8601 string (`"2026-12-01T00:00:00Z"`), which decodes into a `Date` field.

Each such flag has a default in the taool app too: what it gives while it's turned off, and to everyone a percentage leaves out.

In the taool app each flag has a value for the App Store and one for TestFlight: off, on, a percentage you move up or down, or a progressive rollout that climbs on its own, 1%, 5%, 10%, 25%, 50% and everyone over the days you pick (taool Pro). Targeting rules (taool Pro) turn it on or off by app version (with a build too, to tell TestFlight builds apart: 2.5 (211)), OS version, device, App Store country, language, when the app was downloaded, or whether the user has bought something. You can pick users by hand too, by their Apple Account or your user ID: on while they test, or off for a user a new feature broke for. Turn Off for Everyone is one tap, and it beats everything else, the users you picked and TestFlight included.

To check both sides while developing, call `Flags.newOnboarding.force(true)`. It only works in debug builds.

### How it works

- **No defaults in code for on and off.** A flag is off until the device has heard from taool, then has the last values it heard, kept on the device, so reading one never waits on the network. Put the new behavior behind `isOn`.
- **When it changes:** the package asks for the app's flags at each launch, then as the app comes to the foreground once a minute has passed, and new values apply then, never in the middle of a screen. Views that read a flag redraw. The users you pick come with TaoolAnalytics' check-in, at the next launch; a sign-in or sign-out checks in at once, and that user's picks apply as soon as it's answered.
- **Offline, or with taool out of reach,** every flag keeps the last values the device heard, and a user stays in the percentages they were in. Picks by user ID are kept per user, so another user's never apply after a sign-in, and a user's own come back as they sign in again, offline too.
- **Percentages are users, not devices.** A user's place in a flag's percentages comes from the user ID you pass, so your server can work out the same, else Apple's `appTransactionID`, the same on all their devices and after a reinstall, and each flag orders users its own way. Raising a percentage keeps everyone who already had it; lowering it takes out those who got it last.
- **On the device:** percentages, rollouts and targeting rules are worked out where the app runs, from what it knows about itself (its version, the OS, the kind of device, the App Store country, the app's language, StoreKit's purchases), so none of it is sent for them.
- **What's sent:** the key and the bundle ID to read the flags, and with TaoolAnalytics' check-in, the user ID you pass, if any. The package's privacy manifest declares a user ID, for app functionality, not linked to the user and not used for tracking, alongside TaoolAnalytics' own; your App Store privacy answers should include it, as linked to the user if you pass your own user IDs.
- **Not for what users paid for.** A flag decides what a user sees, never what they've bought access to: that's TaoolPurchases, or your own StoreKit code.

## Users (TaoolAnalytics)

`iOS` `iPadOS` `watchOS` `tvOS` `macOS` `visionOS`

One modifier on each scene's root view:

```swift
import SwiftUI
import TaoolAnalytics

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .taoolAnalytics(key: "taool_public_…")
        }
    }
}
```

taool then counts your app's users, weekly and monthly (daily with expanded analytics), new ones by the day they first downloaded the app, and the versions they're on, in the taool app's Earn tab and your app's page. An app with TaoolPurchases or TaoolFlags doesn't need it: `.taoolPurchases` and `.taoolFlags` check in already.

If your app has accounts, pass who's signed in as `userID`, and `nil` while no one is, so the taool app lists a user's Apple Accounts together and finds them by your ID. With TaoolKit's other modifiers, pass the same:

```swift
.taoolAnalytics(key: "taool_public_…", userID: session.userID)
```

For a support or debug screen, `await TaoolAnalytics.appTransactionID()` is StoreKit's ID for this user's Apple Account, nil while StoreKit can't say: find the user by it in the taool app, to pick them for a flag or give them access. It comes with TaoolPurchases and TaoolFlags too.

### How it works

- **Who a user is:** an Apple Account, by StoreKit's AppTransaction. One person on several devices, or after a reinstall, is one user. No sign-in needed; with your `userID`, the taool app groups a user's Apple Accounts under it.
- **One check-in for the whole app.** However many of TaoolKit's products the app links, and however many scenes and modifiers it has, it checks in once: TaoolPurchases and TaoolFlags go through the same check-in and add their part to it.
- **Not on every open.** It checks in at a cold launch, then as the app becomes active or goes to the background when one is due: every 6 hours. So a long session checks in as it starts and, past the interval, as it ends, and nothing is sent while the app sits in the background. A check-in that fails waits on the device and tries again. Everything goes to `kit.taool.com`.
- **Analytics.** Standard: your app's version and build, TaoolKit's version, the platform, the App Store country (from StoreKit, never the IP), the language your app runs in, the language the user chose in Settings (which your app may not have) and the device's region. Expanded: also when the app was last opened and how often, and the days it was opened on (counted on the device, sent with the next check-in), the OS version, and the kind of device and its model ("iPhone17,1"). `analytics: .automatic` (the default, **recommended**) lets you switch between the two in the taool app (TaoolKit → Analytics → the app), with no app update: standard until you turn Expanded Analytics on, a taool Pro feature. Without Pro, taool keeps only the standard facts, whatever the level. Any other level is a code override the taool app can't change: `.standard` stays standard even with Expanded Analytics on, `.expanded` sends expanded even with it off, and `.minimal`, which only code can set, sends nothing about the device, only which Apple Account this is and the user ID you pass, and with TaoolPurchases the signed purchases access needs. With more than one of `.taoolAnalytics`, `.taoolPurchases` and `.taoolFlags`, the most private level any of them asks for holds. Never IDFA, IDFV, an install ID, the IP or the device's name, so two devices of the same model on one Apple Account read as one.
- **What's sent:** the key, the bundle ID, StoreKit's signed AppTransaction (which Apple Account this is, and when it first downloaded the app from the App Store), the `userID` you pass, the level your code sets (so the taool app shows it beside the switch), and the analytics above. Once, after the App Store build is installed over a TestFlight build on the same device (or the other way), the previous build's signed AppTransaction too, so the taool app shows the two as one user. It's kept in TaoolKit's own file in Application Support (Caches on tvOS, which the system may empty), never your defaults, and lost if the app is deleted. The privacy manifest declares what standard analytics need: a user ID and purchase history (the AppTransaction is the app's own purchase record), for analytics, not linked to the user and never for tracking, and your App Store privacy answers include the same, as linked to the user only if you pass TaoolKit your own `userID`. **Expanded analytics are off for most apps, so they're not in TaoolKit's manifest:** before you turn them on, in the taool app or in code, add product interaction and other diagnostic data (analytics, not for tracking, linked as above; the device's model is diagnostic data too) to your app's own `PrivacyInfo.xcprivacy` and App Store privacy answers.

## In-app purchases (TaoolPurchases)

`iOS` `iPadOS` `watchOS` `tvOS` `macOS` `visionOS`

Your app connected to Subscriptions in the taool app (Earn → Subscriptions), then one modifier on each scene's root view. It includes TaoolAnalytics, so it also counts your users:

```swift
import SwiftUI
import TaoolPurchases

@main
struct MyApp: App {
    @State private var session = Session()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .taoolPurchases(key: "taool_public_…", userID: session.user?.id.uuidString)   // nil while no one is signed in; left out without accounts
        }
    }
}
```

Anywhere below it:

```swift
@Environment(TaoolPurchases.self) private var purchases

// An app that sells one thing:
if purchases.hasAccess { ProFeatures() } else { Paywall() }
if !purchases.isLoaded { … }   // StoreKit hasn't answered yet this launch: the last copy shows meanwhile

// One that sells several: subscriptions, a lifetime unlock, items such as city guides.
purchases.has("com.example.pro.monthly", "com.example.pro.yearly", "com.example.pro.lifetime")
purchases.has("com.example.guide.paris")

// The details, named as StoreKit names them: when it ends (nil: for good), whether it renews, its offer.
if let pro = purchases.currentEntitlement(for: "com.example.pro.monthly", "com.example.pro.yearly"), pro.isTrial, let end = pro.expirationDate {
    Text("Your trial ends \(end, format: .dateTime.weekday(.wide))")
}
purchases.currentEntitlements   // everything that gives access, the longest-lasting first

// Your purchase code stays yours; the options name the user signed in:
let result = try await product.purchase(options: purchases.purchaseOptions)
purchases.record(result)   // after every purchase your code makes: access has it at once, and taool hears of it
// …verify and finish the transaction as you do now.

// Your Restore Purchases button:
try await purchases.restore()

// Optional, a Check Access button: asks taool now (grants you give), never asks to sign in.
await purchases.refresh()

// With your users signed in: this Apple Account's subscription is another of your users'.
if purchases.isOnAnotherAccount { Text("In use by another account. Restore Purchases to use it here.") }
```

An `Entitlement` is named as StoreKit 2 names the same things, with StoreKit's own types: `productID`, `purchaseDate`, `originalPurchaseDate`, `expirationDate` (nil for a purchase that's for good), `offer` (`type`, `paymentMode`, `id`, as `Transaction.Offer`; `isTrial` for short), `willAutoRenew`, `state` (`.subscribed`, or `.inGracePeriod` while Apple retries a failed renewal), `ownershipType` (`.purchased` or `.familyShared`), `environment`, `subscriptionGroupID` and `originalTransactionID` (StoreKit's `originalID`), and `isGrant` for access you gave in taool. Consumables never give access (StoreKit doesn't list them), but taool still hears of them.

Outside SwiftUI, `TaoolPurchases.shared` is the same object.

### How it works

- **StoreKit first.** `currentEntitlements` are StoreKit's own, read as the app becomes active and whenever StoreKit reports a change, and kept on the device so it's right the moment the app starts. taool's answer adjusts it: grants you give add, and with your users signed in, a subscription another of them restored is taken away. If taool can't be reached, or never was, StoreKit's answer stands.
- **Never in the purchase path.** TaoolKit never calls `purchase`, never finishes a transaction (your code does, as it does now), and never blocks. StoreKit hands a purchase your code makes only to your code, so call `record(_:)` after each one: access has it at once (without it, a lifetime unlock or an item would wait until the app next comes to the foreground), and taool hears of it right after. Code that needs taool to have the purchase first, because your server reads access from taool, can wait: `await purchases.record(result).value`. StoreKit's own views below the modifier get the user's App Account Token without any code, and tell TaoolKit of their purchases themselves, unless your `onInAppPurchaseCompletion` takes them: call `record` there.
- **Your users.** Pass who's signed in as `userID`, any string up to 128 characters, on every render; an app without accounts leaves it out. A UUID also becomes Apple's App Account Token, so Apple's own transactions name them. A purchase or Restore Purchases moves a subscription to the user doing it; nothing else does (launching the app signed in as another user never moves it). With TaoolFlags or `.taoolAnalytics` too, they share one signed-in user: pass the same `userID` to each, or to one, which then counts for all. A `nil` in the first 3 seconds after the first modifier, while your session may still be loading at launch, doesn't sign anyone out; after that, `nil` means no one is signed in.
- **Not on every open.** TaoolKit checks in with taool when there's news (a purchase, renewal, refund, restore, a new user), at every cold launch, so a grant you give shows once the app is restarted, and otherwise every 6 hours as the app becomes active or leaves, in TaoolAnalytics' check-in, the app's one (see Users above). `refresh()` checks in at once.
- **`restore()` or `refresh()`.** `restore()` is your Restore Purchases button: it runs `AppStore.sync()`, which can ask the user to sign in to their Apple Account, reads StoreKit, and tells taool, which with your users signed in moves a subscription to the one restoring. `refresh()` reads StoreKit and asks taool, never the App Store, so it never asks anyone to sign in and moves nothing: for a Check Access button, or a user you just gave access to.
- **Before Subscriptions is set up** for the app, the check-in still counts your users, and access is StoreKit's alone: taool takes the purchases once the app is connected, from Apple's own history.
- **Analytics** are TaoolAnalytics', with the same levels: `.taoolPurchases(…, analytics:)` sets them as `.taoolAnalytics` would (see Users above).
- **What's sent:** TaoolAnalytics' check-in, and in it your user ID and StoreKit's signed transactions and renewal info. The privacy manifest declares what access needs: purchase history (app functionality and analytics) and a user ID (app functionality), not linked to the user and never for tracking, on top of TaoolAnalytics', and your App Store privacy answers include the same, as linked to the user if you pass your own `userID`.

### Your server

With a server of your own, taool POSTs each purchase event to it (authenticated, already decoded, sent again until it answers), and with a secret server key it asks who has access, by your user ID or by the AppTransaction your app sends it, and gives or ends access. Set both up under Earn → Subscriptions → the app → Your Server; [docs/integrate-purchases.md](docs/integrate-purchases.md#your-server-optional) has the events and the API.

## Coding agents

Each product has a guide written for coding agents such as Claude Code, with its server part where it has one: [docs/integrate-updates.md](docs/integrate-updates.md), [docs/integrate-experiments.md](docs/integrate-experiments.md), [docs/integrate-analytics.md](docs/integrate-analytics.md), [docs/integrate-flags.md](docs/integrate-flags.md) and [docs/integrate-purchases.md](docs/integrate-purchases.md). Point your agent at one and give it your key. The taool app's "Copy Prompt" buttons do this for you, with your key and bundle ID filled in.

## License

MIT. See [LICENSE](LICENSE).
