# Drift

Native SwiftUI iPhone prototype for creating and editing an ordered mix from an existing Qobuz playlist.

The current app runs on fictional sample songs and local keyword rules. Create, edit, reorder, replace, undo and local saved mixes work. Cloud AI and live Qobuz import/export/playback remain disconnected. Included integration code is development groundwork; native provider access is unverified. No paid API fallback is enabled.

Open `Drift.xcodeproj` in Xcode, select the Drift scheme and an iPhone simulator, then run. Requires Swift 6 and a recent Xcode; minimum deployment target is iOS 17. No third-party package dependencies.

No personal playlist, account data, screenshots, credentials or prior Git history is included. Normal demo operation makes no provider requests. The optional debug callback probe uses fake local codes, not real sign-in.

MIT licensed. Not affiliated with Qobuz or OpenAI.
