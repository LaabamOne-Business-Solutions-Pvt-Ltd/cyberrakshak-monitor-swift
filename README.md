# CyberRakshakMonitor (Swift)

Cyber Rakshak error monitoring for **iOS 13+** (and macOS 10.15+): what goes wrong in your app lands on your site's
**Errors** page in the Cyber Rakshak console, scrubbed of secrets on the device before it leaves. One Swift file,
Foundation only, no dependencies.

> **Compiled and tested by our CI** (`.github/workflows/test.yml`, 2026-11-21: Xcode 26.6, Apple Swift 6.3.3, no
> warnings): built for macOS and for iOS devices (arm64), and its tests, sending to a stand-in console, pass on macOS 26.7
> and on an iOS 26.5 Simulator (iPhone 17 Pro). **Not yet run on a real iPhone** or in a shipping app: check that your
> app's first test crash reaches your Errors page.

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
.package(url: "https://github.com/LaabamOne-Business-Solutions-Pvt-Ltd/cyberrakshak-monitor-swift", from: "1.1.0"),
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

The key is your site's app key (`crk_…`), made on the site's **Security scan** tab: under **Apps, servers and scripts**, press **Make an app key**.

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
| `scrubNames` | Names of your own whose values are removed, like `password=`: whole words, `A-Z a-z 0-9 _ . -`, at most 50. Only adds to the built-in rules. |
| `scrubPatterns` | Regular expressions of your own (`NSRegularExpression` syntax), as strings: what they match becomes `[removed]`. At most 20; one that does not compile, or matches an empty text, is left out. Only adds to the built-in rules. |

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
`AKIA`…); email addresses; IBANs (mod-97 checked); card numbers (Luhn-checked); the value after `pin`, `otp`, `cvv`,
`iban`, `sort_code`, `card_number`, `account_number`, `cookie`, `signature`, `authorization` and the like, as whole
words only (`company:` and `spinning:` stay); long hex and random-looking runs. They become `[removed]`, `[token]`,
`[email]`, `[iban]` or `[card]`, and a context entry whose name is one of these names is sent as `[removed]`.
`scrubNames` and `scrubPatterns` add names and patterns of your own; nothing switches the built-in rules off. The
console scrubs everything again when it arrives.

At most 10 problems go per request, each request under 64 KB; repeats of one problem are counted, not resent; what
could not be sent waits on the device and is tried again later, never before `Retry-After`.

Full documentation, the same library for other platforms, and every file's SHA-256:
**https://app.cyberrakshak.ai/sdk/README.md**

## Development

On a Mac with Xcode (Swift 5.7 or later) and Node.js 18+ (for the end-to-end test's fake server, on 127.0.0.1 only):

```sh
swift build
swift test                                    # the end-to-end test starts the fake server itself
xcodebuild build -scheme CyberRakshakMonitor -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
# on a Simulator, with a fake server already running (node Tests/CyberRakshakMonitorTests/Fixtures/fake-server.mjs):
TEST_RUNNER_CR_TEST_SERVER=http://127.0.0.1:PORT xcodebuild test -scheme CyberRakshakMonitor -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

`Sources/CyberRakshakMonitor/CyberRakshakMonitor.swift`, `LICENSE` and the two files in `Tests/…/Fixtures` are byte for
byte the ones served at https://app.cyberrakshak.ai/sdk/ and are not edited here: they are changed in the Cyber Rakshak
console's repository and copied by its `scripts/sdk-packages.mjs`.

## For maintainers

Swift Package Manager reads versions from git tags (`1.0.0`, no `v`); there is no registry to publish to. A release:
copy the new file in (the console's `scripts/sdk-packages.mjs`; a fix goes into the console's copy first), add the
CHANGELOG entry, push, wait for this repository's CI (macOS and the iOS Simulator) to pass, then tag.

## Licence

MIT. Copyright (c) 2026 Laabam One Business Solutions (OPC) Private Limited. See [LICENSE](LICENSE).
