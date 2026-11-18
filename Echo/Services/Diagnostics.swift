// What a bug report needs, put together on the device (Settings → About → Report a Problem).
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The report itself: this device, this app, the connection, what Hermes and its plugin say they
/// are, and the failures above. Plain text, shown in full before it's copied.
@MainActor
enum DiagnosticsReport {
    struct Server: Sendable {
        var hermes: String?
        var plugin: String?
    }

    /// Asks the Dashboard (when signed in to one) for its release and the plugin's version.
    static func askServer(settings: Settings = .shared) async -> Server {
        let client = HermesServeClient.shared
        guard settings.transport.isHermes, client.hasCredentials else { return Server() }
        async let release = client.hermesRelease()
        async let plugin = try? client.pushPlugin()
        let state = await plugin
        return Server(hermes: await release,
                      plugin: state.map { $0.installed ? ($0.version ?? "?") + ($0.enabled ? "" : " (off)") : "not installed" })
    }

    static func text(settings: Settings = .shared, server: Server, failures: [FailureLog.Entry] = FailureLog.shared.recent,
                     now: Date = .now) -> String {
        let locale = Locale.current
        var lines = ["Redde \(SettingsView.versionLine)"]
        #if os(macOS)
        lines.append("Mac \(machine), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #else
        lines.append("\(machine), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        #endif
        lines.append("Language \(locale.language.languageCode?.identifier ?? "?")"
                     + (Bundle.main.preferredLocalizations.first.map { " (app in \($0))" } ?? "")
                     + ", region \(locale.region?.identifier ?? "?")"
                     + ", \(locale.measurementSystem == .metric ? "metric" : "imperial")"
                     + ", \(uses24Hour(locale) ? "24-hour" : "12-hour")")
        #if os(macOS)
        let dark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        lines.append("\(dark ? "Dark" : "Light")" + (ProcessInfo.processInfo.isLowPowerModeEnabled ? ", low power" : ""))
        #else
        let traits = UITraitCollection.current
        lines.append("Text \(traits.preferredContentSizeCategory.rawValue.replacingOccurrences(of: "UICTContentSizeCategory", with: ""))"
                     + ", \(traits.userInterfaceStyle == .dark ? "dark" : "light")"
                     + (UIAccessibility.isReduceMotionEnabled ? ", reduce motion" : "")
                     + (ProcessInfo.processInfo.isLowPowerModeEnabled ? ", low power" : ""))
        #endif
        let active = settings.activeServer
        let address: String? = switch settings.transport {
        case .hermesServe: active?.serveURL
        case .hermesSessions: active?.gatewayURL
        case .acp: active?.acpURL
        case .chatCompletions: nil
        }
        var connection = "Connection \(settings.transport.rawValue)"
        if settings.transport == .acp { connection += ", agent \(settings.acpAgent.nilIfEmpty ?? "default")" }
        connection += ", \(settings.servers.count) server\(settings.servers.count == 1 ? "" : "s")"
        // How it's reached, never where: the scheme alone (https, wss…), or the built-in demo agent.
        if let address = address?.nilIfEmpty {
            connection += address == AcpEndpoint.demoAddress ? ", demo agent" : ", " + (URL(string: address)?.scheme ?? "no scheme")
        }
        if !settings.accessHeaders.isEmpty { connection += ", access headers" }
        if settings.profileName != nil { connection += ", a profile chosen" }
        lines.append(connection)
        if settings.transport.isHermes {
            lines.append("Hermes \(server.hermes ?? "unknown (no Dashboard sign-in)"), plugin \(server.plugin ?? "unknown")"
                         + ", notifications \(settings.notifyInBackground ? "on" : "off")")
        }
        lines.append("")
        if failures.isEmpty {
            lines.append("No failed requests kept.")
        } else {
            lines.append("Last failed requests (newest last):")
            let clock = Date.FormatStyle(date: .omitted, time: .standard).locale(Locale(identifier: "en_US_POSIX"))
            for entry in failures.suffix(FailureLog.kept) {
                let ago = Int(now.timeIntervalSince(entry.at) / 60)
                let when = ago < 120 ? "\(ago) min ago" : entry.at.formatted(clock.month().day())
                lines.append("- \(when) · \(entry.via) · \(entry.what)\(entry.status.map { " · \($0)" } ?? "") · \(entry.error)"
                             + (entry.times.map { " (×\($0))" } ?? ""))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The model's identifier ("iPhone16,2"), which names the exact phone.
    static var machine: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static func uses24Hour(_ locale: Locale) -> Bool {
        !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "").contains("a")
    }
}
