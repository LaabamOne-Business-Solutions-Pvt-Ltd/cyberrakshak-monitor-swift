// Cyber Rakshak error monitoring for iOS (Swift), version 1.1.0
// Docs: https://app.cyberrakshak.ai/sdk/README.md
// Copyright Laabam One Business Solutions (OPC) Private Limited
// Released under the MIT licence: https://app.cyberrakshak.ai/sdk/LICENSE
//
// For Swift 5.5 or later, iOS 13 or later (macOS 10.15 too), Foundation only. Compiled and tested by Cyber Rakshak's CI
// (2026-11-21: Xcode 26.6, Apple Swift 6.3.3, no warnings): built for macOS and for iOS devices, and its tests passed on
// macOS 26.7 and on an iOS 26.5 Simulator, sending to a stand-in console. Not yet run on a real iPhone.
//
// What it catches: Objective-C exceptions (NSException) that nobody caught: they are written to the app's Application
// Support folder at once, the handler that was there before runs as it would have, and the report is sent at the next
// launch. What this version does NOT catch: Swift runtime traps (a force-unwrapped nil, an index out of range,
// fatalError, a failed precondition) and signals (SIGSEGV, SIGABRT from other causes): those end the app without a
// report. Errors you catch yourself, report with captureError.
//
//   CyberRakshakMonitor.start(.init(key: "crk_…", release: "1.4.2+57", environment: "production"))
//   CyberRakshakMonitor.setRoute("Checkout")                                    // the screen now shown
//   CyberRakshakMonitor.captureError(error, context: ["step": 2])
//   CyberRakshakMonitor.captureMessage("Payment provider answered slowly")
//
// Sent: the error's text and its stack (call stack symbols), the screen, when and how often, and the OS version.
// Secrets are scrubbed on the device before anything leaves (email addresses, tokens and keys, password=... values,
// query strings, card numbers). Nothing the user types, no device id, no location, no contacts. Repeats of one problem
// are counted, not resent; at most 10 per request; what could not be sent waits on the device and is tried again.
//
// Nothing in here may throw into your app or slow it: a monitor that fails must never become the app's second problem.

import Foundation

public enum CyberRakshakMonitor {
    public static let version = "1.1.0"
    public static let defaultEndpoint = "https://app.cyberrakshak.ai/api/v1/app-reports"

    /// Settings. beforeSend may change a problem or return nil to drop it; context goes with every problem.
    public struct Options {
        public var key: String
        public var endpoint: String
        public var release: String?
        public var environment: String?
        public var enabled: Bool
        public var sampleRate: Double
        public var beforeSend: ((Problem) -> Problem?)?
        public var debug: Bool
        public var context: [String: Any]
        /// Names of your own whose values are removed, like password= (whole words, A-Z a-z 0-9 _ . -, at most 50). Only adds to the built-in rules.
        public var scrubNames: [String]
        /// Regular expressions of your own (NSRegularExpression syntax): what they match is removed (at most 20). Only adds to the built-in rules.
        public var scrubPatterns: [String]

        public init(key: String, endpoint: String = CyberRakshakMonitor.defaultEndpoint, release: String? = nil, environment: String? = nil,
                    enabled: Bool = true, sampleRate: Double = 1, beforeSend: ((Problem) -> Problem?)? = nil, debug: Bool = false,
                    context: [String: Any] = [:], scrubNames: [String] = [], scrubPatterns: [String] = []) {
            self.key = key
            self.endpoint = endpoint
            self.release = release
            self.environment = environment
            self.enabled = enabled
            self.sampleRate = sampleRate
            self.beforeSend = beforeSend
            self.debug = debug
            self.context = context
            self.scrubNames = scrubNames
            self.scrubPatterns = scrubPatterns
        }
    }

    /// One problem as it is sent (beforeSend gets it scrubbed).
    public struct Problem {
        public var kind: String
        public var message: String
        public var stack: String?
        public var route: String?
        public var level: String
        public var count: Int
        public var at: String
        public var context: [String: Any]?
    }

    // MARK: State

