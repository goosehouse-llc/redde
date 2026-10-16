import Foundation
import Testing
@testable import Echo

/// The terminal against a real OpenSSH server (`scripts/terminal-lab/lab.sh test`: sshd on
/// 127.0.0.1:2222, run as the Mac's user, with keys and config of its own). The app's own SSH
/// client: a new server stopped at with its fingerprint and nothing remembered; once trusted, the
/// shell started in a folder with a space in its name, the screen's size reaching it, `exit`
/// ending it; a known server not stopped at again; a missing folder said so; a changed server key
/// and a key the server doesn't know both refused, in words. Skips when the lab isn't up.
struct TerminalLabTests {
    private actor Screen {
        var text = ""
        var ended: String?
        func add(_ bytes: [UInt8]) { text += String(decoding: bytes, as: UTF8.self) }
        func end(_ why: String) { ended = why }
    }

    private func report(_ ok: Bool, _ what: String, _ detail: String = "") {
        HermesLabApprovalTests.report(ok, what, detail)
    }

    /// Reads a shell's events into a screen the checks look at.
    private static func watch(_ events: AsyncStream<SSHShell.Event>) -> Screen {
        let screen = Screen()
        Task {
            for await event in events {
                switch event {
                case let .output(bytes): await screen.add(bytes)
                case let .ended(why): await screen.end(why)
                }
            }
        }
        return screen
    }

    private static func wait(_ screen: Screen, seconds: Double = 10, until done: @Sendable (String, String?) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done(await screen.text, await screen.ended) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test func aRealServerThroughTheAppsOwnClient() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let lab = env["REDDE_TERMINAL_LAB"], let user = env["REDDE_TERMINAL_USER"],
              let fingerprint = try? String(contentsOfFile: lab + "/fingerprint", encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
            print("LAB SKIP: no terminal lab (scripts/terminal-lab/lab.sh test)")
            return
        }
        let authorized = URL(fileURLWithPath: lab + "/authorized_keys")
        let name = KnownHosts.name(host: "127.0.0.1", port: 2222)
        let folder = lab + "/projects/demo folder"
        let target = SSHShell.Target(host: "127.0.0.1", port: 2222, user: user, folder: folder)
        let line = try #require(SSHIdentity.publicKeyLine, "this device has no key")
        report(line.hasPrefix("ssh-ed25519 ") && line.hasSuffix(" redde"), "this device's key is an ssh-ed25519 line for authorized_keys", line)
        try (line + "\n").write(to: authorized, atomically: true, encoding: .utf8)
        defer {
            try? "".write(to: authorized, atomically: true, encoding: .utf8)
            KnownHosts.forget(name)
        }
        KnownHosts.forget(name)

        // A server met for the first time: stopped at, with the fingerprint ssh shows, nothing kept.
        do {
            _ = try await SSHShell.open(target, columns: 80, rows: 24)
            report(false, "a new server is stopped at, with ssh's fingerprint", "it connected")
        } catch {
            report(error as? SSHShell.Problem == .unknownServer(fingerprint: fingerprint),
                   "a new server is stopped at, with ssh's fingerprint", "\(error)")
        }
        report(KnownHosts.trusted(name) == nil, "and nothing is remembered until the person trusts it")

        // Trusted (as the screen does on a yes): the shell starts in the folder, takes the screen's
        // size, and ends with exit.
        KnownHosts.trust(fingerprint, for: name)
        do {
            let (shell, events) = try await SSHShell.open(target, columns: 80, rows: 24)
            let screen = Self.watch(events)
            report(await Self.wait(screen) { text, _ in text.contains("lab") }, "a shell starts", await String(screen.text.suffix(80)))
            shell.send(Array("pwd\r".utf8))
            report(await Self.wait(screen) { text, _ in text.contains(folder) }, "in the folder, a space in its name", await String(screen.text.suffix(160)))
            shell.resize(columns: 100, rows: 30)
            shell.send(Array("stty size\r".utf8))
            report(await Self.wait(screen) { text, _ in text.contains("30 100") }, "the screen's size reaches the shell", await String(screen.text.suffix(80)))
            shell.send(Array("exit\r".utf8))
            report(await Self.wait(screen) { _, ended in ended?.contains("exit status 0") == true }, "exit ends it, and says so",
                   await screen.ended ?? "still open")
        } catch {
            report(false, "a trusted server lets this device in", error.localizedDescription)
            return
        }

        // Known now: let straight in. A folder that isn't there: said so, the shell at home.
        do {
            var away = target
            away.folder = "/no/such/folder here"
            let (shell, events) = try await SSHShell.open(away, columns: 80, rows: 24)
            let screen = Self.watch(events)
            report(true, "a known server is let straight in")
            report(await Self.wait(screen) { text, _ in text.contains("That folder is not on this server") }, "a missing folder is said so",
                   await String(screen.text.suffix(160)))
            shell.close()
        } catch {
            report(false, "a known server is let straight in", error.localizedDescription)
        }

        // A server showing another key than the one trusted: refused, both fingerprints named.
        KnownHosts.trust("SHA256:not-the-one-it-has", for: name)
        do {
            _ = try await SSHShell.open(target, columns: 80, rows: 24)
            report(false, "a changed server key is refused", "it connected")
        } catch {
            report(error as? SSHShell.Problem == .serverKeyChanged(expected: "SHA256:not-the-one-it-has", presented: fingerprint),
                   "a changed server key is refused, both fingerprints named", "\(error)")
        }

        // This device's key not in authorized_keys: refused, in words that say what to do.
        KnownHosts.trust(fingerprint, for: name)
        try "".write(to: authorized, atomically: true, encoding: .utf8)
        do {
            _ = try await SSHShell.open(target, columns: 80, rows: 24)
            report(false, "a key the server doesn't know is refused", "it connected")
        } catch {
            report(error as? SSHShell.Problem == .keyNotAccepted && error.localizedDescription.contains("authorized_keys"),
                   "a key the server doesn't know is refused, saying where it goes", error.localizedDescription)
        }
    }
}

