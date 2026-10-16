import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Synchronization

/// A terminal on a server over SSH: a login shell in a pseudo-terminal, started in a folder,
/// signed in with this device's key (`SSHIdentity`), the server known by its key (`KnownHosts`).
/// What the shell prints arrives as `Event.output`; keystrokes go back with `send`.
nonisolated final class SSHShell: Sendable {
    struct Target: Equatable, Sendable {
        var host: String
        var port: Int
        var user: String
        /// Where the shell starts; nil for the user's home folder.
        var folder: String?
    }

    enum Event: Equatable, Sendable {
        case output([UInt8])
        /// The shell is gone: the exit status when the server said, else why.
        case ended(String)
    }

    enum Problem: LocalizedError, Equatable {
        /// The device's key couldn't be made or kept (the Keychain is locked).
        case noKey
        /// A server met for the first time: nothing is sent before the person trusts its key
        /// (`KnownHosts.trust`); the next connection checks it against that. Asking with the
        /// connection open would lose it to the server's sign-in deadline (2 minutes in OpenSSH).
        case unknownServer(fingerprint: String)
        /// The server showed a different key from the one trusted before.
        case serverKeyChanged(expected: String, presented: String)
        /// The server turned the device's key down: it isn't in authorized_keys for that user.
        case keyNotAccepted
        case unreachable(String)
        case noShell

        var errorDescription: String? {
            switch self {
            case .noKey: "This device couldn't make or keep its SSH key. Unlock it and try again."
            case let .unknownServer(fingerprint): "This iPhone hasn't met this server before (its key is \(fingerprint))."
            case let .serverKeyChanged(expected, presented):
                "The server's key has changed since you trusted it (was \(expected), now \(presented)). If the server was reinstalled, forget its old key in Settings › Terminal and connect again; if not, someone may be in the way."
            case .keyNotAccepted: "The server didn't accept this device's key. Add the key below to ~/.ssh/authorized_keys for that user."
            case let .unreachable(why): "Couldn't reach the server: \(why)"
            case .noShell: "The server didn't start a shell."
            }
        }
    }

    private let parent: Channel
    private let child: Channel

    private init(parent: Channel, child: Channel) {
        self.parent = parent
        self.child = child
    }

    /// Connects, signs in and starts the shell. A server not met before throws
    /// `Problem.unknownServer` with its key's fingerprint, having sent nothing.
    static func open(_ target: Target, columns: Int, rows: Int) async throws -> (SSHShell, AsyncStream<Event>) {
        guard let key = SSHIdentity.privateKey() else { throw Problem.noKey }
        let (events, continuation) = AsyncStream<Event>.makeStream()
        let problem = ProblemNote()
        let user = target.user, hostName = KnownHosts.name(host: target.host, port: target.port)
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(10))
            .channelOption(.socketOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(.init(
                            userAuthDelegate: KeySignIn(user: user, key: NIOSSHPrivateKey(ed25519Key: key), problem: problem),
                            serverAuthDelegate: ServerKeyCheck(name: hostName, problem: problem))),
                        allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandler(ssh)
                    try channel.pipeline.syncOperations.addHandler(CloseOnError())
                }
            }
        let parent: Channel
        do {
            parent = try await bootstrap.connect(host: target.host, port: target.port).get()
        } catch {
            continuation.finish()
            throw Problem.unreachable(Self.describe(error))
        }
        let folder = target.folder
        do {
            // The session channel opens once the server has let this device in: the key checks
            // (and the person's answer about a new server) happen while this waits.
            let child = try await parent.eventLoop.flatSubmit { () -> EventLoopFuture<Channel> in
                let promise = parent.eventLoop.makePromise(of: Channel.self)
                do {
                    let ssh = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                    ssh.createChannel(promise, channelType: .session) { child, type in
                        guard type == .session else { return child.eventLoop.makeFailedFuture(Problem.noShell) }
                        return child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandler(
                                ShellChannel(folder: folder, columns: columns, rows: rows, events: continuation))
                        }
                    }
                } catch {
                    promise.fail(error)
                }
                return promise.futureResult
            }.get()
            return (SSHShell(parent: parent, child: child), events)
        } catch {
            parent.close(promise: nil)
            continuation.finish()
            throw problem.value ?? Problem.unreachable(Self.describe(error))
        }
    }

    /// What was typed, as the terminal encodes it.
    func send(_ bytes: [UInt8]) {
        child.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: bytes))), promise: nil)
    }

    /// The screen's new size, for the shell and what runs in it (SIGWINCH on the server).
    func resize(columns: Int, rows: Int) {
        let change = SSHChannelRequestEvent.WindowChangeRequest(terminalCharacterWidth: columns, terminalRowHeight: rows,
                                                                terminalPixelWidth: 0, terminalPixelHeight: 0)
        child.triggerUserOutboundEvent(change, promise: nil)
    }

    func close() {
        parent.close(promise: nil)
    }

    /// The shell, started in `folder` when there is one: `cd` there (a missing folder says so
    /// and leaves the shell at home), then the user's own login shell in its place.
    static func startCommand(folder: String) -> String {
        let quoted = "'" + folder.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "cd \(quoted) 2>/dev/null || printf '%s\\r\\n' 'That folder is not on this server: starting in your home folder.'; "
            + "exec \"${SHELL:-/bin/sh}\" -l"
    }

    static func describe(_ error: Error) -> String {
        if let problem = error as? Problem { return problem.localizedDescription }
        if let connect = error as? NIOConnectionError {
            return connect.connectionErrors.first.map { "\($0.error)" } ?? "\(connect)"
        }
        if error is ChannelError { return "the connection closed." }
        return "\(error)"
    }
}

