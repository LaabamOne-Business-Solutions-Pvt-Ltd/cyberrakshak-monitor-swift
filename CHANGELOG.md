# Changelog

## [1.1.0] - unreleased

- Scrubbing, the same rules as every Cyber Rakshak library (the shared `scrub-vectors.json`): IBANs that pass the
  ISO 13616 mod-97 check become `[iban]`; the values after `authorization`, `cookie` / `set-cookie`, `signature`,
  `otp`, `pin`, `cvv`, `cvc`, `iban`, `bban`, `pan`, account number, sort code, card number and bank auth id are
  removed, as whole words only (`company:`, `spinning:` and `japan:` stay).
- `scrubNames` and `scrubPatterns` (the last `Options` parameters, with defaults): names and regular expressions of your own, applied after the built-in
  rules to the message, the stack, the route and context values. They only add: nothing switches the built-in
  rules off. A name or pattern that is not usable is left out (said with `debug`).
- A context entry whose name is a secret name (built in, or one of yours) is sent as `[removed]`.
- The app key's message names where it is made: the site's Security scan tab, Apps, servers and scripts.

## [1.0.0] - 2026-11-21

The iOS library served at https://app.cyberrakshak.ai/sdk/ios/ since 2026-11-21, as a Swift package
(`CyberRakshakMonitor`, iOS 13+, macOS 10.15+).

- Reports uncaught Objective-C exceptions at the next launch (the previous handler still runs). Not Swift runtime
  traps or signals.
- `start`, `setRoute`, `captureError`, `captureMessage`, `flush`, `scrub`; options `key`, `endpoint`, `release`,
  `environment`, `enabled`, `sampleRate`, `beforeSend`, `debug`, `context`.
- Secrets scrubbed on the device before anything leaves, by the rules every Cyber Rakshak library shares.
- Compiled by CI with Xcode 26.6 (Apple Swift 6.3.3) for macOS and iOS devices; tests pass on macOS 26.7 and an iOS 26.5
  Simulator. Not yet run on a real iPhone.
