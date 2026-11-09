# Keywright

**Let AI agents drive your Mac, but only while you say so.**

Keywright is a menu-bar app that gives an agent such as Claude Code the mouse, keyboard, screen,
accessibility tree and clipboard of your Mac through an MCP server. It is the only app that holds
the permissions to do that, it starts locked, and it opens only with your fingerprint or password.

## The problem

To let an agent click, type or take screenshots, macOS has to grant Accessibility and Screen
Recording to *some* app. Most Mac-control tools tell you to grant them to your terminal or IDE.
From then on, every process started from that terminal has them: the agent, every command it
runs, every script an `npm install` pulls in. Any of them can watch your screen and type into any
app, at any time, and there is no switch to turn that off short of digging through System Settings.

Keywright moves those permissions out of the terminal and into one signed app with a lock:

- **Off means off.** While Keywright is locked, nothing can click, type or screenshot through it,
  and a call already running stops within about 0.1 s.
- **On needs you.** Unlocking, approving an agent, copying the token and loosening the
  auto-lock all ask for Touch ID or your login password, which an agent can't fake.
- **Your terminal stays powerless.** A built-in check tells you if a terminal still holds any of
  those permissions, so an agent there can't skip the lock.

## Features

**Security**

- Starts locked. The MCP server doesn't even listen until you unlock it with Touch ID or your password.
- Approve each agent: every new connection names the program behind it ("claude (pid 4242) in
  Terminal") and waits for your Touch ID. A stolen token or session ID gets 403.
- Auto-lock after a stretch of no tool calls (default 15 min) and at a hard limit after unlocking
  (default 4 h). Making the limits longer needs Touch ID.
- Lock or Quit stops a running call within about 0.1 s. Pause (or the global hotkey **⌃⌥⌘⎋**)
  refuses new calls and releases every held key and button.
- Refuses all input while a system security dialog is on screen, so an agent can't approve a
  permission prompt for itself.
- The token lives in the Keychain, is never shown, and a copied token clears from the clipboard after 60 s.
- Hardened runtime, so no other process can inject code into the app that holds the permissions.
- `keywright-check` tells you whether a terminal still holds permissions it shouldn't.
- Every tool call is listed in the menu and logged.

**Control**

- Mouse, trackpad and keyboard input posted the way real hardware posts it: deltas, separate
  modifier presses, force-click pressure, layout-aware key events.
- Screenshots of any display, window or area, and screen recordings (macOS 15+).
- The accessibility tree: find, press, set values and focus without guessing coordinates.
- Apps, windows, menus, menu-bar items, Chrome profiles and the clipboard.
- Knows when *you* touch the mouse or keyboard, and can refuse to act while you are using the Mac.

**Testing**

- `keywright-run` runs end-to-end tests of desktop apps from YAML files, with retries,
  expectations, JUnit output and screenshots on failure.
- Every input call can report which event taps actually received its events, and the focus
  timeline catches windows that lose and regain focus.

## What it doesn't protect

Keywright guards the screen and input. An agent running as you can still read your files, run
commands and use the network; use your agent's own sandbox and permission settings for that.
See [SECURITY.md](SECURITY.md) for the full threat model.

## Requirements

- macOS 14 or later (`record` needs macOS 15).
- Swift 6.1 or later (Xcode 16.3+) to build.
- A Mac with Touch ID, or your login password as the fallback.

## Quick start

```bash
./build.sh
open /Applications/Keywright.app
```

1. Unlock with Touch ID or your password, and grant Accessibility, Screen Recording and Input
   Monitoring from the menu.
2. In each terminal where you run agents, run the check (menu → **Copy terminal check command**)
   and turn off anything it finds.
3. Pick **Copy Claude Code command…** in the menu (Touch ID) and run it in your terminal.
4. Start Claude Code. When it connects, Keywright asks you to approve it with Touch ID.
5. Ask the agent to call `status`, then `selftest` to check that posted input arrives.

## Build

```bash
./build.sh       # swift build -c release → /Applications/Keywright.app, signed
./build-dmg.sh   # signed app packed into dist/Keywright-<version>.dmg (drag to Applications)
swift test       # unit tests (key names, clamp model, push_edge plans, HTTP auth)
swift scripts/make-icon.swift   # re-render Resources/AppIcon.icns (drawn in code)
```

macOS ties the permission grants to the bundle id (`com.kuarasoft.keywright`) and the signing
identity. Sign every build with the same identity, or you'll have to grant the permissions again
after each rebuild. Set `KEYWRIGHT_SIGN_IDENTITY` to a certificate name or SHA-1 from
`security find-identity -v -p codesigning`, or keep it in a git-ignored `.signing` file:

```bash
echo 'KEYWRIGHT_SIGN_IDENTITY=<sha1-or-name>' > .signing
```

Without one, the build is signed ad hoc. After a rebuild, quit and reopen the app. If you build it
yourself, read **If you build it yourself** in [SECURITY.md](SECURITY.md).

macOS gives the permissions to **Keywright.app**, not to your terminal. That only works if
LaunchServices starts it (`open` or a login item), never a shell running the binary directly.

## How the lock works

Keywright starts **locked**: the MCP server doesn't listen until you unlock it with Touch ID or
your Mac login password (macOS asks right after launch; if you cancel, use **Unlock…** in the
menu). Anything can launch the app (`open`, a script, an agent, a login item), and launching it
with any arguments only starts the menu-bar server, so launching gives nothing away; only a human
at the Mac can switch the server on. **Lock** in the menu stops the server again. While locked,
Claude Code sessions just can't connect to `keywright`.

Lock (and Quit) also stops a tool call that is already running: typing, a drag, a wait, a `when`
trigger or a screen recording stops within about 0.1 s, a recording cut short is deleted, and a
result that finishes after the lock is thrown away, so no screenshot or AX tree leaves once
you've locked. `watch_focus` stops too.

Because anything can launch Keywright, a Touch ID prompt you didn't expect may come from an agent
relaunching it. Only approve it when you meant to start a session.

### Connection approval

The token alone isn't enough: Claude Code keeps it in plain text in `~/.claude.json`, where any
process running as you could read it. So every new MCP session waits for you. Keywright finds the
process on the other end of the connection and asks, with Touch ID or your password, "let claude
(pid 4242) in Terminal control this Mac through Keywright", with the program's full path. Refuse,
and the client gets 403. An approved process isn't asked again until you lock; Lock forgets every
approval. A session only answers the process it was approved for, so another program that learns
its session ID gets 403 too, and a process Keywright can't identify is refused without asking.
Each `keywright-run` is a new process, so each run asks once.

### Auto-lock

**Auto-lock** (menu → Auto-lock) locks Keywright by itself, whichever comes first:

- **When idle:** after a stretch with no tool calls (default 15 min; never, 5, 15, 30, 60 or 120 min). A call that is still running counts as activity.
- **At most:** a fixed time after you unlock, even in the middle of a call (default 4 h; no limit, 1, 2, 4, 8 or 12 h).

The menu shows the time left ("Ready · locks in 12 min") and, after an automatic lock, why it
locked. Making a limit stricter applies at once; making it longer or turning it off asks for
Touch ID, so an agent clicking the menu can't extend its own session. The limits are read at
launch only (editing the defaults while Keywright runs changes nothing) and the unlock prompt
names them.

The server also drops a client that hasn't sent its headers within 10 s, or its whole request
within 30 s. A long tool call's reply isn't affected.

### Security dialogs

While a security dialog is on screen (a permission prompt, a password or Touch ID sheet,
Gatekeeper, the screen-sharing picker), every click, key, scroll and AX action fails with
"refused: a system security dialog is showing", and nothing is posted. An agent could otherwise
trigger a permission prompt from its terminal and approve it itself, and that grant would outlive
the lock. There is no override; answer the dialog yourself.

### Check your terminal

The lock only protects you if Keywright is the only app with Accessibility, Screen Recording and
Input Monitoring. A command-line agent runs with its terminal's permissions, so if the terminal
holds any of them, the agent can click, type or take screenshots (`osascript`, `screencapture`)
without Keywright, locked or not. In the menu, **Copy terminal check command**, then paste it in
each terminal or app where you run agents:

```text
Checking Terminal  /System/Applications/Utilities/Terminal.app
  ✓ Accessibility: not granted
  ✓ Screen Recording: not granted
  ✓ Input Monitoring: not granted

OK. Agents running in Terminal can only control this Mac through Keywright, so its lock applies to them.
```

If one is granted, it says what an agent there could do and prints commands that open the right
System Settings panes; turn that app off there. It only reads the current state, never asks for a
permission, and exits 1 when it finds one (`--json` for scripts). macOS doesn't let one app read
another's grants without Full Disk Access, which Keywright shouldn't have, so the check has to run
inside the app being checked.

## The menu

- Server address: Streamable HTTP at `http://127.0.0.1:47615/mcp`. It listens on 127.0.0.1
  only; change the port with `defaults write com.kuarasoft.keywright port -int <port>` and
  restart Keywright (settings are read at launch only).
- Permissions: Accessibility, Screen Recording and Input Monitoring. Click one to get the
  system prompt (if it isn't granted yet) and the matching System Settings pane.
  **Copy terminal check command** is there too (see Check your terminal).
- **Approved agents**: the programs you approved since unlocking (see Connection approval).
- **Copy Claude Code command…** (Touch ID), which copies:

```bash
claude mcp add --transport http keywright http://127.0.0.1:47615/mcp --header "Authorization: Bearer <token>"
```

- Token: copies or regenerates the token, each after Touch ID. The menu never shows it, and a
  copied token (or Claude Code command) is cleared from the clipboard after 60 s. The token is
  created on first run and kept in the login Keychain (service `com.kuarasoft.keywright`).
  Every request needs `Authorization: Bearer <token>`. After you regenerate it, run
  `claude mcp remove keywright` and add the server again.
- **Pause** (or the global hotkey **⌃⌥⌘⎋**): while paused, tool calls fail with `paused`.
  Pausing, quitting and any failed tool call release every held button and key.
- Recent tool calls, with time, result and duration. The log is in
  `~/Library/Logs/Keywright/keywright.log`.
- Launch at login (SMAppService) and Quit.

A dot on the menu-bar icon means a tool call is running. A pause symbol means Keywright is paused.

## Reference

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
| Keyboard | `key {key,modifiers?,holdMs?,layoutText?}` (events carry the current layout's text, like hardware), `type_text {text,intervalMs?}`, `hold {keys,modifiers,ms}`, `chord {hold, steps}` (modifiers held through several steps, e.g. ⌘ through a jump + Tab), `release_all`. Key tools take `keyTarget` and refuse while a terminal that may host the agent is active (`allowActive`, `refuseIfActive`, `defaults write com.kuarasoft.keywright refuseKeysTo -array …`, read at launch) |
| Screen | `screenshot {display?,rect?,window?,scale=0.5,format}`, `wait_screen_stable`, `wait_for_screen_change`, `record {seconds,display?,path}` (macOS 15+) |
| Windows/apps | `list_windows {app?}` (flags `systemPrompt` windows, such as TCC alerts, Gatekeeper, SecurityAgent, UserNotificationCenter and a showing notification banner, and lists them under `systemPrompts`), `launch_app`, `quit_app`, `activate_app`, `running_apps`, `open_url`, `open_file` |
| Chrome | `chrome_profiles {channel?}` (directory, name, signed-in email), `open_chrome {urls?, profile?, newWindow?, incognito?, guest?, appUrl?, channel?, userDataDir?, remoteDebuggingPort?, args?}` (works whether Chrome is running or not; `profile` takes a directory, display name or email; returns the new window ids) |
| Accessibility | `ax_tree {app,window?,maxDepth=8,includeMenuBar?}`, `ax_find`, `ax_press`, `ax_set_value`, `ax_focus` (each takes `path` or `query`), `menu_extra {app,itemPath,method: press\|click}` (status-item menu, e.g. an app's tray menu; `click` = real clicks, a user action), `menu {app,itemPath}`, `status_items {app?}`, `click_status_item {pid \| app, index, method: click\|press}` |
| Clipboard | `clipboard_get {types?}`, `clipboard_set {text \| fileUrls}`, `clipboard_change_count` |
| Waiting | `wait_for_window {app,titleContains?,timeoutMs}`, `wait_for_ax {app,query,timeoutMs}`, `sleep {ms}` |

Notes:

- Every input tool's result has `posted`: the event types, flags and count it sent. Add
  `watch: true` (or `"hid"` / `"both"`) to get `observed`, the events a tap actually saw during the
  call. The taps are read after a *fence*: one more marked zero-delta move that Keywright posts
  after the action and waits for at every tap (taps see events in posting order). So slow delivery
  is waited for instead of being reported as nothing seen; `observed.complete: false` (with
  `fence.missing`) means a tap never received Keywright's events at all. Add `swallow: true` to drop Keywright's own events at the head of the HID stream after
  recording them. That checks delivery at the HID level without any app receiving them.
  While another app's head tap consumes events (e.g. an app that has captured the mouse), a plain watch can't
  see them; `swallow` can.
- Every posted event carries `kCGEventSourceUserData = 0x4D435752` ('MCWR'), so recordings mark
  it `synthetic`. Tap probes and fences carry 'MCWP' and 'MCWF'<<16|seq and are hidden from results.
- **Human input.** An always-on listen-only HID tap counts every event Keywright did not post (the
  human's mouse, trackpad touches, keys, scrolls, or another app's events). It keeps counts, kinds
  and times only, never key codes. Every tool result has `humanInput`: `sinceLastCall` (since the
  previous call ended), `duringCall`, `kinds`, `lastAtMillis`, `msAgo`, `lastKind`, and
  `otherProcesses` when another app posted events. `status` has the totals. Input tools take
  `humanQuietMs`: the call fails without posting anything when human input arrived within that many
  ms (default 0, or `defaults write com.kuarasoft.keywright humanQuietMs -int 500`, read at launch).
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

`keywright-run` runs end-to-end tests written as YAML (or JSON) files, without an agent. It talks
to the running, unlocked app over MCP with the token, so it has no permissions of its own and
works the same on your Mac and on a CI machine with Keywright set up.

```bash
swift build -c release --product keywright-run
export KEYWRIGHT_TOKEN=<token>   # menu: Token → Copy token… (prefer this to --token, which other processes can see in ps)
.build/release/keywright-run examples/
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
| `--token <token>` | Bearer token (default `$KEYWRIGHT_TOKEN`). Any process can read command-line arguments with `ps`, so prefer the variable |
| `--server <url>` | MCP endpoint (default `$KEYWRIGHT_SERVER`, or 127.0.0.1 on the app's port) |
| `--var name=value` | Set or override a variable |
| `--junit <path>` | Write a JUnit XML report for CI |
| `--artifacts <dir>` | Save a screenshot when a test fails |
| `--fail-fast` | Stop after the first failing test |
| `--check` | Parse the files (and check tool names when a token is given), run nothing |
| `--verbose` | Print every step's result |

Exit status: 0 when every test passed, 1 when one failed, 2 for a usage or connection error.

## License

MIT. See [LICENSE](LICENSE).