/// Why connecting failed, as the key checks saw it: the connection itself only says it closed.
private nonisolated final class ProblemNote: Sendable {
    private let note = Mutex<SSHShell.Problem?>(nil)
    var value: SSHShell.Problem? {
        get { note.withLock { $0 } }
        set { note.withLock { $0 = newValue } }
    }
}

/// Signs in with the device's key, once: asked again means the server turned it down.
private nonisolated final class KeySignIn: NIOSSHClientUserAuthenticationDelegate {
    private let user: String
    private let key: NIOSSHPrivateKey
    private let problem: ProblemNote
    private var offered = false

    init(user: String, key: NIOSSHPrivateKey, problem: ProblemNote) {
        self.user = user
        self.key = key
        self.problem = problem
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered, availableMethods.contains(.publicKey) else {
            problem.value = .keyNotAccepted
            nextChallengePromise.fail(SSHShell.Problem.keyNotAccepted)
            return
        }
        offered = true
        nextChallengePromise.succeed(.init(username: user, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}

/// The server's key against the one trusted before; a server not met before stops here.
private nonisolated final class ServerKeyCheck: NIOSSHClientServerAuthenticationDelegate {
    private let name: String
    private let problem: ProblemNote

    init(name: String, problem: ProblemNote) {
        self.name = name
        self.problem = problem
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = KnownHosts.fingerprint(of: hostKey)
        switch KnownHosts.trusted(name) {
        case presented?:
            validationCompletePromise.succeed(())
        case let expected?:
            let changed = SSHShell.Problem.serverKeyChanged(expected: expected, presented: presented)
            problem.value = changed
            validationCompletePromise.fail(changed)
        case nil:
            let unknown = SSHShell.Problem.unknownServer(fingerprint: presented)
            problem.value = unknown
            validationCompletePromise.fail(unknown)
        }
    }
}

/// The session channel: asks for a pseudo-terminal and a shell, hands on what the shell prints,
/// and says when it is gone.
private nonisolated final class ShellChannel: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let folder: String?
    private let columns: Int
    private let rows: Int
    private let events: AsyncStream<SSHShell.Event>.Continuation
    private var exitStatus: Int?
    private var refused = false

    init(folder: String?, columns: Int, rows: Int, events: AsyncStream<SSHShell.Event>.Continuation) {
        self.folder = folder
        self.columns = columns
        self.rows = rows
        self.events = events
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelActive(context: ChannelHandlerContext) {
        let terminal = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: "xterm-256color", terminalCharacterWidth: columns, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:]))
        context.triggerUserOutboundEvent(terminal, promise: nil)
        if let folder, !folder.isEmpty {
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: SSHShell.startCommand(folder: folder), wantReply: true), promise: nil)
        } else {
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case var .byteBuffer(buffer) = message.data, let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        events.yield(.output(bytes))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitStatus = status.exitStatus
        case is ChannelFailureEvent:
            // The server said no to the terminal or the shell.
            refused = true
            context.close(promise: nil)
        case ChannelEvent.inputClosed:
            context.close(promise: nil)
        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        let why = refused ? "The server didn't start a shell." : exitStatus.map { "The shell ended (exit status \($0))." } ?? "The connection closed."
        events.yield(.ended(why))
        events.finish()
        context.channel.parent?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// An error on the connection itself (a broken handshake, a refused key) closes it.
private nonisolated final class CloseOnError: ChannelInboundHandler {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
