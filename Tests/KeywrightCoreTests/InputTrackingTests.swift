import XCTest
@testable import KeywrightCore

final class InputTrackingTests: XCTestCase {
    // MARK: markers

    func testFenceMarkersAreOwnAndDistinct() {
        let f = OwnMarker.fence(7)
        XCTAssertTrue(OwnMarker.isFence(f))
        XCTAssertTrue(OwnMarker.isBookkeeping(f))
        XCTAssertTrue(OwnMarker.isOwn(f))
        XCTAssertNotEqual(OwnMarker.fence(7), OwnMarker.fence(8))
        XCTAssertFalse(OwnMarker.isFence(OwnMarker.synthetic))
        XCTAssertFalse(OwnMarker.isFence(OwnMarker.probe))
        XCTAssertTrue(OwnMarker.isOwn(OwnMarker.synthetic))
        XCTAssertFalse(OwnMarker.isBookkeeping(OwnMarker.synthetic))
        XCTAssertTrue(OwnMarker.isBookkeeping(OwnMarker.probe))
        // Hardware events carry no user data.
        XCTAssertFalse(OwnMarker.isOwn(0))
        XCTAssertFalse(OwnMarker.isOwn(42))
        // The sequence wraps inside the fence tag.
        XCTAssertTrue(OwnMarker.isFence(OwnMarker.fence(70_000)))
    }

    func testInputKinds() {
        XCTAssertEqual(InputKind.of(5), "move")
        XCTAssertEqual(InputKind.of(6), "drag")
        XCTAssertEqual(InputKind.of(1), "click")
        XCTAssertEqual(InputKind.of(10), "key")
        XCTAssertEqual(InputKind.of(12), "modifier")
        XCTAssertEqual(InputKind.of(22), "scroll")
        XCTAssertEqual(InputKind.of(29), "gesture")
        XCTAssertNil(InputKind.of(0xFFFF_FFFE))
    }

    // MARK: human input log

    func testSinceMarkCountsOnlyNewEventsAndMovesTheMark() {
        var log = HumanInputLog()
        log.add(kind: "move", atMillis: 1000)
        log.add(kind: "move", atMillis: 1010)
        log.add(kind: "key", atMillis: 1020)
        let first = log.takeSinceMark()
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(first.kinds, ["move": 2, "key": 1])
        XCTAssertEqual(log.takeSinceMark().count, 0)
        XCTAssertEqual(log.takeSinceMark().kinds, [:])
        log.add(kind: "scroll", atMillis: 2000)
        XCTAssertEqual(log.peekSinceMark().count, 1)
        XCTAssertEqual(log.peekSinceMark().kinds, ["scroll": 1])   // peek does not move the mark
        XCTAssertEqual(log.takeSinceMark().count, 1)
        XCTAssertEqual(log.total, 4)
        XCTAssertEqual(log.lastKind, "scroll")
        XCTAssertEqual(log.lastAtMillis, 2000)
    }

    func testSeenWithin() {
        var log = HumanInputLog()
        XCTAssertFalse(log.seen(withinMs: 500, nowMillis: 10_000))
        log.add(kind: "move", atMillis: 9_700)
        XCTAssertTrue(log.seen(withinMs: 500, nowMillis: 10_000))
        XCTAssertFalse(log.seen(withinMs: 200, nowMillis: 10_000))
    }

    func testOtherProcessesAreTrackedButNotOurOwnPid() {
        var log = HumanInputLog()
        log.add(kind: "move", atMillis: 1, sourcePid: 0, ownPid: 99)     // hardware
        log.add(kind: "click", atMillis: 2, sourcePid: 99, ownPid: 99)   // ourselves (unmarked): not "other"
        log.add(kind: "key", atMillis: 3, sourcePid: 1234, ownPid: 99)
        XCTAssertEqual(log.byOtherPid, [1234: 1])
        XCTAssertEqual(log.total, 3)
    }

    // MARK: focus bounce

