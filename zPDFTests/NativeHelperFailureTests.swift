import Foundation
import Darwin
import XCTest
@testable import zPDF

final class NativeHelperFailureTests: XCTestCase {
    private func helper(_ script: String, commandTimeout: TimeInterval = 0.5,
                        maximumReplyBytes: Int = 1024 * 1024) throws -> NativeHelperTransport {
        try NativeHelperTransport(executable: URL(fileURLWithPath: "/bin/sh"),
                                  arguments: ["-c", script], environment: [:],
                                  limits: .init(command: commandTimeout, shutdownGrace: 0.05,
                                                terminationGrace: 0.05, killGrace: 0.5,
                                                maximumReplyBytes: maximumReplyBytes))
    }

    private func assertFailure(_ helper: NativeHelperTransport, command: String = "open",
                               parameters: [String: Any] = [:], code: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try helper.call(command, parameters), file: file, line: line) { error in
            XCTAssertEqual((error as? NativeSaveError)?.code, code, file: file, line: line)
        }
        helper.dispose()
        XCTAssertFalse(helper.isRunning, "Helper must be reaped", file: file, line: line)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3, file: file, line: line)
    }

    func testStalledResponseTimesOutAndStopsHelper() throws {
        let helper = try helper("read request; while :; do :; done")
        assertFailure(helper, code: "ENGINE_TIMEOUT")
    }

    func testBackpressureHasWriteDeadline() throws {
        let helper = try helper("while :; do :; done")
        assertFailure(helper, parameters: ["password": String(repeating: "private", count: 200_000)], code: "ENGINE_TIMEOUT")
    }

    func testClosedInputDoesNotSendSIGPIPEToApp() throws {
        let helper = try helper("exec 0<&-; while :; do :; done")
        assertFailure(helper, parameters: ["payload": String(repeating: "x", count: 1_000_000)], code: "ENGINE_CONNECTION_LOST")
    }

    func testCrashAndTruncatedResponseFailPromptly() throws {
        let helper = try helper("read request; printf '{\"ok\":'; exit 1")
        assertFailure(helper, code: "ENGINE_CONNECTION_LOST")
    }

    func testInvalidJSONStopsStubbornHelper() throws {
        let helper = try helper("trap '' TERM; read request; printf 'invalid\\n'; while :; do :; done")
        assertFailure(helper, code: "ENGINE_CONNECTION_LOST")
    }

    func testOversizedResponseStopsHelper() throws {
        let helper = try helper("read request; while :; do printf 'xxxxxxxxxxxxxxxx'; done", maximumReplyBytes: 128)
        assertFailure(helper, code: "ENGINE_CONNECTION_LOST")
    }

    func testUnacknowledgedSaveIsExplicitlyUncertain() throws {
        let helper = try helper("read request; exit 0")
        XCTAssertThrowsError(try helper.call("save", [:])) { error in
            let failure = error as? NativeSaveError
            XCTAssertEqual(failure?.code, "SAVE_OUTCOME_UNKNOWN")
            XCTAssertTrue(failure?.message.contains("may already have been replaced") == true)
            XCTAssertTrue(failure?.message.contains("before retrying") == true)
        }
        helper.dispose()
        XCTAssertFalse(helper.isRunning)
    }

    func testLostAcknowledgementCanFollowActualDestinationReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("saved.pdf")
        try Data("old".utf8).write(to: target)
        // The helper simulates publication followed by a crash before its receipt.
        let helper = try NativeHelperTransport(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "read request; printf 'new' > \"$1\"; exit 1", "helper", target.path],
            environment: [:], limits: .init(command: 1, shutdownGrace: 0.05,
                                             terminationGrace: 0.05, killGrace: 0.5))
        assertFailure(helper, command: "save", code: "SAVE_OUTCOME_UNKNOWN")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")
    }

    func testSaveTimeoutDoesNotClaimFileWasUnchanged() throws {
        let helper = try helper("read request; while :; do :; done")
        assertFailure(helper, command: "save", code: "SAVE_OUTCOME_UNKNOWN")
    }

    func testSaveTransportErrorDoesNotClaimCertainFailure() throws {
        let helper = try helper("read request; printf '%s\\n' '{\"ok\":false,\"error\":{\"code\":\"TRANSPORT_FAILED\"}}'")
        assertFailure(helper, command: "save", code: "SAVE_OUTCOME_UNKNOWN")
    }

    func testValidStructuredPolicyFailureIsPreserved() throws {
        let helper = try helper("read request; printf '%s\\n' '{\"ok\":false,\"error\":{\"code\":\"XFA_BLOCKED\",\"message\":\"Read only.\"}}'")
        assertFailure(helper, code: "XFA_BLOCKED")
    }

    func testValidReplyFollowedByHungShutdownIsBounded() throws {
        let helper = try helper("trap '' TERM; read request; printf '%s\\n' '{\"ok\":true,\"result\":{\"value\":42}}'; while :; do :; done")
        let response = try helper.call("inspect_policy", [:])
        XCTAssertEqual((response["result"] as? [String: Int])?["value"], 42)
        let started = ProcessInfo.processInfo.systemUptime
        helper.dispose()
        helper.dispose() // Idempotent; never send a signal after process exit.
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
        XCTAssertFalse(helper.isRunning)
    }

    func testValidSaveReplyWithMissingResultStillReportsUncertainOutcome() throws {
        let helper = try helper("read request; printf '%s\\n' '{\"ok\":true}'")
        _ = try helper.call("save", [:])
        XCTAssertEqual(helper.invalidReply().code, "SAVE_OUTCOME_UNKNOWN")
        helper.dispose()
    }
    func testUnverifiedGroupHandshakeIsRejectedWithoutSignallingAppGroup() throws {
        XCTAssertThrowsError(try NativeHelperTransport(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n' '{\"transport_ready\":true,\"pid\":1,\"process_group\":1}'; read request"],
            environment: [:], limits: .init(command: 0.5, shutdownGrace: 0.05,
                                             terminationGrace: 0.05, killGrace: 0.5), requiresProcessGroup: true)) { error in
            XCTAssertEqual((error as? NativeSaveError)?.code, "ENGINE_UNAVAILABLE")
        }
    }

    private func groupHelper(parentExits: Bool) throws -> NativeHelperTransport {
        let runtime = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("EngineRuntime"))
        let python = runtime.appendingPathComponent("python/bin/python3.13")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: python.path))
        let script = """
        import os, sys, signal, json
        if os.getpgrp() != os.getpid(): os.setsid()
        print(json.dumps(dict(transport_ready=True,pid=os.getpid(),process_group=os.getpgrp())),flush=True)
        sys.stdin.readline()
        child=os.fork()
        if child == 0:
            signal.signal(signal.SIGTERM,signal.SIG_IGN)
            while True: signal.pause()
        print(json.dumps(dict(ok=True,result=dict(child=child))),flush=True)
        if \(parentExits ? "True" : "False"): os._exit(0)
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        while True: signal.pause()
        """
        return try NativeHelperTransport(executable: python, arguments: ["-B", "-u", "-c", script],
            environment: ["PYTHONHOME": runtime.appendingPathComponent("python").path,
                          "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1"],
            limits: .init(command: 2, shutdownGrace: 0.05, terminationGrace: 0.05, killGrace: 0.5),
            requiresProcessGroup: true)
    }

    private func assertChildCleanup(parentExits: Bool) throws {
        let helper = try groupHelper(parentExits: parentExits)
        let response = try helper.call("open", [:])
        let pid = try XCTUnwrap((response["result"] as? [String: Int])?["child"])
        helper.dispose()
        XCTAssertFalse(helper.isRunning)
        // launchd may need a moment to reap an orphan after the group is killed.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while Darwin.kill(pid_t(pid), 0) == 0 && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(Darwin.kill(pid_t(pid), 0), -1, "Native child must not outlive cleanup")
        XCTAssertEqual(errno, ESRCH)
    }

    func testTimeoutCleanupStopsOwnedChildProcess() throws {
        try assertChildCleanup(parentExits: false)
    }

    func testCleanupStopsChildAfterHelperAlreadyExited() throws {
        try assertChildCleanup(parentExits: true)
    }

}