    private static let sdkName = "cyberrakshak-ios"
    private static let kinds: Set<String> = ["exception", "crash", "promise", "log", "http", "script"]
    private static let maxBatch = 10
    private static let maxWaiting = 50
    private static let maxFiles = 20
    private static let maxMessage = 4000
    private static let maxStack = 16000
    private static let maxRoute = 200
    private static let maxContext = 20
    private static let maxContextKey = 40
    private static let maxContextValue = 300
    private static let maxCount = 100_000
    private static let bodyLimit = 60_000
    private static let sendAfter: TimeInterval = 2
    private static let sendTimeout: TimeInterval = 5
    private static let backoffFirst: TimeInterval = 2
    private static let backoffMax: TimeInterval = 300
    private static let blocked: TimeInterval = 3600

    private final class State: @unchecked Sendable {
        let dir: URL
        let key: String
        let endpoint: URL
        let release: String?
        let environment: String?
        let sampleRate: Double
        let beforeSend: ((Problem) -> Problem?)?
        let debug: Bool
        let context: [String: Any]
        let platform: String
        let runtime: String
        var order: [String] = []
        var waiting: [String: Problem] = [:]
        var scheduled = false
        var route: String?
        var notBefore = Date.distantPast
        var backoff: TimeInterval = 0
        var blockedUntil = Date.distantPast
        var logged = Set<Int>()
        var fileCounter = 0

        init(dir: URL, key: String, endpoint: URL, options: Options, release: String?, environment: String?, platform: String, runtime: String) {
            self.dir = dir
            self.key = key
            self.endpoint = endpoint
            self.release = release
            self.environment = environment
            self.sampleRate = options.sampleRate.isNaN ? 1 : min(1, max(0, options.sampleRate))
            self.beforeSend = options.beforeSend
            self.debug = options.debug
            self.context = options.context
            self.platform = platform
            self.runtime = runtime
        }
    }

