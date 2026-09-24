import Foundation
import Darwin

/// Private macOS app transport; this is not part of the portable engine API.
/// Owned by one background operation. It must not be shared across threads.
final class NativeHelperTransport {
    struct Limits {
        // A deadline, not a performance target. Large scanned files may take minutes.
        var command: TimeInterval = 300
        var shutdownGrace: TimeInterval = 0.25
        var terminationGrace: TimeInterval = 0.5
        var killGrace: TimeInterval = 0.5
        var maximumReplyBytes = 32 * 1024 * 1024
    }

    private let process: Process
    private let input = Pipe()
    private let output = Pipe()
    private let limits: Limits
    private var buffer = Data()
    private var interruption: (() throws -> Void)?
    private var disposed = false
    private var lastCommand: String?
    private let requiresProcessGroup: Bool
    private var processGroup: pid_t?
    var isRunning: Bool { process.isRunning }

    init(executable: URL, arguments: [String], environment: [String: String], limits: Limits = Limits(), requiresProcessGroup: Bool = false) throws {
        self.limits = limits
        self.requiresProcessGroup = requiresProcessGroup
        let process = Process()
        self.process = process
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        // Requests may contain passwords and PDF contents. Never log payloads or stderr.
        process.standardError = FileHandle.nullDevice
        do {
            for descriptor in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor] {
                let flags = fcntl(descriptor, F_GETFL)
                guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                    throw failure(code: "ENGINE_UNAVAILABLE")
                }
            }
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) >= 0 else {
                throw failure(code: "ENGINE_UNAVAILABLE")
            }
            try process.run()
            // The parent must not retain the child's ends: otherwise EOF is hidden.
            try input.fileHandleForReading.close()
            try output.fileHandleForWriting.close()
            if requiresProcessGroup {
                let line = try readLine(deadline: ProcessInfo.processInfo.systemUptime + min(limits.command, 10))
                let ready = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                let pid = process.processIdentifier
                guard ready?["transport_ready"] as? Bool == true,
                      ready?["pid"] as? Int == Int(pid), ready?["process_group"] as? Int == Int(pid),
                      process.isRunning, getpgid(pid) == pid, pid != getpgrp() else {
                    throw failure(code: "ENGINE_UNAVAILABLE")
                }
                processGroup = pid
            }
        } catch {
            dispose()
            throw NativeSaveError(code: "ENGINE_UNAVAILABLE", message: "The PDF engine could not be started. Your on-screen edits are still available.")
        }
    }

    deinit { dispose() }

    func invalidReply() -> NativeSaveError { failure(code: "ENGINE_CONNECTION_LOST") }

    func call(_ command: String, _ parameters: [String: Any]) throws -> [String: Any] {
        guard !disposed else { throw invalidReply() }
        // Validate locally before there is any possibility of sending a Save.
        var request = try JSONSerialization.data(withJSONObject: ["command": command, "parameters": parameters])
        request.append(10)
        lastCommand = command
        let deadline = ProcessInfo.processInfo.systemUptime + limits.command
        let response: [String: Any]
        do {
            try write(request, deadline: deadline)
            let line = try readLine(deadline: deadline)
            guard let decoded = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  decoded["ok"] is Bool else { throw invalidReply() }
            response = decoded
        } catch {
            // This session cannot safely accept another request after a partial exchange.
            dispose()
            throw error
        }
        if response["ok"] as? Bool != true {
            let error = response["error"] as? [String: Any] ?? [:]
            let code = error["code"] as? String ?? "ENGINE_FAILED"
            if command == "save", ["TRANSPORT_FAILED", "INTERNAL_ERROR", "ENGINE_FAILED"].contains(code) {
                throw failure(code: code)
            }
            throw NativeSaveError(code: code, message: error["message"] as? String ?? "The PDF engine could not complete the operation.")
        }
        return response
    }

    /// Separate export protocol: progress events followed by one terminal reply.
    func exchange(_ request: [String: Any], check: @escaping () throws -> Void,
                  event: ([String: Any]) throws -> Bool) throws -> [String: Any] {
        interruption = check
        defer { interruption = nil }
        do {
            var data = try JSONSerialization.data(withJSONObject: request); data.append(10)
            let deadline = ProcessInfo.processInfo.systemUptime + limits.command
            try write(data, deadline: deadline)
            while true {
                let line = try readLine(deadline: deadline)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw invalidReply() }
                if try event(message) { return message }
            }
        } catch { dispose(); throw error }
    }

    private func write(_ data: Data, deadline: TimeInterval) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try ready(input.fileHandleForWriting.fileDescriptor, events: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.write(input.fileHandleForWriting.fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
                else { throw invalidReply() }
            }
        }
    }

    private func readLine(deadline: TimeInterval) throws -> Data {
        while true {
            if let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                return line
            }
            try ready(output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), deadline: deadline)
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &chunk, chunk.count)
            if count > 0 {
                guard buffer.count + count <= limits.maximumReplyBytes else { throw invalidReply() }
                buffer.append(contentsOf: chunk.prefix(count))
            } else if count < 0 && [EINTR, EAGAIN].contains(errno) {
                continue
            } else { throw invalidReply() }
        }
    }

    private func ready(_ descriptor: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            try interruption?()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw failure(code: "ENGINE_TIMEOUT") }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&item, 1, Int32(min(remaining * 1000 + 1, 200)))
            if result < 0 {
                if errno == EINTR { continue }
                throw invalidReply()
            }
            if result == 0 { continue }
            // Read any final bytes even when the writer has just closed.
            if item.revents & events != 0 { return }
            throw invalidReply()
        }
    }

    private func failure(code: String) -> NativeSaveError {
        if lastCommand == "save" {
            return NativeSaveError(code: "SAVE_OUTCOME_UNKNOWN", message: "The PDF engine did not confirm Save. The destination may already have been replaced. Keep your on-screen edits and reopen a separate copy of the destination to check its saved state before retrying.")
        }
        let message = code == "ENGINE_TIMEOUT"
            ? "The PDF engine took too long and was stopped. Your on-screen edits are still available."
            : "The PDF engine stopped or returned an invalid response. Your on-screen edits are still available."
        return NativeSaveError(code: code, message: message)
    }

    /// Never waitUntilExit: a wedged native call or ignored EOF must not hang Save/quit.
    func dispose() {
        guard !disposed else { return }
        disposed = true
        try? input.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        // If startup failed after setsid but before its receipt, verify the live
        // leader directly. Never infer a group from an untrusted JSON value.
        if requiresProcessGroup, processGroup == nil, process.isRunning {
            let pid = process.processIdentifier
            if getpgid(pid) == pid && pid != getpgrp() { processGroup = pid }
        }
        if !waitForExit(limits.shutdownGrace) {
            signalOwnedProcesses(SIGTERM)
            if !waitForExit(limits.terminationGrace) {
                signalOwnedProcesses(SIGKILL)
                _ = waitForExit(limits.killGrace)
            }
        }
        try? output.fileHandleForReading.close()
    }

    private func ownedProcessesRemain() -> Bool {
        if process.isRunning { return true }
        // An exited Python parent may have left QPDF children in its isolated
        // group. Keep the verified group identity until this bounded cleanup ends.
        if let processGroup { return Darwin.kill(-processGroup, 0) == 0 || errno == EPERM }
        return false
    }

    private func signalOwnedProcesses(_ signal: Int32) {
        if let processGroup {
            _ = Darwin.kill(-processGroup, signal)
        } else if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, signal)
        }
    }

    private func waitForExit(_ timeout: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ownedProcessesRemain() && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: min(0.01, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
        }
        return !ownedProcessesRemain()
    }
}
