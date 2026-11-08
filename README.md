# MacWright

A menu-bar app that drives your Mac (mouse, keyboard, screen, accessibility, clipboard) for
end-to-end tests of desktop apps. It hosts an MCP server so an agent such as Claude Code can use
it. Input is posted the way physical hardware posts it (deltas, modifier presses, force-click
pressure), and every call can report what event taps actually received.

There is no other way in: every request needs the token, and launching the app (with any
arguments) only starts the menu-bar server, so another agent or process can't borrow MacWright's
permissions. See [SECURITY.md](SECURITY.md).

macOS gives the permissions to **MacWright.app**, not to your terminal. That only works if
LaunchServices starts it (`open` or a login item), never a shell
running the binary directly.

## Requirements

- macOS 14 or later (`record` needs macOS 15).
- Swift 6.1 or later (Xcode 16.3+) to build.
- Accessibility, Screen Recording and Input Monitoring permissions, granted from the menu.

## Build

```bash
./build.sh       # swift build -c release → /Applications/MacWright.app, signed
./build-dmg.sh   # signed app packed into dist/MacWright-<version>.dmg (drag to Applications)
swift test       # unit tests (key names, clamp model, push_edge plans, HTTP auth)
swift scripts/make-icon.swift   # re-render Resources/AppIcon.icns (drawn in code)
```

macOS ties the permission grants to the bundle id (`com.kuarasoft.macwright`) and the signing
identity. Sign every build with the same identity, or you'll have to grant the permissions again
after each rebuild. Set `MACWRIGHT_SIGN_IDENTITY` to a certificate name or SHA-1 from
`security find-identity -v -p codesigning`, or keep it in a git-ignored `.signing` file:

```bash
echo 'MACWRIGHT_SIGN_IDENTITY=<sha1-or-name>' > .signing
```

Without one, the build is signed ad hoc. After a rebuild, quit and reopen the app.

## Quick start

1. `./build.sh`, then `open /Applications/MacWright.app`.
2. Unlock with Touch ID or your password, and grant the three permissions from the menu.
3. Pick **Copy Claude Code command** in the menu and run it in your terminal.
4. Ask the agent to call `status`, then `selftest` to check that posted input arrives.

## Menu-bar app + MCP server

```bash
open /Applications/MacWright.app
```

MacWright starts **locked**: the MCP server doesn't listen until you unlock it with Touch ID or
your Mac login password (macOS asks right after launch; if you cancel, use **Unlock…** in the
menu). Anything can launch the app (`open`, a script, an agent, a login item), so launching it
gives nothing away; only a human at the Mac can switch the server on. **Lock** in the menu stops
the server again. While locked, Claude Code sessions just can't connect to `macwright`.

Lock (and Quit) also stops a tool call that is already running: typing, a drag, a wait, a `when`
trigger or a screen recording stops within about 0.1 s, a recording cut short is deleted, and a
result that finishes after the lock is thrown away, so no screenshot or AX tree leaves once
you've locked. `watch_focus` stops too.

### Check your terminal

The lock only protects you if MacWright is the only app with Accessibility, Screen Recording and
Input Monitoring. A command-line agent runs with its terminal's permissions, so if the terminal
holds any of them, the agent can click, type or take screenshots (`osascript`, `screencapture`)
without MacWright, locked or not. In the menu, **Copy terminal check command**, then paste it in
each terminal or app where you run agents:

```text
Checking Terminalo  /Applications/Terminalo.app
  ✓ Accessibility: not granted
  ✓ Screen Recording: not granted
  ✓ Input Monitoring: not granted

OK. Agents running in Terminalo can only control this Mac through MacWright, so its lock applies to them.
```

If one is granted, it says what an agent there could do and prints commands that open the right
System Settings panes; turn that app off there. It only reads the current state, never asks for a
permission, and exits 1 when it finds one (`--json` for scripts). macOS doesn't let one app read
another's grants without Full Disk Access, which MacWright shouldn't have, so the check has to run
inside the app being checked.

The menu shows:

- Server address: Streamable HTTP at `http://127.0.0.1:47615/mcp`. It listens on 127.0.0.1
  only; change the port with `defaults write com.kuarasoft.macwright port -int <port>`.