    func testKeyWindowBounceInsideOneApp() {
        let ev = [
            FocusChange(seq: 1, t: 0, kind: "focusedWindowChanged", pid: 10, window: "#5"),
            FocusChange(seq: 2, t: 1000, kind: "focusedWindowChanged", pid: 10, window: "#9"),
            FocusChange(seq: 3, t: 1090, kind: "focusedWindowChanged", pid: 10, window: "#5"),
        ]
        let b = FocusBounce.detect(ev, withinMs: 150)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b.first?["window"] as? String, "#5")
        XCTAssertEqual(b.first?["gapMs"] as? Double, 90)
        XCTAssertEqual(b.first?["seq"] as? [Int], [2, 3])
    }

    func testDuplicateNotificationsDoNotHideABounce() {
        let ev = [
            FocusChange(seq: 1, t: 0, kind: "focusedWindowChanged", pid: 10, window: "#5"),
            FocusChange(seq: 2, t: 1000, kind: "focusedWindowChanged", pid: 10, window: "#9"),
            FocusChange(seq: 3, t: 1001, kind: "focusedWindowChanged", pid: 10, window: "#9"),
            FocusChange(seq: 4, t: 1100, kind: "focusedWindowChanged", pid: 10, window: "#5"),
            FocusChange(seq: 5, t: 1101, kind: "focusedWindowChanged", pid: 10, window: "#5"),
        ]
        let b = FocusBounce.detect(ev, withinMs: 150)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b.first?["seq"] as? [Int], [2, 4])
    }

    func testBounceThroughNoWindow() {
        let ev = [
            FocusChange(seq: 1, t: 0, kind: "mainWindowChanged", pid: 10, window: "#5"),
            FocusChange(seq: 2, t: 500, kind: "mainWindowChanged", pid: 10, window: nil),
            FocusChange(seq: 3, t: 560, kind: "mainWindowChanged", pid: 10, window: "#5"),
        ]
        XCTAssertEqual(FocusBounce.detect(ev, withinMs: 150).count, 1)
    }

    func testSlowSwitchBackIsNotABounce() {
        let ev = [
            FocusChange(seq: 1, t: 0, kind: "focusedWindowChanged", pid: 10, window: "#5"),
            FocusChange(seq: 2, t: 1000, kind: "focusedWindowChanged", pid: 10, window: "#9"),
            FocusChange(seq: 3, t: 3000, kind: "focusedWindowChanged", pid: 10, window: "#5"),
        ]
        XCTAssertTrue(FocusBounce.detect(ev, withinMs: 150).isEmpty)
    }

    func testOtherAppsAndKindsDoNotMix() {
        let ev = [
            FocusChange(seq: 1, t: 0, kind: "focusedWindowChanged", pid: 10, window: "#5"),
            FocusChange(seq: 2, t: 10, kind: "focusedWindowChanged", pid: 11, window: "#9"),
            FocusChange(seq: 3, t: 20, kind: "mainWindowChanged", pid: 10, window: "#5"),
        ]
        XCTAssertTrue(FocusBounce.detect(ev, withinMs: 150).isEmpty)
    }

    func testAppReactivated() {
        let ev = [
            FocusChange(seq: 1, t: 100, kind: "appDeactivated", pid: 10, window: nil),
            FocusChange(seq: 2, t: 100, kind: "appActivated", pid: 20, window: nil),
            FocusChange(seq: 3, t: 180, kind: "appActivated", pid: 10, window: nil),
        ]
        let b = FocusBounce.detect(ev, withinMs: 150)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b.first?["kind"] as? String, "appReactivated")
        XCTAssertEqual(b.first?["pid"] as? Int, 10)
    }

    // MARK: Notification Center

    func testIdleNotificationCenterShowsNothing() {
        // Idle: the app element only (or empty hosting containers).
        XCTAssertFalse(NotificationCenterRule.content([AXLite(role: "AXApplication", subrole: "", width: 0, height: 0, label: "Notification Center")]).visible)
        XCTAssertFalse(NotificationCenterRule.content([
            AXLite(role: "AXWindow", subrole: "AXSystemDialog", width: 1440, height: 932, label: "Notification Center"),
            AXLite(role: "AXGroup", subrole: "AXHostingView", width: 1440, height: 932, label: ""),
            AXLite(role: "AXGroup", subrole: "", width: 0, height: 0, label: "widgets-overlay-view"),
        ]).visible)
    }

    func testBannerIsVisible() {
        let c = NotificationCenterRule.content([
            AXLite(role: "AXWindow", subrole: "AXSystemDialog", width: 1440, height: 932, label: "Notification Center"),
            AXLite(role: "AXGroup", subrole: "AXNotificationCenterBanner", width: 344, height: 58, label: "Script Editor, Hi, there"),
            AXLite(role: "AXStaticText", subrole: "", width: 96, height: 16, label: "Hi"),
        ])
        XCTAssertTrue(c.visible)
        XCTAssertEqual(c.banners, ["Script Editor, Hi, there"])
        XCTAssertTrue(c.alerts.isEmpty)
    }

    func testAlertIsReportedAsAlert() {
        let c = NotificationCenterRule.content([AXLite(role: "AXGroup", subrole: "AXNotificationCenterAlert", width: 344, height: 80, label: "Calendar")])
        XCTAssertTrue(c.visible)
        XCTAssertEqual(c.alerts, ["Calendar"])
        XCTAssertTrue(c.banners.isEmpty)
    }

    func testZeroSizedLeftoversDoNotCount() {
        XCTAssertFalse(NotificationCenterRule.content([AXLite(role: "AXGroup", subrole: "AXNotificationCenterBanner", width: 0, height: 0, label: "gone")]).visible)
    }

    // MARK: status items

    let items = [
        StatusItemRef(pid: 100, bundleId: "com.kuarasoft.terminalo", name: "Terminalo", index: 0, x: 900),
        StatusItemRef(pid: 200, bundleId: "com.jetbrains.jbr.java", name: "Terminalo", index: 0, x: 950),
        StatusItemRef(pid: 300, bundleId: "com.example.multi", name: "Multi", index: 0, x: 700),
        StatusItemRef(pid: 300, bundleId: "com.example.multi", name: "Multi", index: 1, x: 720),
    ]

    func testFilterByPidBundleOrName() {
        XCTAssertEqual(StatusItemPick.filter(items, app: "200").map(\.pid), [200])
        XCTAssertEqual(StatusItemPick.filter(items, app: "com.kuarasoft.terminalo").map(\.pid), [100])
        XCTAssertEqual(StatusItemPick.filter(items, app: "terminalo").map(\.pid), [100, 200])
        XCTAssertEqual(StatusItemPick.filter(items, app: nil).count, 4)
    }

    func testPickNeedsPidWhenTwoProcessesShareAName() throws {
        XCTAssertThrowsError(try StatusItemPick.pick(items, pid: nil, app: "Terminalo", index: 0)) { e in
            XCTAssertTrue("\(e)".contains("100"))
            XCTAssertTrue("\(e)".contains("200"))
        }
        XCTAssertEqual(try StatusItemPick.pick(items, pid: 200, app: "Terminalo", index: 0).bundleId, "com.jetbrains.jbr.java")
        XCTAssertEqual(try StatusItemPick.pick(items, pid: nil, app: "com.jetbrains.jbr.java", index: 0).pid, 200)
    }

    func testPickByIndex() throws {
        XCTAssertEqual(try StatusItemPick.pick(items, pid: 300, app: nil, index: 1).x, 720)
        XCTAssertThrowsError(try StatusItemPick.pick(items, pid: 300, app: nil, index: 2))
        XCTAssertThrowsError(try StatusItemPick.pick(items, pid: 999, app: nil, index: 0))
    }
}
