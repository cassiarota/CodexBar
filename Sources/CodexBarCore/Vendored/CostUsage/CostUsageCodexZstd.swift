#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Keep decoded offsets seekable for the existing bounded JSONL reader and token anchors.
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
        if let roots = self.context?.roots, roots.count == 2 {
            let archivedPrefix = roots[1].standardizedFileURL.path + "/"
            let path = plain.standardizedFileURL.path
            if path.hasPrefix(archivedPrefix) {
                let relative = String(path.dropFirst(archivedPrefix.count))
                var candidates = [roots[0].appendingPathComponent(relative)]
                if !relative.contains("/"),
                   let day = CostUsageScanner.dayKeyFromFilename(plain.lastPathComponent)
                {
                    candidates.append(roots[0]
                        .appendingPathComponent(day.replacingOccurrences(of: "-", with: "/"))
                        .appendingPathComponent(plain.lastPathComponent))
                }
                if candidates.contains(where: {
                    self.isRegularFile($0) || self.isRegularFile($0.appendingPathExtension("zst"))
                }) { return false }
            }
        }
        return true
    }

    static func readableURL(_ source: URL) throws -> URL {
        guard self.isCompressed(source) else { return source }
        try self.context?.checkCancellation?()
        let before = try self.fingerprint(source)
        let key = SHA256.hash(data: Data((source.standardizedFileURL.path + "\n" + before).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let root = self.context?.cacheRoot
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let directory = root.appendingPathComponent("CodexBar/cost-usage/zstd", isDirectory: true)
        let destination = directory.appendingPathComponent(key).appendingPathExtension("jsonl")
        if self.isRegularFile(destination) { return destination }

        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        guard let executable = self.executableOverrideForTesting
            ?? BinaryLocator.find("zstd", in: paths, fileManager: .default).map(URL.init(fileURLWithPath:))
        else { throw SubprocessRunnerError.binaryNotFound("zstd") }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SubprocessRunnerError.binaryNotFound("zstd")
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent("\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporary) }

        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--quiet", "--decompress", "--stdout", "--", source.path]
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                SubprocessRunner.terminateProcess(process, processGroup: nil)
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning {
            try self.context?.checkCancellation?()
            guard Date() < deadline else { throw SubprocessRunnerError.timedOut("Zstandard rollout decoding") }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw SubprocessRunnerError.nonZeroExit(
                code: process.terminationStatus,
                stderr: "Invalid Zstandard rollout")
        }
        try output.close()
        guard try self.fingerprint(source) == before else { throw CocoaError(.fileReadUnknown) }
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            // A concurrent app/CLI scan may have published the same immutable generation.
            guard self.isRegularFile(destination) else { throw error }
        }
        return destination
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    private static func fingerprint(_ source: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber
        else { throw CocoaError(.fileReadUnknown) }
        return "\(inode)|\(size)|\(modified.timeIntervalSince1970.bitPattern)"
    }
}
