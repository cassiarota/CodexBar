import Foundation
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

extension CostUsageCodexZstd {
    static var cacheDirectory: URL {
        CostUsageStore.databaseURL(cacheRoot: self.context?.cacheRoot)
            .deletingLastPathComponent().appendingPathComponent("zstd", isDirectory: true)
    }

    struct Snapshot {
        let source: URL
        let directory: URL
        let destination: URL
        let partial: URL

        init(source: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            guard let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date,
                  let inode = attributes[.systemFileNumber] as? NSNumber
            else { throw CocoaError(.fileReadUnknown) }
            self.source = source
            self.directory = CostUsageCodexZstd.cacheDirectory.appendingPathComponent(
                CostUsageCodexZstd.digest(source.standardizedFileURL.path), isDirectory: true)
            let generation = CostUsageCodexZstd.digest("\(inode)|\(size)|\(modified.timeIntervalSince1970.bitPattern)")
            self.destination = self.directory.appendingPathComponent(generation).appendingPathExtension("jsonl")
            self.partial = self.directory.appendingPathComponent(generation).appendingPathExtension("partial")
        }
    }

    static func openPrivateFile(_ url: URL, flags: Int32 = O_RDWR | O_CREAT) throws -> Int32 {
        let descriptor = open(url.path, flags | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        guard fchmod(descriptor, 0o600) == 0 else {
            close(descriptor)
            throw CocoaError(.fileWriteNoPermission)
        }
        return descriptor
    }

    private static func writePrivate(_ data: Data, to url: URL, flags: Int32 = O_RDWR | O_CREAT | O_TRUNC) throws {
        let handle = try FileHandle(fileDescriptor: self.openPrivateFile(url, flags: flags), closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }

    static func createSnapshotDirectory(_ snapshot: Snapshot) throws {
        for directory in [self.cacheDirectory, snapshot.directory] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let sourceRecord = snapshot.directory.appendingPathComponent("source")
        if !self.isRegularFile(sourceRecord) {
            // Fixed-size records let cleanup resume across app and CLI launches without a tree walk.
            try self.writePrivate(
                Data((snapshot.directory.lastPathComponent + "\n").utf8),
                to: self.cacheDirectory.appendingPathComponent("sources"),
                flags: O_WRONLY | O_CREAT | O_APPEND)
            try self.writePrivate(Data(snapshot.source.path.utf8), to: sourceRecord)
        }
    }

    /// Cleanup visits at most 32 source records per refresh, including deleted/now-plain sources.
    /// A shared transcript lock postpones unlinking generations still held by concurrent readers.
    static func pruneCache() {
        guard self.registry.lock.try() else { return }
        defer { self.registry.lock.unlock() }
        for (key, session) in self.registry.sessions {
            if !self.isRegularFile(session.snapshot.source) || !self.shouldRead(session.snapshot.source)
                || (try? Snapshot(source: session.snapshot.source).destination) != session.snapshot.destination
            {
                self.registry.sessions.removeValue(forKey: key)
            }
        }
        let root = self.cacheDirectory
        guard let lockDescriptor = try? self.openPrivateFile(root.appendingPathComponent("sweep-lock")) else { return }
        defer { close(lockDescriptor) }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0,
              let sources = try? FileHandle(forReadingFrom: root.appendingPathComponent("sources")) else { return }
        defer { try? sources.close() }
        let cursor = root.appendingPathComponent("sweep-offset")
        let offset = (try? String(contentsOf: cursor, encoding: .utf8)).flatMap(UInt64.init) ?? 0
        do {
            try sources.seek(toOffset: offset)
            var nextOffset = offset
            for _ in 0..<32 {
                guard let record = try sources.read(upToCount: 65), record.count == 65 else {
                    nextOffset = 0
                    break
                }
                nextOffset += 65
                guard let key = String(bytes: record.prefix(64), encoding: .utf8),
                      key.count == 64, key.allSatisfy(\.isHexDigit) else { continue }
                self.pruneSourceDirectory(root.appendingPathComponent(key, isDirectory: true))
            }
            try self.writePrivate(Data(String(nextOffset).utf8), to: cursor)
        } catch {
            // Derived snapshots are retried on the next refresh; accounting remains in SQLite.
        }
    }

    private static func pruneSourceDirectory(_ directory: URL) {
        guard self.registry.sessions[directory.path] == nil,
              let lockDescriptor = try? self.openPrivateFile(directory.appendingPathComponent("lock")) else { return }
        defer { close(lockDescriptor) }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else { return }
        let source = (try? String(contentsOf: directory.appendingPathComponent("source"), encoding: .utf8))
            .map { URL(fileURLWithPath: $0) }
        let current = source.flatMap { self.shouldRead($0) ? try? Snapshot(source: $0) : nil }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for file in files where ["jsonl", "partial"].contains(file.pathExtension) {
            if file == current?.destination || file == current?.partial { continue }
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            if flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
                try? FileManager.default.removeItem(at: file)
            }
            try? handle.close()
        }
    }
}
