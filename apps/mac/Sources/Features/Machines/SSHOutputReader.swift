// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

struct SSHOutputChunk: Sendable {
    var data: [UInt8]
    var nextOffset: UInt64
    var dropped: Bool
    var closed: Bool
    var error: String?
}

enum SSHOutputReaderError: LocalizedError {
    case sessionMissing, invalidOffset
    var errorDescription: String? {
        switch self {
        case .sessionMissing: L10n.text("apple.sshliveterminal.session_unavailable")
        case .invalidOffset: L10n.text("apple.sshliveterminal.invalid_output_position")
        }
    }
}

/// Keeps an output cursor across reversible pauses. The emulator and output
/// filter belong to the terminal; this reader never replaces either one.
@MainActor
final class SSHOutputReader {
    private(set) var offset: UInt64 = 0
    private(set) var foreground = true
    private(set) var retired = false
    private(set) var shellEnded = false
    private(set) var drained = false
    private(set) var inputEpoch: UInt64 = 0
    private var ticket: UUID?
    private var closeTicket: UUID?
    private var task: Task<Void, Never>?
    private let read: @MainActor (UInt64) async throws -> SSHOutputChunk
    private let deliver: @MainActor (SSHOutputChunk) -> Void
    private let failed: @MainActor (Error) -> Void
    private let sleep: @Sendable (UInt64) async -> Void

    init(read: @escaping @MainActor (UInt64) async throws -> SSHOutputChunk,
         deliver: @escaping @MainActor (SSHOutputChunk) -> Void,
         failed: @escaping @MainActor (Error) -> Void,
         sleep: @escaping @Sendable (UInt64) async -> Void = { milliseconds in
             try? await Task.sleep(for: .milliseconds(milliseconds))
         }) {
        self.read = read
        self.deliver = deliver
        self.failed = failed
        self.sleep = sleep
    }

    deinit { task?.cancel() }

    var canInput: Bool { foreground && !retired && !shellEnded && closeTicket == nil }
    private var canRead: Bool { foreground && !retired && !drained && closeTicket == nil }

    func acceptsInput(_ epoch: UInt64) -> Bool { canInput && epoch == inputEpoch }

    func setForeground(_ value: Bool) {
        guard !retired, foreground != value else { return }
        foreground = value
        inputEpoch &+= 1
        cancelRead()
        if value { start() }
    }

    func noteShellEnded() {
        guard !shellEnded else { return }
        shellEnded = true
        inputEpoch &+= 1
        // Metadata can precede the last output chunk. Keep draining.
    }

    func retire() {
        guard !retired else { return }
        retired = true
        inputEpoch &+= 1
        cancelRead()
    }

    /// Closing is available while paused and after EOF. Failure leaves the
    /// same reader retryable; success permanently retires it.
    func beginClose() -> UUID? {
        guard !retired, closeTicket == nil else { return nil }
        let token = UUID()
        closeTicket = token
        inputEpoch &+= 1
        cancelRead()
        return token
    }

    func finishClose(_ token: UUID, succeeded: Bool) {
        guard closeTicket == token else { return }
        closeTicket = nil
        if succeeded { retire() }
        else { start() }
    }

    func start() {
        guard canRead, ticket == nil else { return }
        let token = UUID()
        ticket = token
        let read = read, deliver = deliver, failed = failed, sleep = sleep
        task = Task { @MainActor [weak self] in
            defer { self?.finish(token) }
            while !Task.isCancelled {
                guard let position = self?.position(token) else { return }
                do {
                    let chunk = try await read(position)
                    guard !Task.isCancelled, self?.position(token) == position else { return }
                    guard chunk.nextOffset >= position, chunk.data.isEmpty || chunk.nextOffset > position
                    else { throw SSHOutputReaderError.invalidOffset }
                    guard self?.accept(chunk, position: position, ticket: token) == true else { return }
                    deliver(chunk)
                    if self?.drained == true { return }
                    await sleep(chunk.data.isEmpty ? 50 : 16)
                } catch {
                    guard !Task.isCancelled, self?.position(token) == position else { return }
                    if case SSHOutputReaderError.sessionMissing = error {
                        self?.noteShellEnded()
                        self?.drained = true
                        failed(error)
                        return
                    }
                    failed(error)
                    await sleep(500)
                }
            }
        }
    }

    private func position(_ token: UUID) -> UInt64? {
        canRead && ticket == token ? offset : nil
    }

    private func accept(_ chunk: SSHOutputChunk, position: UInt64, ticket token: UUID) -> Bool {
        guard self.position(token) == position, chunk.nextOffset >= position,
              chunk.data.isEmpty || chunk.nextOffset > position else { return false }
        offset = chunk.nextOffset
        if chunk.closed {
            noteShellEnded()
            // Read once at the consumed end offset. The host then knows the
            // final bytes were delivered, rather than merely sent to a task
            // that might have been cancelled before feeding its emulator.
            drained = chunk.data.isEmpty
        }
        return true
    }

    private func cancelRead() {
        ticket = nil
        task?.cancel()
        task = nil
    }

    private func finish(_ token: UUID) {
        guard ticket == token else { return }
        ticket = nil
        task = nil
    }
}
