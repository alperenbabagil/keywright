import XCTest
@testable import KeywrightCore

final class ChromeTests: XCTestCase {
    let localState = """
    {"profile": {"last_used": "Profile 1", "info_cache": {
      "Default": {"name": "Person 1", "user_name": "tech@example.com", "gaia_name": "Kuara Tech"},
      "Profile 1": {"name": "Work", "user_name": "po@example.com", "gaia_name": "Kuara PO"},
      "Profile 10": {"name": "Scratch"},
      "Profile 2": {"name": "Work Old", "user_name": ""}
    }}}
    """.data(using: .utf8)!

    func testParseLocalState() throws {
        let s = try Chrome.parseLocalState(localState)
        XCTAssertEqual(s.lastUsed, "Profile 1")
        XCTAssertEqual(s.profiles.map(\.directory), ["Default", "Profile 1", "Profile 2", "Profile 10"])
        XCTAssertEqual(s.profiles[0], ChromeProfile(directory: "Default", name: "Person 1", email: "tech@example.com", gaiaName: "Kuara Tech"))
        XCTAssertEqual(s.profiles[3].email, "")
    }

    func testResolve() throws {
        let ps = try Chrome.parseLocalState(localState).profiles
        XCTAssertEqual(try Chrome.resolve("profile 1", in: ps).name, "Work")
        XCTAssertEqual(try Chrome.resolve("Person 1", in: ps).directory, "Default")
        XCTAssertEqual(try Chrome.resolve("PO@example.com", in: ps).directory, "Profile 1")
        XCTAssertEqual(try Chrome.resolve("work", in: ps).directory, "Profile 1", "exact name wins over substring")
        XCTAssertEqual(try Chrome.resolve("Kuara Tech", in: ps).directory, "Default")
        XCTAssertEqual(try Chrome.resolve("scr", in: ps).directory, "Profile 10")
        XCTAssertThrowsError(try Chrome.resolve("kuara", in: ps)) { XCTAssert("\($0)".contains("several")) }
        XCTAssertThrowsError(try Chrome.resolve("nobody", in: ps)) { XCTAssert("\($0)".contains("Profile 1 = Work")) }
    }

    func testArguments() throws {
        var o = Chrome.Options()
        o.urls = ["https://a.example", "https://b.example"]
        o.profileDirectory = "Profile 1"
        o.newWindow = true
        XCTAssertEqual(try Chrome.arguments(o),
                       ["--profile-directory=Profile 1", "--new-window", "https://a.example", "https://b.example"])

        o = Chrome.Options()
        o.incognito = true
        o.remoteDebuggingPort = 9222
        o.userDataDir = "/tmp/x"
        XCTAssertEqual(try Chrome.arguments(o), ["--user-data-dir=/tmp/x", "--remote-debugging-port=9222", "--incognito"])

        o = Chrome.Options()
        o.appURL = "https://app.example"
        XCTAssertEqual(try Chrome.arguments(o), ["--app=https://app.example"])
    }

    func testArgumentErrors() {
        var o = Chrome.Options(); o.incognito = true; o.guest = true
        XCTAssertThrowsError(try Chrome.arguments(o))
        o = Chrome.Options(); o.urls = ["--kiosk"]
        XCTAssertThrowsError(try Chrome.arguments(o))
        o = Chrome.Options(); o.remoteDebuggingPort = 70000
        XCTAssertThrowsError(try Chrome.arguments(o))
        o = Chrome.Options(); o.appURL = "https://x"; o.incognito = true
        XCTAssertThrowsError(try Chrome.arguments(o))
    }

    func testChannel() throws {
        XCTAssertEqual(try ChromeChannel.parse(nil), .stable)
        XCTAssertEqual(try ChromeChannel.parse("Canary").bundleId, "com.google.Chrome.canary")
        XCTAssertEqual(try ChromeChannel.parse("chrome"), .stable)
        XCTAssertThrowsError(try ChromeChannel.parse("firefox"))
    }
}
