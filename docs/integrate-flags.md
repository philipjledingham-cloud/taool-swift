# Adding taool's feature flags to an app (for coding agents)

Follow these steps to add TaoolKit's `TaoolFlags` product to an iOS or macOS app. The developer makes each flag in the taool app and turns it on there, for a few users while testing, in TestFlight, then for everyone once the version is out (at once, at a percentage, or a step at a time), with no app update. The app's code only asks whether a flag is on.

**The app's server** can work out the same flags for its users, so it agrees with the app, and pick users for a flag: see [Your server](#your-server-optional), the last section. If that's all the prompt asks for, go straight there.

You need the developer's **taool key**, which looks like `taool_public_` followed by 31 letters and digits (never the server key, `taool_secret_…`, which belongs only on a server). It's usually in the prompt that sent you here. If not, ask for it: it's on the taool app's TaoolKit page. The key is public, so hard-coding it in the app is correct.

**Ask the developer which flags to add and what each one turns on**, if the prompt that sent you doesn't say. Each flag must already exist in the taool app (the TaoolKit page, the app, Flags): its key there is what the code reads, and the taool app's Copy Swift writes the enum below for you.

## 1. Add the package

- **Xcode project:** add a package dependency on `https://github.com/taoolcom/taool-swift` (Up to Next Major Version from 1.0.0), with the `TaoolFlags` product linked to the app target, and to any other app target that ships to the App Store (a separate Mac app). Never to widgets or extensions.
- **SwiftPM:** `.package(url: "https://github.com/taoolcom/taool-swift", from: "1.0.0")` and `.product(name: "TaoolFlags", package: "taool-swift")`.
- **The project has the package already** (for another TaoolKit product): only link `TaoolFlags`, never add the package again.

The package needs iOS 17, iPadOS 17, watchOS 10, tvOS 17, macOS 14 or visionOS 1. If the app supports older versions, stop and tell the developer.

## 2. Apply the modifier at the root of every scene

Find the `App` struct (`@main`), and put the modifier on the root view inside each `WindowGroup`, outside any switch between signed-out and signed-in UI. In a UIKit app without one, put it on the root SwiftUI view of a `UIHostingController` that stays on screen; if there's none, stop and tell the developer.

```swift
import SwiftUI
import TaoolFlags

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .taoolFlags(key: "taool_public_REPLACE_ME")
        }
    }
}
```

- **The app has its own accounts:** pass the signed-in user's stable ID, and `nil` while no one is signed in, read from wherever the app keeps its session so the modifier sees sign-ins and sign-outs: `.taoolFlags(key: "taool_public_REPLACE_ME", userID: session.userID)`. The developer can then pick a user by it in the taool app. Ask the developer if it isn't clear which ID that is. If the app also has `.taoolPurchases`, pass it the same `userID`: the two share one signed-in user. A `nil` in the first 3 seconds after the first modifier, while the session may still be loading at launch, doesn't sign anyone out; after that, `nil` means no one is signed in.
- **Debug builds with their own bundle ID:** pass the App Store app's, `bundleID: "com.example.app"`. It's the same ID in release builds, so there's no need for `#if DEBUG`.

## 3. Declare the flags

A String enum conforming to `TaoolFlag`, each raw value a flag's key in the taool app, exactly as it's written there:

```swift
enum Flags: String, TaoolFlag {
    case newOnboarding = "new-onboarding"
    case widgets
}
```

## 4. Read a flag where it decides something

```swift
var body: some View {
    if Flags.newOnboarding.isOn {
        NewOnboarding()
    } else {
        Onboarding()
    }
}
```

- A flag is **off until the device has heard from taool**, then has the last values it heard, kept on the device. So the code that's off is what everyone sees today: put the new behavior behind `isOn`, never the old.
- Reading a flag never waits on the network, and SwiftUI views that read one redraw when it changes, as the app comes to the foreground or a user signs in or out, never in the middle of a screen.
- `isOn` is on the main actor. Read it in views and main-actor code.
- A key the taool app doesn't have is always off: check the spelling against the taool app.

