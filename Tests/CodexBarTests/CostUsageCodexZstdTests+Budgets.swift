import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageCodexZstdTests {
    @Test
    func `an expired decoder slice yields and continues on a later refresh`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let source = env.root.appendingPathComponent("session.jsonl.zst")
        try self.archive.write(to: source)
        try self.withContext(env) {
            let clock = LockIsolated(ContinuousClock.now)
            let budget = CostUsageScanner.CodexScanBudget(
                maxFileBytes: 1024, maxBytesPerRefresh: 1024, maxDuration: 1, now: { clock.value })
            clock.setValue(clock.value.advanced(by: .seconds(2)))
            let completed = try CostUsageCodexZstd.prepare(source, budget: budget)
            #expect(!completed)
            #expect(budget.deferredByTimeBudgetFileCount > 0)
            #expect(CostUsageCodexZstd.decodedSize(source) == nil)
            let resumed = try CostUsageCodexZstd.prepare(source, budget: nil)
            #expect(resumed)
        }
    }

    @Test
    func `cancellation releases the launched decoder and unpublished slice`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let source = env.root.appendingPathComponent("session.jsonl.zst")
        try self.archive.write(to: source)
        let checks = LockIsolated(0)
        try CostUsageCodexZstd.$context.withValue(.init(
            cacheRoot: env.cacheRoot, roots: [], checkCancellation: {
                checks.setValue(checks.value + 1)
                if checks.value >= 2 { throw CancellationError() }
            })) {
                #expect(throws: CancellationError.self) {
                    _ = try CostUsageCodexZstd.prepare(source, budget: nil)
                }
                let snapshot = try CostUsageCodexZstd.Snapshot(source: source)
                let retained = CostUsageCodexZstd.registry.lock.withLock {
                    CostUsageCodexZstd.registry.sessions[snapshot.directory.path] != nil
                }
                #expect(!retained)
                #expect(!FileManager.default.fileExists(atPath: snapshot.partial.path))
            }
    }

    @Test
    func `metadata inspection never launches a decoder or writes transcript data`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let source = env.root.appendingPathComponent("session.jsonl.zst")
        try self.archive.write(to: source)
        try self.withContext(env) {
            let metadata = CostUsageScanner.codexFileMetadata(fileURL: source)
            #expect(metadata.size == Int64(self.archive.count))
            #expect(CostUsageCodexZstd.decodedSize(source) == nil)
            #expect(!FileManager.default.fileExists(atPath: CostUsageCodexZstd.cacheDirectory.path))
        }
    }

    @Test
    func `decoding and prefix replay converge within the refresh byte allowance`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let source = env.root.appendingPathComponent("session.jsonl.zst")
        try self.archive.write(to: source)
        try self.withContext(env) {
            var complete = false
            var previousSize: Int64 = 0
            for pass in 0..<100 {
                let budget = CostUsageScanner.CodexScanBudget(maxFileBytes: 17, maxBytesPerRefresh: 17)
                complete = try CostUsageCodexZstd.prepare(source, budget: budget)
                #expect(budget.bytesConsumed <= 17)
                if complete { break }
                #expect(CostUsageCodexZstd.decodedSize(source) == nil)
                let partial = try CostUsageCodexZstd.Snapshot(source: source).partial
                let size = try #require(FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)
                    .int64Value
                #expect(size >= previousSize)
                previousSize = size
                if pass == 2 {
                    // Simulate relaunch: the next decoder must replay more than one allowance.
                    CostUsageCodexZstd.registry.lock.withLock {
                        CostUsageCodexZstd.registry.sessions.removeAll()
                    }
                }
            }
            #expect(complete)
            #expect(CostUsageCodexZstd.decodedSize(source) == Int64(self.contents.utf8.count))
        }
    }

    @Test
    func `paged compression transitions never publish both counted representations`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try self.day()
        let plain = try env.writeCodexSessionFile(
            day: day, filename: "rollout-2025-12-20-session.jsonl", contents: self.contents)
        let baseline = self.report(day: day, options: self.options(env))
        #expect(baseline.summary?.totalTokens == 1100)
        try self.archive.write(to: plain.appendingPathExtension("zst"))
        try FileManager.default.removeItem(at: plain)
        var options = self.options(env)
        options.maxCodexScanDurationPerRefresh = 60
        options.maxCodexSessionFileBytes = 17
        options.maxCodexScanBytesPerRefresh = 17
        var completed = false
        for _ in 0..<200 {
            let report = self.report(day: day, options: options)
            #expect((report.summary?.totalTokens ?? 0) <= 1100)
            let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
            if cache.codexScanCatchUpPending != true {
                #expect(report.summary?.totalTokens == 1100)
                #expect(cache.files[plain.path] == nil)
                completed = true
                break
            }
        }
        #expect(completed)

        let compressed = plain.appendingPathExtension("zst")
        let archived = env.codexArchivedSessionsRoot.appendingPathComponent(compressed.lastPathComponent)
        // Copy-and-delete also changes the inode, so physical-file aliasing cannot reconcile it.
        try FileManager.default.copyItem(at: compressed, to: archived)
        try FileManager.default.removeItem(at: compressed)
        completed = false
        for _ in 0..<200 {
            let report = self.report(day: day, options: options)
            #expect((report.summary?.totalTokens ?? 0) <= 1100)
            let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
            if cache.codexScanCatchUpPending != true {
                #expect(report.summary?.totalTokens == 1100)
                #expect(cache.files[compressed.path] == nil)
                completed = true
                break
            }
        }
        #expect(completed)
    }

    @Test
    func `retired generations survive active readers then disappear after a source is deleted`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let source = env.root.appendingPathComponent("session.jsonl.zst")
        try self.archive.write(to: source)
        try self.withContext(env) {
            #expect(try CostUsageCodexZstd.prepare(source, budget: nil))
            let decoded = try CostUsageCodexZstd.readableURL(source)
            let reader = try CostUsageCodexZstd.openReadableFile(source)
            try FileManager.default.removeItem(at: source)
            CostUsageCodexZstd.pruneCache()
            #expect(FileManager.default.fileExists(atPath: decoded.path))
            #expect(try reader.readToEnd()?.count == self.contents.utf8.count)
            try reader.close()
            CostUsageCodexZstd.pruneCache()
            #expect(!FileManager.default.fileExists(atPath: decoded.path))
        }
    }

    @Test
    func `a restored plain sibling retires decoded transcript content`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let source = env.root.appendingPathComponent("session.jsonl.zst")
        try self.archive.write(to: source)
        try self.withContext(env) {
            #expect(try CostUsageCodexZstd.prepare(source, budget: nil))
            let decoded = try CostUsageCodexZstd.readableURL(source)
            try self.contents.write(to: source.deletingPathExtension(), atomically: true, encoding: .utf8)
            CostUsageCodexZstd.pruneCache()
            #expect(!FileManager.default.fileExists(atPath: decoded.path))
        }
    }
}