- Permissions: Accessibility, Screen Recording and Input Monitoring. Click one to get the
  system prompt (if it isn't granted yet) and the matching System Settings pane.
  **Copy terminal check command** is there too (see Check your terminal).
- **Copy Claude Code command**, which copies:

```bash
claude mcp add --transport http macwright http://127.0.0.1:47615/mcp --header "Authorization: Bearer <token>"
```

- Token: shows the token, copies it, or regenerates it. The token is created on first run and
  kept in the login Keychain (service `com.kuarasoft.macwright`). Every request needs
  `Authorization: Bearer <token>`. After you regenerate it, run `claude mcp remove macwright`
  and add the server again.
- **Pause** (or the global hotkey **⌃⌥⌘⎋**): while paused, tool calls fail with `paused`.
  Pausing, quitting and any failed tool call release every held button and key.
- Recent tool calls, with time, result and duration. The log is in
  `~/Library/Logs/MacWright/macwright.log`.
- Launch at login (SMAppService) and Quit.

A dot on the menu-bar icon means a tool call is running. A pause symbol means MacWright is paused.

### Coordinates

All coordinates are CoreGraphics global points. The origin is the top-left of the main display,
y grows downward, and displays left of or above the main one have negative coordinates.
`displays` lists each display's bounds and which displays touch each of its edges.
`screenshot` returns a mapping you can use to turn image pixels into points:

```text
pointX = origin.x + pixelX * pointsPerPixel
pointY = origin.y + pixelY * pointsPerPixel
```

### The physical-mouse model

Relative moves (`move`, `drag`, `move_to`, `push_edge`) post `mouseMoved`, or `*MouseDragged`
while a button is held, at `kCGHIDEventTap` with the delta fields set. The location is clamped
to the displays and slides along edges, and after each event the driver re-reads the real
cursor. Apps that capture the mouse at a screen edge read these deltas. `warp` teleports the cursor instead, and it
is not a way to cross an edge.

While the cursor is hidden system-wide, the cursor stays where it is: moves are posted at the
cursor's current spot and still carry their deltas. Apps that capture the mouse (KVM-style
edge switchers, games, remote desktops) hide and freeze the cursor, so this is how a real mouse
behaves. Every result's `cursor` includes `hidden`, which is a quick way for a test to see that
the app under test has captured.

### Tools

