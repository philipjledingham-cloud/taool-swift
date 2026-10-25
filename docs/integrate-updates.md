# Adding taool's update prompts and What's New (for coding agents)

Follow these steps to add TaoolKit's `TaoolUpdates` product to an iOS or macOS app. It has two features, each a modifier of its own, and the developer may want either or both:

- **Update prompts** (`.taoolUpdatePrompts(key:)`): the app shows a banner when a newer App Store version is available, and covers itself with an update screen when the developer requires an update.
- **What's New** (`.taoolWhatsNew(key:)`): the app shows the developer's What's New page for a version (taool Pro), once, in a sheet, to everyone who had the app before that version.

Add the ones the prompt that sent you asks for. If it doesn't say, ask the developer. With both, they share one check with taool.

**The app's server** can refuse versions below the minimum and take a webhook when a version goes live: see [Your server](#your-server-optional), the last section. If that's all the prompt asks for, go straight there.

You need the developer's **taool key**, which looks like `taool_public_` followed by 31 letters and digits (never the server key, `taool_secret_…`, which belongs only on a server). It's usually in the prompt that sent you here. If not, ask for it: it's on the taool app's TaoolKit page. The key is public, so hard-coding it in the app is correct. Don't put it in a secrets file or the Keychain.

## 1. Add the package

- **Xcode project:** add a package dependency on `https://github.com/taoolcom/taool-swift` (Up to Next Major Version from 1.0.0), with the `TaoolUpdates` product linked to the app target. Also link it to any other app target that ships to the App Store, such as a separate Mac app target. Never link it to widgets or extensions.
- **SwiftPM:** add `.package(url: "https://github.com/taoolcom/taool-swift", from: "1.0.0")` and `.product(name: "TaoolUpdates", package: "taool-swift")`.
- **The project has the package already** (for another TaoolKit product): only link `TaoolUpdates`, never add the package again.

The package needs iOS 17 or macOS 14. If the app supports older versions, stop and tell the developer. TaoolUpdates is for iOS and Mac apps. If one target also builds for tvOS, watchOS or visionOS, link TaoolUpdates for iOS and macOS only (the framework's platform filter in the target's Frameworks, Libraries, and Embedded Content) and wrap `import TaoolUpdates` and its modifiers in `#if os(iOS) || os(macOS)`.

## 2. Apply the modifiers at the root of every scene

Find the `App` struct (`@main`), and put the modifiers on the root view inside each `WindowGroup`:

```swift
import SwiftUI
import TaoolUpdates

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .taoolUpdatePrompts(key: "taool_public_REPLACE_ME")   // update prompts
                .taoolWhatsNew(key: "taool_public_REPLACE_ME")        // What's New
        }
    }
}
```

- If the app has several `WindowGroup`s, or a `Window` that users work in, add them to each.
- If the root view switches between sign-in and the main UI, put the modifiers outside that switch. Users who aren't signed in need them too.
- The Update button and the icons are in the asset catalog's AccentColor. If the app's brand color is somewhere else (set with `.tint(…)` in code, or the app has no AccentColor), add `.taoolTint(thatColor)` after the modifiers. Leave out its `label:` (black or white is picked to read on the color) unless the developer asks for a label color.

### Update prompts

- **Where the banner shows:** in most apps, in the first screen users see, at the top of its scroll view or list, scrolling with it like any card there: `placement: .inline` on the modifier, and `TaoolUpdates.Banner()` where it goes, with the padding of what's beside it. It takes no space until an update is available, so it stays in the code for good. Use it when the app opens on a screen with a scroll view or list. Without one (a game, a camera, a full-screen canvas), leave `placement:` out: the banner then floats at the top of the window, the app's content moving down for it (`placement: .bottom` for the bottom instead).

  ```swift
  ContentView()
      .taoolUpdatePrompts(key: "taool_public_REPLACE_ME", placement: .inline)

  // The first screen:
  ScrollView {
      TaoolUpdates.Banner()
      …
  }
  ```

  With `.inline`, the update-required screen still covers the app from the modifier; only the banner moves.

  If that screen's other items are cards of the app's own design, draw the banner as one of them, with the app's own card view and button styles, and TaoolKit's words and actions. Use every one of `update.title`, `update.message`, `update.button` and `update.notNow` as given (never your own text: they're translated, and the developer's own message can replace `message` from the taool app), and call `update.open()` and `update.dismiss()` from the two buttons:

  ```swift
  TaoolUpdates.Banner { update in
      MyCard {
          Text(update.title).font(.headline)
          Text(update.message)
          HStack {
              Button(update.button, action: update.open)
              Button(update.notNow, action: update.dismiss)
          }
      }
  }
  ```
