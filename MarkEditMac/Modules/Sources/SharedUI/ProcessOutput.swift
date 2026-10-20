import Darwin
import Foundation

/// Runs short-lived tools without filling either pipe or blocking an actor executor.
public struct ProcessOutput: Sendable {
  public enum Failure: Error { case outputTooLarge }

  public let standardOutput: Data
  public let standardError: Data
  public let status: Int32

  public static func run(
    executableURL: URL,
    arguments: [String],
    timeout: TimeInterval = 30,
    maximumBytes: Int = 32 * 1024 * 1024
  ) async throws -> Self {
    try await withCheckedThrowingContinuation { continuation in
      Thread {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        do {
          try process.run()
        } catch {
          continuation.resume(throwing: error)
          return
        }
        let processID = process.processIdentifier
        let hasGroup = getpgid(processID) == processID
        let deadline = DispatchWorkItem {
          if hasGroup {
            Darwin.kill(-processID, SIGKILL)
          } else if process.isRunning {
            Darwin.kill(processID, SIGKILL)
          }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        let errorBox = OutputBox()
        let drained = DispatchSemaphore(value: 0)
        Thread {
          errorBox.result = Result { try read(errors.fileHandleForReading, maximumBytes: min(maximumBytes, 64 * 1024), truncate: true) }
          drained.signal()
        }.start()
        let standardOutput = Result { try read(output.fileHandleForReading, maximumBytes: maximumBytes) }
        drained.wait()
        process.waitUntilExit()
        deadline.cancel()
        continuation.resume(with: Result {
          try Self(
            standardOutput: standardOutput.get(),
            standardError: errorBox.result.get(),
            status: process.terminationStatus
          )
        })
      }.start()
    }
  }

  private final class OutputBox: @unchecked Sendable {
    // Written on the stderr thread, read only after its semaphore signals.
    var result: Result<Data, Error> = .success(Data())
  }

  private static func read(_ handle: FileHandle, maximumBytes: Int, truncate: Bool = false) throws -> Data {
    defer { try? handle.close() }
    var result = Data()
    var overflowed = false
    while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
      let available = max(0, maximumBytes - result.count)
      overflowed = overflowed || chunk.count > available
      if truncate {
        result.append(chunk)
        if result.count > maximumBytes { result.removeFirst(result.count - maximumBytes) }
      } else {
        result.append(chunk.prefix(available))
      }
    }
    if overflowed && !truncate { throw Failure.outputTooLarge }
    return result
  }
}
