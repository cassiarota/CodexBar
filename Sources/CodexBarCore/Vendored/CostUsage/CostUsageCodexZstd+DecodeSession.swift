import Foundation
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

extension CostUsageCodexZstd {
    final class DecodeSession {
        let snapshot: Snapshot
        let output: FileHandle
        let process: Process
        private let pipe: Pipe
        private let lockDescriptor: Int32
        private var consumedOutput: Int64 = 0
        private var onDisk: Int64
        var lease = UUID()

        init?(snapshot: Snapshot) throws {
            let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
                + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            guard let executable = CostUsageCodexZstd.executableOverrideForTesting
                ?? BinaryLocator.find("zstd", in: paths, fileManager: .default).map(URL.init(fileURLWithPath:)),
                FileManager.default.isExecutableFile(atPath: executable.path)
            else { throw SubprocessRunnerError.binaryNotFound("zstd") }
            let lockDescriptor = try CostUsageCodexZstd
                .openPrivateFile(snapshot.directory.appendingPathComponent("lock"))
            guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(lockDescriptor)
                return nil
            }
            var adopted = false
            defer { if !adopted { close(lockDescriptor) } }
            let output = try FileHandle(
                fileDescriptor: CostUsageCodexZstd.openPrivateFile(snapshot.partial),
                closeOnDealloc: true)
            defer { if !adopted { try? output.close() } }
            let onDisk = try output.seekToEnd()
            let pipe = Pipe()
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--quiet", "--decompress", "--stdout", "--", snapshot.source.path]
            process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            ProcessExitRelease.afterExit(process)
            defer {
                if !adopted {
                    SubprocessRunner.terminateProcess(process, processGroup: nil)
                    try? pipe.fileHandleForReading.close()
                    try? pipe.fileHandleForWriting.close()
                }
            }
            try pipe.fileHandleForWriting.close()
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
                throw CocoaError(.fileReadUnknown)
            }
            self.snapshot = snapshot
            self.output = output
            self.process = process
            self.pipe = pipe
            self.lockDescriptor = lockDescriptor
            self.onDisk = Int64(onDisk)
            adopted = true
        }

        deinit {
            if self.process.isRunning {
                kill(self.process.processIdentifier, SIGCONT)
                SubprocessRunner.terminateProcess(self.process, processGroup: nil)
            }
            try? self.pipe.fileHandleForReading.close()
            try? self.output.close()
            close(self.lockDescriptor)
        }

        func advance(
            allowance: Int64,
            budget: CostUsageScanner.CodexScanBudget,
            consumed: inout Int64) throws -> Bool
        {
            if self.process.isRunning { kill(self.process.processIdentifier, SIGCONT) }
            defer { if self.process.isRunning { kill(self.process.processIdentifier, SIGSTOP) } }
            let stallDeadline = ContinuousClock.now.advanced(by: .seconds(30))
            var buffer = [UInt8](repeating: 0, count: Int(min(64 * 1024, allowance)))
            while consumed < allowance {
                try CostUsageCodexZstd.context?.checkCancellation?()
                if consumed > 0, budget.shouldYield(additionalBytes: consumed) { return false }
                let readCount = Int(min(allowance - consumed, Int64(buffer.count)))
                let count = read(self.pipe.fileHandleForReading.fileDescriptor, &buffer, readCount)
                if count > 0 {
                    let skip = Int(min(Int64(count), max(0, self.onDisk - self.consumedOutput)))
                    if skip < count {
                        try self.output.write(contentsOf: Data(buffer[skip..<count]))
                        self.onDisk += Int64(count - skip)
                    }
                    self.consumedOutput += Int64(count)
                    consumed += Int64(count)
                } else if count == 0, !self.process.isRunning {
                    guard self.process.terminationReason == .exit, self.process.terminationStatus == 0,
                          self.consumedOutput == self.onDisk
                    else {
                        throw SubprocessRunnerError.nonZeroExit(
                            code: self.process.terminationStatus, stderr: "Invalid Zstandard rollout")
                    }
                    return true
                } else {
                    if count < 0, errno != EAGAIN, errno != EINTR { throw CocoaError(.fileReadUnknown) }
                    if budget.shouldYield(additionalBytes: 1) || ContinuousClock.now >= stallDeadline { return false }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
            return false
        }
    }
}
