// MacWright — drives this Mac's mouse, keyboard, screen and accessibility for end-to-end tests of desktop apps.
//
// Runs as its own app bundle so the Accessibility / Screen Recording grants belong to MacWright,
// not to a terminal. Always launch it through LaunchServices (`open` or a login item); running the
// binary from a shell makes the terminal the responsible process.
//
// It is only ever the menu-bar app hosting the MCP server (Streamable HTTP on 127.0.0.1:47615/mcp),
// whatever arguments it is launched with. Every request needs the Bearer token, so launching the app
// gives another process nothing: there is no unauthenticated way to borrow MacWright's grants.
// It also starts locked (App.swift): the server only listens after Touch ID or the login password.
// `open` without -n reuses a running instance, so there is one menu-bar app.
import AppKit

@main
enum Entry {
    static func main() {
        MacWrightApp.main()
    }
}
