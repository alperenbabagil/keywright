# Security

Keywright can move the mouse, type, read the screen and press buttons in any app, using
permissions you grant it. Its safeguards:

- The MCP server listens on `127.0.0.1` only.
- Every request needs the bearer token, which is generated on first run and kept in the login
  Keychain. The menu never shows it; copying or regenerating it needs Touch ID, and a copied token
  is cleared from the clipboard after 60 s.
- Every new MCP session needs the owner's approval (Touch ID or password), which names the
  connecting program, its pid and the app it runs in. A session then answers only that process,
  and Lock forgets every approval. A stolen token is useless on its own.
- The app is signed with the hardened runtime, so no other process can inject code into it
  (`DYLD_INSERT_LIBRARIES`) or attach a debugger and use its permissions.
- Settings that affect safety (auto-lock limits, `refuseKeysTo`, `humanQuietMs`, the port) are
  read at launch only, so `defaults write` while Keywright runs changes nothing.
- The app starts locked. The server doesn't listen until a human unlocks it with Touch ID or the
  Mac login password, so a process that can launch the app gains nothing.
- **Lock** stops the server and every tool call, including one already running; a result that
  finishes after the lock is thrown away, and a recording cut short is deleted.
- Input tools (clicks, keys, scrolls, AX actions) refuse while a security dialog is on screen:
  permission prompts, password and Touch ID sheets, Gatekeeper, the screen-sharing picker. An
  agent can't approve a permission for itself that would outlive the lock.
- The HTTP server checks the path and token as soon as a request's headers arrive, before reading
  the body, and rejects malformed or oversized bodies.
- **Auto-lock** locks after a stretch with no tool calls and at most a fixed time after
  unlocking (defaults 15 min and 4 h). Loosening either limit needs Touch ID; the unlock prompt
  names the limits in force.
- Clients must send a request's headers within 10 s and the whole request within 30 s.
- **Pause** (or ⌃⌥⌘⎋) makes every tool call fail, and pausing releases every held key and button.
- Key tools refuse to type into terminals that may host the agent, unless told otherwise.
- Human input is counted (never key codes) so a test can refuse to act while someone is using
  the Mac (`humanQuietMs`).

The lock only helps if no other app used by agents holds Accessibility, Screen Recording or
Input Monitoring: an agent runs with its terminal's permissions and can use them directly. Run
the terminal check (menu: **Copy terminal check command**) in each terminal you use with agents.

Anyone holding the token while the app is unlocked can control the Mac as you. Treat the token
like a password (with `keywright-run`, pass it in `KEYWRIGHT_TOKEN`, not `--token`, which `ps`
shows), and lock or quit Keywright when you're not testing.

Anything can launch the app, and launching it shows the unlock prompt. A Touch ID prompt you didn't
expect may be an agent relaunching Keywright; only approve it when you meant to start a session.

## If you build it yourself

Your signing key decides who can change Keywright without losing its permissions. macOS ties
Accessibility and Screen Recording to the app's signature, so anyone who can re-sign a modified
Keywright with your key keeps them. If your Developer ID key's keychain entry lets `codesign` use
it without asking ("Always Allow"), any process running as you can do that. Remove that
permission in Keychain Access (the key → Get Info → Access Control) so every signing asks.

Keep the installed app owned by root, so changing it needs an administrator password:

```bash
sudo chown -R root:wheel /Applications/Keywright.app
```

`build.sh` then needs `sudo` to install; or build somewhere else and copy it with `sudo`.

## Reporting a vulnerability

Please don't open a public issue. Use GitHub's private vulnerability reporting
(**Security → Report a vulnerability** on the repository), with steps to reproduce and the macOS
version.
