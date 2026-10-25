# Adding taool's in-app purchases (for coding agents)

Follow these steps to add TaoolKit's `TaoolPurchases` product to an iOS or macOS app that sells in-app purchases with StoreKit 2: subscriptions, lifetime unlocks, or items such as a city guide. It tells the app who has access to what: StoreKit's own answer, adjusted by taool (grants the developer gives, and with sign-in, a subscription that moved to another of the app's users). The app's own StoreKit code keeps doing the buying.

**The app's server** can take taool's webhooks for purchase events and ask taool who has access: see [Your server](#your-server-optional), the last section. If that's all the prompt asks for, go straight there.

You need the developer's **taool key**, which looks like `taool_public_` followed by 31 letters and digits (never the server key, `taool_secret_…`, which belongs only on a server). It's usually in the prompt that sent you here. If not, ask for it: it's on the taool app's TaoolKit page. The key is public, so hard-coding it in the app is correct.

Before you start, the app should be connected to Subscriptions in the taool app (Earn → Subscriptions). If the developer hasn't, tell them; the code works either way: until it is, access is StoreKit's alone, and taool takes the purchases once it's connected.

`TaoolPurchases` includes `TaoolAnalytics`, which counts the app's users. If the app already has `.taoolAnalytics(key:…)`, replace it with `.taoolPurchases` (keeping any `analytics:` argument) rather than having both; both would do no harm, since it's one check-in.

## 1. Add the package

- **Xcode project:** add a package dependency on `https://github.com/taoolcom/taool-swift` (Up to Next Major Version from 1.0.0), with the `TaoolPurchases` product linked to the app target, and to any other app target that ships to the App Store (a separate Mac app). Never to widgets or extensions.
- **SwiftPM:** `.package(url: "https://github.com/taoolcom/taool-swift", from: "1.0.0")` and `.product(name: "TaoolPurchases", package: "taool-swift")`.
- **The project has the package already** (for another TaoolKit product): only link `TaoolPurchases`, never add the package again.

The package needs iOS 17, iPadOS 17, watchOS 10, tvOS 17, macOS 14 or visionOS 1. If the app supports older versions, stop and tell the developer.

## 2. Apply the modifier at the root of every scene

Put it on the root view inside each `WindowGroup` (and each `Window` users buy or check access in), outside any switch between signed-out and signed-in UI:

```swift
import SwiftUI
import TaoolPurchases

WindowGroup {
    ContentView()
        .taoolPurchases(key: "taool_public_REPLACE_ME", userID: /* the signed-in user's ID as a String, or nil */)
}
```

- **Apps without a SwiftUI `App`:** put it on the root SwiftUI view of a `UIHostingController` that stays on screen; if there's none, stop and tell the developer.
- **Debug builds with their own bundle ID:** pass the App Store app's, `bundleID: "com.example.app"`. It's the same ID in release builds, so there's no need for `#if DEBUG`.
- **`userID`:** if the app has accounts, pass the signed-in user's ID as a String (a UUID's `uuidString`), read from wherever the app keeps its session, so it updates as users sign in and out, and `nil` while no one is signed in. If the app has no accounts, leave `userID` out: `.taoolPurchases(key: "taool_public_REPLACE_ME")`. If the app also has `.taoolFlags`, pass it the same `userID`: the two share one signed-in user. A `nil` in the first 3 seconds after the first modifier, while the session may still be loading at launch, doesn't sign anyone out; after that, `nil` means no one is signed in.
- A view that reads `@Environment(TaoolPurchases.self)` in a scene without the modifier crashes, as SwiftUI does for any missing environment object, so cover every scene.

## 3. Read access from TaoolKit

Find where the app decides whether a user has access (often a store or manager class looping over `Transaction.currentEntitlements`, or `subscriptionStatusTask`). Replace the answer with TaoolKit's, keeping the app's own structure. A non-renewing subscription is the one exception: StoreKit keeps it after it ends and never says how long it lasts, so TaoolKit gives no access for it, and the app's own check for those stays:

```swift
@Environment(TaoolPurchases.self) private var purchases

purchases.hasAccess                                               // anything gives access: an app that sells one thing
purchases.has("com.example.pro.yearly", "com.example.pro.monthly")   // any of these products
purchases.has("com.example.guide.paris")                          // an item bought for good
purchases.currentEntitlement(for: "com.example.pro.yearly")       // its details, nil without access
purchases.isOnAnotherAccount                                      // with accounts: another user has this Apple Account's subscription
```

An `Entitlement` is named as StoreKit 2 names the same things, with StoreKit's own types: `productID`, `purchaseDate`, `originalPurchaseDate`, `expirationDate` (nil for a purchase that's for good), `offer` (`type`, `paymentMode`, `id`, as `Transaction.Offer`; `isTrial` for short), `willAutoRenew`, `state` (`.subscribed`, or `.inGracePeriod` while Apple retries a failed renewal), `ownershipType` (`.purchased` or `.familyShared`), `environment`, `subscriptionGroupID` and `originalTransactionID` (StoreKit's `originalID`), and `isGrant` for access you gave in taool. Where the app unlocks per product (several tiers, or items), use `has(_:)` with that product's IDs, never `hasAccess`, which any purchase makes true.

Outside SwiftUI views (a class, a view model), use `TaoolPurchases.shared` on the main actor. It's `@Observable`.

## 4. Purchases: add the options, and record the result

Keep the app's purchase call, at every place the app makes one. Add TaoolKit's options, so Apple's transaction names the signed-in user, and record the result:

```swift
let result = try await product.purchase(options: purchases.purchaseOptions)   // or the environment's purchase(_:options:)
purchases.record(result)
// The app's existing handling stays: verify, unlock, and finish the transaction.
```

`record` isn't optional: StoreKit hands a purchase the app makes only to that call, so without it a lifetime unlock or an item gives no access in TaoolKit until the app next comes to the foreground. It gives access on that line and tells taool right after, so nothing waits on taool. Only if the app's server reads access from taool and must have the purchase first, wait for it: `await purchases.record(result).value`.

If the app merges its own options (a promotional offer), add `purchases.purchaseOptions` to them. StoreKit's views (`SubscriptionStoreView`, `ProductView`) below the modifier get the options automatically, and tell TaoolKit of their purchases themselves, so they need no `record`, unless the app handles their purchases in `onInAppPurchaseCompletion`, which keeps them from TaoolKit: then call `purchases.record(result)` in that handler.

**Never remove the app's `transaction.finish()` calls or its `Transaction.updates` listener that finishes transactions.** TaoolKit only observes.

## 5. Restore Purchases

Where the app's Restore button calls `AppStore.sync()`, call TaoolKit instead (it calls `AppStore.sync()` itself):

```swift
try await purchases.restore()
```

With accounts, this is what moves a subscription to the user restoring.

If the app has an account or support screen, a **Check Access** button can call `await purchases.refresh()`: it reads StoreKit again and asks taool at once for what it keeps about this Apple Account (grants the developer gives, and with accounts a subscription that's another user's), but never calls `AppStore.sync()`, so nothing asks the user to sign in, and it moves nothing. It's optional: every cold launch of the app does the same, so restarting the app shows a grant too. Don't call it on a timer or on every appearance. The same screen can show `await TaoolAnalytics.appTransactionID()` (there with `import TaoolPurchases`), which the developer finds the user by in the taool app to give them access.

## 6. Show "in use by another account" (apps with accounts)

Where the paywall or settings show the subscription state, add a line for `purchases.isOnAnotherAccount`: this Apple Account pays, but the subscription is another of the app's users'. Offer Restore Purchases there.

## 7. Analytics (ask the developer)

The check-in is TaoolAnalytics', which `TaoolPurchases` includes. The default is standard analytics (app version, TaoolKit version, platform, App Store country, the app's language, the user's preferred language and the device's region). Expanded analytics (last opened, opens and the days they were on, OS version, device kind and model) are switched on in the taool app, with no code. Leave `analytics` out (`.automatic`, recommended), so the developer switches between the two in the taool app. Only if the developer wants to promise less, add a code override, which the taool app can't change: `analytics: .minimal` (nothing beyond what access needs) or `.standard` (never expanded). Tell the developer their App Store privacy answers should include purchase history (app functionality and analytics) and user ID (app functionality and analytics), not used for tracking, which TaoolKit's privacy manifests declare as not linked to the user; they answer linked if the app passes its own user IDs as `userID`, as an app with accounts does. Expanded analytics aren't in TaoolKit's manifest, since most apps leave them off: only if the developer will turn them on, add product interaction and other diagnostic data (analytics, not used for tracking, linked as above; the device's model is diagnostic data too) to the app's own `PrivacyInfo.xcprivacy`, and tell them to add the same to their App Store privacy answers first.

## 8. Check

Build the app. Run it, buy a sandbox purchase, and confirm `has(_:)` with its product ID turns true. In the taool app, the app's Subscriptions page shows TaoolKit's last report under Status, and the TaoolKit page's Purchases card when the app last checked in.

## Your server (optional)

For an app connected to Subscriptions in the taool app whose developer has a server of their own. Two parts, either or both:

- **Webhooks**: taool POSTs each purchase event to the server as it happens, already decoded, with the subscription as taool has it now. The app can have several, each taking production, sandbox or both, and every event or those picked: one for production and one for a staging server, say.
- **The entitlement API**: with a secret server key, the server asks taool whether one user has access, and gives or ends access (grants).

The app itself needs nothing more: TaoolKit's `TaoolPurchases` (above) already counts grants and moves between users on the device.

Ask the developer for two secrets, made in the taool app under Earn → Subscriptions → the app → Your Server, and put them in the server's secrets (never in code, never in the app):

- what the webhook proves it's taool's with (Webhooks → the webhook), whichever the developer picked there, each webhook its own: the **Authorization header** value they set, e.g. `Taool:PurchasesWebhookAuthorization`, or the **signing secret**, e.g. `Taool:PurchasesWebhookSecret`;
- a **server key**, `taool_secret_…` (Server Keys → Create Key, shown once, also on the app's page under TaoolKit), e.g. `Taool:ServerKey`. It's the only key the server sends taool, the same one it reads update prompts' policy and feature flags with; never the taool key the app ships.

### The webhook

Add an `https` POST route and give its URL to the developer to enter under Webhooks → Add Webhook, where they pick the environment and events it takes. It has to be a server's URL: Slack and Discord can't read the JSON, so taool refuses theirs. Each POST is one event:

```json
{
  "id": "5d1c0c3e-8f0a-4a3e-9d6b-2f9c1d7e4b10",
  "type": "subscription.renewed",
  "createdDate": "2026-10-09T08:00:00Z",
  "appId": 1234567890,
  "bundleId": "com.example.app",
  "data": {
    "environment": "production",
    "userId": "8e3f7a2c-4b1d-4c9e-a0f5-6d2b9e8c1a47",
    "appTransactionId": "704000000000000001",
    "subscription": {
      "originalTransactionId": "2000000123456789", "transactionId": "2000000234567890", "productId": "com.example.pro.monthly",
      "subscriptionGroupId": "21000001", "periodType": "normal", "price": 4.99, "currency": "USD", "storefront": "USA",
      "originalPurchaseDate": "2026-06-09T07:59:41Z", "purchaseDate": "2026-10-09T07:59:41Z", "expirationDate": "2026-11-09T07:59:41Z",
      "priceUsd": 4.99, "transactionReason": "renewal", "renewalNumber": 4, "willAutoRenew": true, "renewalProductId": "com.example.pro.monthly", "renewalPrice": 4.99,
      "renewalCurrency": "USD", "renewalPriceUsd": 4.99, "status": "active"
    },
    "apple": { "notificationType": "DID_RENEW", "subtype": "…", "notificationId": "a1b2c3d4-…" }
  }
}
```

- Nulls are left out, and so are booleans that are false (`willAutoRenew` missing means it won't renew). Dates are UTC (`2026-10-09T08:00:00Z`), each named for what it is and ending in `Date`, as StoreKit's are (`purchaseDate`, `expirationDate`).
- `environment`: `production` or `sandbox` (TestFlight and development builds).
- `userId`: the app's own user the subscription is with (TaoolKit's `userID`, or the purchase's App Account Token); missing when there's none.
- `appTransactionId`: the Apple Account's ID in the app.
- `subscription.subscriptionGroupId`: the subscription group it's in.
- `subscription.periodType`: `trial`, `introductory`, `promotional`, `offerCode`, `winBack` or `normal`.
- `subscription.offerId`: which offer the period is on (a promotional offer's, an offer code's or a win-back offer's ID), when it's on one.
- `subscription.storefront`: the App Store country it was bought in, in Apple's three letters (`USA`), like StoreKit's `Storefront.countryCode`.
- `subscription.originalPurchaseDate`: when they first subscribed, the same through every renewal.
- `subscription.priceUsd` and `renewalPriceUsd`: the price and the renewal's in US dollars, at the exchange rate of the purchase's day and of today: an estimate, the price itself when it's in dollars.
- `subscription.renewalNumber`: which period of the subscription the event is about: 1 at its first purchase (a free trial's start included), and each renewal one more, an upgrade's new charge too, so a trial's conversion is 2. A re-subscribe after a lapse starts at 1 again. `subscription.isTrialConversion`: there on the `subscription.renewed` right after a free trial.
- `subscription.transactionReason`: `renewal` when Apple renewed the period on its own, `purchase` when the customer bought it (a first purchase, a re-subscribe, an upgrade). An upgrade's `subscription.renewed` says `purchase`, so it reads apart from Apple's renewals.
- `subscription.isBillingRecovery`: there on the `subscription.renewed` that came after a failed payment, once Apple's retry or the customer's new card got it paid: the same subscription, so `renewalNumber` goes on.
- `subscription.renewalProductId`, `renewalPrice` and `renewalCurrency`: what the next renewal is for and costs, as Apple's renewal info says. A `renewalProductId` other than `productId` is a change waiting for the renewal (a downgrade, or a crossgrade to another length).
- `subscription.status`: `active`, `trial` (a free trial now), `grace` (Apple retrying a failed payment, access on through the billing grace period), `retry` (Apple retrying, access off), `expired` or `revoked`.
- `subscription.expirationReason`, once it's expired: `cancelled`, `billing`, `priceIncrease`, `unavailable` or `other`.
- `subscription.revocationDate` and `revocationReason` (`appIssue` or `other`) on a refund, and `revocationPercentage` on a partial one (`50` for half).
- `subscription.familyShared`: there when the user has it through Family Sharing.
- `apple`: Apple's own notification: its type, its subtype when Apple gives one, and its ID.

| Type | When |
|---|---|
| `subscription.started` | A first purchase, a trial included |
| `subscription.resubscribed` | Bought again after it had expired |
| `subscription.renewed` | A renewal, once however many notifications Apple sends for it; also an upgrade's new charge, after its `subscription.productChanged` |
| `subscription.cancelled` | Renewal turned off: access lasts until `expirationDate` |
| `subscription.uncancelled` | Renewal turned back on |
| `subscription.productChanged` | An upgrade, or a crossgrade to a product of the same length: it changes now, `productId` the new product |
| `subscription.renewalProductChanged` | A downgrade, or a crossgrade to another length, chosen for the next renewal, or that choice taken back: `renewalProductId` is what it renews as now. The renewal itself comes as `subscription.renewed`, `productId` the new product |
| `subscription.billingIssue` | A renewal failed; Apple retries, maybe with a grace period (`gracePeriodExpirationDate`) |
| `subscription.gracePeriodEnded` | The grace period ended without a payment |
| `subscription.expired` | Access ended |
| `subscription.refunded`, `purchase.refunded` | Apple refunded it: take access away |
| `subscription.refundReversed`, `purchase.refundReversed` | A refund was reversed |
| `subscription.revoked`, `purchase.revoked` | A family member's access through Family Sharing ended |
| `subscription.offerRedeemed`, `subscription.priceIncrease`, `subscription.extended` | Apple's news about them |
| `subscription.transferred` | Moved to another of the app's users by a purchase or Restore Purchases: `data.transfer: { fromUserId, toUserId }` |
| `purchase.completed` | A one-time purchase |
| `grant.started`, `grant.ended` | Access the developer gave started, or was ended early: `data.grant: { grantId, productId, expirationDate, revocationDate, note }` |
| `test` | The taool app's Send Test Event |

**Check every POST**, the way the developer picked: a POST carries one, never both. Either its `Authorization` header is exactly the value they set (`Bearer` included if they use it), compared in constant time; or `Taool-Signature: t={unix seconds},v1={hex}`, where `v1` is HMAC-SHA256 of `"{t}.{raw body}"` keyed with the signing secret's UTF-8 bytes: check the raw body, compare in constant time, refuse a `t` more than 5 minutes old. `Taool-Event` repeats the type. That check is the authentication, not the server's own sign-in (`.AllowAnonymous()` where authorization is the default).

**Answer 2xx at once** and do the work after. Anything else is sent again, from a minute to a day apart, for about three days, and the developer can send any event again from the taool app, so an `id` already handled is done; an event's `id` is the same at every webhook it goes to. Events arrive in about the order they happened, never guaranteed: compare `subscription.expirationDate` rather than trusting the order.

```csharp
app.MapPost("/hooks/taool/purchases", async (HttpRequest request, IConfiguration config, ILogger<Program> logger) =>
{
    using var reader = new StreamReader(request.Body);
    var body = await reader.ReadToEndAsync();
    if (!TaoolWebhook.IsFromTaool(request, body, config["Taool:PurchasesWebhookAuthorization"], config["Taool:PurchasesWebhookSecret"]))
        return Results.Unauthorized();

    var e = JsonSerializer.Deserialize<TaoolPurchaseEvent>(body, new JsonSerializerOptions(JsonSerializerDefaults.Web))!;
    // Queue the work and answer now; skip e.Id if it's been handled before.
    logger.LogInformation("taool {Type} for {UserId}", e.Type, e.Data.UserId);
    return Results.Ok();
}).AllowAnonymous();   // checked above, not signed in

public sealed record TaoolPurchaseEvent(Guid Id, string Type, DateTime CreatedDate, long AppId, string BundleId, TaoolEventData Data);
public sealed record TaoolEventData(string? Environment, string? UserId, string? AppTransactionId, TaoolSubscription? Subscription);
public sealed record TaoolSubscription(string OriginalTransactionId, string? TransactionId, string ProductId, string? PeriodType,
    DateTime? ExpirationDate, DateTime? GracePeriodExpirationDate, bool WillAutoRenew, string? RenewalProductId, string? Status);
```

`TaoolWebhook.IsFromTaool` is the release webhook's, in [integrate-updates.md](integrate-updates.md#the-release-webhook-optional).

### The entitlement API

Every request has `Authorization: Bearer {server key}`. The key opens one app, by any of its bundle IDs. It's at `api.taool.com`, never `kit.taool.com`, the host apps call with the public SDK key, which answers it with a 404.

It answers for one user or Apple Account per request, with no list of everyone who has access. A server that needs one keeps its own from the webhook's events.

**A user's access:** `GET https://api.taool.com/v1/purchases/{bundleId}/users/{userId}`, where `userId` is the ID the app passes TaoolKit, any string up to 128 characters (a UUID matches whatever its letters' case).

```json
{
  "entitled": true,
  "entitlements": [
    { "productId": "com.example.pro.yearly", "source": "purchase", "environment": "production",
      "expirationDate": "2027-10-09T07:59:41Z", "willAutoRenew": true, "renewalProductId": "com.example.pro.yearly", "periodType": "normal",
      "originalTransactionId": "2000000123456789" },
    { "productId": "com.example.pro.yearly", "source": "grant", "expirationDate": "2026-11-09T00:00:00Z", "grantId": 42 }
  ]
}
```

- `entitled` is left out when nothing gives access. `source`: `purchase`, `familySharing` or `grant`. A grant without an end has no `expirationDate`. `inGracePeriod` is there while Apple retries a failed renewal and access continues.
- `renewalProductId` is what a subscription's next renewal is for: another product than `productId` while a downgrade, or a crossgrade to another length, waits for it.
- A user's subscriptions are those that are theirs now (a restore by another user moves one away), plus grants to them or to the Apple Accounts they've been signed in on.

**An Apple Account's access, for an app without sign-in:** `POST https://api.taool.com/v1/purchases/{bundleId}/apple-accounts` with `{ "appTransaction": "…" }`, the JWS of StoreKit's `AppTransaction.shared` (`jwsRepresentation`) the app sends its server. Same answer. A bare `appTransactionId` is never enough, since anyone could send one; Apple's signature proves it. `400 invalid_app_transaction` when it isn't Apple's, or another app's.

Keep an answer a minute at most, and drop a user's when a webhook event about them comes.

```csharp
builder.Services.AddHttpClient("taool", c =>
{
    c.BaseAddress = new Uri("https://api.taool.com/v1/purchases/com.example.app/");
    c.DefaultRequestHeaders.Authorization = new("Bearer", builder.Configuration["Taool:ServerKey"]);
    c.Timeout = TimeSpan.FromSeconds(5);
});

public sealed record TaoolEntitlements(bool Entitled, List<TaoolEntitlement> Entitlements);
public sealed record TaoolEntitlement(string ProductId, string Source, DateTime? ExpirationDate, bool WillAutoRenew, long? GrantId);

public static async Task<TaoolEntitlements> EntitlementsAsync(IHttpClientFactory http, string userId, CancellationToken ct) =>
    await http.CreateClient("taool").GetFromJsonAsync<TaoolEntitlements>($"users/{Uri.EscapeDataString(userId)}", ct)
    ?? new(false, []);
```

Decide what to do when taool can't be reached: most servers keep the last answer they had.

### Grants

Free access the developer gives, to a tester or for a support case. Never codes redeemed in the app, which App Review forbids.

- **Give:** `POST https://api.taool.com/v1/purchases/{bundleId}/grants` with `{ "userId": "…", "productId": "com.example.pro.yearly", "expirationDate": "2026-12-31T00:00:00Z", "note": "Beta tester" }`, or `appTransactionId` in place of `userId` for an Apple Account taool has seen. `expirationDate` and `note` (200 characters) are optional. Answers `{ "grant": { "id": 42, … } }`.
- **Who sees it:** one to an `appTransactionId` reaches TaoolKit on that Apple Account's devices at its next check-in, and this API. One to a `userId` reaches only this API: TaoolKit never reads anything by user ID, which anyone could claim from a device, so an app that unlocks from TaoolKit alone needs grants to its Apple Accounts (as the taool app gives them).
- **End early:** `DELETE https://api.taool.com/v1/purchases/{bundleId}/grants/{id}`, 204; 404 when it's ended already.
- The developer can also give and end access on a customer's page in the taool app.

### Errors

`401 invalid_key` (a wrong or revoked key, or another app's), `401 sdk_key` (the app's public key, `taool_public_…`, sent where the server key goes), `404 not_connected` (the app isn't connected to Subscriptions in the taool app), `400 invalid_app_transaction`, `invalid_product`, `invalid_end` (in the past), `invalid_note` or `no_one` (neither a user ID nor an Apple Account), `429` when asking too often (wait and retry).

Each taool account can have two server keys working for an app at once: to rotate, make a new one, deploy it, then revoke the old one in the taool app.

### Check the server

1. In the taool app, Webhooks → the webhook → Send Test Event: the server should answer 2xx, and the app shows the status it got. Then a sandbox purchase in a TestFlight build should POST `subscription.started` within a minute or two.
2. `curl -H "Authorization: Bearer taool_secret_…" https://api.taool.com/v1/purchases/{bundleId}/users/{userId}` for a user who bought in the sandbox should answer `"entitled": true`.
3. Give that user a grant from the server, check it shows on the customer's page in the taool app, and end it.
