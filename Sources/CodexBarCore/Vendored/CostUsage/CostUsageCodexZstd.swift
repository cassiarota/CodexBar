#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Decompression is admitted explicitly; metadata and readers never start a decoder.
enum CostUsageCodexZstd {
    final class Context: @unchecked Sendable {
        let cacheRoot: URL?
        let roots: [URL]
        let checkCancellation: (() throws -> Void)?

        init(cacheRoot: URL?, roots: [URL], checkCancellation: (() throws -> Void)?) {
            self.cacheRoot = cacheRoot
            self.roots = roots
            self.checkCancellation = checkCancellation
        }
    }

    @TaskLocal static var context: Context?
    @TaskLocal static var executableOverrideForTesting: URL?

    static func isCompressed(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().hasSuffix(".jsonl.zst")
    }

    static func isSessionFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "jsonl" || self.isCompressed(url)
    }

    static func shouldRead(_ url: URL) -> Bool {
        guard self.isSessionFile(url) else { return false }
        let plain = self.isCompressed(url) ? url.deletingPathExtension() : url
        if self.isCompressed(url), self.isRegularFile(plain) { return false }
        if !self.isCompressed(url), !self.isRegularFile(url),
           self.isRegularFile(url.appendingPathExtension("zst")) { return false }
        return !self.activeCandidates(for: plain).contains {
            self.isRegularFile($0) || self.isRegularFile($0.appendingPathExtension("zst"))
        }
    }

    private static func activeCandidates(for plain: URL) -> [URL] {
        guard let roots = self.context?.roots, roots.count == 2 else { return [] }
        let archivedPrefix = roots[1].standardizedFileURL.path + "/"
        let path = plain.standardizedFileURL.path
        guard path.hasPrefix(archivedPrefix) else { return [] }
        let relative = String(path.dropFirst(archivedPrefix.count))
        var candidates = [roots[0].appendingPathComponent(relative)]
        if !relative.contains("/"), let day = CostUsageScanner.dayKeyFromFilename(plain.lastPathComponent) {
            candidates.append(roots[0]
                .appendingPathComponent(day.replacingOccurrences(of: "-", with: "/"))
                .appendingPathComponent(plain.lastPathComponent))
        }
        return candidates
    }

    static func supersededPaths(for url: URL) -> [String] {
        let plain = self.isCompressed(url) ? url.deletingPathExtension() : url
        var candidates = [plain, plain.appendingPathExtension("zst")]
        for active in self.activeCandidates(for: plain) {
            candidates.append(contentsOf: [active, active.appendingPathExtension("zst")])
        }
        if let roots = self.context?.roots, roots.count == 2 {
            let activePrefix = roots[0].standardizedFileURL.path + "/"
            let path = plain.standardizedFileURL.path
            if path.hasPrefix(activePrefix) {
                let relative = String(path.dropFirst(activePrefix.count))
                for archived in [
                    roots[1].appendingPathComponent(relative),
                    roots[1].appendingPathComponent(plain.lastPathComponent),
                ] {
                    candidates.append(contentsOf: [archived, archived.appendingPathExtension("zst")])
                }
            }
        }
        return candidates.filter { $0.standardizedFileURL != url.standardizedFileURL }.map(\.path)
    }

    /// Only complete, validated generations are visible to parsers.
    static func readableURL(_ source: URL) throws -> URL {
        guard self.isCompressed(source) else { return source }
        let destination = try Snapshot(source: source).destination
        guard self.isRegularFile(destination) else { throw CocoaError(.fileReadUnknown) }
        return destination
    }

    static func openReadableFile(_ source: URL) throws -> FileHandle {
        let handle = try FileHandle(forReadingFrom: self.readableURL(source))
        // Retiring a generation must leave a concurrent reader's transcript intact.
        if self.isCompressed(source), flock(handle.fileDescriptor, LOCK_SH | LOCK_NB) != 0 {
            try? handle.close()
            throw CocoaError(.fileReadUnknown)
        }
        return handle
    }

    static func decodedSize(_ source: URL) -> Int64? {
        guard let decoded = try? self.readableURL(source),
              let attributes = try? FileManager.default.attributesOfItem(atPath: decoded.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    /// A paused child retains the decoder state between refreshes. After relaunch its saved
    /// prefix is replayed in budgeted slices before new bytes are appended.
    static func prepare(_ source: URL, budget: CostUsageScanner.CodexScanBudget?) throws -> Bool {
        guard self.isCompressed(source) else { return true }
        try self.context?.checkCancellation?()
        guard self.shouldRead(source) else { return false }
        let snapshot = try Snapshot(source: source)
        if self.isRegularFile(snapshot.destination) { return true }
        let budget = budget ?? CostUsageScanner.CodexScanBudget(
            maxFileBytes: 256 * 1024 * 1024, maxBytesPerRefresh: 512 * 1024 * 1024, maxDuration: 2)
        let allowance: Int64
        switch budget.admit(workBytes: Int64.max, tracksPartialFile: false) {
        case let .allow(bytes): allowance = bytes
        case .deferBudget: return false
        }
        var consumed: Int64 = 0
        var completed = false
        defer {
            budget.complete(admittedWorkBytes: allowance, actualWorkBytes: consumed)
            if !completed { budget.recordPartialFile() }
        }
        guard allowance > 0, self.registry.lock.try() else { return false }
        defer { self.registry.lock.unlock() }
        let key = snapshot.directory.path
        if self.registry.sessions[key]?.snapshot.destination != snapshot.destination {
            self.registry.sessions.removeValue(forKey: key)
        }
        if self.registry.sessions[key] == nil {
            try self.createSnapshotDirectory(snapshot)
            guard let session = try DecodeSession(snapshot: snapshot) else { return false }
            self.registry.sessions[key] = session
        }
        guard let session = self.registry.sessions[key] else { return false }
        do {
            let complete = try session.advance(allowance: allowance, budget: budget, consumed: &consumed)
            if complete {
                guard try Snapshot(source: source).destination == snapshot.destination else {
                    throw CocoaError(.fileReadUnknown)
                }
                try session.output.close()
                try FileManager.default.moveItem(at: snapshot.partial, to: snapshot.destination)
                self.registry.sessions.removeValue(forKey: key)
                completed = true
                return true
            }
            session.lease = UUID()
            let lease = session.lease
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) {
                self.registry.lock.withLock {
                    if self.registry.sessions[key]?.lease == lease {
                        self.registry.sessions.removeValue(forKey: key)
                    }
                }
            }
            return false
        } catch {
            self.registry.sessions.removeValue(forKey: key)
            try? FileManager.default.removeItem(at: snapshot.partial)
            throw error
        }
    }

    static func isRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var sessions: [String: DecodeSession] = [:]

        init() {
            atexit {
                // A short-lived CLI must not leave suspended decoder children behind.
                CostUsageCodexZstd.registry.lock.withLock {
                    CostUsageCodexZstd.registry.sessions.removeAll()
                }
            }
        }
    }

    static let registry = Registry()
}
