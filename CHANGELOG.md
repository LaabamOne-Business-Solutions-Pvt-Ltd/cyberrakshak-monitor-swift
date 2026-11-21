# Changelog

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
