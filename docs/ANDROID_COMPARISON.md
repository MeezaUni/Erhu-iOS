# Android and iOS comparison

Source review on 4 November 2026. The repositories remain separate.

- Android: [`lochanpthakke/erhu`, `master`, `304cd79`](https://github.com/lochanpthakke/erhu/tree/304cd7935e6b72c74168711fb29597d2a033dd4e).
- iOS before this branding update: animated [`27b3c7d`](https://github.com/MeezaUni/Erhu-iOS/tree/27b3c7df48e5feb81139c022cd223e8ad2284724), static [`3200ff3`](https://github.com/MeezaUni/Erhu-iOS/tree/3200ff309bb8e8739fc4e2bbb2aeb13b2d46bdf7).
- Recent Android changes were also checked against its earlier `364a31f` baseline. Some gaps below predate that baseline; they are labelled separately.

This is a source comparison, not a claim that both apps were exercised on phones. A Kotlin fix does not automatically imply a Swift bug.

## Recent Android additions

| Change | iOS status | Evidence / implication |
| --- | --- | --- |
| First-launch introduction, tool previews and a Transition Studio guide; reopen from Settings | Missing | Android [entry gate][entry] and [pages][pages]. iOS [ErhuApp](../Erhu/App/ErhuApp.swift) opens [RootView](../Erhu/App/RootView.swift) directly; Settings has no introduction destination. |
| Persisted VYBE visibility switch | Missing | Android [visibility policy][visibility] hides the tab, radio actions and selected mixes. iOS [preferences](../Erhu/Core/Settings/AppSettings.swift) have no such flag; RootView mounts all sections. This is broader than hiding one button. |
| Manual and monthly stable-release checks, validated APK download/install | Missing notification UI; installation is platform-specific | Android [update documentation][updates]. iOS currently directs users to GitHub Releases and SideStore/AltStore. A release notification could be added; Android's APK installer cannot be reused. |
| Widget compatibility and playback fixes | No WidgetKit extension | Android's three widget styles exist; iOS [project configuration](../project.yml) contains only the app and tests. iOS Now Playing controls on the Lock Screen and in Control Center already work and serve a different purpose. |
| Artwork carousel occurrence identity, long drags, release velocity and neighbour taps | Several equivalents already present | Android [carousel][carousel]. iOS [scene](../Erhu/Features/Player/CarouselScene.swift), [motion](../Erhu/Features/Player/CarouselMotion.swift), and [gesture handling](../Erhu/Features/Player/TrackCarousel.swift) already handle queue occurrences, bounded drags, interruption/cancellation, velocity and adjacent selection. [Existing scene tests](../ErhuTests/Playback/CarouselSceneTests.swift) cover repeated entries, long drags and interrupted swipes. Android-specific gesture timing still needs device comparison if a similar symptom appears on iOS. |
| Temporary logo, wordmark and product showcase | Applied in this update | Original Android assets are now used in the iOS README, AppIcon catalog and About page. The gallery keeps genuine iPhone captures and four images per main row. [Provenance](../ThirdParty/ANDROID-NOTICE.md#shared-branding). |

The recent `364a31f..304cd79` diff contains **no changes under Android's `core/vybe`**. Its new VYBE work is visibility/onboarding, not a replacement ranking model or a fix for every song-reference query.

## Earlier gaps still present

| Area | Android behavior | iOS status |
| --- | --- | --- |
| Radio browsing | Featured stations open a [detail page][radio] before playback. | Radio generation and “Start radio” exist, but [Home](../Erhu/Features/Library/HomeView.swift) lacks the featured station shelf/detail flow. [Start radio](../Erhu/Features/Library/LibraryActions.swift) immediately starts its generated queue. |
| Explicit offline lyrics | [Lookup][lyrics] separates temporary responses from explicit Download/Remove actions. | [Lookup](../Erhu/Core/Lyrics/OnlineLyricsRepository.swift) automatically persists matches. No equivalent distinction between a response cache and a user-requested offline download. Synced lookup and embedded lyrics already work. |
| Library Builder / file renaming | Reviewed artist/album folder moves through Android's Storage Access Framework. | Deliberately deferred. iOS uses the file path as song identity; moving a file needs an identity migration to preserve playlists, favourites, history, bookmarks and transitions. See [port status](ANDROID_PORT.md#library-and-data). |
| Animated artwork compression | [Opt-in validated HEVC compression][compression] for a restricted set of supported clips. | No compression UI or transcoding pipeline. The animated variant downloads and plays saved clips; the static variant omits motion artwork entirely. Porting this requires AVFoundation-specific validation and safe replacement, rather than copying Android's encoder code. |
| Theme and glass controls | Fonts/skins and separate popup/sidebar glass controls. | Imported colours, artwork themes and the glass on/off preference exist. Android's full font/skin and glass-strength controls are not ported. |
| Audio formats | Android transfer accepts Ogg/OGA and Opus. | These imports are rejected by the current native iOS audio pipeline. The supported iOS formats are listed in the [README](../README.md#features); extra codecs would require decoder work. |

## What iOS already has

Library browsing, playlists/favourites/history, smart mixes, radio generation, queue controls, synced lyrics, an eight-band EQ, waveform seeking, A–B loops/bookmarks, Transition Studio, tag repair/writing, artwork fetching and Wi-Fi import are already implemented. They do not need wholesale replacement just because the Android UI changed.

The inference implementations differ: iOS bundles a roughly 17 MB MiniLM Core ML model; Android documents a separately imported roughly 184 MB EmbeddingGemma bundle. iOS already has artist aliases and multiple song references in [VYBE](VYBE.md). Neither implementation listens to the music to infer its mood; results depend on local metadata and available lyrics. Android's model-install instructions should not be copied into the iOS README.

## Suggested implementation order

1. Introduction and tool guides, with a persisted VYBE visibility preference.
2. Browseable radio stations and explicit lyrics downloads.
3. Optional release notifications for sideload users.
4. Library identity migration before file moves; separately evaluate WidgetKit and artwork compression.

Only documentation and branding are changed by this comparison task. These feature ports remain future work.

[entry]: https://github.com/lochanpthakke/erhu/blob/304cd7935e6b72c74168711fb29597d2a033dd4e/app/src/main/java/com/erhu/erhu/onboarding/AppEntry.kt
[pages]: https://github.com/lochanpthakke/erhu/blob/304cd7935e6b72c74168711fb29597d2a033dd4e/app/src/main/java/com/erhu/erhu/onboarding/IntroductionPages.kt
[visibility]: https://github.com/lochanpthakke/erhu/blob/304cd7935e6b72c74168711fb29597d2a033dd4e/feature/library/src/main/java/com/erhu/erhu/feature/library/VybeVisibility.kt
[updates]: https://github.com/lochanpthakke/erhu/blob/304cd7935e6b72c74168711fb29597d2a033dd4e/docs/app-update-checker.md
[carousel]: https://github.com/lochanpthakke/erhu/blob/304cd7935e6b72c74168711fb29597d2a033dd4e/feature/library/src/main/java/com/erhu/erhu/feature/library/TrackCarousel.kt
[radio]: https://github.com/lochanpthakke/erhu/blob/304cd7935e6b72c74168711fb29597d2a033dd4e/feature/library/src/main/java/com/erhu/erhu/feature/library/RadioStationDetailScreen.kt
[lyrics]: https://github.com/lochanpthakke/erhu/blob/304cd7935e6b72c74168711fb29597d2a033dd4e/core/network/src/main/java/com/erhu/erhu/core/network/lyrics/OnlineLyricsRepository.kt
[compression]: https://github.com/lochanpthakke/erhu/blob/304cd7935e6b72c74168711fb29597d2a033dd4e/docs/opt-in-artwork-compression.md
