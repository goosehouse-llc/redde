import CarPlay
import ObjectiveC
import Testing
import UIKit
@testable import Echo

/// What CarPlay draws with Redde's templates, without a car: the view controllers CarPlay itself
/// uses (in the simulator's CarPlaySupport framework) are handed the app's real templates and
/// drawn to PNG files at car-screen sizes. Run it with `scripts/carplay-preview.sh`; it does
/// nothing unless REDDE_CARPLAY_PREVIEW names a folder (TEST_RUNNER_REDDE_CARPLAY_PREVIEW from
/// xcodebuild).
///
/// It goes by class names that are not API, so it can stop working with any iOS release, and it
/// is a preview: no car's status bar, no tab bar (a tab's name shows as a title instead), and
/// sizes are points, of which a car's screen has fewer than its pixels suggest (800 by 480
/// pixels is usually 400 by 240 points). It exists because two rounds of CarPlay work were done
/// blind and both looked wrong on a car: buttons 40 points across, and a voice card whose
/// picture had been squeezed out by its own buttons.
@MainActor
struct CarPlayPreviewTests {
    private nonisolated static let folder = ProcessInfo.processInfo.environment["REDDE_CARPLAY_PREVIEW"]

    /// One of CarPlay's own template view controllers, holding `template`.
    private func controller(_ className: String, _ selector: String, for template: CPTemplate) -> UIViewController? {
        guard dlopen("/System/Library/PrivateFrameworks/CarPlaySupport.framework/CarPlaySupport", RTLD_NOW) != nil,
              let cls = NSClassFromString(className) else { return nil }
        typealias Make = @convention(c) (AnyObject, Selector, AnyObject, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
        let sel = NSSelectorFromString(selector)
        guard cls.instancesRespond(to: sel), let imp = class_getMethodImplementation(cls, sel),
              let raw = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return nil }
        return unsafeBitCast(imp, to: Make.self)(raw, sel, template, nil, nil)?.takeRetainedValue() as? UIViewController
    }

    private func list(_ template: CPListTemplate) -> UIViewController? {
        controller("CPSListTemplateViewController", "initWithListTemplate:templateDelegate:templateEnvironment:", for: template)
    }

    private func voice(_ template: CPVoiceControlTemplate) -> UIViewController? {
        controller("CPSVoiceTemplateViewController", "initWithVoiceTemplate:templateDelegate:templateEnvironment:", for: template)
    }

    /// Frames of what matters on a screen, for the notes beside the pictures.
    private func measure(_ view: UIView, in root: UIView, into lines: inout [String]) {
        let frame = view.convert(view.bounds, to: root)
        let name = String(describing: type(of: view))
        let size = "\(Int(frame.width))x\(Int(frame.height)) at \(Int(frame.minX)),\(Int(frame.minY))"
        if let picture = view as? UIImageView, picture.image != nil, frame.width >= 20 || (picture.animationImages?.count ?? 0) > 1 {
            lines.append("  picture \(size)\((picture.animationImages?.count ?? 0) > 1 ? ", \(picture.animationImages?.count ?? 0) frames" : "")")
        } else if let label = view as? UILabel, let text = label.text, !text.isEmpty {
            lines.append("  “\(text)” \(Int(label.font.pointSize)) pt, \(size)")
        } else if name.hasPrefix("BaseView<Cell>") || name == "CPUIImageRowCellItem" {
            lines.append("  card \(size)")
        }
        for sub in view.subviews { measure(sub, in: root, into: &lines) }
    }

    @Test(.enabled(if: folder != nil)) func drawTheCarScreens() async throws {
        let folder = try #require(Self.folder)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let sizes = (ProcessInfo.processInfo.environment["REDDE_CARPLAY_SIZES"] ?? "400x240,640x360,800x480")
            .split(separator: ",").compactMap { pair -> CGSize? in
                let parts = pair.split(separator: "x").compactMap { Double($0) }
                return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
            }

        // A phone with two conversations, the hike open.
        let h = CarPlayTests.Harness()
        await h.ask("Draft the landlord email")
        h.conversation.reset()
        await h.ask("Plan the weekend hike")
        let chatRows = try await h.delegate.chatRows()
        let states = h.delegate.voiceTemplate().voiceControlStates

        var screens: [(String, () -> UIViewController?)] = [
            ("ask", { self.list(CPListTemplate(title: "Ask", sections: h.delegate.askSections())) }),
            ("chats", { self.list(CPListTemplate(title: "Chats", sections: [CPListSection(items: chatRows)])) }),
        ]
        for state in CarPlayArtwork.VoiceState.allCases {
            screens.append(("voice-\(state.rawValue)", {
                let template = CPVoiceControlTemplate(voiceControlStates: states.filter { $0.identifier == state.rawValue })
                h.delegate.setBar(of: template, for: state)
                return self.voice(template)
            }))
        }

        var notes: [String] = []
        for (name, make) in screens {
            for size in sizes {
                for style in [UIUserInterfaceStyle.dark, .light] {
                    guard let controller = make() else {
                        Issue.record("CarPlay's own view for \(name) could not be made on this iOS; the preview needs updating")
                        return
                    }
                    let window = UIWindow(windowScene: scene)
                    // Away from the phone's own bars, which would otherwise take a share of the height.
                    window.frame = CGRect(x: 0, y: 150, width: size.width, height: size.height)
                    window.backgroundColor = style == .dark ? .black : .white
                    window.traitOverrides.userInterfaceIdiom = .carPlay
                    window.traitOverrides.userInterfaceStyle = style
                    let bar = UINavigationController(rootViewController: controller)
                    bar.additionalSafeAreaInsets = UIEdgeInsets(top: -window.safeAreaInsets.top, left: 0, bottom: -window.safeAreaInsets.bottom, right: 0)
                    window.rootViewController = bar
                    window.isHidden = false
                    window.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(600))
                    window.layoutIfNeeded()
                    let label = "\(name)-\(Int(size.width))x\(Int(size.height))-\(style == .dark ? "dark" : "light")"
                    var lines: [String] = []
                    measure(window, in: window, into: &lines)
                    notes.append(label)
                    notes += lines
                    let picture = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    try picture.pngData()?.write(to: URL(fileURLWithPath: folder).appending(path: "\(label).png"))
                    window.isHidden = true
                    window.rootViewController = nil
                }
            }
        }
        try notes.joined(separator: "\n").write(to: URL(fileURLWithPath: folder).appending(path: "measurements.txt"), atomically: true, encoding: .utf8)
    }
}