Every result also has `activeApp` (the app that gets posted keys) and, for input tools, `pointer`
(`hidden`, and after relative moves `moves`: false when the cursor didn't follow). Any input tool
takes `when {file, regex, timeoutMs}`: it waits for a new matching line in that file, then acts.

Every tool returns structured JSON. Tools that act also return `cursor`, the position after the
action. Calls run one at a time.

| Group | Tools |
|---|---|
| Info | `status`, `displays`, `cursor`, `event_taps {process}` (every event tap with mode and latency), `selftest {suite: mouse\|keys\|force\|all}` |
| Focus | `watch_focus {action: start\|read\|stop, apps?, since?, bounceMs?}` (frontmost-app and key/main-window timeline, with bounces) |
| Events | `record_events {seconds, types?, taps?}` (full dump of HID + session taps to a JSON file), `watch_events {seconds, tap?, types?}` |
| Mouse | `warp {x,y}`, `move {dx,dy,steps,intervalMs,modifiers?}`, `drag {dx,dy,steps,intervalMs,button?,modifiers?}` or `drag {toEdge,display?,dwellMs?,pushSteps?,holdMs?,release?}` (a file drag onto an edge), `move_to {x,y,durationMs,modifiers?}`, `push_edge {edge,display?,along,distance,steps,intervalMs,dwellMs?,modifiers?}` (modifiers held through the whole gesture, e.g. ⌘ or fn), `click {button,count,x?,y?,modifiers?}`, `down/up {button}`, `force_click {x?,y?}`, `scroll {dx,dy,unit,phases}` |
| Keyboard | `key {key,modifiers?,holdMs?,layoutText?}` (events carry the current layout's text, like hardware), `type_text {text,intervalMs?}`, `hold {keys,modifiers,ms}`, `chord {hold, steps}` (modifiers held through several steps, e.g. ⌘ through a jump + Tab), `release_all`. Key tools take `keyTarget` and refuse while a terminal that may host the agent is active (`allowActive`, `refuseIfActive`, `defaults write com.kuarasoft.macwright refuseKeysTo -array …`) |
| Screen | `screenshot {display?,rect?,window?,scale=0.5,format}`, `wait_screen_stable`, `wait_for_screen_change`, `record {seconds,display?,path}` (macOS 15+) |
| Windows/apps | `list_windows {app?}` (flags `systemPrompt` windows, such as TCC alerts, Gatekeeper, SecurityAgent, UserNotificationCenter and a showing notification banner, and lists them under `systemPrompts`), `launch_app`, `quit_app`, `activate_app`, `running_apps`, `open_url`, `open_file` |
| Chrome | `chrome_profiles {channel?}` (directory, name, signed-in email), `open_chrome {urls?, profile?, newWindow?, incognito?, guest?, appUrl?, channel?, userDataDir?, remoteDebuggingPort?, args?}` (works whether Chrome is running or not; `profile` takes a directory, display name or email; returns the new window ids) |
| Accessibility | `ax_tree {app,window?,maxDepth=8,includeMenuBar?}`, `ax_find`, `ax_press`, `ax_set_value`, `ax_focus` (each takes `path` or `query`), `menu_extra {app,itemPath,method: press\|click}` (status-item menu, e.g. an app's tray menu; `click` = real clicks, a user action), `menu {app,itemPath}`, `status_items {app?}`, `click_status_item {pid \| app, index, method: click\|press}` |
| Clipboard | `clipboard_get {types?}`, `clipboard_set {text \| fileUrls}`, `clipboard_change_count` |
| Waiting | `wait_for_window {app,titleContains?,timeoutMs}`, `wait_for_ax {app,query,timeoutMs}`, `sleep {ms}` |

Notes:

- Every input tool's result has `posted`: the event types, flags and count it sent. Add
  `watch: true` (or `"hid"` / `"both"`) to get `observed`, the events a tap actually saw during the
  call. The taps are read after a *fence*: one more marked zero-delta move that MacWright posts
  after the action and waits for at every tap (taps see events in posting order). So slow delivery
  is waited for instead of being reported as nothing seen; `observed.complete: false` (with
  `fence.missing`) means a tap never received MacWright's events at all. Add `swallow: true` to drop MacWright's own events at the head of the HID stream after
  recording them. That checks delivery at the HID level without any app receiving them.
  While another app's head tap consumes events (e.g. an app that has captured the mouse), a plain watch can't
  see them; `swallow` can.
- Every posted event carries `kCGEventSourceUserData = 0x4D435752` ('MCWR'), so recordings mark
  it `synthetic`. Tap probes and fences carry 'MCWP' and 'MCWF'<<16|seq and are hidden from results.
- **Human input.** An always-on listen-only HID tap counts every event MacWright did not post (the
  human's mouse, trackpad touches, keys, scrolls, or another app's events). It keeps counts, kinds
  and times only, never key codes. Every tool result has `humanInput`: `sinceLastCall` (since the
  previous call ended), `duringCall`, `kinds`, `lastAtMillis`, `msAgo`, `lastKind`, and
  `otherProcesses` when another app posted events. `status` has the totals. Input tools take
  `humanQuietMs`: the call fails without posting anything when human input arrived within that many
  ms (default 0, or `defaults write com.kuarasoft.macwright humanQuietMs -int 500`).
- **Focus timeline.** `watch_focus {action: "start"}` records `appActivated`/`appDeactivated`
  (NSWorkspace) and `focusedWindowChanged`/`mainWindowChanged` (AX observers on the frontmost app,
  every app that becomes frontmost, and `apps`), each with `t` (ms since start), pid, bundle id and
  the window (`windowId` as in `list_windows`, title, bounds). `read {since}` returns the events
  after a seq (pass back `next`) and `bounces`: a window that lost key/main and got it back within
  `bounceMs` (default 200), or an app deactivated and re-activated that quickly.
- **Status items.** `status_items` lists every app's AXExtrasMenuBar items left to right with pid,
  bundle id, path, frame and centre, so two processes with the same name (a dev JVM
  `com.jetbrains.jbr.java` and the packaged app) are told apart. `click_status_item {pid, index}`
  clicks one with a real mouse click at its centre (right for icons that toggle a popup), or
  `method: "press"` for AXPress. `menu_extra` remains the way to pick items in a status menu.
- **Notification Center.** Its full-display window (layer 21) is always there and can be reported
  on screen while nothing shows. `list_windows` reads Notification Center's AX tree and flags it
  only while it shows a banner, an alert or the open panel (`notificationCenter`, `promptKind`:
  `notificationBanner`, `notificationAlert`, `notificationCenterOpen`). A banner goes away by
  itself, so wait and list again before asking the human.
- Keyboard events look like a physical keyboard's. Each modifier is its own flagsChanged press
  with the cumulative flags. Key events carry every held modifier, with the left-hand device bits
  and NonCoalesced. Arrows add NumericPad and SecondaryFn, and function and navigation keys add
  SecondaryFn. Modifiers are released in reverse order. Clicks, drags, scrolls, `hold` and
  `type_text` (a real Shift press for capitals and shifted symbols) use the same model.

- Key names: `esc`, `return`, `tab`, `space`, `delete`, `forwarddelete`, the arrow keys,
  `home`, `end`, `pageup`, `pagedown`, `f1`–`f20`, `a`–`z`, `0`–`9`, punctuation, and
  `volumeup`, `volumedown` and `mute`. You can also give a raw keycode (`53`, `0x35`). The
  modifiers are `cmd`, `opt`, `ctrl`, `shift` and `fn`. They're posted as real modifier presses.
- `type_text` puts every character into the event with `CGEventKeyboardSetUnicodeString`, so
  the result doesn't depend on the keyboard layout. ASCII characters also carry their US
  keycode.
- `force_click` replays the shape of a recorded trackpad force click: gesture began, left down,
  type-29 pressure events (HID type force, phase, stage, pressure and transition fields) through
  stage 1 into stage 2, back to stage 1, ended, left up. Taps see NSEventTypePressure with stage
  2. `selftest {suite: "force"}` checks it.
- An AX `path` is a list of AXChildren indexes, starting at the application element. You can
  pass a path from `ax_tree` or `ax_find` straight back to `ax_press`, `ax_set_value` or
  `ax_focus`.
- If `list_windows` shows `systemPrompts`, a test should stop and ask the human to deal with them.

## Test runner

`macwright-run` runs end-to-end tests written as YAML (or JSON) files, without an agent. It talks
to the running, unlocked app over MCP with the token, so it has no permissions of its own and
works the same on your Mac and on a CI machine with MacWright set up.

```bash
swift build -c release --product macwright-run
export MACWRIGHT_TOKEN=<token>   # menu: Token → Copy token
.build/release/macwright-run examples/
```

A test file has optional `setup`, the `steps`, and optional `teardown`. Each step calls one tool
with its arguments, exactly as an agent would:

```yaml
name: Calculator adds
vars:
  app: com.apple.calculator
setup:
  - launch_app: {bundleId: "${app}"}
  - wait_for_window: {app: "${app}"}
steps:
  - key: {key: esc, keyTarget: "${app}"}
  - type_text: {text: "2+3=", keyTarget: "${app}"}
  - name: Display shows 5
    ax_find: {app: "${app}", role: AXStaticText, value: "5"}
    retry: 2000
    expect:
      count: {gte: 1}
teardown:
  - quit_app: {bundleId: "${app}"}
```

Setup and steps stop at the first failure; teardown always runs. A step can also have:

- `name`: shown instead of the tool name.
- `expect`: result paths mapped to matchers. A path is `windows[0].title` (also `windows.0.title`,
  and `[-1]` for the last element). A plain value must be equal (`1` equals `1.0`); a plain map
  only needs the keys it names. Operators: `equals`, `not`, `contains` (substring, list element
  or map key), `matches` (regex), `gt`, `gte`, `lt`, `lte`, `exists`, `length`, `any`, `all`.
- `retry`: `2000` or `{timeoutMs, intervalMs}`. Repeats the call until `expect` passes.
- `save`: `{win: "windows[0]"}` stores part of the result for later steps.
- `expectError`: `true`, or a substring of the error. The step passes only if the call fails.

A step with no arguments can be just the tool name (`- release_all`). Strings can use
`${name}`, `${win.id}` (a field of a saved value) and `${env.HOME}`. A string that is only
`${…}` keeps the value's type, so `"${win.id}"` passes a number.

Keys go to the active app, and key tools refuse while a terminal is active (that's where the
runner usually is). Bring the app forward first and pass `keyTarget`, as in the example.

| Option | |
|---|---|
| `--token <token>` | Bearer token (default `$MACWRIGHT_TOKEN`) |
| `--server <url>` | MCP endpoint (default `$MACWRIGHT_SERVER`, or 127.0.0.1 on the app's port) |
| `--var name=value` | Set or override a variable |
| `--junit <path>` | Write a JUnit XML report for CI |
| `--artifacts <dir>` | Save a screenshot when a test fails |
| `--fail-fast` | Stop after the first failing test |
| `--check` | Parse the files (and check tool names when a token is given), run nothing |
| `--verbose` | Print every step's result |

Exit status: 0 when every test passed, 1 when one failed, 2 for a usage or connection error.

## License

MIT. See [LICENSE](LICENSE).
