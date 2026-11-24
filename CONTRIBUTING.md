# Contributing

Bug reports and focused pull requests are welcome. For a bug, include the app version, macOS version, architecture, reproduction steps and the expected result. Use Demo Mode to reproduce a scenario where possible. Remove private names and paths from screenshots or diagnostic exports before posting them.

Build and test with:

```sh
swift build -c release
zsh Scripts/test.sh
```

Before a pull request, also run:

```sh
xcrun swift-format lint --strict --recursive Sources Tests Package.swift Scripts/make-icon.swift
mkdir -p build
xcrun clang --analyze Sources/CSystem/CSystem.c -I Sources/CSystem/include -o build/CSystem.plist
zsh -n Scripts/build-app.sh Scripts/build-direct.sh Scripts/test.sh
```

The native fixture suite needs a working macOS graphical session. Report any environment limitation explicitly rather than marking unexecuted tests as passed.

Keep changes small and explain the user-visible behavior and how it was checked. Preserve optional/unavailable metrics, bounded storage, live/demo isolation and process identity checks. Exercise signals only against disposable test processes. Do not test by exhausting system memory or stopping someone else's workload.

Use [private vulnerability reporting](https://github.com/santiagoo43/MemorySentinel/security/advisories/new) for security-sensitive reports instead of a public issue.
