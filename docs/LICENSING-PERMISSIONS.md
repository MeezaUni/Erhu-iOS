# Licensing and permissions

## Copyright

| Material | Rights holder | Basis for use in the proprietary iOS app |
| --- | --- | --- |
| iOS code, interface, documentation, tests, tooling and screenshots written for this repository | Mohammed Azeemulla Khan | Own work |
| Material ported or adapted from erhu for Android (see below) | Kshitij H Kekunnaya and/or Lochan Thakke, for the parts each wrote | Written permission from each (below). They keep their copyright. |
| erhu cube logo, wordmark and app icon | Committed to the Android project by Kshitij H Kekunnaya; covered by both permissions below | Written permission (below) |
| Third-party components | Their owners | Their own licences (see `ThirdParty/`) |

## Permission from the Android authors

Kshitij H Kekunnaya and Lochan Thakke asked Mohammed Azeemulla Khan to build erhu for iOS. They have each permitted, in writing, the
Android-derived material in this repository to be used, modified and distributed as part of the proprietary iOS
application.

| Rights holder | Confirmation | Date | Record kept |
| --- | --- | --- | --- |
| Kshitij H Kekunnaya | Received in writing | 10 November 2026 | Original message kept by Mohammed Azeemulla Khan |
| Lochan Thakke | Received in writing | 10 November 2026 | Original message kept by Mohammed Azeemulla Khan |

**Scope**
- **Covered:** the repository as of `b73084a` (`without-animated-art`) and `e35ac56` (`with-animated-art`),
  8 November 2026, and later changes to the same material in the iOS app.
- **Not transferred:** their Android copyright.
- **Future work:** iOS work written independently by Azeem doesn't need their approval.
- **Unchanged:** Android ownership and commercial arrangements (between Kshitij and Lochan) stay separate. Third-party licences still apply,
  and earlier GPL recipients keep their rights.

### Android-derived material identified so far

| iOS material | Android source (commit `f291c7d`) |
| --- | --- |
| `Erhu/Core/Metadata/FilenameCleaner.swift` | `FilenameCleaner.kt` |
| Moods and smart-mix lists and text in `Erhu/Features/Mixes/SmartMixEngine.swift` | `Moods.kt`, SmartMix files |
| `Erhu/Core/Metadata/MatchText.swift` | `MetadataScorer.kt` |
| `Erhu/Core/AnimatedArtwork/*` (`with-animated-art`) | `AnimatedArtworkNetworkDataSourceImpl.kt`, `AppleMusicTokenProvider.kt`, `HlsPlaylistParser.kt`, `FragmentedMp4Timeline.kt` |
| `Erhu/App/LibraryChromeState.swift`, `LibraryBottomChrome.swift` | `LibraryChromeState.kt`, `LibraryBottomChrome.kt`, `LibraryNavigationBar.kt` |
| Edition-aware artwork matching, verified cache and preview design (`Erhu/Core/Metadata/AlbumArtworkMatching.swift`, `ArtworkCandidateCache.swift`, `ArtworkSearch.swift`; see `ThirdParty/ARTWORK-MATCHING.md`) | `core/network/.../artwork` at `kshitij` branch `8d443f9` |
| `ErhuTests/Resources/library_fixture.tsv`, `ErhuTests/Metadata/ArtworkSearchTests.swift` data | Android test resources |
| Other files ported on 27 October 2026 (library model, data layer, playback, DSP, mixes, VYBE, lyrics, Wi-Fi Transfer, theme import) | Corresponding Android modules. Covered by the same permission, so no per-file list is needed. |
| `docs/branding/erhu-cube.png`, `docs/branding/erhu-wordmark.png` (and derived `-on-dark`/`-on-light`), `AppIcon`, `ErhuLogo` | Android `images/branding/*`, `erhu_logo.png` (commit `304cd79`) |

## Licence history

| Versions | Licence |
| --- | --- |
| Up to and including `b73084a` (`without-animated-art`), `e35ac56` (`with-animated-art`) and release `v1.0-beta` | GNU GPL v3.0 (`LICENSES/GPL-3.0-historical.txt`). These copies remain under the GPL for everyone who received them. |
| `v1.0-beta.2` and later | erhu for iOS Source-Visible Proprietary Licence (`LICENSE`) |
