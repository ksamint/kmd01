// Standalone transport/process regression checks. Build with -D STABILITY_STANDALONE
// and the production ProcessOutput, LocalAgentBridge, LocalMCPUnixBridge sources.
import Darwin
import Foundation

#if STABILITY_STANDALONE
// Only the MCP request dispatcher is stubbed; socket lifecycle and framing are real.
public actor LocalMCPServer {
  public init(workspaceURL: URL, allowWrite: Bool) throws {}
  public func prepare() async throws {}
  public func responseData(for request: Data) async -> Data {
    try? await Task.sleep(for: .milliseconds(20))
    return request
  }
}
#endif

@main
private enum SwiftStabilityTestMain {
  static func main() async throws {
    signal(SIGPIPE, SIG_IGN)
    try await processChecks()
    try await socketChecks()
    try await agentChecks()
    print("Swift stability checks passed")
  }

  static func processChecks() async throws {
    let output = try await ProcessOutput.run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "head -c 2097152 /dev/zero; head -c 2097152 /dev/zero >&2; printf diagnostic >&2; exit 7"],
      timeout: 5
    )
    precondition(output.standardOutput.count == 2 * 1024 * 1024)
    precondition(output.standardError.count == 64 * 1024)
    precondition(String(bytes: output.standardError.suffix(10), encoding: .utf8) == "diagnostic")
    precondition(output.status == 7)
    let start = Date()
    let timed = try await ProcessOutput.run(
      executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.1
    )
    precondition(timed.status != 0 && Date().timeIntervalSince(start) < 3)
    do {
      _ = try await ProcessOutput.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["too much output"], maximumBytes: 3
      )
      preconditionFailure("Oversize stdout must not be silently truncated")
    } catch ProcessOutput.Failure.outputTooLarge {}
  }

  static func socketChecks() async throws {
    signal(SIGPIPE, SIG_DFL)
    defer { signal(SIGPIPE, SIG_IGN) }
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for _ in 0..<10 {
      let server = try await LocalMCPUnixServer.start(workspaceURL: root, runtimeRoot: root)
      let descriptor = try connect(server.connectionInfo.socketPath)
      let token = try String(contentsOf: server.connectionInfo.capabilityFileURL, encoding: .utf8)
      let request = Data(("{\"capability\":\"\(token)\"}\n{\"id\":1}\n").utf8)
      _ = request.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
      var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      precondition(Darwin.poll(&ready, 1, 2_000) > 0)
      var bytes = [UInt8](repeating: 0, count: 1024)
      precondition(Darwin.read(descriptor, &bytes, bytes.count) > 0)
      let disconnectedPeer = try connect(server.connectionInfo.socketPath)
      _ = request.withUnsafeBytes { Darwin.write(disconnectedPeer, $0.baseAddress, $0.count) }
      Darwin.close(disconnectedPeer)
      try await Task.sleep(for: .milliseconds(60))
      server.stop()
      server.stop()
      ready.revents = 0
      precondition(Darwin.poll(&ready, 1, 2_000) > 0, "stop must wake accepted clients")
      precondition(Darwin.read(descriptor, &bytes, bytes.count) == 0)
      Darwin.close(descriptor)
      precondition(!FileManager.default.fileExists(atPath: server.connectionInfo.socketPath))
      precondition(!FileManager.default.fileExists(atPath: server.connectionInfo.capabilityFileURL.path))
    }
    let server = try await LocalMCPUnixServer.start(workspaceURL: root, runtimeRoot: root)
    defer { server.stop() }
    let descriptor = try connect(server.connectionInfo.socketPath)
    defer { Darwin.close(descriptor) }
    let token = try String(contentsOf: server.connectionInfo.capabilityFileURL, encoding: .utf8)
    let finalRequest = Data(("{\"capability\":\"\(token)\"}\n{\"id\":2}").utf8)
    _ = finalRequest.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    Darwin.shutdown(descriptor, SHUT_WR)
    var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    precondition(Darwin.poll(&ready, 1, 2_000) > 0)
    var bytes = [UInt8](repeating: 0, count: 1024)
    let count = Darwin.read(descriptor, &bytes, bytes.count)
    precondition(String(bytes: bytes.prefix(max(0, count)), encoding: .utf8) == "{\"id\":2}\n")
    precondition(Darwin.poll(&ready, 1, 2_000) > 0)
    precondition(Darwin.read(descriptor, &bytes, bytes.count) == 0, "An EOF line must not be replayed forever")
  }

  static func connect(_ path: String) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.initializeMemory(as: UInt8.self, repeating: 0)
      buffer.copyBytes(from: path.utf8)
    }
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    precondition(result == 0)
    return descriptor
  }

  static func agentChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cli = root.appending(path: "mock-cli")
    let responsiveScript = #"""
    #!/bin/sh
    while read request; do
      case "$request" in
        *control_request*) ;;
        *slow*) sleep 3; touch completed; printf '%s\n' '{"type":"result","is_error":false}' ;;
        *) printf '%s\n' '{"type":"result","is_error":false}' ;;
      esac
    done
    """#
    try responsiveScript.write(to: cli, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
    let configuration = LocalAgentMCPConfiguration(
      helperExecutableURL: cli,
      connection: LocalMCPConnectionInfo(socketPath: "/tmp/unused.sock", capabilityFileURL: root.appending(path: "token")),
      configurationDirectory: root.appending(path: "config")
    )
    let bridge = LocalAgentBridge()
    let received = ReceivedEvents()
    let events = Task {
      for await event in bridge.events { await received.record(event) }
    }
    defer { events.cancel() }
    // A previous CLI's exit callback must never disconnect its replacement.
    for _ in 0..<10 {
      try await bridge.start(provider: .claude, executableURL: cli, workspaceURL: root, mcp: configuration, applicationVersion: "test")
    }
    try await Task.sleep(for: .milliseconds(200))
    try await bridge.send("ping")
    await received.waitForCompletions(1)
    try await bridge.send("ping again")
    await bridge.cancel()
    await received.waitForCompletions(2)
    try await bridge.send("slow")
    await received.waitForCompletions(3)
    precondition(
      FileManager.default.fileExists(atPath: root.appending(path: "completed").path),
      "A prior cancellation timer must not kill the next Claude turn"
    )
    try await bridge.send("still connected")
    await received.waitForCompletions(4)
    await bridge.stop()

    try #"""
    #!/bin/sh
    trap '' TERM
    echo $$ > pid
    while :; do sleep 0.1; done
    """#.write(to: cli, atomically: true, encoding: .utf8)
    try await bridge.start(provider: .claude, executableURL: cli, workspaceURL: root, mcp: configuration, applicationVersion: "test")
    let pidURL = root.appending(path: "pid")
    let pidDeadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: pidURL.path) && Date() < pidDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    guard let pid = Int32(try String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) else {
      preconditionFailure("The mock CLI must report its process identifier")
    }
    await bridge.stop()
    try await Task.sleep(for: .milliseconds(1400))
    precondition(Darwin.kill(pid, 0) == -1 && errno == ESRCH, "stop must reap a CLI that ignores SIGTERM")

    try FileManager.default.removeItem(at: pidURL)
    var orphan: LocalAgentBridge? = LocalAgentBridge()
    try await orphan?.start(provider: .claude, executableURL: cli, workspaceURL: root, mcp: configuration, applicationVersion: "test")
    let orphanDeadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: pidURL.path) && Date() < orphanDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    guard let orphanPID = Int32(try String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) else {
      preconditionFailure("The orphan CLI must report its process identifier")
    }
    orphan = nil
    try await Task.sleep(for: .milliseconds(1400))
    precondition(Darwin.kill(orphanPID, 0) == -1 && errno == ESRCH, "Dropping the bridge must reap its CLI")

    try await bridge.start(provider: .claude, executableURL: cli, workspaceURL: root, mcp: configuration, applicationVersion: "test")
    let writeStarted = Date()
    do {
      try await bridge.send(String(repeating: "x", count: 2 * 1024 * 1024))
      preconditionFailure("A CLI that never reads stdin must fail a backpressured write")
    } catch {
      precondition(Date().timeIntervalSince(writeStarted) < 2, "A backpressured pipe must not block cancellation")
    }
    await bridge.stop()
    try responsiveScript.write(to: cli, atomically: true, encoding: .utf8)
    try await bridge.start(provider: .claude, executableURL: cli, workspaceURL: root, mcp: configuration, applicationVersion: "test")
    try await bridge.send("reconnected after backpressure")
    await received.waitForCompletions(5)
    await bridge.stop()
  }
}

private actor ReceivedEvents {
  private var completed = 0
  private var messages = [String]()

  func record(_ event: LocalAgentEvent) {
    if case .completed = event { completed += 1 }
    if case let .error(message) = event { messages.append(message) }
  }

  func waitForCompletions(_ count: Int) async {
    let deadline = Date().addingTimeInterval(6)
    while completed < count && Date() < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    precondition(completed >= count, "Missing completion \(count): \(messages)")
  }
}
