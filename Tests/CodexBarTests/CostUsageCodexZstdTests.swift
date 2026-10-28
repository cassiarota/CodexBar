import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageCodexZstdTests {
    @Test
    func `compressed active and archived rollouts match plain history across refreshes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try self.day()
        let plain = try env.writeCodexSessionFile(
            day: day, filename: "rollout-2025-12-20-session.jsonl", contents: self.contents)
        let options = self.options(env)
        let baseline = self.report(day: day, options: options)
        #expect(baseline.data.first?.inputTokens == 1000)
        #expect(baseline.data.first?.outputTokens == 100)

        let compressed = plain.appendingPathExtension("zst")
        try self.archive.write(to: compressed)
        let both = self.report(day: day, options: options)
        #expect(both.summary?.totalTokens == baseline.summary?.totalTokens)
        #expect(both.summary?.totalCostUSD == baseline.summary?.totalCostUSD)

        try FileManager.default.removeItem(at: plain)
        let compressedOnly = self.report(day: day, options: options)
        #expect(compressedOnly.summary?.totalTokens == baseline.summary?.totalTokens)
        #expect(compressedOnly.summary?.totalCostUSD == baseline.summary?.totalCostUSD)
        let archived = env.codexArchivedSessionsRoot.appendingPathComponent(compressed.lastPathComponent)
        try FileManager.default.moveItem(at: compressed, to: archived)
        let moved = self.report(day: day, options: options)
        #expect(moved.summary?.totalTokens == baseline.summary?.totalTokens)
        #expect(moved.summary?.totalCostUSD == baseline.summary?.totalCostUSD)
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexScanCatchUpPending != true)
    }

    @Test
    func `a newly preferred plain copy does not clear a debounced cached report`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try self.day()
        let compressed = env.codexArchivedSessionsRoot.appendingPathComponent("rollout-2025-12-20-session.jsonl.zst")
        try self.archive.write(to: compressed)
        var options = self.options(env)
        let original = self.report(day: day, options: options)
        #expect(original.data.first?.inputTokens == 1000)

        let plain = compressed.deletingPathExtension()
        let updated = self.contents
            .replacingOccurrences(of: "\"input_tokens\":1000", with: "\"input_tokens\":2000")
            .replacingOccurrences(of: "\"cached_input_tokens\":400", with: "\"cached_input_tokens\":800")
            .replacingOccurrences(of: "\"output_tokens\":100", with: "\"output_tokens\":200")
            .replacingOccurrences(of: "\"total_tokens\":1100", with: "\"total_tokens\":2200")
        try updated.write(to: plain, atomically: true, encoding: .utf8)
        options.refreshMinIntervalSeconds = 3600
        let debounced = self.report(day: day, options: options)
        #expect(debounced.summary?.totalTokens == original.summary?.totalTokens)

        options.refreshMinIntervalSeconds = 0
        let refreshed = self.report(day: day, options: options)
        #expect(refreshed.data.first?.inputTokens == 2000)
        #expect(refreshed.data.first?.outputTokens == 200)
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files[compressed.path] == nil)
    }

    @Test
    func `active copy wins over archived copies in either encoding`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try self.day()
        let active = try env.writeCodexSessionFile(
            day: day, filename: "rollout-2025-12-20-session.jsonl", contents: self.contents)
        let relative = String(active.path.dropFirst(env.codexSessionsRoot.path.count + 1))
        let archived = env.codexArchivedSessionsRoot.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: archived.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.replacementArchive.write(to: archived.appendingPathExtension("zst"))
        let result = self.report(day: day, options: self.options(env))
        #expect(result.data.first?.inputTokens == 1000)
    }

    @Test
    func `decoded cache stays private preserves sources and tracks replacements`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let source = env.root.appendingPathComponent("session.jsonl.zst")
        try self.archive.write(to: source)
        try self.withContext(env) {
            #expect(try CostUsageCodexZstd.prepare(source, budget: nil))
            let decoded = try CostUsageCodexZstd.readableURL(source)
            let decodedLines = try String(contentsOf: decoded, encoding: .utf8).split(separator: "\n")
            let expectedLines = self.contents.split(separator: "\n")
            #expect(decodedLines.count == expectedLines.count)
            for (actual, expected) in zip(decodedLines, expectedLines) {
                let actualObject = try JSONSerialization.jsonObject(with: Data(actual.utf8)) as? NSDictionary
                let expectedObject = try JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSDictionary
                #expect(actualObject == expectedObject)
            }
            #expect(try Data(contentsOf: source) == self.archive)
            #expect(try CostUsageCodexZstd.readableURL(source) == decoded)
            CostUsageCodexZstd.pruneCache()
            #expect(try CostUsageCodexZstd.readableURL(source) == decoded)
            let attributes = try FileManager.default.attributesOfItem(atPath: decoded.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            try self.replacementArchive.write(to: source, options: .atomic)
            #expect(try CostUsageCodexZstd.prepare(source, budget: nil))
            let replacement = try CostUsageCodexZstd.readableURL(source)
            #expect(replacement != decoded)
            #expect(try Data(contentsOf: replacement) != Data(contentsOf: decoded))
            CostUsageCodexZstd.pruneCache()
            #expect(!FileManager.default.fileExists(atPath: decoded.path))
        }
    }

    @Test
    func `bounded JSONL reads resume in decoded bytes and retain token anchors`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let source = env.root.appendingPathComponent("session.jsonl.zst")
        try self.archive.write(to: source)
        try self.withContext(env) {
            #expect(try CostUsageCodexZstd.prepare(source, budget: nil))
            var offset: Int64 = 0
            var resume: CostUsageJsonl.ResumeState?
            var lines: [Data] = []
            for _ in 0..<100 {
                let progress = try CostUsageJsonl.scanBounded(
                    fileURL: source,
                    offset: offset,
                    maxLineBytes: 4096,
                    prefixBytes: 4096,
                    maxBytesToRead: 17,
                    resumeState: resume,
                    onLine: { lines.append($0.bytes) })
                let next = progress.resumeState?.offset ?? progress.committedOffset
                #expect(next - offset <= 17)
                offset = next
                resume = progress.resumeState
                if offset == Int64(self.contents.utf8.count), resume == nil { break }
            }
            #expect(lines.count == 3)
            #expect(offset == Int64(self.contents.utf8.count))
            #expect(CostUsageScanner.codexFileMetadata(fileURL: source).size == offset)
            let anchor = try #require(CostUsageScanner.codexTokenIndexAnchor(fileURL: source, indexedBytes: offset))
            #expect(CostUsageScanner.codexTokenIndexAnchorMatches(
                anchor, fileURL: source, metadata: CostUsageScanner.codexFileMetadata(fileURL: source)))
        }
    }

    @Test(arguments: [Data(), Data("invalid archive".utf8)])
    func `unreadable archives stay pending instead of becoming a verified empty history`(invalid: Data) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let source = env.codexArchivedSessionsRoot.appendingPathComponent("rollout-2025-12-20-session.jsonl.zst")
        try invalid.write(to: source)
        let result = try self.report(day: self.day(), options: self.options(env))
        #expect(result.summary == nil || result.data.isEmpty)
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexScanCatchUpPending == true)
    }

    @Test
    func `missing decoder does not publish a decoded cache file`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let source = env.root.appendingPathComponent("session.jsonl.zst")
        try self.archive.write(to: source)
        try self.withContext(env) {
            CostUsageCodexZstd.$executableOverrideForTesting.withValue(
                URL(fileURLWithPath: "/codexbar-test/missing-zstd"))
            {
                #expect(throws: SubprocessRunnerError.self) {
                    _ = try CostUsageCodexZstd.prepare(source, budget: nil)
                }
            }
        }
        #expect(try Data(contentsOf: source) == self.archive)
    }

    func day() throws -> Date {
        try #require(ISO8601DateFormatter().date(from: "2025-12-20T12:00:00Z"))
    }

    func options(_ env: CostUsageTestEnvironment) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(codexSessionsRoot: env.codexSessionsRoot, cacheRoot: env.cacheRoot)
        options.calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        options.refreshMinIntervalSeconds = 0
        options.codexTraceDatabaseURL = env.codexHomeRoot.appendingPathComponent("missing-traces.sqlite")
        return options
    }

    func report(day: Date, options: CostUsageScanner.Options) -> CostUsageDailyReport {
        CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)
    }

    func withContext<T>(_ env: CostUsageTestEnvironment, operation: () throws -> T) rethrows -> T {
        try CostUsageCodexZstd.$context.withValue(.init(
            cacheRoot: env.cacheRoot,
            roots: [env.codexSessionsRoot, env.codexArchivedSessionsRoot],
            checkCancellation: nil), operation: operation)
    }

    var contents: String {
        [
            #"{"timestamp":"2025-12-20T12:00:00Z","type":"session_meta","payload":{"id":"compressed-session","# +
                #""cwd":"/workspace/project"}}"#,
            #"{"timestamp":"2025-12-20T12:00:00Z","type":"turn_context","payload":{"model":"gpt-5"}}"#,
            #"{"timestamp":"2025-12-20T12:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"# +
                #""total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100,"reasoni"# +
                #"ng_output_tokens":20,"total_tokens":1100}}}}"#,
        ].joined(separator: "\n") + "\n"
    }

    /// Synthetic fixtures only; no account data or captured transcripts.
    var archive: Data {
        Data(base64Encoded: [
            "KLUv/QRY5QYA8g4sH2BnqwMGoaG/eENpMlTTr8IVKA5BF6eWNLTKiiDHAAaEGGPMPCedTSJlvOMtL01OK3uTCaCaErDFbjLzpHMr",
            "8KmxWFHI6u0v6Tvwjpv3U5app4dtg53qpwZ6DEVD4+mItnV9oP2WqZcoTYjxzbRgE1hQtiAfkkUUnt4Q7OZFU2ZNoFv29HZ8SW9",
            "rkcSCN1+tTr09mJWfrjDRNxfITJkJnYBEBTqFASV6OnSrWd3RXwIPAHfgRlCNwLo3Oc6nXDhICmjT/GCnfwamRh7EVy2QH+R0fzB",
            "uNVeZATK+vAk=",
        ].joined())!
    }

    private var replacementArchive: Data {
        Data(base64Encoded: [
            "KLUv/QRY5QYA8g4sH1Bp2wYgXfDL/xZqoNqet5MMM6rqDXiMTNzJi5nVzB6F995DPCfPBgEQ0pK2nFQ5vewNYgBaWqCSukHEk+de",
            "XFMk8YISqbe/yC9BS27ebVmFmiK2EWaomx7ocTDaIc8ndC1rBO22CjVl6cJ7b6UGqziDquQYoazC8PxSqJsbS5lVcWzV8yv5Ir",
            "/SJhKSu3lqZahtwqz8vLqEvvkAYiLmOQTwGOcwDgfP846lZmVJfxEPAHfgRlCNwLo3Oc6nXDhICmjT/GCnfwamRh7EVy2QH+R0fz",
            "BuNVeZAcAhO7o=",
        ].joined())!
    }
}
