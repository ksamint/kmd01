//
//  LocalMCPUnixBridge.swift
//
//  Capability-authenticated Unix socket used only while the Agent panel is open.
//

import Darwin
import Foundation

public struct LocalMCPConnectionInfo: Sendable {
  public let socketPath: String
  public let capabilityFileURL: URL

  public init(socketPath: String, capabilityFileURL: URL) {
    self.socketPath = socketPath
    self.capabilityFileURL = capabilityFileURL
  }
}

public final class LocalMCPUnixServer: @unchecked Sendable {
  public enum BridgeError: LocalizedError {
    case invalidSocketPath
    case socketFailure(String)
    case authenticationFailed
    case messageTooLarge
    case disconnected

    public var errorDescription: String? {
      switch self {
      case .invalidSocketPath:
        "The local MCP socket path is invalid."
      case let .socketFailure(operation):
        "The local MCP socket could not \(operation)."
      case .authenticationFailed:
        "The local MCP capability token was rejected."
      case .messageTooLarge:
        "The local MCP message exceeds its safety limit."
      case .disconnected:
        "The local MCP connection closed unexpectedly."
      }
    }
  }

  public let connectionInfo: LocalMCPConnectionInfo

  private static let maximumRequestBytes = 2 * 1024 * 1024
  private static let maximumResponseBytes = 16 * 1024 * 1024
  private let listener: Int32
  private let capability: String
  private let server: LocalMCPServer
  private let acceptThread: Thread
  private let stopFlag = StopFlag()
  private let runtimeDirectory: URL
  private let stateLock = NSLock()
  private var stopped = false

  /// Shared between `stop()` and the accept thread.
  final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var clients = Set<Int32>()

    var isSet: Bool {
      lock.lock()
      defer { lock.unlock() }
      return value
    }

    func insert(_ client: Int32) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard !value, clients.count < 8 else { return false }
      clients.insert(client)
      return true
    }

    func close(_ client: Int32) {
      lock.lock()
      defer { lock.unlock() }
      clients.remove(client)
      Darwin.close(client)
    }

    func set() {
      lock.lock()
      value = true
      for client in clients {
        Darwin.shutdown(client, SHUT_RDWR)
      }
      lock.unlock()
    }
  }

  public static func start(
    workspaceURL: URL,
    runtimeRoot: URL = URL.applicationSupportDirectory
      // Preserve the legacy storage path so the rename does not orphan MCP
      // sockets, capabilities, or audit history.
      .appending(path: "ksamint MarkEdit", directoryHint: .isDirectory)
      .appending(path: "AgentBridge", directoryHint: .isDirectory)
  ) async throws -> LocalMCPUnixServer {
    let server = try LocalMCPServer(workspaceURL: workspaceURL, allowWrite: false)
    try await server.prepare()
    let runtimeDirectory = runtimeRoot.appending(
      path: UUID().uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: runtimeDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    var started = false
    defer {
      if !started { try? FileManager.default.removeItem(at: runtimeDirectory) }
    }
    let capability = Self.randomCapability()
    let capabilityFileURL = runtimeDirectory.appending(path: "capability", directoryHint: .notDirectory)
    try Data(capability.utf8).write(to: capabilityFileURL, options: [.atomic, .completeFileProtection])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: capabilityFileURL.path
    )

    let socketPath = "/tmp/ksamint-agent-\(getuid())-\(UUID().uuidString.prefix(12)).sock"
    let listener = try SocketIO.listen(path: socketPath)
    let bridge = LocalMCPUnixServer(
      listener: listener,
      socketPath: socketPath,
      capabilityFileURL: capabilityFileURL,
      capability: capability,
      server: server,
      runtimeDirectory: runtimeDirectory
    )
    started = true
    return bridge
  }

  private init(
    listener: Int32,
    socketPath: String,
    capabilityFileURL: URL,
    capability: String,
    server: LocalMCPServer,
    runtimeDirectory: URL
  ) {
    self.listener = listener
    self.connectionInfo = LocalMCPConnectionInfo(
      socketPath: socketPath,
      capabilityFileURL: capabilityFileURL
    )
    self.capability = capability
    self.server = server
    self.runtimeDirectory = runtimeDirectory

    // The accept loop and each connection block in poll/read/write. They run
    // on dedicated threads rather than detached tasks so they never occupy
    // the fixed-size cooperative pool that every actor in the app shares.
    let stopFlag = self.stopFlag
    let thread = Thread {
      Self.acceptLoop(listener: listener, capability: capability, server: server, stopFlag: stopFlag)
    }
    thread.name = "kmd.mcp.accept"
    thread.qualityOfService = .utility
    self.acceptThread = thread
    thread.start()
  }

  private static func acceptLoop(
    listener: Int32,
    capability: String,
    server: LocalMCPServer,
    stopFlag: StopFlag
  ) {
    defer { Darwin.close(listener) }
    while !stopFlag.isSet {
      var readiness = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
      let ready = Darwin.poll(&readiness, 1, 250)
      if stopFlag.isSet {
        break
      }
      if ready == 0 {
        continue
      }
      if ready < 0 {
        if errno == EINTR {
          continue
        }
        break
      }
      guard readiness.revents & Int16(POLLIN) != 0 else {
        break
      }
      let client = Darwin.accept(listener, nil, nil)
      if client < 0 {
        if errno == EINTR {
          continue
        }
        break
      }
      guard stopFlag.insert(client) else {
        Darwin.close(client)
        continue
      }
      guard SocketIO.configure(client) else {
        stopFlag.close(client)
        continue
      }
      let connection = Thread {
        defer {
          stopFlag.close(client)
        }
        try? Self.serve(client: client, capability: capability, server: server, stopFlag: stopFlag)
      }
      connection.name = "kmd.mcp.connection"
      connection.qualityOfService = .utility
      connection.start()
    }
  }

  deinit {
    stop()
  }

  public func stop() {
    stateLock.lock()
    guard !stopped else {
      stateLock.unlock()
      return
    }
    stopped = true
    stateLock.unlock()
    stopFlag.set()
    // The accept thread owns close, preventing descriptor reuse while it is polling.
    Darwin.unlink(connectionInfo.socketPath)
    try? FileManager.default.removeItem(at: runtimeDirectory)
  }
}

