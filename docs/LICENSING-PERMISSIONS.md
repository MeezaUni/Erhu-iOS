# Licensing and permissions

erhu for iOS is open-source software under the **GNU General Public License version 3** ([LICENSE](../LICENSE)).

## Copyright

| Material | Rights holder | Licence |
| --- | --- | --- |
| iOS code, interface, documentation, tests, tooling and screenshots written for this repository | Mohammed Azeemulla Khan | GPL-3.0 |
| Material ported or adapted from erhu for Android (see below) | Kshitij H Kekunnaya and/or Lochan Thakke, for the parts each wrote | GPL-3.0, the licence it was received under |
| erhu cube logo, wordmark and app icon | Committed to the Android project by Kshitij H Kekunnaya | Used with permission (below) |
| Third-party components | Their owners | Their own licences (see `ThirdParty/`) |

## Android-derived material

Kshitij H Kekunnaya and Lochan Thakke asked Mohammed Azeemulla Khan to build erhu for iOS. The Android-derived
material came from erhu for Android under GPL-3.0 and is used here under that licence. On 10 November 2026 both
also gave separate written permission for it, and for the erhu logo and wordmark, to be used in the iOS app. That
permission doesn't transfer their copyright.

| iOS material | Android source |
| --- | --- |
| `Erhu/Core/Metadata/FilenameCleaner.swift` | `FilenameCleaner.kt` |
| Moods and smart-mix lists and text in `Erhu/Features/Mixes/SmartMixEngine.swift` | `Moods.kt`, SmartMix files |
| `Erhu/Core/Metadata/MatchText.swift` | `MetadataScorer.kt` |
| `Erhu/Core/AnimatedArtwork/*` (`with-animated-art`) | `AnimatedArtworkNetworkDataSourceImpl.kt`, `AppleMusicTokenProvider.kt`, `HlsPlaylistParser.kt`, `FragmentedMp4Timeline.kt` |
| `Erhu/App/LibraryChromeState.swift`, `LibraryBottomChrome.swift` | `LibraryChromeState.kt`, `LibraryBottomChrome.kt`, `LibraryNavigationBar.kt` |
| Edition-aware artwork matching (`Erhu/Core/Metadata/AlbumArtworkMatching.swift`, `ArtworkCandidateCache.swift`, `ArtworkSearch.swift`; see `ThirdParty/ARTWORK-MATCHING.md`) | `core/network/.../artwork` |
| `ErhuTests/Resources/library_fixture.tsv`, `ErhuTests/Metadata/ArtworkSearchTests.swift` data | Android test resources |
| Other files ported on 27 October 2026 (library model, data layer, playback, DSP, mixes, VYBE, lyrics, Wi-Fi Transfer, theme import) | Corresponding Android modules |
| `docs/branding/erhu-cube.png`, `docs/branding/erhu-wordmark.png` (and derived `-on-dark`/`-on-light`), `AppIcon`, `ErhuLogo` | Android `images/branding/*`, `erhu_logo.png` |

## Licence history

| Versions | Licence |
| --- | --- |
| Up to and including v1.0-beta | GPL-3.0 |
| v1.0-beta.2 | Released on 10 November 2026 under a source-visible proprietary licence. On 11 November 2026 the copyright holder also licensed it under GPL-3.0, so it is available under GPL-3.0 too. |
| Later versions | GPL-3.0 |
