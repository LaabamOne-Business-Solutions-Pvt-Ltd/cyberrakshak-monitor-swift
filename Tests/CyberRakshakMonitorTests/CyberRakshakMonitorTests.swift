// Tests for CyberRakshakMonitor: the shared scrub cases, and one end-to-end run against Fixtures/fake-server.mjs (on
// 127.0.0.1 only: no test talks to a real Cyber Rakshak host).
//
//   swift test                       macOS: the end-to-end test starts the fake server itself, with Node.js
//   TEST_RUNNER_CR_TEST_SERVER=http://127.0.0.1:PORT xcodebuild test ... -destination 'platform=iOS Simulator,...'
//                                    iOS Simulator: a fake server already running (the CI workflow starts one)
//
// The library has no close(), so a start lasts for the whole test process. XCTest runs a class's tests in name order:
// testSendingEndToEnd is the first to start it (a start before it would catch what it expects to be dropped), then
// testThatScrubNamesAndPatternsOnlyAdd, with an address nothing answers.
import Foundation
import XCTest

import CyberRakshakMonitor

final class CyberRakshakMonitorTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    private static let key = "crk_" + String(repeating: "0", count: 32)

    func testVersion() {
        XCTAssertEqual(CyberRakshakMonitor.version, "1.1.0")
        XCTAssertEqual(CyberRakshakMonitor.defaultEndpoint, "https://app.cyberrakshak.ai/api/v1/app-reports")
    }

    func testScrubEverySharedVector() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("scrub-vectors.json"))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let vectors = try XCTUnwrap(root["vectors"] as? [[String: Any]])
        XCTAssertGreaterThan(vectors.count, 10)
        for vector in vectors {
            let input = try XCTUnwrap(vector["in"] as? String)
            let output = try XCTUnwrap(vector["out"] as? String)
            XCTAssertEqual(CyberRakshakMonitor.scrub(input), output, input)
        }
    }

    func testOptionsDefaults() {
        let options = CyberRakshakMonitor.Options(key: Self.key)
        XCTAssertEqual(options.endpoint, CyberRakshakMonitor.defaultEndpoint)
        XCTAssertNil(options.release)
        XCTAssertNil(options.environment)
        XCTAssertTrue(options.enabled)
        XCTAssertEqual(options.sampleRate, 1)
        XCTAssertFalse(options.debug)
        XCTAssertTrue(options.context.isEmpty)
        XCTAssertTrue(options.scrubNames.isEmpty)
        XCTAssertTrue(options.scrubPatterns.isEmpty)
    }

    func testThatScrubNamesAndPatternsOnlyAdd() {
        let nowhere = "http://127.0.0.1:9/api/v1/app-reports"
        // Before a start with them: only the built-in rules.
        XCTAssertEqual(CyberRakshakMonitor.scrub("x-brand-key=1 pin=2"), "x-brand-key=1 pin=[removed]")
        CyberRakshakMonitor.start(.init(key: Self.key, endpoint: nowhere, scrubNames: ["x-brand-key", "face.key", "bad name"],
                                        scrubPatterns: [#"faces/[A-Za-z0-9/_.-]+"#, "(", "x*"]))
        XCTAssertEqual(CyberRakshakMonitor.scrub("x-brand-key=B1 face.key=K xface.key=keep faces/2026/a.jpg pin=1 password=2"),
                       "x-brand-key=[removed] face.key=[removed] xface.key=keep [removed] pin=[removed] password=[removed]")
        // A start without them takes them away again; the built-in rules stay.
        CyberRakshakMonitor.start(.init(key: Self.key, endpoint: nowhere))
        XCTAssertEqual(CyberRakshakMonitor.scrub("x-brand-key=1 pin=2"), "x-brand-key=1 pin=[removed]")
    }

    func testSendingEndToEnd() throws {
        let server: FakeServer
        if let given = ProcessInfo.processInfo.environment["CR_TEST_SERVER"], !given.isEmpty {
            server = FakeServer(running: given)
        } else {
            #if os(macOS)
                server = try FakeServer()
            #else
                throw XCTSkip("set CR_TEST_SERVER (TEST_RUNNER_CR_TEST_SERVER for xcodebuild) to a running Fixtures/fake-server.mjs: only macOS can start one here")
            #endif
        }
        defer { server.stop() }

        // A key that is not a crk_ key starts nothing: nothing is sent.
        CyberRakshakMonitor.start(.init(key: "crw_" + String(repeating: "0", count: 32), endpoint: server.endpoint))
        CyberRakshakMonitor.captureMessage("never sent")
        XCTAssertTrue(CyberRakshakMonitor.flush(timeout: 1))
        XCTAssertEqual(try server.requests().count, 0)

        // A good key: a message and an error go, scrubbed, in the shape the console accepts.
        CyberRakshakMonitor.start(.init(key: Self.key, endpoint: server.endpoint, release: "1.4.2+57", environment: "Production",
                                        context: ["build": 57]))
        CyberRakshakMonitor.setRoute("Checkout")
        CyberRakshakMonitor.captureMessage("Payment provider answered slowly for someone@example.com password=hunter2")
        CyberRakshakMonitor.captureError(NSError(domain: "ShopError", code: 42, userInfo: [NSLocalizedDescriptionKey: "card declined"]))
        XCTAssertTrue(CyberRakshakMonitor.flush(timeout: 5), "flush did not finish")

        #if os(macOS)
            let platform = "desktop"
            let runtime = "macos "
        #else
            let platform = "mobile"
            let runtime = "ios "
        #endif
        let requests = try server.requests()
        XCTAssertGreaterThanOrEqual(requests.count, 1)
        var problems: [[String: Any]] = []
        for request in requests {
            XCTAssertEqual(request["violations"] as? [String], [], "the request broke the contract: \(request)")
            let body = try XCTUnwrap(request["body"] as? [String: Any])
            XCTAssertEqual((body["sdk"] as? [String: Any])?["name"] as? String, "cyberrakshak-ios")
            XCTAssertEqual((body["sdk"] as? [String: Any])?["version"] as? String, "1.1.0")
            XCTAssertEqual(body["release"] as? String, "1.4.2+57")
            XCTAssertEqual(body["environment"] as? String, "production")
            XCTAssertEqual(body["platform"] as? String, platform)
            XCTAssertTrue((body["runtime"] as? String ?? "").hasPrefix(runtime), "runtime \(body["runtime"] ?? "none")")
            problems += try XCTUnwrap(body["errors"] as? [[String: Any]])
        }
        let messages = problems.compactMap { $0["message"] as? String }
        XCTAssertTrue(messages.contains("Payment provider answered slowly for [email] password=[removed]"), "\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("card declined") }, "\(messages)")
        XCTAssertFalse(messages.joined().contains("hunter2"))
        XCTAssertFalse(messages.joined().contains("someone@example.com"))
        for problem in problems {
            XCTAssertEqual(problem["route"] as? String, "Checkout")
            XCTAssertEqual((problem["context"] as? [String: Any])?["build"] as? Int, 57)
        }
        XCTAssertEqual(problems.first { ($0["message"] as? String ?? "").hasPrefix("Payment") }?["kind"] as? String, "log")
        XCTAssertEqual(problems.first { ($0["message"] as? String ?? "").contains("card declined") }?["kind"] as? String, "exception")
    }
}

/// Fixtures/fake-server.mjs: one already running (CR_TEST_SERVER), or on macOS one started here with node (it prints
/// {"url": ...} and serves until its standard input closes).
private final class FakeServer {
    let base: String
    #if os(macOS)
        private var process: Process?
        private var input: Pipe?
    #endif

    var endpoint: String { base + "/api/v1/app-reports" }

    init(running base: String) {
        self.base = base
    }

    #if os(macOS)
        init() throws {
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fake-server.mjs")
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [ProcessInfo.processInfo.environment["CR_NODE"] ?? "node", script.path]
            process.standardInput = input
            process.standardOutput = output
            do {
                try process.run()
            } catch {
                throw XCTSkip("could not start node (Node.js 18 or later is needed for this test): \(error)")
            }
            var line = Data()
            let deadline = Date().addingTimeInterval(15)
            while !line.contains(UInt8(ascii: "\n")) && Date() < deadline {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                line.append(chunk)
            }
            guard let object = try? JSONSerialization.jsonObject(with: line.split(separator: UInt8(ascii: "\n")).first ?? Data()) as? [String: Any],
                  let url = object["url"] as? String
            else {
                process.terminate()
                throw XCTSkip("the fake server did not start (is Node.js 18 or later on the PATH?): \(String(decoding: line, as: UTF8.self))")
            }
            self.process = process
            self.input = input
            base = url
        }
    #endif

    /// Every report request the fake server has had.
    func requests() throws -> [[String: Any]] {
        let data = try Data(contentsOf: XCTUnwrap(URL(string: base + "/__control/requests")))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    func stop() {
        #if os(macOS)
            guard let process = process else { return }
            try? input?.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { process.terminate() }
        #endif
    }
}
