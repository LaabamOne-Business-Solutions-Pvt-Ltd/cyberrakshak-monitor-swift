// Tests for CyberRakshakMonitor: the shared scrub cases, and one end-to-end run against Fixtures/fake-server.mjs (started
// here with Node.js, on 127.0.0.1 only: no test talks to a real Cyber Rakshak host). Run with `swift test` on a Mac.
//
// NOT YET COMPILED OR RUN BY US: written on a computer without a Swift toolchain, like the library itself. The CI
// workflow (.github/workflows/test.yml, macos-latest) is the first place it will be built.
//
// The library has no close(), so a start lasts for the whole test process: only testSendingEndToEnd starts it.
import Foundation
import XCTest

import CyberRakshakMonitor

final class CyberRakshakMonitorTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    private static let key = "crk_" + String(repeating: "0", count: 32)

    func testVersion() {
        XCTAssertEqual(CyberRakshakMonitor.version, "1.0.0")
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
    }

    func testSendingEndToEnd() throws {
        #if os(macOS)
            let server = try FakeServer()
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

            let requests = try server.requests()
            XCTAssertGreaterThanOrEqual(requests.count, 1)
            var problems: [[String: Any]] = []
            for request in requests {
                XCTAssertEqual(request["violations"] as? [String], [], "the request broke the contract: \(request)")
                let body = try XCTUnwrap(request["body"] as? [String: Any])
                XCTAssertEqual((body["sdk"] as? [String: Any])?["name"] as? String, "cyberrakshak-ios")
                XCTAssertEqual((body["sdk"] as? [String: Any])?["version"] as? String, "1.0.0")
                XCTAssertEqual(body["release"] as? String, "1.4.2+57")
                XCTAssertEqual(body["environment"] as? String, "production")
                XCTAssertEqual(body["platform"] as? String, "desktop") // macOS; "mobile" on iOS
                XCTAssertTrue((body["runtime"] as? String ?? "").hasPrefix("macos "))
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
        #else
            throw XCTSkip("the fake server is started with Process, which only macOS has: run swift test on a Mac")
        #endif
    }
}

#if os(macOS)
    /// Fixtures/fake-server.mjs, run with node: it prints {"url": ...} and serves until its standard input closes.
    private final class FakeServer {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let base: String

        var endpoint: String { base + "/api/v1/app-reports" }

        init() throws {
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fake-server.mjs")
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
            base = url
        }

        /// Every report request the fake server has had.
        func requests() throws -> [[String: Any]] {
            let data = try Data(contentsOf: XCTUnwrap(URL(string: base + "/__control/requests")))
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        }

        func stop() {
            try? input.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { process.terminate() }
        }
    }
#endif
