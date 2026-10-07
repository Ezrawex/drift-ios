# Drift

Native SwiftUI iPhone prototype for creating and editing an ordered mix from an existing Qobuz playlist.

Create, edit, reorder, replace, undo and local saved mixes work with fictional sample music and local rules. Real music selection and Qobuz import/export/playback remain disconnected.

Connections includes an official ChatGPT-plan sign-in preview: app-local loopback callback, PKCE, signed identity validation, Keychain storage, renewal and an explicit small cloud test. Actual provider sign-in/inference and physical iPhone compatibility remain unverified. Demo generation never silently uses the cloud. No separately billed API fallback is enabled.

Open `Drift.xcodeproj` in recent Xcode, select Drift and an iPhone simulator, then run with normal local signing enabled for Keychain. Keep Derived Data outside cloud-synced Documents folders. Swift 6, iOS 17 minimum; the connection preview requires iOS 17.4 or later. No third-party package dependencies.

No personal playlist, account data, screenshots, credentials or prior private Git history is included. Demo operation makes no provider requests. Choosing ChatGPT sign-in contacts OpenAI; the optional test sends a short greeting without playlist data and uses the authorized plan allowance. Credentials stay in this device's Keychain. Sign out locally in Drift; manage app access in ChatGPT Settings.

MIT licensed. Not affiliated with Qobuz or OpenAI.