- **The update-required screen in the app's own design**, only when the developer asks for it: `.taoolUpdateRequiredScreen { required in … }` once, after the modifiers on the root view. Use `required.title` and `required.message` as given, and the button only when `required.button` isn't nil (it's nil when no version runs on the device's OS), calling `required.open()`. Never add a way to close it or go past it: TaoolKit lays it over the whole window for a reason.

  ```swift
  ContentView()
      .taoolUpdatePrompts(key: "taool_public_REPLACE_ME")
      .taoolUpdateRequiredScreen { required in
          VStack(spacing: 16) {
              Text(required.title).font(.title.bold())
              Text(required.message).multilineTextAlignment(.center)
              if let button = required.button {
                  Button(button, action: required.open)
              }
          }
          .padding(32)
      }
  ```
- **If the app has its own server:** in the app's networking code, send `TaoolUpdates.appVersion` with every request to it in an `X-App-Version` header, and when a response is **426**, call `TaoolUpdates.serverRequiredUpdate()` (from any thread). `.taoolUpdatePrompts(key:)` then covers the app with its update-required screen at once. Don't show your own screen or alert for a 426. If the server doesn't refuse old versions yet, see [Your server](#your-server-optional).
- **Full-screen covers and sheets users can't close** (a hard paywall or onboarding shown with `.fullScreenCover` or `.sheet`): they sit above the root's update screen, so add `.taoolUpdatePrompts(key:)` to each one's root view too (never `.taoolWhatsNew`). It's still one check. A sheet users can close needs nothing, and a paywall or onboarding the root view switches to is covered already.

  ```swift
  ContentView()
      .fullScreenCover(isPresented: $store.showsPaywall) {
          Paywall()
              .taoolUpdatePrompts(key: "taool_public_REPLACE_ME")   // the update screen covers the paywall too
      }
      .taoolUpdatePrompts(key: "taool_public_REPLACE_ME")
  ```
- **UIKit apps without a SwiftUI `App`:** call `await TaoolUpdates.status(key:)` from a `Task` in `sceneDidBecomeActive`. Present your own UI for `.available`, `.required` and `.unsupported` with the status's `text` (`title` and `message`, on the main actor). For `.available` and `.required`, add a button titled `text.button` that opens `release.appStoreURL` with `UIApplication.shared.open`; `.unsupported` has none, since nothing on the App Store runs on that OS.

### What's New