**Flags of text, a number or JSON** (remote config: the taool app shows each flag's type) are read with what they fall back to until the device has heard from taool, the same value the app shows today:

```swift
Text(Flags.paywallHeadline.string(default: "Unlock Pro"))
let days = Flags.trialDays.int(default: 7)                      // .number(default:) for any number
let plans = Flags.plans.value(as: [Plan].self, default: Plan.all)  // JSON, as any Decodable
```

Use the reader for the flag's type: one of another type gives the fallback. A date in a JSON flag is an ISO 8601 string (`"2026-12-01T00:00:00Z"`), which decodes into a `Date` field.

## 5. Check it

1. Build the app.
2. In a debug build only, `Flags.newOnboarding.force(true)` turns a flag on for this device without asking taool (inside `#if DEBUG`; it does nothing in release builds). Check both sides that way, then **remove the call**.
3. Run it. In the taool app, set the flag's TestFlight value to On, or pick this device's user by their Apple Account (`await TaoolAnalytics.appTransactionID()`, there with `import TaoolFlags`, worth showing on a debug or support screen), and relaunch the app.

## Privacy

Tell the developer what TaoolFlags sends: it asks taool for the app's flags (with the key and bundle ID, nothing about the user) and checks in through TaoolAnalytics, which it includes, sending the user ID they pass, if any, so users picked by it get their values. Percentages, rollouts and targeting rules (app version, OS, device, country, language, when the app was downloaded, what the user has bought) are worked out on the device, so nothing about it is sent for them. Its privacy manifest declares a user ID, for app functionality, not used for tracking, alongside TaoolAnalytics' own; the App Store privacy answers should include them, as linked to the user if the app passes its own user IDs.

## Rules

- Don't add your own network calls, caching or retries around TaoolFlags, and never a default value for a flag in code: the taool app holds them.
- Don't use a flag to decide what a user has paid for: that's purchases (TaoolPurchases or the app's own StoreKit code).
- Don't call it from widgets, extensions or App Clips.
- The key is the same for all of the developer's apps. TaoolKit finds the app from its bundle ID.

## Your server (optional)

For a developer whose server should agree with the app: hiding a new feature's routes, or a field of a response, from users the flag is off for. The app needs only step 2's `userID`, the same ID the server knows the user by, and a percentage then picks the same users on both. Every call goes to `https://api.taool.com` with one key, the app's **server key**, `taool_secret_…`, in the `Authorization: Bearer` header, never the taool key the app ships (step 2's), which servers don't use. The developer makes it in the taool app, on the app's page under TaoolKit → Server Keys (Create Key, shown once), which needs one of their App Store Connect keys in taool to cover the app, and gives it to the server as a secret, never in code and never in the app. It reads the flags of the taool account that made it, so the developer makes it from the account whose taool key is in the app. A 401 is a wrong or revoked key, or another app's, and a 404 (`unknown_app`) a key whose maker no longer has the app in taool.

### The ruleset (recommended)

`GET /v1/flags/{bundleId}/ruleset`: keep it in memory and ask again every 30 seconds with `If-None-Match` (a 304 while nothing changed), so turning a flag off, a pause or a pick reaches the server within 30 seconds. Then work each flag out for a user in the server's own code, with no call per check:

```json
{
  "flags": [
    { "key": "new-onboarding", "salt": "k3j9x2m7q1w8e5r4", "default": false,
      "serve": { "value": true, "otherwise": false, "steps": [{ "percent": 5, "at": "2026-10-16T09:00:00Z" }, { "percent": 100, "at": "2026-10-18T09:00:00Z" }] },
      "rules": [{ "when": [{ "attribute": "country", "op": "in", "values": ["SWE", "NOR"] }], "serve": { "value": true } }] }
  ],
  "picks": [{ "userId": "8e3f7a2c-4b1d-4c9e-a0f5-6d2b9e8c1a47", "flags": [{ "key": "new-onboarding", "value": true }] }]
}
```

A flag's value for a user ID, the first that applies:

1. `off` (sent only when it's turned off for everyone): its `default`.
2. The user's pick in `picks`: its value.
3. The first of its `rules` whose every condition holds: that rule's `serve`. A condition on something the server doesn't know about the user doesn't hold. `testFlight` is a device's, never a server's.
4. Its `serve`.

A `serve` is a value (`value` alone), or `value` for a percentage of users and `otherwise` (else `default`) for the rest: `percent`, or `steps`, whose percentage is the last step's whose `at` has passed (held at `pausedAt` when there is one), 0 before the first. At 100, `value`; at 0, `otherwise`. Otherwise the user is in when their bucket is below the percentage × 100: the first 8 bytes of the SHA-256 of `"{salt}.{userId}"`, read as a big-endian unsigned 64-bit integer, mod 10,000. The `userId` is trimmed, and a UUID, with its dashes or as 32 hex digits without them, is written lowercase with its dashes, as taool writes it.

Conditions (`attribute`, `op`, `values`): `appversion` `atleast` or `below` a version; `osversion` `atleast` or `below` versions, each for any Apple OS (`26.0`, 26 or later, as Swift's `anyAppleOS`) or for one device kind's OS (`pad:18.0`, iPadOS 18), which wins over any Apple OS's, the condition not holding on a device it names neither for; versions compared number by number; `device` `in` or `notin` `phone`, `pad`, `mac`, `watch`, `vision`, `tv`; `country` `in` or `notin` App Store countries as StoreKit names them (`SWE`); `language` `in` or `notin` (`en` matches `en-GB`); `downloaded` `onorafter` or `before` a UTC day (`2026-10-15`), App Store builds only, since StoreKit's sandbox gives every TestFlight and development build the same made-up download date; `subscribed` `is` or `isnot` any of the product IDs listed, or any product when none is: on a device, what gives access, TaoolPurchases' `currentEntitlements` (grants you give in taool included) in an app with it, else StoreKit's.

### One user, asked of taool

`GET /v1/flags/{bundleId}/users/{userId}` answers `{"flags": [{"key", "value", "source"}]}`, worked out as above with no facts, so no rule matches. It's a request per check: fine now and then, never on every request of a busy server.

### Picking users from the server

`PUT /v1/flags/{bundleId}/users/{userId}/{flagKey}` with `{"value": true}` (a value of the flag's type) gives that user the value, as picking them in the taool app does: on when a user joins a beta, say. `DELETE` puts them back on everyone's value. Both answer 204; 404 for a flag that isn't there; 400 `invalid_value`, or `too_many_overrides` past 1,000 users on a flag.

User IDs should be hard to guess: a device asks for its user's picks by their ID, with the public key.
