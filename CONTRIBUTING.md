# Contributing

Issues and pull requests are welcome.

## Setup

- macOS 14 or later, Swift 6.1 or later (Xcode 16.3+).
- `swift build` and `swift test` need no permissions. The unit tests cover the pure logic in
  `KeywrightCore` (key names, flags, geometry, input tracking, HTTP auth, Chrome profiles).
- To run the app, see **Build** in the README. Set `KEYWRIGHT_SIGN_IDENTITY` (or a git-ignored
  `.signing` file) to a stable signing identity, or you'll have to grant permissions again after
  every rebuild.

## Changes

- Keep `KeywrightCore` free of anything that needs a permission, so it stays testable in CI.
- New tools go in `Sources/Keywright/Tools.swift`, with a description an agent can act on, and a
  line in the README's tool table.
- Anything that posts input must go through the pause check and release held keys and buttons
  on failure, like the existing tools.
- Run `swift test` before opening a pull request.