- **A hard paywall, onboarding, or a sheet of the app's own at launch:** hold the page while they show, with `mode:` read from the app's own state (its purchase state, its onboarding flag; don't add new state). It shows as soon as the mode is `.automatic` again, and nothing is lost while it's held.

  ```swift
  // A hard paywall the root view switches to:
  Group {
      if store.hasPro { ContentView() } else { Paywall() }
  }
  .taoolUpdatePrompts(key: "taool_public_REPLACE_ME")
  .taoolWhatsNew(key: "taool_public_REPLACE_ME", mode: store.hasPro ? .automatic : .held)

  // Onboarding:
  ContentView()
      .taoolWhatsNew(key: "taool_public_REPLACE_ME", mode: hasOnboarded ? .automatic : .held)
  ```
- **If the app has a settings screen**, add a "What's New" row there, so users can open the page again after closing it. `TaoolUpdates.hasWhatsNew` (on the main actor) says whether there's a page, from this launch's answer, so no request (false for up to 3 seconds as the app opens, while it waits for that answer):

  ```swift
  if TaoolUpdates.hasWhatsNew {
      Button("What's New") { TaoolUpdates.showWhatsNew() }
  }
  ```
- Don't build a What's New screen of your own. If the app has one, ask the developer which to keep. To keep it and let taool decide when it shows, add `.taoolWhatsNewScreen { whatsNew in … }` after the modifiers and draw the app's screen for `whatsNew.version`, falling back to `TaoolUpdates.WhatsNewPageSheet(whatsNew)` for a version the app has nothing for. A page still has to be uploaded for each version.
- The page never shows while this version must update: it waits until the user has updated.

## 3. Debug builds with their own bundle ID

TaoolKit identifies the app by `Bundle.main.bundleIdentifier`. Check the target's build settings. If Debug builds use a different bundle ID (e.g. `com.example.debug`), pass the App Store one to each modifier, after any `placement:` or `mode:`:

```swift
.taoolUpdatePrompts(key: "taool_public_…", bundleID: "com.example")
.taoolWhatsNew(key: "taool_public_…", bundleID: "com.example")
```

`TaoolUpdates.status(key:bundleID:)` takes it too. Otherwise, leave the parameter out.

## 4. Check it

1. Build the app.
2. **Update prompts:** temporarily add `simulating: .required` to the modifier, as its last argument (`.taoolUpdatePrompts(key: "taool_public_…", simulating: .required)`), then run it. The update screen should cover the app. Try `.available` too: a banner should appear at the top (at the bottom with `placement: .bottom`, or where `TaoolUpdates.Banner()` is with `placement: .inline`). Simulations only work in debug builds. **Remove the `simulating:` argument** before you finish.
3. **What's New** has nothing to simulate: the page shows once the developer has uploaded and published one, which needs its version on the App Store, or turned on Show in TestFlight for it, which shows it in TestFlight and Xcode builds on its version or newer.

## Rules

- Don't add your own network calls, timers, or caching around TaoolKit. It already checks as the app comes to the foreground: once a launch, then at most hourly, showing what it saved from the first frame.
- Don't catch errors or add retries: `status(key:)` never throws. When taool is unreachable it returns the last known answer, or `.current`.
- Don't build a second "update available" UI next to the modifier. If the app already has one, for example driven by the app's own server headers, ask the developer which to keep.
- The key is the same for all of the developer's apps. TaoolKit finds the app from its bundle ID.
- Only the developer can set the minimum version, in the taool app. Don't hard-code versions.
- Don't translate or reword TaoolKit's text, or add strings for it to the app's catalog. It comes in 37 languages and follows the language the app runs in; the developer writes their own messages, and can lock the language, in the taool app.
- `serverRequiredUpdate()` is only for a 426 from the app's own server, never for other errors.

## What the developer does next

- **Minimum version:** in the taool app, TaoolKit → Update Prompts → the app. It needs taool Pro; without it, the update prompts show the banner only.
- **Messages and language:** in the same place, the developer can lock the prompts to one language (for an app whose bundle doesn't say which language it's in, such as a Swedish-only app whose development language is still English) and, on taool Pro, write their own banner and update-required text.
- **What's New pages:** in the taool app, TaoolKit → What's New → the app → Upload a Page, then publish it there, or have it publish itself when its version is on the App Store. It needs taool Pro.
- **Servers:** if the app has a backend that should refuse old clients, see [Your server](#your-server-optional) below.

## Your server (optional)

Use this when the app's own server should know the latest App Store version and refuse clients that are too old. taool does two things for it:

1. **The update policy**, at `GET https://api.taool.com/v1/updates/{bundleId}/{ios|macos}/policy`: the app's recent versions, plus the minimum version the developer set in the taool app (with taool Pro; without it the answer has no minimum and nothing is refused). The server reads it every minute or so. It replaces the latest and minimum versions servers usually keep in their config.
2. **A release webhook**, which is optional: an authenticated POST when a new version goes live, for the server to act on (send a push, post to Slack).

The server sends only the app's **server key**, `taool_secret_…`, as `Authorization: Bearer {server key}`: never the taool key the app ships (`taool_public_…`), which servers don't use. The developer makes it in the taool app, on the app's page under TaoolKit → Server Keys (Create Key, shown once), which needs one of their App Store Connect keys in taool to cover the app. It's secret: put it in the server's secrets, e.g. `Taool:ServerKey`, never in code or in the app. It reads the policy of the taool account that made it, so the developer makes it from the account whose taool key is in the app. It's at `api.taool.com`, never `kit.taool.com`, the host apps call, which answers it with a 404.

If the app has update prompts (above), it shows them itself, so the server only needs to refuse clients that are too old, and the app calls `TaoolUpdates.serverRequiredUpdate()` when the server answers 426 (see Update prompts above).

### The policy

```json
{
  "appId": 1234567890,
  "bundleId": "com.example",
  "platform": "ios",
  "minimumVersion": "1.8.0",
  "latest": { "version": "1.8.8", "releasedAt": "2026-09-22T16:35:34Z", "minimumOsVersion": "26.2", "releaseNotes": "…" },
  "versions": [ { "version": "1.8.8", "releasedAt": "2026-09-22T16:35:34Z", "minimumOsVersion": "26.2" }, … ],
  "requireVersion": true
}
```

- `minimumVersion` and `latest` can be missing: the API leaves out null values, so read a missing field as null.
- `requireVersion` is strict mode, and only there when it's on: a missing one is `false`. See Refusing old clients.
- The answer also has fields for TaoolKit's own UI (`language`, `messages`, `whatsNew`). A server ignores them.
- A 404 (`unknown_app`) means the account that made the server key no longer has the app in taool. Treat it as "no requirements". A 401 is a wrong or revoked key, or another app's (`sdk_key`: the app's taool key, sent where the server key goes): refuse nobody either, and tell the developer.
- Answers carry `Cache-Control: private, max-age=60` and an `ETag`. Read the policy **at most every minute**, send `If-None-Match`, and keep the last good answer in memory.
- **Fail open:** if taool can't be reached, keep using the last answer. With none, refuse nobody. taool being down must never lock users out.

**Comparing versions:** split on `.` and compare each part as a number, treating a missing part as 0. So `1.10` > `1.9`, and `1.8` == `1.8.0`. Never compare version strings as text.

**A client must update** when its version is below `minimumVersion`.

**An update is available** when `latest.version` is newer than the client's version. The server doesn't know the device's OS, and a device may be too old for the latest version. Only use this to *inform* clients (e.g. a response header), never to refuse them.

### Refusing old clients

The app must send its version with each request. Many apps already do, e.g. in an `X-App-Version` header with `CFBundleShortVersionString`, which TaoolKit gives as `TaoolUpdates.appVersion`. If it doesn't, add that to the app's networking code first.

Refuse clients that must update with **HTTP 426 Upgrade Required** and a JSON body the app can recognize, e.g. `{"error":"update_required"}`. Let requests without a version header through, since older builds may not send one, unless the policy has `requireVersion: true`: that's **strict mode**, which the developer turns on in the taool app once every build still in use sends the header. Then refuse those too.

Check only the routes the app calls. Other callers never send a version: taool's own release webhook, health checks, web pages, other services. In strict mode they would all be refused.

The developer controls who is refused from the taool app, and taool refuses a minimum above the latest release. Don't add a second minimum in config.

#### ASP.NET Core (minimal API)

```csharp
// Program.cs: one long-lived instance, so the policy is kept between requests.
builder.Services.AddSingleton(new TaoolUpdates(
    new HttpClient(new SocketsHttpHandler { PooledConnectionLifetime = TimeSpan.FromMinutes(15) }) { Timeout = TimeSpan.FromSeconds(10) },
    builder.Configuration["Taool:ServerKey"]!, bundleId: "com.example", platform: "ios"));

// After routing/auth middleware, before the endpoints, for the routes the app calls only
// (here everything under /api; not taool's webhook, health checks or web pages):
app.UseWhen(context => context.Request.Path.StartsWithSegments("/api"), api => api.Use(async (context, next) =>
{
    var version = context.Request.Headers["X-App-Version"].ToString();
    if (await context.RequestServices.GetRequiredService<TaoolUpdates>().MustUpdateAsync(version, context.RequestAborted))
    {
        context.Response.StatusCode = StatusCodes.Status426UpgradeRequired;
        await context.Response.WriteAsJsonAsync(new { error = "update_required" });
        return;
    }
    await next();
}));
```

```csharp
// TaoolUpdates.cs
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;

public sealed record TaoolPolicy(string? MinimumVersion, TaoolRelease? Latest, bool RequireVersion);
public sealed record TaoolRelease(string Version, DateTime ReleasedAt, string? MinimumOsVersion, string? ReleaseNotes);

/// <summary>taool's update policy for one app and platform: read with the app's server key at most every minute, and failing open.</summary>
public sealed class TaoolUpdates(HttpClient http, string serverKey, string bundleId, string platform)
{
    private static readonly TimeSpan RefreshEvery = TimeSpan.FromMinutes(1);
    private readonly SemaphoreSlim _gate = new(1, 1);
    private TaoolPolicy? _policy;
    private string? _etag;
    private DateTime _checkedAt = DateTime.MinValue;

    /// <summary>
    /// Below the minimum version, or in strict mode, no version at all. False whenever the
    /// policy is unknown.
    /// </summary>
    public async Task<bool> MustUpdateAsync(string? version, CancellationToken ct) =>
        await GetAsync(ct) is { } policy && (string.IsNullOrEmpty(version)
            ? policy.RequireVersion
            : policy.MinimumVersion is { } minimum && Compare(version, minimum) < 0);

    /// <summary>The latest App Store version, for an "update available" header. Null when unknown.</summary>
    public async Task<string?> LatestVersionAsync(CancellationToken ct) => (await GetAsync(ct))?.Latest?.Version;

    public async Task<TaoolPolicy?> GetAsync(CancellationToken ct)
    {
        if (DateTime.UtcNow - _checkedAt < RefreshEvery) return _policy;
        if (!await _gate.WaitAsync(0, ct)) return _policy; // another request is refreshing
        try
        {
            var request = new HttpRequestMessage(HttpMethod.Get,
                $"https://api.taool.com/v1/updates/{Uri.EscapeDataString(bundleId)}/{platform}/policy");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", serverKey);
            if (_etag is not null) request.Headers.IfNoneMatch.Add(new EntityTagHeaderValue(_etag));
            using var response = await http.SendAsync(request, ct);
            if (response.StatusCode == HttpStatusCode.OK)
            {
                _policy = await response.Content.ReadFromJsonAsync<TaoolPolicy>(ct);
                _etag = response.Headers.ETag?.Tag;
            }
            else if (response.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            {
                _policy = null; // no app for this key, or a wrong one: refuse nobody
            }
            // 304: unchanged. Anything else: keep the last answer.
        }
        catch (Exception) when (!ct.IsCancellationRequested)
        {
            // taool unreachable: keep the last answer.
        }
        finally
        {
            _checkedAt = DateTime.UtcNow;
            _gate.Release();
        }
        return _policy;
    }

    /// <summary>Version strings compared number by number: "1.10" &gt; "1.9", "1.8" == "1.8.0".</summary>
    public static int Compare(string a, string b)
    {
        var x = a.Split('.');
        var y = b.Split('.');
        for (var i = 0; i < Math.Max(x.Length, y.Length); i++)
        {
            var order = Part(x, i).CompareTo(Part(y, i));
            if (order != 0) return order;
        }
        return 0;
    }

    private static long Part(string[] parts, int i) =>
        i < parts.Length && long.TryParse(new string(parts[i].TakeWhile(char.IsAsciiDigit).ToArray()), out var n) ? n : 0;
}
```

For both iOS and a separate macOS version (a Mac app has its own version numbers), register one `TaoolUpdates` per platform. Pick one by a header the app sends with `TaoolUpdates.platform` (`ios` or `macos`), such as `X-App-Platform`, beside its `X-App-Version`.

### The release webhook (optional)

In the taool app, open TaoolKit → Update Prompts → the app → Webhook, enter an `https` URL on the server, and pick how each POST proves it's taool's. Ask the developer which they picked: a POST carries one of the two, never both.

- **Authorization header:** each POST carries an `Authorization` header with exactly the value the developer typed there (`Bearer` included if they use it; the taool app can make a random one). Put that value in the server's secrets, e.g. `Taool:WebhookAuthorization`.
- **Signature:** taool shows a **signing secret**; put it in the server's secrets, e.g. `Taool:WebhookSecret`. Each POST is signed with it.

Either value *is* secret. When a new version goes live, taool POSTs:

```json
{ "type": "version.released", "appId": 1234567890, "bundleId": "com.example", "platform": "ios",
  "version": "1.8.9", "releasedAt": "2026-09-30T08:00:00Z", "minimumOsVersion": "26.2", "releaseNotes": "…" }
```

- The headers are `Taool-Event: version.released`, then either `Authorization` as the developer set it, or `Taool-Signature: t={unix seconds},v1={hex}`, where `v1` is HMAC-SHA256 of `"{t}.{raw body}"` keyed with the signing secret's UTF-8 bytes.
- The "Send Test" button in the taool app sends `"type": "test"`, checked the same way.
- **Check every delivery:** compare the Authorization header with the server's copy in constant time; or check the signature against the *raw* body, in constant time, and refuse a `t` more than 5 minutes old. Answer 2xx quickly; taool retries after 1 and 10 minutes otherwise.
- **That check is the authentication**, not the server's own sign-in: the route must take requests the server's auth doesn't recognize, so if the server requires authorization by default (a fallback policy), mark it `.AllowAnonymous()`; its auth middleware may try taool's Authorization header as a token of its own, which fails harmlessly there. Keep it out of the version check too (see Refusing old clients).
- Don't use the webhook as the only way the server learns the latest version: deliveries can be missed. Reading the policy stays the source of truth.

```csharp
app.MapPost("/hooks/taool", async (HttpRequest request, IConfiguration config) =>
{
    using var reader = new StreamReader(request.Body);
    var body = await reader.ReadToEndAsync();
    // Whichever the developer picked: configure only that one.
    if (!TaoolWebhook.IsFromTaool(request, body, config["Taool:WebhookAuthorization"], config["Taool:WebhookSecret"]))
        return Results.Unauthorized();

    var release = System.Text.Json.JsonSerializer.Deserialize<TaoolWebhookEvent>(body,
        new System.Text.Json.JsonSerializerOptions(System.Text.Json.JsonSerializerDefaults.Web))!;
    if (release.Type == "version.released")
    {
        // e.g. tell users on older versions, clear a cache, post to Slack.
    }
    return Results.Ok();
}).AllowAnonymous();   // checked above, not signed in
```

```csharp
using System.Security.Cryptography;
using System.Text;

public sealed record TaoolWebhookEvent(string Type, long AppId, string BundleId, string Platform, string Version,
    DateTime ReleasedAt, string? MinimumOsVersion, string? ReleaseNotes);

public static class TaoolWebhook
{
    /// The developer's Authorization header when one is configured, else the signature.
    public static bool IsFromTaool(HttpRequest request, string body, string? authorization, string? secret) =>
        !string.IsNullOrEmpty(authorization)
            ? CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(request.Headers.Authorization.ToString()), Encoding.UTF8.GetBytes(authorization))
            : !string.IsNullOrEmpty(secret) && IsValid(request.Headers["Taool-Signature"].ToString(), body, secret);

    public static bool IsValid(string header, string body, string secret)
    {
        var parts = header.Split(',').Select(p => p.Split('=', 2)).Where(p => p.Length == 2).ToDictionary(p => p[0], p => p[1]);
        if (!parts.TryGetValue("t", out var t) || !long.TryParse(t, out var timestamp) || !parts.TryGetValue("v1", out var signature))
            return false;
        if (Math.Abs(DateTimeOffset.UtcNow.ToUnixTimeSeconds() - timestamp) > 300)
            return false;
        var expected = HMACSHA256.HashData(Encoding.UTF8.GetBytes(secret), Encoding.UTF8.GetBytes($"{t}.{body}"));
        return CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(Convert.ToHexString(expected).ToLowerInvariant()), Encoding.ASCII.GetBytes(signature));
    }
}
```

### Check the server

1. `curl -H "Authorization: Bearer taool_secret_…" "https://api.taool.com/v1/updates/{bundleId}/ios/policy"` should answer 200 with the app's versions. A 401 means the key is wrong, revoked or another app's, and a 404 that the account that made it no longer has the app in taool.
2. Send a request with a version header below the minimum and expect 426. Send one without the header and expect it to pass, or with strict mode on in the taool app (within a couple of minutes), expect 426. Check that the webhook route and health checks still pass without the header.
3. For the webhook, press "Send Test" in the taool app. The server should answer 2xx, and the taool app shows the status it got.
