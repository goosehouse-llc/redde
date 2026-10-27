#if DEBUG && os(iOS)
import Foundation
import os
import QuartzCore
import UIKit

/// `-echo.hitches`: every frame the main thread made late, logged with when it happened, and the
/// measured steps of the launch hooks that act by themselves (`-echo.tour`, `scripts/smoothness.sh`).
/// Measured in the app, not by a UI test: XCUITest has the app describe its whole screen for
/// accessibility on the main thread for every query, and made most of the late frames it saw
/// itself (2026-10-21). A display link fires once a frame; when one comes more than half a frame late, the main thread was busy
/// through the frames between, and anything moving on screen stood still for them. Lines go to
/// the log (category "frames") and to Library/Caches/frames.log, to read off a phone.
///
/// `-echo.autoScroll [seconds]` (with `-echo.hitches`): a few seconds after launch the tallest
/// scroll view on screen (the transcript, or the list) is scrolled up and back down by itself,
/// at a finger's pace, and how many frames came late and how much the app worked meanwhile is
/// logged ("autoscroll: …"). No test runner is involved, so none of it is the runner's: this is
/// for trying a change to scrolling against the one before it.
///
/// `-echo.autoOpen [times]` (with `-echo.hitches`): the conversation open at launch and the
/// shortest other one are opened in turn, as their rows in the list open them, and each open's
/// late frames are logged ("autoopen: …").
final class FrameMonitor: NSObject {
    static let shared = FrameMonitor()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var lines: [String] = []
    private var flush: Timer?
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "frames")
    /// In Caches, not Documents: Documents shows in the Files app.
    private let file = URL.cachesDirectory.appending(path: "frames.log")

    func start() {
        guard link == nil else { return }
        try? FileManager.default.removeItem(at: file)   // each launch's own
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        flush = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.write() }
        }
        log.notice("frames: watching")
        if DevHooks.has("-echo.autoOpen") {
            let times = DevHooks.value("-echo.autoOpen").flatMap(Int.init) ?? 4
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                await self.autoOpen(times: times)
            }
        }
        if DevHooks.has("-echo.autoScroll") {
            let seconds = DevHooks.value("-echo.autoScroll").flatMap(Double.init) ?? 8
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                self.autoScroll(for: seconds)
            }
        }
    }

    // MARK: Opening conversations by itself

    private func autoOpen(times: Int) async {
        guard let conversation = Conversation.current else { return }
        let store = ConversationStore.shared
        let first = conversation.id
        guard let other = store.summaries.filter({ $0.id != first }).min(by: { $0.turnCount < $1.turnCount }) else {
            log.notice("autoopen: nothing else to open"); return
        }
        var results: [String: [(late: Int, lateMS: Double, worst: Double)]] = [:]
        for _ in 0 ..< times {
            for (label, id) in [("short", other.id), ("long", first)] {
                let measured = await measure(seconds: 2.5) {
                    if let full = await store.loadRecord(id: id) { conversation.load(full) }
                }
                results[label, default: []].append(measured)
            }
        }
        for (label, runs) in results.sorted(by: { $0.key < $1.key }) {
            let line = "autoopen \(label): " + runs.map { String(format: "%d late %.0f ms (worst %.0f)", $0.late, $0.lateMS, $0.worst) }.joined(separator: "; ")
            log.notice("\(line, privacy: .public)")
            lines.append("# " + line)
        }
        lines.append("# autoopen done")
        write()
    }

    /// The late frames from `action` on, for `seconds`.
    private func measure(seconds: Double, _ action: () async -> Void) async -> (late: Int, lateMS: Double, worst: Double) {
        window = (0, 0, 0)
        await action()
        try? await Task.sleep(for: .seconds(seconds))
        defer { window = nil }
        return window ?? (0, 0, 0)
    }

    /// `action`, measured and logged as "<label>: …": late frames and the app's CPU time, from
    /// its start until half a second after it ends. For the launch hooks that act by themselves
    /// (`-echo.autoType`).
    func report(_ label: String, _ action: () async -> Void) async {
        let began = Date.now, cpu = Self.cpuSeconds()
        let measured = await measure(seconds: 0.5, action)
        let elapsed = Date.now.timeIntervalSince(began)
        let used = (Self.cpuSeconds() - cpu) * 1000
        let line = String(format: "%@: %d late, %.0f ms late (worst %.0f), cpu %.0f ms (%.0f%% of a core) over %.1f s from %.3f",
                          label, measured.late, measured.lateMS, measured.worst, used, used / elapsed / 10, elapsed, began.timeIntervalSince1970)
        log.notice("\(line, privacy: .public)")
        lines.append("# " + line)
        write()
    }

    private var window: (late: Int, lateMS: Double, worst: Double)?

    // MARK: Scrolling by itself

    private var scroller: CADisplayLink?
    private var scrolling: (view: UIScrollView, start: CFTimeInterval, seconds: Double, from: CGFloat, reach: CGFloat)?
    private var during: (late: Int, lateMS: Double, cpu: Double, began: Date)?

    /// Scrolls the tallest scroll view on screen up and back by itself (`-echo.autoScroll`).
    func autoScroll(for seconds: Double) {
        let windows = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }
        func scrollViews(in view: UIView) -> [UIScrollView] {
            ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        guard let view = windows.flatMap({ scrollViews(in: $0) })
            .filter({ $0.window != nil && !$0.isHidden && $0.bounds.height > 300 })
            .max(by: { $0.contentSize.height < $1.contentSize.height }) else {
            log.notice("autoscroll: no scroll view"); return
        }
        // Away from whichever end it is at, and back.
        let from = view.contentOffset.y
        let up = from + view.adjustedContentInset.top
        let down = view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height - from
        let reach = (up > down ? 1 : -1) * min(max(up, down), view.bounds.height * 6)
        scrolling = (view, CACurrentMediaTime(), seconds, from, reach)
        during = (0, 0, Self.cpuSeconds(), .now)
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        scroller = link
        log.notice("autoscroll: \(Int(reach)) points up and back over \(seconds, format: .fixed(precision: 1)) s, content \(Int(view.contentSize.height)) high")
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let scrolling else { link.invalidate(); return }
        let t = (CACurrentMediaTime() - scrolling.start) / scrolling.seconds
        guard t < 1 else {
            link.invalidate(); scroller = nil; self.scrolling = nil
            scrolling.view.contentOffset.y = scrolling.from
            if let during {
                let elapsed = Date.now.timeIntervalSince(during.began)
                let cpu = (Self.cpuSeconds() - during.cpu) * 1000
                let line = String(format: "autoscroll: %d late, %.0f ms late, %.1f ms/s late, cpu %.0f ms (%.0f%% of a core) over %.1f s",
                                  during.late, during.lateMS, during.lateMS / elapsed, cpu, cpu / elapsed / 10, elapsed)
                log.notice("\(line, privacy: .public)")
                lines.append("# " + line)
                write()
            }
            during = nil
            return
        }
        // Up and back down, easing in and out like a hand: half a cosine each way.
        let u = t < 0.5 ? t * 2 : (1 - t) * 2
        let eased = (1 - cos(.pi * u)) / 2
        scrolling.view.contentOffset.y = scrolling.from - scrolling.reach * eased
    }

    /// The text field or view that has the keyboard, to type into as the keyboard does.
    static func focusedTextInput() -> UIKeyInput? {
        func find(_ view: UIView) -> UIKeyInput? {
            if view.isFirstResponder, let input = view as? UIKeyInput { return input }
            return view.subviews.lazy.compactMap(find).first
        }
        return UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.lazy.compactMap(find).first
    }

    /// The process's CPU time so far, user and system.
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last > 0 else { return }
        let frame = link.targetTimestamp - link.timestamp
        let gap = link.timestamp - last
        guard frame > 0, gap > frame * 1.5 else { return }
        let late = (gap - frame) * 1000
        let at = Date.now.timeIntervalSince1970 - (CACurrentMediaTime() - last)   // when the stall began
        log.notice("frames: late \(late, format: .fixed(precision: 0)) ms at \(at, format: .fixed(precision: 3))")
        lines.append(String(format: "%.3f %.0f", at, late))
        if during != nil { during?.late += 1; during?.lateMS += late }
        if var counted = window { counted.late += 1; counted.lateMS += late; counted.worst = max(counted.worst, late); window = counted }
    }

    private func write() {
        guard !lines.isEmpty else { return }
        let text = lines.joined(separator: "\n") + "\n"
        lines = []
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
        } else {
            try? Data(text.utf8).write(to: file)
        }
    }
}
#elseif DEBUG
import AppKit
import os

/// The Mac's: no frames counted yet, only how long each step of `-echo.tour` takes.
@MainActor
final class FrameMonitor: NSObject {
    static let shared = FrameMonitor()
    private let log = Logger(subsystem: "com.goosehouse.echo", category: "frames")

    func start() {}
    func autoScroll(for seconds: Double) {}

    func report(_ label: String, _ action: () async -> Void) async {
        let began = Date.now
        await action()
        log.notice("\(label, privacy: .public): \(String(format: "%.1f", Date.now.timeIntervalSince(began)), privacy: .public) s")
    }

    /// The text view typing goes into, as the keyboard puts it there.
    static func focusedTextInput() -> NSTextView? { NSApplication.shared.keyWindow?.firstResponder as? NSTextView }
}
#endif