public enum LocalMCPUnixClient {
  public static func run(
    socketPath: String,
    capabilityFileURL: URL,
    input: FileHandle = .standardInput,
    output: FileHandle = .standardOutput
  ) async throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: capabilityFileURL.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
    guard permissions & 0o077 == 0, owner == nil || owner == getuid() else {
      throw LocalMCPUnixServer.BridgeError.authenticationFailed
    }
    let capability = try String(contentsOf: capabilityFileURL, encoding: .utf8)
    let socket = try SocketIO.connect(path: socketPath)
    defer {
      Darwin.close(socket)
    }
    let auth = try JSONSerialization.data(withJSONObject: ["capability": capability])
    try SocketIO.writeLine(auth, to: socket)

    var responseBuffer = Data()
    for try await line in input.bytes.lines {
      let data = Data(line.utf8)
      guard data.count <= 2 * 1024 * 1024 else {
        throw LocalMCPUnixServer.BridgeError.messageTooLarge
      }
      try SocketIO.writeLine(data, to: socket)
      guard let response = try SocketIO.readLine(
        from: socket,
        buffer: &responseBuffer,
        maximumBytes: 16 * 1024 * 1024
      ) else {
        throw LocalMCPUnixServer.BridgeError.disconnected
      }
      try output.write(contentsOf: response)
      try output.write(contentsOf: Data([0x0A]))
    }
  }
}

private extension LocalMCPUnixServer {
  final class ResponseBox: @unchecked Sendable {
    var value = Data()
  }

  /// Runs on a dedicated connection thread; blocking here is intentional and
  /// keeps the socket loop off the cooperative pool.
  static func response(for request: Data, server: LocalMCPServer, stopFlag: StopFlag) throws -> Data {
    let box = ResponseBox()
    let semaphore = DispatchSemaphore(value: 0)
    let task = Task {
      box.value = await server.responseData(for: request)
      semaphore.signal()
    }
    let deadline = DispatchTime.now() + 30
    while semaphore.wait(timeout: .now() + .milliseconds(250)) != .success {
      if stopFlag.isSet || DispatchTime.now() >= deadline {
        task.cancel()
        throw BridgeError.disconnected
      }
    }
    return box.value
  }

