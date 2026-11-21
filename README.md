# CyberRakshakMonitor (Swift)

Cyber Rakshak error monitoring for **iOS 13+** (and macOS 10.15+): what goes wrong in your app lands on your site's
**Errors** page in the Cyber Rakshak console, scrubbed of secrets on the device before it leaves. One Swift file,
Foundation only, no dependencies.

> **1.0.0 has not yet been compiled by us.** The library was written without a Swift compiler at hand and has not been
> built or run by Cyber Rakshak yet; neither have this package's tests. Build it in your app before you rely on it, and
> tell us what the compiler says. The first build is this repository's CI on macOS (`.github/workflows/test.yml`).

## What it catches

- **Uncaught Objective-C exceptions** (`NSException`): written to the app's Application Support folder at once, the
  handler that was there before runs as it would have, and the report is sent at the next launch.
- Anything you report yourself: `captureError(error)` and `captureMessage(text)`.

**Not caught**: Swift runtime traps (a force-unwrapped nil, an index out of range, `fatalError`, a failed precondition)
and signals (SIGSEGV, SIGABRT from other causes): those end the app without a report.

## Install

Swift Package Manager. In Xcode: File → Add Package Dependencies…, then
`https://github.com/LaabamOne-Business-Solutions-Pvt-Ltd/cyberrakshak-monitor-swift`. In a `Package.swift`:

```swift
.package(url: "https://github.com/LaabamOne-Business-Solutions-Pvt-Ltd/cyberrakshak-monitor-swift", from: "1.0.0"),
// and in your target: .product(name: "CyberRakshakMonitor", package: "cyberrakshak-monitor-swift")
```

## Use

```swift
import CyberRakshakMonitor
CyberRakshakMonitor.start(.init(key: "crk_…", release: "1.4.2+57", environment: "production"))  // as early as you can
CyberRakshakMonitor.setRoute("Checkout")                       // the screen now shown
CyberRakshakMonitor.captureError(error, context: ["step": 2])
CyberRakshakMonitor.captureMessage("Payment provider answered slowly")
```

The key is your site's app key (`crk_…`), from the site's **Errors** page.

## Options (`CyberRakshakMonitor.Options`)

| Option | Meaning |
|---|---|
| `key` | Your site's app key, `crk_` and 32 letters or digits. Required; with no valid key the library does nothing. |
| `endpoint` | Where reports go. Default `https://app.cyberrakshak.ai/api/v1/app-reports`. |
| `release` | Your version or build (`A-Z a-z 0-9 . _ + -`, at most 60), so a problem shows the release it started in. |
| `environment` | `production`, `staging`… (`a-z 0-9 _ -`, at most 30). |
| `enabled` | `false` sends nothing (default `true`). |
| `sampleRate` | 0 to 1: the share of problems sent (default 1, all). |
| `beforeSend` | Gets each problem, already scrubbed; return it (changed if you like) or `nil` to drop it. |
| `debug` | Says on the console what the library does and why something was not sent. The key is never printed. |
| `context` | Values sent with every problem: at most 20, strings (300 characters), numbers, true/false. |

Functions: `start(_:)`, `setRoute(_:)`, `captureError(_:route:context:level:)`,
`captureMessage(_:level:route:context:)` (level `warning` by default), `flush(timeout:)` (blocks: call it off the main
thread; `true` when nothing is left waiting), `scrub(_:)` (shows what a text would become).

## What is sent, and what never is

Sent, per problem: its kind (exception, crash, log message), its message, its call stack symbols, the screen
(`setRoute`), the level, how many times it happened and when last; with each request: the library's name and version,
the OS and its version (`ios 18.1`), your release and environment.

Never sent: what a user types, form fields, request or response bodies, headers, cookies, device identifiers,
location, contacts.

**Scrubbed on the device before anything leaves**: query strings; `Bearer`/`Basic` values; the value after `password`,
`secret`, `token`, `api_key` and the like; JSON Web Tokens; keys that say what they are (`crk_`, `sk_live_`, `ghp_`,
`AKIA`…); email addresses; card numbers (Luhn-checked); long hex and random-looking runs. They become `[removed]`,
`[token]`, `[email]` or `[card]`. The console scrubs everything again when it arrives.

At most 10 problems go per request, each request under 64 KB; repeats of one problem are counted, not resent; what
could not be sent waits on the device and is tried again later, never before `Retry-After`.

Full documentation, the same library for other platforms, and every file's SHA-256:
**https://app.cyberrakshak.ai/sdk/README.md**

## Development

On a Mac with Xcode (Swift 5.7 or later) and Node.js 18+ (for the end-to-end test's fake server, on 127.0.0.1 only):

```sh
swift build
swift test
xcodebuild build -scheme CyberRakshakMonitor -destination 'generic/platform=iOS Simulator'
```

`Sources/CyberRakshakMonitor/CyberRakshakMonitor.swift`, `LICENSE` and the two files in `Tests/…/Fixtures` are byte for
byte the ones served at https://app.cyberrakshak.ai/sdk/ and are not edited here: they are changed in the Cyber Rakshak
console's repository and copied by its `scripts/sdk-packages.mjs`.

## For maintainers

Swift Package Manager reads versions from git tags (`1.0.0`); there is no registry to publish to. **Do not tag 1.0.0
yet**: first `swift build`, `swift test` and the iOS build above must pass on a Mac (or this repository's CI), and any
fix goes into the console's copy first, then here. Until then the package can be tried from the `main` branch.

## Licence

MIT. Copyright (c) 2026 Laabam One Business Solutions (OPC) Private Limited. See [LICENSE](LICENSE).
