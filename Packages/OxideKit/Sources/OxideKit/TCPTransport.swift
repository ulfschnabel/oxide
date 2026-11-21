import Foundation
import Network

public enum TransportError: Error, Equatable {
    case failed(String)
}

/// A TCP connection to a host, over Network.framework.
public final class TCPTransport: Transport, @unchecked Sendable {
    public static let defaultPort: UInt16 = 21118
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "oxide.tcp")

    public init(host: String, port: UInt16 = TCPTransport.defaultPort) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true  // input events are small and latency-bound
        tcp.connectionTimeout = 10
        connection = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
            using: NWParameters(tls: nil, tcp: tcp))
    }

    /// Opens the connection; throws if the host cannot be reached or the
    /// task is cancelled. On failure the connection is torn down, not left
    /// retrying in the background.
    public func connect() async throws {
        let connection = connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                let once = Once()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        once.run { done.resume() }
                    case .failed(let e), .waiting(let e):
                        once.run {
                            connection.cancel()
                            done.resume(throwing: TransportError.failed(e.localizedDescription))
                        }
                    case .cancelled:
                        once.run { done.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { done.resume(throwing: TransportError.failed(error.localizedDescription)) } else { done.resume() }
            })
        }
    }

    public func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let error {
                    done.resume(throwing: TransportError.failed(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    done.resume(returning: data)
                } else if isComplete {
                    done.resume(returning: nil)
                } else {
                    done.resume(returning: Data())
                }
            }
        }
    }

    public func close() {
        connection.cancel()
    }
}

/// Runs a closure at most once, from any thread.
private final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