  static func serve(client: Int32, capability: String, server: LocalMCPServer, stopFlag: StopFlag) throws {
    var input = Data()
    guard let authData = try SocketIO.readLine(
      from: client,
      buffer: &input,
      maximumBytes: maximumRequestBytes
    ),
    let auth = try JSONSerialization.jsonObject(with: authData) as? [String: Any],
    auth["capability"] as? String == capability else {
      throw BridgeError.authenticationFailed
    }

    // Authenticated sessions may remain idle between user prompts; stop() wakes them.
    var idleTimeout = timeval(tv_sec: 0, tv_usec: 0)
    _ = Darwin.setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &idleTimeout, socklen_t(MemoryLayout<timeval>.size))
    while let request = try SocketIO.readLine(
      from: client,
      buffer: &input,
      maximumBytes: maximumRequestBytes
    ) {
      let response = try Self.response(for: request, server: server, stopFlag: stopFlag)
      guard response.count <= maximumResponseBytes else {
        throw BridgeError.messageTooLarge
      }
      try SocketIO.writeLine(response, to: client)
    }
  }

  static func randomCapability() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<32)
      .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
      .joined()
  }
}

private enum SocketIO {
  static func listen(path: String) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw LocalMCPUnixServer.BridgeError.socketFailure("be created")
    }
    do {
      var address = try unixAddress(path: path)
      let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard result == 0 else {
        throw LocalMCPUnixServer.BridgeError.socketFailure("bind")
      }
      guard Darwin.chmod(path, S_IRUSR | S_IWUSR) == 0 else {
        throw LocalMCPUnixServer.BridgeError.socketFailure("set permissions")
      }
      guard Darwin.listen(descriptor, 8) == 0 else {
        throw LocalMCPUnixServer.BridgeError.socketFailure("listen")
      }
      return descriptor
    } catch {
      Darwin.close(descriptor)
      Darwin.unlink(path)
      throw error
    }
  }

  static func connect(path: String) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw LocalMCPUnixServer.BridgeError.socketFailure("be created")
    }
    let addressValue = try? unixAddress(path: path)
    guard var address = addressValue else {
      Darwin.close(descriptor)
      throw LocalMCPUnixServer.BridgeError.invalidSocketPath
    }
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      Darwin.close(descriptor)
      throw LocalMCPUnixServer.BridgeError.socketFailure("connect")
    }
    guard configure(descriptor) else {
      Darwin.close(descriptor)
      throw LocalMCPUnixServer.BridgeError.disconnected
    }
    return descriptor
  }

  /// Writes to a peer that has gone away must fail with EPIPE, not kill the
  /// process; `Application.main` also ignores SIGPIPE globally.
  static func configure(_ descriptor: Int32) -> Bool {
    var timeout = timeval(tv_sec: 30, tv_usec: 0)
    for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
      _ = Darwin.setsockopt(descriptor, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
    var enabled: Int32 = 1
    return Darwin.setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_NOSIGPIPE,
      &enabled,
      socklen_t(MemoryLayout<Int32>.size)
    ) == 0
  }

  static func readLine(
    from descriptor: Int32,
    buffer: inout Data,
    maximumBytes: Int
  ) throws -> Data? {
    while true {
      if let newline = buffer.firstIndex(of: 0x0A) {
        guard buffer.distance(from: buffer.startIndex, to: newline) <= maximumBytes else {
          throw LocalMCPUnixServer.BridgeError.messageTooLarge
        }
        let line = buffer[..<newline]
        buffer.removeSubrange(...newline)
        return Data(line)
      }
      if buffer.count > maximumBytes {
        throw LocalMCPUnixServer.BridgeError.messageTooLarge
      }
      var bytes = [UInt8](repeating: 0, count: 64 * 1024)
      let count = Darwin.read(descriptor, &bytes, bytes.count)
      if count == 0 {
        let lastLine = buffer.isEmpty ? nil : Data(buffer)
        buffer.removeAll()
        return lastLine
      }
      if count < 0 {
        if errno == EINTR {
          continue
        }
        throw LocalMCPUnixServer.BridgeError.disconnected
      }
      buffer.append(bytes, count: count)
    }
  }

  static func writeLine(_ data: Data, to descriptor: Int32) throws {
    var value = data
    value.append(0x0A)
    try value.withUnsafeBytes { rawBuffer in
      guard var base = rawBuffer.baseAddress else {
        return
      }
      var remaining = rawBuffer.count
      while remaining > 0 {
        let count = Darwin.write(descriptor, base, remaining)
        if count <= 0 {
          if count < 0, errno == EINTR {
            continue
          }
          throw LocalMCPUnixServer.BridgeError.disconnected
        }
        remaining -= count
        base = base.advanced(by: count)
      }
    }
  }

  static func unixAddress(path: String) throws -> sockaddr_un {
    let bytes = Array(path.utf8)
    var address = sockaddr_un()
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      throw LocalMCPUnixServer.BridgeError.invalidSocketPath
    }
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.initializeMemory(as: UInt8.self, repeating: 0)
      buffer.copyBytes(from: bytes)
    }
    return address
  }
}
