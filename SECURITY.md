# Security

MacWright can move the mouse, type, read the screen and press buttons in any app, using
permissions you grant it. Its safeguards:

- The MCP server listens on `127.0.0.1` only.
- Every request needs the bearer token, which is generated on first run and kept in the login
  Keychain.
- The app starts locked. The server doesn't listen until a human unlocks it with Touch ID or the
  Mac login password, so a process that can launch the app gains nothing.
- **Lock** stops the server and every tool call, including one already running; a result that
  finishes after the lock is thrown away, and a recording cut short is deleted.
- **Pause** (or ⌃⌥⌘⎋) makes every tool call fail, and pausing releases every held key and button.
- Key tools refuse to type into terminals that may host the agent, unless told otherwise.
- Human input is counted (never key codes) so a test can refuse to act while someone is using
  the Mac (`humanQuietMs`).

The lock only helps if no other app used by agents holds Accessibility, Screen Recording or
Input Monitoring: an agent runs with its terminal's permissions and can use them directly. Run
the terminal check (menu: **Copy terminal check command**) in each terminal you use with agents.

Anyone holding the token while the app is unlocked can control the Mac as you. Treat the token
like a password, and lock or quit MacWright when you're not testing.

## Reporting a vulnerability

Please don't open a public issue. Use GitHub's private vulnerability reporting
(**Security → Report a vulnerability** on the repository), with steps to reproduce and the macOS
version.
