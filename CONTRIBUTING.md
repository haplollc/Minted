# Contributing to Minted

Thanks for helping. Small, focused pull requests are easiest to review. If you are unsure where to start, look for issues labeled `good first issue`.

## Build and test

You need Xcode 16 or later (the tests use Swift Testing) and an iOS 17 or later simulator. Minted is built on UIKit, so plain `swift build` and `swift test`, which build for macOS, fail. Build and test it for the iOS Simulator with `xcodebuild` instead:

```bash
xcodebuild build -scheme Minted -destination "generic/platform=iOS Simulator"
xcodebuild test -scheme Minted -destination "platform=iOS Simulator,name=iPhone 17 Pro"
```

Any installed iPhone simulator works in the test destination. `xcrun simctl list devices available` lists them.

Run the tests before opening a pull request, and note the result in the pull request description.

## Opening a pull request

1. Fork the repository and create a branch for your change.
2. Keep the change focused on one thing, and add or update tests where the change needs them.
3. Open the pull request against `main`, describe what changed and why, and link any related issue.

## Code style

Match the style of the file you are changing, and add doc comments for new public API, as the surrounding code does.
