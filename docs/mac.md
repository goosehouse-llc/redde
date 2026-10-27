# Redde for the Mac

`ReddeMac` (in `project.yml`) is a native SwiftUI app for macOS 26, built from the iPhone app's own
models, services and views: `Echo/Models`, `Echo/Services`, `Echo/Views`, `Echo/Intents`, `Shared`
and `Echo/Resources`, plus `Mac/`. It is laid out as the iPad lays Redde out, the conversations in a
sidebar and the chat beside them: `Mac/ReddeMacApp.swift` shows `ContentView` with
`.environment(\.horizontalSizeClass, .regular)`, in a Mac window with its menus (`MacCommands`)
and the Settings window (⌘,).

```
xcodebuild build -project Echo.xcodeproj -scheme ReddeMac -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath DerivedData-mac -allowProvisioningUpdates
open DerivedData-mac/Build/Products/Debug/Redde.app
```

## The iPhone comes first

The two apps share their code, and the iPhone's must not pay for the Mac. Everything the Mac needs
that the iPhone does differently is decided when the code is compiled, never while it runs:

- **`#if os(iOS)` / `#if os(macOS)`** around what only one of them has. The iPhone's side is its code
  as it was, moved inside the `#if`, not rewritten.
- **Twins**: where the iPhone's type is built on something the Mac lacks, the Mac has its own type
  of the same name and the same calls, behind `#else`: `AudioSessionController` (a Mac has no audio
  session), `BackgroundTurn` (nor suspends Redde), `TurnActivity` (nor Live Activities),
  `FrameMonitor`. And the views built on UIKit have AppKit versions beside them:
  `PageWebView`, `WebBlock`, `ZoomableWebView` (web pages, diagrams, maths), `SelectableTextView`,
  `WaveformBarsView`, `ScrollHandle.Finder`, `CameraPreview`, `DocumentPreview` (Quick Look),
  `PhotoViewer`, `ShareSheet`.
- **`Mac/MacShims.swift`**: the iPhone's names, for the Mac target only, so a shared view compiles
  unchanged: modifiers the Mac doesn't have (`navigationBarTitleDisplayMode`,
  `textInputAutocapitalization`, `keyboardType`), `fullScreenCover` as a sheet, the top bar's
  toolbar placements, `UIImage` as `NSImage`, `UIPasteboard` over `NSPasteboard`, `UIApplication`
  and `UIDevice` answering for a Mac, the haptics as nothing, and a `Form` that is SwiftUI's with
  the grouped style (the Mac's own puts labels in a column of their own).
- **`Echo/Models/Platform.swift`**: what both share: `PlatformImage`, `PlatformColor`, `AppState`.

Left out of the Mac target (`project.yml`): calls from agents (CallKit, PushKit), the Apple Watch
link, alarms (AlarmKit), Messages (MessageUI), CarPlay, wake phrases (built on the iPhone's scenes),
the iPhone's side panel, alternate app icons and, for now, the terminal (SwiftTerm's Mac view is
another class).

## What is the Mac's own

- **Bundle id**: `com.goosehouse.echo.mac` while it is being made, so it never shares a container,
  notification settings or links with the iPad app a Mac can already run. To ship it takes the
  iPhone's id, `com.goosehouse.echo`, for one purchase on both.
- **Sandbox** (`Mac/Redde.entitlements`): the network, a listener on its own loopback address (the
  Dashboard's browser sign-in comes back to one), the microphone and camera, files the person
  picks, calendars, contacts and photos for the phone tools, the app group, and the iPhone's iCloud
  key-value store (settings and servers sync between them). Push notifications wait for the relay.
- **Keychain**: the data protection keychain (`Keychain.onThisDevice`), the iPhone's kind, which is
  the app's own and never asks; it needs `keychain-access-groups` (the Mac app's own group while it
  has its own id). The Mac's older login keychain asks its person each time another build reads
  what one saved.
- **Text zoom** (`Mac/TextZoom.swift`, View → Zoom In, Zoom Out, Actual Size): a Mac's text styles
  don't follow Dynamic Type, which is all the iPhone's chat text size moves. So the theme carries
  the zoom on the Mac (`ResolvedTheme.textScale`) and its fonts take it, and the conversation's
  views set their fonts with `chatFont(.caption)`: on the iPhone exactly `.font(.caption)`, on the
  Mac at the zoom. A new view in the conversation uses `chatFont` for its text.
- **Menus** (`Mac/MacCommands.swift`): the conversation publishes what it can do
  (`ChatCommands`, a focused scene value); File, Edit and the Conversation menu call it. The iPad's
  keyboard shortcuts are buttons hidden in the window, which the Mac's menus replace.
- **Icon**: `Mac/Assets.xcassets/AppIconMac`, Redde Face on the Mac's icon grid (an 824-point
  rounded square in a 1024 canvas, with its shadow), made from the iPhone's `AppIconFaceMist`.
- **Strings**: the Mac's own text (its menus) is in the app's catalog: `scripts/strings.swift sync`
  reads the Mac build too (`DerivedData-mac`), and marks nothing gone without it.
