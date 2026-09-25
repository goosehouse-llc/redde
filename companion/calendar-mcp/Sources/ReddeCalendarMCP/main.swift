import Foundation

/// Redde Calendar MCP: exposes this Mac's Calendar (which syncs your iPhone's calendars through
/// iCloud) to a Hermes agent as MCP tools over Streamable HTTP. Read-only unless started with
/// --allow-writes. Only accepts connections from the tailnet and loopback, with a bearer token.
///
///   redde-calendar-mcp [--port 8765] [--allow-writes] [--print-token]

var port: UInt16 = 8765
var allowWrites = false
var printTokenOnly = false
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let arg = arguments.next() {
    switch arg {
    case "--port": if let v = arguments.next(), let p = UInt16(v) { port = p }
    case "--allow-writes": allowWrites = true
    case "--print-token": printTokenOnly = true
    default: FileHandle.standardError.write(Data("unknown argument \(arg)\n".utf8)); exit(2)
    }
}

let token: String
do { token = try TokenStore.loadOrCreate() } catch {
    FileHandle.standardError.write(Data("could not read or create the token: \(error)\n".utf8)); exit(1)
}
if printTokenOnly { print(token); exit(0) }

let calendar = CalendarService(allowWrites: allowWrites)
calendar.requestAccess()
let reminders = ReminderService(allowWrites: allowWrites)
reminders.requestAccess()
let mcp = MCPHandler(tools: CalendarTools(service: calendar), reminders: ReminderTools(service: reminders))
let server = HTTPServer(port: port, token: token, handler: mcp)
do { try server.start() } catch {
    Log.info("could not listen on port \(port): \(error)"); exit(1)
}
Log.info("starting on port \(port) (writes \(allowWrites ? "enabled" : "disabled"))")
dispatchMain()
