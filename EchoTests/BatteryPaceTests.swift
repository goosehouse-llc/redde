import Foundation
import Testing
@testable import Echo

/// How often Redde asks for news, and how hard it listens for a wake phrase (battery review,
/// 2026-11-11).
struct BatteryPaceTests {
    @Test func theListWaitsLongerWhileNothingIsHappeningAndLongerAgainSavingPower() {
        #expect(Pace.wait(busy: true, .seconds(4), idle: .seconds(20), saving: false) == .seconds(4))
        #expect(Pace.wait(busy: false, .seconds(4), idle: .seconds(20), saving: false) == .seconds(20))
        #expect(Pace.wait(busy: true, .seconds(4), idle: .seconds(20), saving: true) == .seconds(12))
        #expect(Pace.wait(busy: false, .seconds(4), idle: .seconds(20), saving: true) == .seconds(60))
    }

    @Test func voicesThatArentAPhraseRaiseTheBarThenRest() {
        var ease = WakeEase()
        let start = ContinuousClock.now
        #expect(ease.margin == 12)
        // Five in a minute: a step up each time, to the top.
        for step in 1 ... WakeEase.top {
            for i in 0 ..< WakeEase.run { _ = ease.falseStart(at: start + .seconds(step * 10 + i)) }
            #expect(ease.step == step)
        }
        #expect(ease.margin == 24)
        #expect(!ease.resting(at: start + .seconds(40)))
        // At the top, another run rests it.
        for i in 0 ..< WakeEase.run { _ = ease.falseStart(at: start + .seconds(41 + i)) }
        #expect(ease.resting(at: start + .seconds(50)))
        #expect(!ease.resting(at: start + .seconds(70)))
        // Two quiet spells later, two steps down.
        _ = ease.falseStart(at: start + .seconds(45) + WakeEase.calm * 2)
        #expect(ease.step == WakeEase.top - 2)
        // A phrase heard: as at first.
        ease.heard()
        #expect(ease.step == 0)
    }

    @Test func aFewVoicesSpreadOutChangeNothing() {
        var ease = WakeEase()
        let start = ContinuousClock.now
        for i in 0 ..< 10 { _ = ease.falseStart(at: start + .seconds(i * 30)) }
        #expect(ease.step == 0)
    }
}
