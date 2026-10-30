import Foundation

/// What an approval would do, in plain words, for its card (asked 2026-10-30: "in every approval
/// card, list in plain english what it's doing"). Worked out here, from what Hermes sends, on
/// both connections and at once: a shell command read part by part, a script by what it calls,
/// and the approval hook's own sentences (Sol's and Coder's: `ask_before_code_writes.py`) taken
/// apart into their files. Nothing is asked of a model, so the card shows as fast as before.
nonisolated struct ApprovalSummary: Equatable, Sendable {
    struct Step: Equatable, Sendable {
        var symbol: String
        var text: String
        /// Can't be taken back (a delete, a force push, a reset): drawn in red.
        var risky = false
    }

    /// "Coder wants to put its change in place".
    var headline: String
    /// Where, under it: "In Hermes's settings".
    var place: String?
    var steps: [Step]
    /// "+12 −3 lines".
    var size: String?
    /// The rule Hermes asked by ("recursive delete"), when it is Hermes's own.
    var reason: String?
    /// The command or the script as sent, to look at.
    var command: String?

    var risky: Bool { steps.contains(where: \.risky) }

    /// `agent`: who asks, as the chat names it. `name`: a profile's name as Redde shows it
    /// ("claude" → "Coder").
    init(_ request: ApprovalRequest, agent: String, name: (String) -> String = { $0 }) {
        let description = (request.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let tool = request.command.firstMatch(of: /^<([\w.-]+)> \(plugin approval rule\)$/)?.output.1 {
            self = Self.fromHook(String(tool), description, agent: agent, name: name)
        } else if description.hasPrefix("execute_code") {
            headline = String(localized: "\(agent) wants to run a script", comment: "Approval card's headline: the agent's own Python script")
            steps = Self.script(request.command)
            command = request.command
        } else {
            headline = String(localized: "\(agent) wants to run a command", comment: "Approval card's headline: a shell command")
            steps = CommandWords.explain(request.command)
            reason = description.isEmpty ? nil : description
            command = request.command
        }
        if steps.isEmpty, command?.isEmpty == false {
            steps = [Step(symbol: "terminal", text: String(localized: "Runs what's shown below", comment: "Approval card: a command it couldn't put in words"))]
        }
    }

    private init(headline: String, place: String? = nil, steps: [Step] = [], size: String? = nil, command: String? = nil) {
        self.headline = headline
        self.place = place
        self.steps = steps
        self.size = size
        self.command = command
    }

    // MARK: The approval hook's sentences

    /// "Sol wants to put Claude's change in place to <where>. DELETES 1 file(s): a; adds 2: b, c;
    /// edits 1: d. +5 −2 lines. Card x.", "Sol wants to run: <command>", "Sol wants to write
    /// <path>", "Sol wants to run code"; "The claude bot …" for another profile.
    private static func fromHook(_ tool: String, _ said: String, agent: String, name: (String) -> String) -> ApprovalSummary {
        var who = agent
        var rest = said
        if let m = said.firstMatch(of: #/^(?:The ([\w.-]+) bot|Sol) wants to /#) {
            who = m.output.1.map { name(String($0)) } ?? agent
            rest = String(said[m.range.upperBound...])
        }
        if let command = rest.firstMatch(of: /(?s)^run: (.+)$/)?.output.1 {
            let command = String(command)
            return ApprovalSummary(headline: String(localized: "\(who) wants to run a command"), steps: CommandWords.explain(command), command: command)
        }
        if rest == "run code" {
            return ApprovalSummary(headline: String(localized: "\(who) wants to run a script"),
                                   steps: [Step(symbol: "chevron.left.forwardslash.chevron.right",
                                                text: String(localized: "Runs a script it wrote, which can change files", comment: "Approval card: a script whose text isn't sent"))])
        }
        if let path = rest.firstMatch(of: /^write (.+)$/)?.output.1 {
            return ApprovalSummary(headline: String(localized: "\(who) wants to change a file", comment: "Approval card's headline: the agent writing one file"),
                                   steps: [Step(symbol: "square.and.pencil", text: String(localized: "Writes \(CommandWords.shown(String(path)))", comment: "Approval card: a file written; the file"))])
        }
        if rest.hasPrefix("put Claude's change in place") {
            return change(rest, who: who, isCoder: who == name("claude"))
        }
        // Anything else a hook says: its own words, and the tool.
        let words = said.isEmpty ? String(localized: "\(agent) wants to use \(tool)", comment: "Approval card's headline: a tool named only") : said
        return ApprovalSummary(headline: words)
    }

    private static func change(_ said: String, who: String, isCoder: Bool) -> ApprovalSummary {
        let hermes = said.contains("to Hermes's own settings")
        let repo = said.firstMatch(of: /^put Claude's change in place to ([^\s.(]+)/).map { String($0.output.1) }
        var steps: [Step] = []
        func files(_ label: Regex<(Substring, Substring)>) -> String? {
            said.firstMatch(of: label).map { CommandWords.list(String($0.output.1).components(separatedBy: ", ")) }
        }
        if let gone = files(/DELETES \d+ file\(s\): (.+?)(?=; |\. [+(]|\.$)/) {
            steps.append(Step(symbol: "trash", text: String(localized: "Deletes \(gone)", comment: "Approval card: files or folders deleted; the list"), risky: true))
        }
        if let made = files(/adds \d+: (.+?)(?=; |\. [+(]|\.$)/) {
            steps.append(Step(symbol: "plus.circle", text: String(localized: "Adds \(made)", comment: "Approval card: new files; the list")))
        }
        if let edited = files(/edits \d+: (.+?)(?=; |\. [+(]|\.$)/) {
            steps.append(Step(symbol: "pencil", text: String(localized: "Changes \(edited)", comment: "Approval card: files changed; the list")))
        }
        if let count = said.firstMatch(of: /\(skills, patches or docs\): (\d+) file/)?.output.1 {
            steps.append(Step(symbol: "doc.on.doc", text: String(localized: "Changes \(Int(count) ?? 0) files in the skills, patches or docs, and your phone asks again first",
                                                                    comment: "Approval card: a change to the skills, patches or docs; the number of files")))
        }
        if hermes {
            steps.append(Step(symbol: "arrow.clockwise", text: String(localized: "Restarts Hermes after, and puts everything back if Hermes isn't well",
                                                                        comment: "Approval card: what happens after a change to Hermes's settings")))
        }
        let size = said.firstMatch(of: /\+(\d+) −(\d+) lines/).map { String(localized: "+\(Int($0.output.1) ?? 0) −\(Int($0.output.2) ?? 0) lines", comment: "Approval card: lines added and taken out") }
        let place: String? = hermes ? String(localized: "In Hermes's settings", comment: "Approval card: where a change goes")
            : repo.map { (name: String) in String(localized: "In \(name)", comment: "Approval card: the repository a change goes into") }
        let headline = isCoder ? String(localized: "\(who) wants to put its change in place", comment: "Approval card's headline: Coder applying its own work")
            : String(localized: "\(who) wants to put Coder's change in place", comment: "Approval card's headline: another agent applying Coder's work")
        return ApprovalSummary(headline: headline, place: place, steps: steps, size: size)
    }

    // MARK: A script

    /// What a script the agent wrote reaches for, by the calls in it.
    static func script(_ code: String) -> [Step] {
        var steps = [Step(symbol: "chevron.left.forwardslash.chevron.right",
                          text: String(localized: "Runs a script it wrote (\(code.split(separator: "\n").count) lines)", comment: "Approval card: the agent's script; its length"))]
        if code.contains(/(os\.remove|os\.unlink|os\.rmdir|shutil\.rmtree|\.unlink\(|\.rmdir\(|send2trash)/) {
            steps.append(Step(symbol: "trash", text: String(localized: "It deletes files", comment: "Approval card: a script that deletes"), risky: true))
        }
        if code.contains(/\bopen\([^)]*['"][wax]b?\+?['"]|\.write_text\(|\.write_bytes\(|shutil\.(copy|move)|os\.rename/) {
            steps.append(Step(symbol: "square.and.pencil", text: String(localized: "It writes or moves files", comment: "Approval card: a script that writes")))
        }
        if code.contains(/\b(subprocess|os\.system|os\.popen|pty\.spawn)\b/) {
            steps.append(Step(symbol: "terminal", text: String(localized: "It runs commands", comment: "Approval card: a script that runs commands")))
        }
        if code.contains(/\b(requests|httpx|urllib|aiohttp|socket)\b/) {
            steps.append(Step(symbol: "globe", text: String(localized: "It goes on the internet", comment: "Approval card: a script that uses the network")))
        }
        return steps
    }
}

/// A shell command in words, a part at a time (`a && b | c`): what each does that matters,
/// reading parts skipped unless that's all there is.
nonisolated enum CommandWords {
    typealias Step = ApprovalSummary.Step

    static func explain(_ command: String) -> [Step] {
        var steps: [Step] = []
        var onlyReads = true
        let parts = split(command)
        for (i, part) in parts.enumerated() {
            var words = part.words
            // Leading VAR=value, sudo, env, nohup, time: what follows is the command.
            var admin = false
            while let first = words.first, first.contains("=") && !first.hasPrefix("-") || ["sudo", "env", "nohup", "time", "exec", "command"].contains(first) {
                if first == "sudo" { admin = true }
                words.removeFirst()
                if first == "sudo" { while words.first?.hasPrefix("-") == true { words.removeFirst() } }
            }
            guard let program = words.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
            let args = Array(words.dropFirst())
            // Piped into a shell: the part before is a script, run as it comes.
            if part.pipedFrom, ["sh", "bash", "zsh", "python", "python3"].contains(program), args.isEmpty, i > 0 {
                steps.append(Step(symbol: "exclamationmark.triangle", text: String(localized: "Runs what the command before it downloads, as a script", comment: "Approval card: curl … | sh"), risky: true))
                onlyReads = false
                continue
            }
            var said = step(program, args)
            if admin, var first = said.first {
                first.text = String(localized: "\(first.text) (as administrator)", comment: "Approval card: a step run with sudo")
                said[0] = first
            }
            if !said.isEmpty { onlyReads = false }
            steps += said
            if let target = part.writesTo {
                onlyReads = false
                steps.append(Step(symbol: "square.and.pencil", text: part.appends
                    ? String(localized: "Adds the output to the end of \(shown(target))", comment: "Approval card: >> file")
                    : String(localized: "Writes the output into \(shown(target)), replacing what's there", comment: "Approval card: > file")))
            }
        }
        if steps.isEmpty, onlyReads, !parts.isEmpty {
            steps = [Step(symbol: "eye", text: String(localized: "Only looks: changes nothing", comment: "Approval card: a command that only reads"))]
        }
        return Array(steps.prefix(8))
    }

    private static let reads: Set<String> = ["ls", "pwd", "cat", "head", "tail", "less", "more", "wc", "grep", "egrep", "rg", "stat", "file", "du",
                                             "df", "ps", "pgrep", "which", "whoami", "id", "date", "uptime", "free", "printenv", "echo", "printf",
                                             "tree", "realpath", "basename", "dirname", "readlink", "sort", "uniq", "cut", "tr", "column", "jq",
                                             "diff", "cmp", "md5sum", "sha256sum", "true", "false", "test", "journalctl", "cd", "sleep", "awk", "xargs", "nl"]

    private static func step(_ program: String, _ args: [String]) -> [Step] {
        let operands = args.filter { !$0.hasPrefix("-") }
        let flags = args.filter { $0.hasPrefix("-") }
        func has(_ short: Character, _ long: String? = nil) -> Bool {
            flags.contains { f in (!f.hasPrefix("--") && f.dropFirst().contains(short)) || (long.map { f == $0 } ?? false) }
        }
        func one(_ symbol: String, _ text: String, risky: Bool = false) -> [Step] { [Step(symbol: symbol, text: text, risky: risky)] }
        switch program {
        case "rm":
            let what = list(operands)
            return has("r", "--recursive") || has("R")
                ? one("trash", String(localized: "Deletes \(what) and everything in them", comment: "Approval card: rm -r; the list"), risky: true)
                : one("trash", String(localized: "Deletes \(what)"), risky: true)
        case "rmdir": return one("trash", String(localized: "Deletes the empty folder \(list(operands))", comment: "Approval card: rmdir"), risky: true)
        case "shred", "srm": return one("trash", String(localized: "Erases \(list(operands)) for good", comment: "Approval card: shred"), risky: true)
        case "mv" where operands.count >= 2:
            return one("arrow.right", String(localized: "Moves \(list(operands.dropLast())) to \(shown(operands.last!))", comment: "Approval card: mv; what, then where"))
        case "cp" where operands.count >= 2:
            return one("doc.on.doc", String(localized: "Copies \(list(operands.dropLast())) to \(shown(operands.last!))", comment: "Approval card: cp; what, then where"))
        case "mkdir": return one("folder.badge.plus", String(localized: "Makes the folder \(list(operands))", comment: "Approval card: mkdir"))
        case "touch": return one("doc.badge.plus", String(localized: "Makes \(list(operands)) if it isn't there", comment: "Approval card: touch"))
        case "ln": return one("link", String(localized: "Makes a link to \(list(operands))", comment: "Approval card: ln"))
        case "chmod": return one("lock", String(localized: "Changes who may read, change or run \(list(operands.dropFirst()))", comment: "Approval card: chmod"))
        case "chown": return one("person", String(localized: "Changes who owns \(list(operands.dropFirst()))", comment: "Approval card: chown"))
        case "tee" where !operands.isEmpty:
            return one("square.and.pencil", has("a", "--append") ? String(localized: "Adds the output to the end of \(list(operands))") : String(localized: "Writes the output into \(list(operands)), replacing what's there"))
        case "sed" where has("i"): return one("pencil", String(localized: "Edits \(list(operands.dropFirst())) in place", comment: "Approval card: sed -i"))
        case "find" where args.contains("-delete") || args.contains("-exec") && args.contains("rm"):
            return one("trash", String(localized: "Deletes the files it finds in \(shown(operands.first ?? "."))", comment: "Approval card: find -delete"), risky: true)
        case "git": return git(args)
        case "systemctl", "service", "launchctl": return service(program, args)
        case "kill", "pkill", "killall":
            return one("xmark.octagon", String(localized: "Stops \(list(operands))", comment: "Approval card: kill; the program or its number"))
        case "reboot": return one("power", String(localized: "Restarts the computer", comment: "Approval card: reboot"), risky: true)
        case "shutdown", "halt", "poweroff": return one("power", String(localized: "Shuts the computer down", comment: "Approval card: shutdown"), risky: true)
        case "dd": return one("exclamationmark.triangle", String(localized: "Writes raw data onto \(args.first { $0.hasPrefix("of=") }.map { shown(String($0.dropFirst(3))) } ?? "a disk")", comment: "Approval card: dd"), risky: true)
        case _ where program.hasPrefix("mkfs"): return one("exclamationmark.triangle", String(localized: "Erases and formats \(list(operands))", comment: "Approval card: mkfs"), risky: true)
        case "crontab" where has("r"): return one("trash", String(localized: "Deletes all the scheduled jobs in crontab", comment: "Approval card: crontab -r"), risky: true)
        case "crontab": return one("clock", String(localized: "Changes the scheduled jobs in crontab", comment: "Approval card: crontab"))
        case "curl", "wget": return web(program, args)
        case "ssh":
            let host = operands.first.map { shown($0) } ?? "?"
            return operands.count > 1 ? one("network", String(localized: "Runs a command on \(host): \(shown(operands.dropFirst().joined(separator: " ")))", comment: "Approval card: ssh host command"))
                : one("network", String(localized: "Signs in to \(host)", comment: "Approval card: ssh host"))
        case "scp", "rsync":
            guard operands.count >= 2 else { return one("arrow.left.arrow.right", String(localized: "Runs \(program)")) }
            var steps = one("arrow.left.arrow.right", String(localized: "Copies \(list(operands.dropLast())) to \(shown(operands.last!))"))
            if args.contains(where: { $0.hasPrefix("--delete") }) {
                steps.append(Step(symbol: "trash", text: String(localized: "And deletes what's in \(shown(operands.last!)) but not in the copy", comment: "Approval card: rsync --delete"), risky: true))
            }
            return steps
        case "tar":
            let archive = args.firstIndex(where: { $0.hasPrefix("-") && $0.contains("f") }).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? operands.first ?? ""
            return has("x") ? one("shippingbox", String(localized: "Unpacks \(shown(archive))", comment: "Approval card: tar -x / unzip"))
                : one("shippingbox", String(localized: "Packs files into \(shown(archive))", comment: "Approval card: tar -c / zip"))
        case "unzip": return one("shippingbox", String(localized: "Unpacks \(shown(operands.first ?? ""))"))
        case "zip": return one("shippingbox", String(localized: "Packs files into \(shown(operands.first ?? ""))"))
        case "pip", "pip3", "npm", "pnpm", "yarn", "brew", "apt", "apt-get", "dnf", "yum", "cargo", "gem", "uv", "pipx", "go", "bun":
            return packages(program, args)
        case "python", "python3", "node", "bash", "sh", "zsh", "ruby", "perl", "deno":
            if args.first == "-m", args.count > 1 {
                return args[1] == "pip" ? packages("pip", Array(args.dropFirst(2)))
                    : one("play", args[1] == "pytest" || args[1] == "unittest" ? String(localized: "Runs the tests", comment: "Approval card: pytest")
                        : String(localized: "Runs \(args[1])", comment: "Approval card: python -m module; the module"))
            }
            if args.contains("-c") || args.contains("-e") { return one("chevron.left.forwardslash.chevron.right", String(localized: "Runs a few lines of code", comment: "Approval card: python -c")) }
            return operands.first.map { one("play", String(localized: "Runs the script \(shown($0))", comment: "Approval card: a script file run")) } ?? []
        case "pytest": return one("play", String(localized: "Runs the tests"))
        case "make", "just": return one("hammer", String(localized: "Runs the build step \(operands.first ?? "all")", comment: "Approval card: make target"))
        case "docker", "podman": return docker(args)
        case "hermes":
            let sub = operands.prefix(2).joined(separator: " ")
            if sub.hasPrefix("gateway restart") || sub == "restart" { return one("arrow.clockwise", String(localized: "Restarts Hermes", comment: "Approval card: Hermes restarted")) }
            return one("terminal", String(localized: "Runs Hermes's “\(sub)” command", comment: "Approval card: a hermes CLI command; the subcommand"))
        default:
            return reads.contains(program) ? [] : one("terminal", String(localized: "Runs \(program)", comment: "Approval card: a program it can't put in words; its name"))
        }
    }

    private static func git(_ args: [String]) -> [Step] {
        var rest = args
        while let first = rest.first, first.hasPrefix("-") {   // git -C dir …
            rest.removeFirst()
            if first == "-C" || first == "-c", !rest.isEmpty { rest.removeFirst() }
        }
        guard let sub = rest.first else { return [] }
        let args = Array(rest.dropFirst())
        let operands = args.filter { !$0.hasPrefix("-") }
        func one(_ symbol: String, _ text: String, risky: Bool = false) -> [Step] { [Step(symbol: symbol, text: text, risky: risky)] }
        switch sub {
        case "push":
            let force = args.contains { ["-f", "--force", "--force-with-lease"].contains($0) || $0.hasPrefix("--force") } || operands.contains { $0.hasPrefix("+") }
            let target = operands.count >= 2 ? String(localized: "\(operands[1]) to \(operands[0])", comment: "Approval card: git push; branch, then remote") : operands.first ?? String(localized: "this branch")
            if args.contains("--delete") || args.contains("-d") { return one("trash", String(localized: "Deletes the branch \(operands.dropFirst().first ?? "?") on \(operands.first ?? "?")", comment: "Approval card: git push --delete"), risky: true) }
            return force ? one("exclamationmark.arrow.circlepath", String(localized: "Force-pushes \(target), replacing what's there", comment: "Approval card: git push --force"), risky: true)
                : one("arrow.up.circle", String(localized: "Pushes \(target)", comment: "Approval card: git push"))
        case "commit":
            if args.contains("--amend") { return one("pencil.circle", String(localized: "Rewrites the last commit", comment: "Approval card: git commit --amend")) }
            if let i = args.firstIndex(where: { $0 == "-m" || $0 == "--message" || $0 == "-am" }), args.indices.contains(i + 1) {
                return one("checkmark.circle", String(localized: "Commits the changes: “\(shown(args[i + 1], limit: 80))”", comment: "Approval card: git commit -m; the message"))
            }
            return one("checkmark.circle", String(localized: "Commits the changes", comment: "Approval card: git commit"))
        case "add": return one("plus.circle", operands.isEmpty || operands == ["."] || args.contains("-A")
            ? String(localized: "Gets every change ready to commit", comment: "Approval card: git add .")
            : String(localized: "Gets \(list(operands)) ready to commit", comment: "Approval card: git add files"))
        case "reset" where args.contains("--hard"): return one("arrow.uturn.backward", String(localized: "Throws away every change not committed", comment: "Approval card: git reset --hard"), risky: true)
        case "reset": return one("arrow.uturn.backward", String(localized: "Takes changes back out of the next commit", comment: "Approval card: git reset"))
        case "restore": return one("arrow.uturn.backward", String(localized: "Throws away the changes to \(list(operands))", comment: "Approval card: git restore / checkout -- files"), risky: true)
        case "checkout", "switch":
            if let i = args.firstIndex(where: { $0 == "-b" || $0 == "-c" || $0 == "-B" }), args.indices.contains(i + 1) {
                return one("arrow.triangle.branch", String(localized: "Makes the branch \(args[i + 1]) and switches to it", comment: "Approval card: git checkout -b"))
            }
            if args.contains("--") || operands == ["."] { return one("arrow.uturn.backward", String(localized: "Throws away the changes to \(list(operands.filter { $0 != "--" }))"), risky: true) }
            return one("arrow.triangle.branch", String(localized: "Switches to \(operands.first ?? "?")", comment: "Approval card: git checkout branch"))
        case "pull": return one("arrow.down.circle", String(localized: "Gets the latest changes from \(operands.first ?? "the server")", comment: "Approval card: git pull"))
        case "fetch": return one("arrow.down.circle", String(localized: "Checks \(operands.first ?? "the server") for new changes", comment: "Approval card: git fetch"))
        case "clone": return one("arrow.down.doc", String(localized: "Downloads the repository \(shown(operands.first ?? "?"))", comment: "Approval card: git clone"))
        case "merge": return one("arrow.triangle.merge", String(localized: "Merges \(operands.first ?? "?") into this branch", comment: "Approval card: git merge"))
        case "rebase": return one("arrow.triangle.branch", String(localized: "Moves this branch's commits onto \(operands.first ?? "?")", comment: "Approval card: git rebase"))
        case "branch" where args.contains("-D") || args.contains("-d") || args.contains("--delete"):
            return one("trash", String(localized: "Deletes the branch \(list(operands))", comment: "Approval card: git branch -D"), risky: true)
        case "clean": return one("trash", String(localized: "Deletes the files git doesn't keep track of", comment: "Approval card: git clean"), risky: true)
        case "stash" where ["drop", "clear"].contains(operands.first ?? ""):
            return one("trash", String(localized: "Throws away changes put aside", comment: "Approval card: git stash drop"), risky: true)
        case "stash": return one("tray.and.arrow.down", String(localized: "Puts the changes aside for later", comment: "Approval card: git stash"))
        case "tag": return one("tag", String(localized: "Tags this version \(operands.first ?? "")", comment: "Approval card: git tag"))
        case "status", "log", "diff", "show", "branch", "remote", "rev-parse", "blame", "ls-files", "describe", "config": return []
        default: return one("terminal", String(localized: "Runs git \(sub)", comment: "Approval card: another git command"))
        }
    }

    private static func service(_ program: String, _ args: [String]) -> [Step] {
        let words = args.filter { !$0.hasPrefix("-") }
        // `service name verb`, `systemctl verb name…`, `launchctl verb name`.
        let (verb, units) = program == "service" ? (words.dropFirst().first ?? "", Array(words.prefix(1))) : (words.first ?? "", Array(words.dropFirst()))
        let names = list(units.map { $0.replacingOccurrences(of: ".service", with: "") })
        switch verb {
        case "restart", "reload", "kickstart", "try-restart": return [Step(symbol: "arrow.clockwise", text: String(localized: "Restarts \(names)", comment: "Approval card: a service restarted"))]
        case "stop", "bootout", "unload", "kill": return [Step(symbol: "stop.circle", text: String(localized: "Stops \(names)"))]
        case "start", "bootstrap", "load": return [Step(symbol: "play.circle", text: String(localized: "Starts \(names)", comment: "Approval card: a service started"))]
        case "enable": return [Step(symbol: "power", text: String(localized: "Starts \(names) by itself from now on", comment: "Approval card: systemctl enable"))]
        case "disable": return [Step(symbol: "power", text: String(localized: "Stops starting \(names) by itself", comment: "Approval card: systemctl disable"))]
        case "daemon-reload": return [Step(symbol: "arrow.clockwise", text: String(localized: "Reloads the services' settings", comment: "Approval card: systemctl daemon-reload"))]
        case "status", "is-active", "is-enabled", "list-units", "cat", "show", "print", "list": return []
        default: return [Step(symbol: "gearshape", text: String(localized: "Runs \(program) \(verb)"))]
        }
    }

    private static func web(_ program: String, _ args: [String]) -> [Step] {
        let url = args.first { $0.contains("://") } ?? args.last { !$0.hasPrefix("-") } ?? ""
        let host = URL(string: url)?.host() ?? shown(url)
        let method = args.firstIndex(of: "-X").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1].uppercased() : nil }
        let sends = method.map { ["POST", "PUT", "PATCH"].contains($0) } ?? false
            || args.contains { ["-d", "--data", "--data-raw", "--data-binary", "-F", "--form", "--json", "-T", "--upload-file"].contains($0) || $0.hasPrefix("--data") }
        if method == "DELETE" { return [Step(symbol: "trash", text: String(localized: "Asks \(host) to delete something", comment: "Approval card: curl -X DELETE"), risky: true)] }
        if sends { return [Step(symbol: "paperplane", text: String(localized: "Sends data to \(host)", comment: "Approval card: curl POST"))] }
        if program == "wget" || args.contains("-o") || args.contains("-O") || args.contains("--output") {
            let file = args.firstIndex(where: { $0 == "-o" || $0 == "--output" }).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            return [Step(symbol: "arrow.down.circle", text: file.map { String(localized: "Downloads from \(host) into \(shown($0))", comment: "Approval card: curl -o") }
                ?? String(localized: "Downloads from \(host)", comment: "Approval card: wget"))]
        }
        return [Step(symbol: "globe", text: String(localized: "Fetches \(host)", comment: "Approval card: curl GET"))]
    }

    private static func packages(_ program: String, _ args: [String]) -> [Step] {
        var words = args.filter { !$0.hasPrefix("-") }
        if program == "uv", words.first == "pip" { words.removeFirst() }
        if program == "uv", words.first == "sync" { return [Step(symbol: "shippingbox", text: String(localized: "Installs the project's packages", comment: "Approval card: uv sync / npm install"))] }
        guard let verb = words.first else { return [] }
        let names = Array(words.dropFirst())
        switch verb {
        case "install", "add", "i", "get":
            return [Step(symbol: "shippingbox", text: names.isEmpty ? String(localized: "Installs the project's packages") : String(localized: "Installs \(list(names))", comment: "Approval card: packages installed"))]
        case "uninstall", "remove", "rm", "purge", "autoremove":
            return [Step(symbol: "trash", text: String(localized: "Removes \(names.isEmpty ? program : list(names))", comment: "Approval card: packages removed"), risky: true)]
        case "update", "upgrade", "up":
            return [Step(symbol: "arrow.up.circle", text: names.isEmpty ? String(localized: "Updates the packages", comment: "Approval card: brew upgrade") : String(localized: "Updates \(list(names))", comment: "Approval card: packages updated"))]
        case "run", "exec", "x":
            let script = names.first ?? ""
            return [Step(symbol: "play", text: script == "test" ? String(localized: "Runs the tests") : String(localized: "Runs the project's \(script) script", comment: "Approval card: npm run x"))]
        case "test": return [Step(symbol: "play", text: String(localized: "Runs the tests"))]
        case "list", "show", "info", "search", "outdated", "freeze", "view", "ls", "doctor": return []
        default: return [Step(symbol: "terminal", text: String(localized: "Runs \(program) \(verb)"))]
        }
    }

    private static func docker(_ args: [String]) -> [Step] {
        var words = args.filter { !$0.hasPrefix("-") }
        if words.first == "compose" { words.removeFirst() }
        guard let verb = words.first else { return [] }
        let names = list(Array(words.dropFirst()))
        switch verb {
        case "up", "start", "run": return [Step(symbol: "play.circle", text: words.count > 1 ? String(localized: "Starts \(names)") : String(localized: "Starts the containers", comment: "Approval card: docker compose up"))]
        case "down", "stop", "kill": return [Step(symbol: "stop.circle", text: words.count > 1 ? String(localized: "Stops \(names)") : String(localized: "Stops the containers", comment: "Approval card: docker compose down"))]
        case "restart": return [Step(symbol: "arrow.clockwise", text: words.count > 1 ? String(localized: "Restarts \(names)") : String(localized: "Restarts the containers", comment: "Approval card: docker compose restart"))]
        case "rm", "rmi", "prune": return [Step(symbol: "trash", text: String(localized: "Deletes \(words.count > 1 ? names : String(localized: "containers or images", comment: "Approval card: what docker rm deletes"))"), risky: true)]
        case "pull": return [Step(symbol: "arrow.down.circle", text: String(localized: "Downloads \(words.count > 1 ? names : String(localized: "the newest images", comment: "Approval card: what docker pull downloads"))", comment: "Approval card: docker pull"))]
        case "ps", "logs", "images", "inspect", "config", "ls": return []
        default: return [Step(symbol: "shippingbox", text: String(localized: "Runs docker \(verb)", comment: "Approval card: another docker command"))]
        }
    }

    // MARK: Words

    /// A path or a value as the card shows it: whole when short, else its start and its end.
    static func shown(_ text: String, limit: Int = 48) -> String {
        text.count <= limit ? text : String(text.prefix(limit / 2 - 1)) + "…" + String(text.suffix(limit / 2 - 1))
    }

    /// "a, b and c", "a, b and 4 more".
    static func list<S: Collection>(_ items: S) -> String where S.Element == String {
        let items = items.map { shown($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty && $0 != "…" }
        guard !items.isEmpty else { return "?" }
        if items.count > 4 {
            return ListFormatter.localizedString(byJoining: Array(items.prefix(3)) + [String(localized: "\(items.count - 3) more", comment: "Approval card: the end of a long list of files")])
        }
        return ListFormatter.localizedString(byJoining: items)
    }

    // MARK: Reading a command

    struct Part: Equatable {
        var words: [String]
        /// After a `|`.
        var pipedFrom = false
        /// `> file`, `>> file`: where its output goes (not /dev/null).
        var writesTo: String?
        var appends = false
    }

    /// The command's parts, at `&&`, `||`, `;`, `|` and new lines outside quotes, each in words
    /// with its quotes taken off and its redirections taken out.
    static func split(_ command: String) -> [Part] {
        var parts: [Part] = [], words: [String] = [], word = "", inWord = false
        var quote: Character? = nil
        var piped = false, nextPiped = false
        var redirect: (append: Bool, fd: Bool)? = nil
        var target: String? = nil
        var appends = false
        func endWord() {
            guard inWord else { return }
            if let r = redirect {
                if !r.fd, word != "/dev/null" { target = word; appends = r.append }
                redirect = nil
            } else { words.append(word) }
            word = ""; inWord = false
        }
        func endPart() {
            endWord()
            if !words.isEmpty { parts.append(Part(words: words, pipedFrom: piped, writesTo: target, appends: appends)) }
            words = []; target = nil; appends = false; piped = nextPiped; nextPiped = false
        }
        let chars = Array(command)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q { quote = nil } else if c == "\\", q == "\"", i + 1 < chars.count { i += 1; word.append(chars[i]) } else { word.append(c) }
            } else if c == "'" || c == "\"" {
                quote = c; inWord = true
            } else if c == "\\", i + 1 < chars.count {
                i += 1; word.append(chars[i]); inWord = true
            } else if c == " " || c == "\t" {
                endWord()
            } else if c == "&", i + 1 < chars.count, chars[i + 1] == ">" {
                endWord()   // `&> file`: both outputs, a redirection (the `>` next), not a background job
            } else if c == "\n" || c == ";" || c == "&" || c == "|" {
                let double = i + 1 < chars.count && chars[i + 1] == c
                if c == "|", !double { endPart(); piped = true } else { nextPiped = false; endPart() }
                if double { i += 1 }
            } else if c == ">" {
                // `2>`, `>&2`, `2>&1`: file descriptors; `>`/`>>` a file
                let fd = inWord && word.allSatisfy(\.isNumber) && word != "1"
                if inWord, word.allSatisfy(\.isNumber) { word = ""; inWord = false } else { endWord() }
                let append = i + 1 < chars.count && chars[i + 1] == ">"
                if append { i += 1 }
                if i + 1 < chars.count, chars[i + 1] == "&" {   // >&2
                    i += 1
                    while i + 1 < chars.count, chars[i + 1].isNumber { i += 1 }
                } else {
                    redirect = (append, fd)
                }
            } else {
                word.append(c); inWord = true
            }
            i += 1
        }
        endPart()
        return parts
    }
}
