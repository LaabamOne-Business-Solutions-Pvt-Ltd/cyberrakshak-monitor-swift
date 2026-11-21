# Changelog

## [1.0.0] - 2026-11-21 (not tagged: not yet compiled by us)

The iOS library served at https://app.cyberrakshak.ai/sdk/ios/ since 2026-11-21, as a Swift package
(`CyberRakshakMonitor`, iOS 13+, macOS 10.15+).

- Reports uncaught Objective-C exceptions at the next launch (the previous handler still runs). Not Swift runtime
  traps or signals.
- `start`, `setRoute`, `captureError`, `captureMessage`, `flush`, `scrub`; options `key`, `endpoint`, `release`,
  `environment`, `enabled`, `sampleRate`, `beforeSend`, `debug`, `context`.
- Secrets scrubbed on the device before anything leaves, by the rules every Cyber Rakshak library shares.
