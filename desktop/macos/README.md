# AssetFurnace for macOS

This native AppKit app opens Studio in WKWebView on Apple Silicon, macOS 12 or newer. It reuses an existing AssetFurnace installation and library, without bundling or downloading model weights.

## Build

Xcode command line tools and an internet connection for the pinned Sparkle dependency are required. Run `./build.sh` to create an optimized, ad-hoc signed `build/AssetFurnace.app`, or pass another output path. `swift test` runs the focused native tests.

For distribution, set `AF_DISTRIBUTION=1` and `AF_SERVER_COMMIT` to the full, tested commit in the configured fork before running `build.sh`. `AF_BUILD_NUMBER` optionally overrides the monotonically increasing bundle build number. Production bundles must pin their server commit. The application version and trusted public update key are in Info.plist.

## Updates and runtime versions

The Updates window shows installed app and engine versions. Official stable releases are checked once per 24 hours while the app runs; an explicit check bypasses the interval. The last result survives restarts and offline failures do not trigger repeated automatic requests. The daily checkbox controls automatic checks; `I3D_NO_UPDATE_CHECK=1` disables the official release checker.

Compatible app updates are distributed through Sparkle 2.10.1 from this fork. Both the feed and update archives require Ed25519 signatures. Updates are downloaded and installed after user approval. The first updater-enabled app must be installed manually. Ad-hoc signing is for local use; Developer ID signing and Apple notarization are separate distribution steps.

The signed app bundle pins the compatible server source commit. Each server version gets its own source directory and Python environment under `~/Library/Application Support/AssetFurnace/runtimes/`. Existing `vendor` engines and the `output` library are linked from the original installation; they are never deleted by runtime preparation. Model folder preferences remain in the existing library. Python dependencies are installed from the pinned lockfile; model weights are not installed.

Preparation checks the new server against an isolated temporary library before attaching the real library. The selection changes only after the app successfully starts the new server. Failed preparation keeps the previous runtime selected. Incomplete inactive installations are archived for diagnosis and retry; selected and previous runtimes are retained.

Before installing an app update, the wrapper checks brush edits and acquires a server maintenance lease. The server refuses that lease while generation, finishing, skins, rigging, animation, setup, downloads or chains are active. While leased, new mutations are refused. Only the owning desktop app with its private credential can request server shutdown. An externally launched server is left running; close it yourself after saving work and reopen the desktop app before installing an update. Ordinary app exit leaves the server running for background jobs.

## Publishing

Signing uses the `AssetFurnaceDesktop` Keychain account. Use Sparkle's `generate_keys --account AssetFurnaceDesktop` once; keep the private key in Keychain, never in the repository. Package the built app using `ditto -c -k --sequesterRsrc --keepParent`, then generate the signed feed with `generate_appcast --account AssetFurnaceDesktop --download-url-prefix <release-assets-url> <archives-directory>`. Publish the archive and appcast.xml together in the fork's latest compatible desktop release. Verify signatures before publishing; never modify an archive or signed feed afterwards.

The Stitch design reference for the native Updates window is https://stitch.withgoogle.com/projects/17005716598729908133 (screen 5b3ef8b0673b452d9958e423ad9d6110). Its example versions are not runtime data.

## Validation

Native tests cover version comparison, daily/manual checks, coalescing requests, offline caching, runtime selection/rollback, interrupted preparation, isolated health checks and ownership-based maintenance. Server tests cover maintenance gates and request protections. These tests do not replace end-to-end checks of actual installation, relaunch, downloads, file panels, clipboard interactions or the 3D viewport; exercise those on the packaged application before publishing.