    /// Everything shared, behind one lock (a box, so Swift 6's concurrency checks accept it).
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var state: State?
        var previousHandler: (@convention(c) (NSException) -> Void)?
        var installed = false
    }

    private static let shared = Shared()

    /// scrubNames and scrubPatterns as start() last set them, behind their own lock: scrub() runs where the state's lock
    /// may be held, and an NSLock is not reentrant.
    private final class Extras: @unchecked Sendable {
        let lock = NSLock()
        var names: NSRegularExpression?
        var keys: NSRegularExpression?
        var patterns: [NSRegularExpression] = []
    }

    private static let extras = Extras()
    private static let work = DispatchQueue(label: "ai.cyberrakshak.monitor", qos: .utility)
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = sendTimeout
        configuration.timeoutIntervalForResource = sendTimeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    // MARK: API

    /// Starts monitoring: call it once, as early as you can (application(_:didFinishLaunchingWithOptions:) or your App's init).
    public static func start(_ options: Options) {
        guard options.enabled else { return }
        let key = options.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard matches(key, #"^crk_[A-Za-z0-9]{32}$"#) else {
            say(options.debug, "not started: key must be your site's crk_ app key (its Security scan tab, Apps, servers and scripts)")
            return
        }
        setExtras(options)
        var release = options.release
        if let r = release, !matches(r, #"^[A-Za-z0-9._+\-]{1,60}$"#) {
            say(options.debug, "release left out: it may hold only A-Z a-z 0-9 . _ + - (at most 60)")
            release = nil
        }
        var environment = options.environment?.lowercased()
        if let e = environment, !matches(e, #"^[a-z0-9_-]{1,30}$"#) {
            say(options.debug, "environment left out: it may hold only a-z 0-9 _ - (at most 30)")
            environment = nil
        }
        let endpoint = URL(string: options.endpoint).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil } ?? URL(string: defaultEndpoint)!
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "app").appendingPathComponent("CyberRakshakMonitor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var platform = "mobile"
        var name = "ios"
        #if os(macOS)
            platform = "desktop"
            name = "macos"
        #elseif os(tvOS)
            name = "tvos"
        #elseif os(watchOS)
            name = "watchos"
        #endif
        let runtime = "\(name) \(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
        let s = State(dir: dir, key: key, endpoint: endpoint, options: options, release: release, environment: environment, platform: platform, runtime: runtime)
        shared.lock.lock()
        shared.state = s
        if !shared.installed {
            shared.installed = true
            shared.previousHandler = NSGetUncaughtExceptionHandler()
            NSSetUncaughtExceptionHandler { exception in
                CyberRakshakMonitor.onException(exception)
            }
        }
        shared.lock.unlock()
        // What the last run could not send (its crash, most often) goes now, in the background.
        work.async { drain(s) }
        debug(s, "started: \(sdkName) \(version) reporting to \(endpoint.absoluteString)")
    }

    /// Reports an error you caught.
    public static func captureError(_ error: Error, route: String? = nil, context: [String: Any] = [:], level: String = "error") {
        let ns = error as NSError
        var message = String(describing: error)
        if message.isEmpty { message = "\(ns.domain) \(ns.code)" }
        let stack = Thread.callStackSymbols.dropFirst().joined(separator: "\n")
        capture(kind: "exception", message: "\(type(of: error)): \(message)", stack: stack, route: route, context: context, level: level)
    }

    /// Reports a message; level "warning" (the default) or "error".
    public static func captureMessage(_ text: String, level: String = "warning", route: String? = nil, context: [String: Any] = [:]) {
        capture(kind: "log", message: text, stack: nil, route: route, context: context, level: level)
    }

    /// The screen now shown: sent as the route of what goes wrong next.
    public static func setRoute(_ route: String?) {
        shared.lock.lock()
        shared.state?.route = route
        shared.lock.unlock()
    }

    /// Sends what is waiting now and waits for it, at most `timeout` seconds. It blocks: call it off the main thread.
    @discardableResult
    public static func flush(timeout: TimeInterval = 2) -> Bool {
        guard let s = current() else { return true }
        let done = DispatchSemaphore(value: 0)
        let result = Flag()
        work.async {
            sendWaiting(s, timeout: min(timeout, sendTimeout))
            drain(s)
            shared.lock.lock()
            result.value = s.waiting.isEmpty
            shared.lock.unlock()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success && result.value
    }

    /// Values a closure on another queue hands back (a class, so Swift 6's concurrency checks accept it).
    private final class Flag: @unchecked Sendable {
        var value = false
    }

    private final class Reply: @unchecked Sendable {
        var status = 0
        var retryAfter: TimeInterval?
    }

    // MARK: Scrubbing: the same rules, in the same order, in every Cyber Rakshak library

    private struct Rule: @unchecked Sendable {
        let regex: NSRegularExpression
        let replace: (NSTextCheckingResult, NSString) -> String?
    }

    private static func rule(_ pattern: String, _ options: NSRegularExpression.Options = [], _ replace: @escaping (NSTextCheckingResult, NSString) -> String?) -> Rule? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        return Rule(regex: regex, replace: replace)
    }

    private static let rules: [Rule] = [
        // A query string: ?name=... up to a space or quote. Where a request went is kept, never what it asked.
        rule(#"\?[A-Za-z0-9_.%-]+[=&][^ \t\r\n#"'<>]*"#) { _, _ in "" },
        // Authorization values.
        rule(#"(bearer|basic) +([A-Za-z0-9._~+/=-]{8,})"#, [.caseInsensitive]) { m, s in
            let value = s.substring(with: m.range(at: 2))
            return matches(value, #"[0-9A-Z._~+/=]"#, anywhere: true) ? s.substring(with: m.range(at: 1)) + " [token]" : nil
        },
        // password=..., "client_secret": "...", x-api-key: ... (the name is kept, the value is not). The match starts at
        // the word (what comes before it is kept as it is) and allows 40 more name characters after it.
        rule(#"((?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|credential|session[_-]?id)[A-Za-z0-9_-]{0,40}\\?["']?[ ]*[=:][ ]*\\?["']?)[^ \t\r\n&,;"'<>\\]+"#, [.caseInsensitive]) { m, s in
            s.substring(with: m.range(at: 1)) + "[removed]"
        },
        // JSON Web Tokens (a header of at most 500 characters).
        rule(#"eyJ[A-Za-z0-9_-]{1,500}\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)?"#) { _, _ in "[token]" },
        // Keys that say what they are.
        rule(#"(?<![A-Za-z0-9])(?:crk_|crw_|sk_live_|sk_test_|pk_live_|pk_test_|rk_live_|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xoxb-|xoxp-|xoxa-|AKIA|ASIA|AIza)[A-Za-z0-9_-]{10,}"#) { _, _ in "[token]" },
        // Email addresses (at most 64 characters before the @, as in an address).
        rule(#"[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#) { _, _ in "[email]" },
        // IBANs: two capital letters, two digits, then 11 to 30 capitals or digits (or the same in groups of four, single
        // spaces between), 15 to 34 in all, passing the ISO 13616 mod-97 check. Before cards: an IBAN holds a digit run.
        rule(#"(?<![A-Za-z0-9])[A-Z]{2}[0-9]{2}(?:[A-Z0-9]{11,30}|(?: [A-Z0-9]{4}){2,7}(?: [A-Z0-9]{1,4})?)(?![A-Za-z0-9])"#) { m, s in
            ibanOk(s.substring(with: m.range)) ? "[iban]" : nil
        },
        // Card numbers: 13 to 19 digits (single spaces or dashes between) that pass the Luhn check.
        rule(#"(?<![0-9])[0-9](?:[ -]?[0-9]){12,18}"#) { m, s in
            let digits = s.substring(with: m.range).filter { $0 >= "0" && $0 <= "9" }
            return luhn(String(digits)) ? "[card]" : nil
        },
        // pin: 1234, "iban": "...", set-cookie: ..., x-tink-signature=...: these names only as whole words (not right after a
        // letter or digit, the separator right after the name), so company:, spinning: and japan: stay; the value goes as in
        // the password rule. After IBANs and cards, so a value with spaces in it has gone whole already. A value that is
        // Bearer or Basic and a space was handled above.
        rule(#"(?<![A-Za-z0-9])((?:authorization|cookie|signature|otp|pin|cvv|cvc|iban|bban|pan|account[_-]?(?:no|number|num)|sort[_-]?code|card[_-]?number|bank[_-]?auth[_-]?id)\\?["']?[ ]*[=:][ ]*\\?["']?)(?!(?:bearer|basic) )[^ \t\r\n&,;"'<>\\]+"#, [.caseInsensitive]) { m, s in
            s.substring(with: m.range(at: 1)) + "[removed]"
        },
        // Long hex runs: session ids, hashes, keys.
        rule(#"[0-9a-fA-F]{32,}"#) { _, _ in "[token]" },
        // Long random-looking runs: a digit, an upper-case and a lower-case letter in 40 or more of A-Z a-z 0-9 + _ -.
        rule(#"[A-Za-z0-9+_-]{40,}"#) { m, s in
            let run = s.substring(with: m.range)
            let digit = run.contains { $0 >= "0" && $0 <= "9" }
            let upper = run.contains { $0 >= "A" && $0 <= "Z" }
            let lower = run.contains { $0 >= "a" && $0 <= "z" }
            return digit && upper && lower ? "[token]" : nil
        },
    ].compactMap { $0 }

    private static func luhn(_ digits: String) -> Bool {
        var sum = 0
        var double = false
        for ch in digits.reversed() {
            guard var n = ch.wholeNumberValue else { return false }
            if double {
                n *= 2
                if n > 9 { n -= 9 }
            }
            sum += n
            double.toggle()
        }
        return sum % 10 == 0
    }

    /// ISO 13616: the first four characters moved to the end, letters as 10..35, the whole number mod 97 is 1.
    private static func ibanOk(_ text: String) -> Bool {
        let s = Array(text.unicodeScalars.filter { $0 != " " })
        if s.count < 15 || s.count > 34 { return false }
        var rest = 0
        for c in Array(s[4...]) + Array(s[..<4]) {
            let code = Int(c.value)
            let v = code >= 65 ? code - 55 : code - 48
            rest = v > 9 ? (rest * 100 + v) % 97 : (rest * 10 + v) % 97
        }
        return rest == 1
    }

    // A context entry's name that says its value is a secret: the words of the password rule anywhere in it, or one of the
    // whole-word names (at the end, not right after a letter or digit: user_pin, x-tink-signature, not spinning).
    private static let secretNameRule = rule(#"password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|credential|session[_-]?id"#, [.caseInsensitive]) { _, _ in nil }
    private static let wholeNameRule = rule(#"(?:^|[^A-Za-z0-9])(?:authorization|cookie|signature|otp|pin|cvv|cvc|iban|bban|pan|account[_-]?(?:no|number|num)|sort[_-]?code|card[_-]?number|bank[_-]?auth[_-]?id)$"#, [.caseInsensitive]) { _, _ in nil }

    private static func found(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex = regex else { return false }
        return regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func secretName(_ name: String) -> Bool {
        if found(secretNameRule?.regex, name) || found(wholeNameRule?.regex, name) { return true }
        extras.lock.lock()
        let keys = extras.keys
        extras.lock.unlock()
        return found(keys, name)
    }

    private static func apply(_ text: String, _ regex: NSRegularExpression, _ replace: (NSTextCheckingResult, NSString) -> String?) -> String {
        let s = text as NSString
        var result = ""
        var last = 0
        for m in regex.matches(in: text, options: [], range: NSRange(location: 0, length: s.length)) {
            guard let replaced = replace(m, s) else { continue }
            result += s.substring(with: NSRange(location: last, length: m.range.location - last)) + replaced
            last = m.range.location + m.range.length
        }
        if last == 0 && result.isEmpty { return text }
        return result + s.substring(from: last)
    }

    /// What a text looks like once scrubbed: what this library would send. The built-in rules always run, first; then the
    /// names and patterns given as scrubNames and scrubPatterns, which can only add to them.
    public static func scrub(_ text: String) -> String {
        var out = text
        for rule in rules {
            out = apply(out, rule.regex, rule.replace)
        }
        extras.lock.lock()
        let names = extras.names
        let patterns = extras.patterns
        extras.lock.unlock()
        if let names = names {
            out = apply(out, names) { m, s in s.substring(with: m.range(at: 1)) + "[removed]" }
        }
        for pattern in patterns {
            out = pattern.stringByReplacingMatches(in: out, options: [], range: NSRange(location: 0, length: (out as NSString).length), withTemplate: NSRegularExpression.escapedTemplate(for: "[removed]"))
        }
        return out
    }

    /// scrubNames (whole words, at most 50) and scrubPatterns (at most 20; a bad one, or one matching "", is left out).
    private static func setExtras(_ options: Options) {
        var names: [String] = []
        for name in options.scrubNames {
            guard matches(name, #"^[A-Za-z0-9_.-]{1,40}$"#) else {
                say(options.debug, "scrubNames: a name was left out: only A-Z a-z 0-9 _ . - (1 to 40)")
                continue
            }
            if names.count >= 50 {
                say(options.debug, "scrubNames: only the first 50 are used")
                break
            }
            let lower = name.lowercased()
            if !names.contains(lower) { names.append(lower) }
        }
        var patterns: [NSRegularExpression] = []
        for source in options.scrubPatterns {
            if patterns.count >= 20 {
                say(options.debug, "scrubPatterns: only the first 20 are used")
                break
            }
            guard let regex = try? NSRegularExpression(pattern: source) else {
                say(options.debug, "scrubPatterns: a pattern was left out: it does not compile")
                continue
            }
            if regex.firstMatch(in: "", options: [], range: NSRange(location: 0, length: 0)) != nil {
                say(options.debug, "scrubPatterns: a pattern that matches an empty text was left out")
                continue
            }
            patterns.append(regex)
        }
        var namesRegex: NSRegularExpression?
        var keysRegex: NSRegularExpression?
        if !names.isEmpty {
            let alternation = names.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            namesRegex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])((?:"# + alternation + #")\\?["']?[ ]*[=:][ ]*\\?["']?)[^ \t\r\n&,;"'<>\\]+"#, options: [.caseInsensitive])
            keysRegex = try? NSRegularExpression(pattern: "(?:^|[^A-Za-z0-9])(?:" + alternation + ")$", options: [.caseInsensitive])
        }
        extras.lock.lock()
        extras.names = namesRegex
        extras.keys = keysRegex
        extras.patterns = patterns
        extras.lock.unlock()
    }

    private static func matches(_ text: String, _ pattern: String, anywhere: Bool = false) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return anywhere ? regex.firstMatch(in: text, range: range) != nil : regex.firstMatch(in: text, options: [.anchored], range: range)?.range == range
    }

    // MARK: Capturing

    private static func current() -> State? {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        return shared.state
    }

    /// At most `max` UTF-16 units, never cut inside a character.
    private static func clip(_ text: String, _ max: Int) -> String {
        if text.utf16.count <= max { return text }
        var out = ""
        var units = 0
        for scalar in text.unicodeScalars {
            let n = scalar.utf16.count
            if units + n > max { break }
            out.unicodeScalars.append(scalar)
            units += n
        }
        return out
    }

    private static func clean(_ text: String, _ max: Int) -> String {
        return clip(scrub(clip(text, max * 2)), max)
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private static func cleanContext(_ sources: [[String: Any]]) -> [String: Any]? {
        var out: [String: Any] = [:]
        for source in sources {
            for (name, value) in source {
                let key = clip(name, maxContextKey)
                var kept: Any?
                if secretName(name) {
                    kept = "[removed]"
                } else {
                    switch value {
                    case let v as String: kept = clean(v, maxContextValue)
                    case let v as Bool: kept = v
                    case let v as Int: kept = v
                    case let v as Double: kept = v.isFinite ? v : nil
                    case is NSNull: kept = NSNull()
                    default: kept = nil
                    }
                }
                guard let k = kept else { continue }
                if out[key] == nil && out.count >= maxContext { continue }
                out[key] = k
            }
        }
        return out.isEmpty ? nil : out
    }

    private static func capture(kind: String, message: String, stack: String?, route: String?, context: [String: Any], level: String) {
        guard let s = current() else { return }
        let now = Date()
        shared.lock.lock()
        let blockedNow = now < s.blockedUntil
        let screen = s.route
        shared.lock.unlock()
        if blockedNow { return }
        if s.sampleRate < 1 && Double.random(in: 0..<1) >= s.sampleRate { return }
        let draft = Problem(
            kind: kind,
            message: { let m = clean(message, maxMessage); return m.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(no message)" : m }(),
            stack: stack.map { clean($0, maxStack) }.flatMap { $0.isEmpty ? nil : $0 },
            route: (route ?? screen).map { clean($0.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? "", maxRoute) }.flatMap { $0.isEmpty ? nil : $0 },
            level: level == "error" || level == "warning" ? level : (kind == "log" ? "warning" : "error"),
            count: 1,
            at: iso(now),
            context: cleanContext([s.context, context])
        )
        let changed: Problem?
        if let filter = s.beforeSend {
            changed = filter(draft)
        } else {
            changed = draft
        }
        guard let picked = changed, let problem = normalise(picked, kind) else { return }
        enqueue(s, problem)
        schedule(s, after: sendAfter)
    }

    private static func normalise(_ p: Problem, _ fallbackKind: String) -> Problem? {
        let message = clip(p.message, maxMessage)
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        var out = p
        out.kind = kinds.contains(p.kind) ? p.kind : fallbackKind
        out.message = message
        out.stack = p.stack.map { clip($0, maxStack) }
        out.route = p.route.map { clip($0, maxRoute) }
        out.level = p.level == "warning" ? "warning" : "error"
        out.count = min(maxCount, max(1, p.count))
        // Only clipped here: what beforeSend handed back is the app's own choice.
        var context: [String: Any] = [:]
        for (name, value) in p.context ?? [:] where context.count < maxContext {
            switch value {
            case let v as String: context[clip(name, maxContextKey)] = clip(v, maxContextValue)
            case let v as Bool: context[clip(name, maxContextKey)] = v
            case let v as Int: context[clip(name, maxContextKey)] = v
            case let v as Double: if v.isFinite { context[clip(name, maxContextKey)] = v }
            case is NSNull: context[clip(name, maxContextKey)] = NSNull()
            default: break
            }
        }
        out.context = context.isEmpty ? nil : context
        return out
    }

    private static func fingerprint(_ p: Problem) -> String {
        let top = p.stack?.split(separator: "\n").first.map(String.init) ?? ""
        return p.kind + "\n" + p.message + "\n" + top
    }

    private static func enqueue(_ s: State, _ problem: Problem) {
        let id = fingerprint(problem)
        shared.lock.lock()
        defer { shared.lock.unlock() }
        if var have = s.waiting[id] {
            have.count = min(maxCount, have.count + problem.count)
            have.at = problem.at
            s.waiting[id] = have
        } else {
            s.waiting[id] = problem
            s.order.append(id)
            while s.order.count > maxWaiting {
                s.waiting.removeValue(forKey: s.order.removeFirst())
            }
        }
    }

    private static func schedule(_ s: State, after delay: TimeInterval) {
        shared.lock.lock()
        let already = s.scheduled
        s.scheduled = true
        let wait = max(delay, s.notBefore.timeIntervalSinceNow)
        shared.lock.unlock()
        if already { return }
        work.asyncAfter(deadline: .now() + wait) {
            shared.lock.lock()
            s.scheduled = false
            shared.lock.unlock()
            sendWaiting(s, timeout: sendTimeout)
            drain(s)
        }
    }

    // MARK: Crash

    private static func onException(_ exception: NSException) {
        if shared.lock.try() {
            let s = shared.state
            let previous = shared.previousHandler
            shared.lock.unlock()
            if let s = s {
                let reason = exception.reason ?? ""
                let crash = Problem(kind: "crash", message: clean(exception.name.rawValue + (reason.isEmpty ? "" : ": " + reason), maxMessage),
                                    stack: clean(exception.callStackSymbols.joined(separator: "\n"), maxStack), route: s.route.map { clean($0, maxRoute) },
                                    level: "error", count: 1, at: iso(Date()), context: nil)
                if let problem = normalise(crash, "crash") { enqueue(s, problem) }
                // Written now, while the app still runs: everything waiting, the crash with it. Sent at the next launch.
                shared.lock.lock()
                let problems = s.order.compactMap { s.waiting[$0] }
                s.order.removeAll()
                s.waiting.removeAll()
                shared.lock.unlock()
                writeBatches(s, problems)
            }
            previous?(exception)
        } else {
            shared.previousHandler?(exception)
        }
    }

    // MARK: Sending

    private static func envelope(_ s: State, _ problems: [Problem]) -> [String: Any] {
        var body: [String: Any] = ["sdk": ["name": sdkName, "version": version], "platform": s.platform, "runtime": clip(s.runtime, 60)]
        if let r = s.release { body["release"] = r }
        if let e = s.environment { body["environment"] = e }
        body["errors"] = problems.map { p -> [String: Any] in
            var e: [String: Any] = ["kind": p.kind, "message": p.message, "level": p.level, "count": p.count, "at": p.at]
            if let v = p.stack { e["stack"] = v }
            if let v = p.route { e["route"] = v }
            if let v = p.context, !v.isEmpty { e["context"] = v }
            return e
        }
        return body
    }

    /// Bodies under 64 KB: long stacks are halved first, then fewer problems go in one body.
    /// JSON for a body; never the Objective-C exception JSONSerialization raises for what it cannot write.
    private static func encode(_ object: [String: Any]) -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { return Data() }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func fit(_ s: State, _ batch: [Problem]) -> (Data, [Problem]) {
        var problems = batch
        var rest: [Problem] = []
        var body = encode(envelope(s, problems))
        var round = 0
        while body.count > bodyLimit && round < 200 {
            round += 1
            if let i = problems.indices.filter({ (problems[$0].stack?.utf16.count ?? 0) > 1000 }).max(by: { problems[$0].stack!.utf16.count < problems[$1].stack!.utf16.count }) {
                problems[i].stack = clip(problems[i].stack!, problems[i].stack!.utf16.count / 2) + "\n[cut]"
            } else if problems.count > 1 {
                rest.insert(problems.removeLast(), at: 0)
            } else if problems[0].message.utf16.count > 1000 {
                problems[0].message = clip(problems[0].message, problems[0].message.utf16.count / 2)
            } else if problems[0].context != nil {
                problems[0].context = nil
            } else if problems[0].stack != nil {
                problems[0].stack = nil
            } else {
                break
            }
            body = encode(envelope(s, problems))
        }
        return (body, rest)
    }

    private static func pendingFiles(_ s: State) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: s.dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("pending-") && $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func writeBody(_ s: State, _ body: Data) {
        shared.lock.lock()
        s.fileCounter += 1
        let n = s.fileCounter
        shared.lock.unlock()
        if body.isEmpty { return }
        let name = String(format: "pending-%015.0f-%06ld.json", Date().timeIntervalSince1970 * 1000, n)
        try? body.write(to: s.dir.appendingPathComponent(name), options: .atomic)
        let files = pendingFiles(s)
        if files.count > maxFiles {
            for file in files.prefix(files.count - maxFiles) { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static func writeBatches(_ s: State, _ problems: [Problem]) {
        var left = problems
        while !left.isEmpty {
            let batch = Array(left.prefix(maxBatch))
            left.removeFirst(batch.count)
            let (body, rest) = fit(s, batch)
            left = rest + left
            writeBody(s, body)
        }
    }

    private enum Outcome { case done, keep, stop }

    private static func answer(_ s: State, status: Int, retryAfter: TimeInterval?) -> Outcome {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        if (200 ..< 300).contains(status) {
            s.backoff = 0
            return .done
        }
        if status == 0 || status == 429 || status >= 500 {
            var wait = retryAfter
            if wait == nil {
                s.backoff = s.backoff == 0 ? backoffFirst : min(backoffMax, s.backoff * 2)
                wait = s.backoff
            }
            s.notBefore = Date().addingTimeInterval(wait!)
            if s.debug { say(true, "the console answered \(status == 0 ? "nothing" : String(status)); trying again in \(Int(wait!)) s") }
            return .keep
        }
        if status == 401 || status == 403 {
            s.blockedUntil = Date().addingTimeInterval(blocked)
            s.waiting.removeAll()
            s.order.removeAll()
            if s.logged.insert(status).inserted { say(s.debug, "the console answered \(status): nothing is sent for an hour") }
            return .stop
        }
        if s.logged.insert(status).inserted { say(s.debug, "the console answered \(status): those problems were dropped") }
        return .done
    }

    /// One POST; on this library's own queue (never the main thread), waiting for the answer.
    private static func post(_ s: State, _ body: Data, timeout: TimeInterval) -> (Int, TimeInterval?) {
        var request = URLRequest(url: s.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer " + s.key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(sdkName)/\(version)", forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        let reply = Reply()
        let task = session.dataTask(with: request) { _, response, error in
            if let http = response as? HTTPURLResponse {
                reply.status = http.statusCode
                for (name, value) in http.allHeaderFields {
                    if let n = name as? String, n.lowercased() == "retry-after", let v = value as? String, let seconds = TimeInterval(v.trimmingCharacters(in: .whitespaces)) {
                        reply.retryAfter = min(86400, max(0, seconds))
                    }
                }
            } else if let error = error {
                debug(s, "could not reach \(s.endpoint.absoluteString): \(error.localizedDescription)")
            }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            return (0, nil)
        }
        return (reply.status, reply.retryAfter)
    }

    /// Sends what waits in memory now; what the console cannot take now becomes a file, tried again later.
    private static func sendWaiting(_ s: State, timeout: TimeInterval) {
        while true {
            shared.lock.lock()
            if s.waiting.isEmpty || Date() < s.blockedUntil {
                s.waiting.removeAll(keepingCapacity: false)
                s.order.removeAll()
                shared.lock.unlock()
                return
            }
            let ids = Array(s.order.prefix(maxBatch))
            let batch = ids.compactMap { s.waiting[$0] }
            for id in ids { s.waiting.removeValue(forKey: id) }
            s.order.removeFirst(ids.count)
            let later = Date() < s.notBefore
            shared.lock.unlock()
            if later {
                writeBatches(s, batch)
                continue
            }
            let (body, rest) = fit(s, batch)
            for p in rest.reversed() {
                shared.lock.lock()
                let id = fingerprint(p)
                if s.waiting[id] == nil {
                    s.waiting[id] = p
                    s.order.insert(id, at: 0)
                }
                shared.lock.unlock()
            }
            let (status, retryAfter) = post(s, body, timeout: timeout)
            switch answer(s, status: status, retryAfter: retryAfter) {
            case .keep: writeBody(s, body)
            case .stop: return
            case .done: break
            }
        }
    }

    /// Sends the files that wait, oldest first, until one cannot go yet.
    private static func drain(_ s: State) {
        for file in pendingFiles(s) {
            shared.lock.lock()
            let refused = Date() < s.blockedUntil
            let later = Date() < s.notBefore
            shared.lock.unlock()
            if refused {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if later {
                schedule(s, after: 0)
                return
            }
            guard let body = try? Data(contentsOf: file) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let (status, retryAfter) = post(s, body, timeout: sendTimeout)
            switch answer(s, status: status, retryAfter: retryAfter) {
            case .keep:
                schedule(s, after: 0)
                return
            case .done, .stop:
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: Debug output

    private static func say(_ on: Bool, _ message: String) {
        if on { NSLog("[cyberrakshak-monitor] %@", message) }
    }

    private static func debug(_ s: State, _ message: String) {
        say(s.debug, message)
    }
}
