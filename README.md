# Erhu for iOS

A native iPhone music player for your own files, with offline discovery and custom transitions.

**iOS 17+ · Free to sideload · In active development**

[![Install Erhu](https://img.shields.io/badge/Install_Erhu-2ea44f?style=for-the-badge&logo=apple&logoColor=white)](#install)

## Why choose Erhu?

| Area | At a glance |
| --- | --- |
| **Why Erhu** | • Your own music library, played offline.<br>• No Erhu account or music subscription required.<br>• Free sideloaded builds. |
| **Design & UI** | • Native SwiftUI interface, artwork carousel, and mini-player.<br>• Artwork-based colours, light/dark/system appearance, and imported colour themes. |

## Screenshots

<p align="center">
  <img src="docs/screenshots/home.png" alt="Erhu home with smart playlists and featured albums" width="22%" loading="lazy">
  <img src="docs/screenshots/now-playing.png" alt="Now Playing with artwork, playback controls, and lyrics" width="22%" loading="lazy">
  <img src="docs/screenshots/lock-screen.png" alt="iPhone Lock Screen showing expanded cover artwork and playback controls" width="22%" loading="lazy">
  <img src="docs/screenshots/vybe1.png" alt="VYBE search matching Dramatic Girl and Carried Away with similar tracks from the library" width="22%" loading="lazy">
  <br>
  <sub>Home · Now Playing · Lock Screen · VYBE</sub>
</p>

<p align="center">
  <img src="docs/screenshots/lyrics.png" alt="Full-screen synced lyrics with the current line highlighted" width="22%" loading="lazy">
  <img src="docs/screenshots/album1.png" alt="Album page with artwork, track list, and Transition Studio" width="22%" loading="lazy">
  <img src="docs/screenshots/artist.png" alt="Artist page with albums and tracks" width="22%" loading="lazy">
  <img src="docs/screenshots/transitions.png" alt="Transition Studio with source waveforms and editable transition curves" width="22%" loading="lazy">
  <br>
  <sub>Lyrics · Album · Artist · Transition Studio</sub>
</p>

<details>
<summary>More screens: library, themes, visualizer, equalizer, lyrics, and track menu</summary>

<p align="center">
  <img src="docs/screenshots/library.png" alt="Library with playlists, favorites, and artists" width="22%" loading="lazy">
  <img src="docs/screenshots/themes.png" alt="Themes and Appearance with artwork colours selected" width="22%" loading="lazy">
  <img src="docs/screenshots/visualizer.png" alt="Circular audio visualizer around album artwork" width="22%" loading="lazy">
  <br>
  <sub>Library · Themes &amp; Settings · Visualizer</sub>
</p>

<p align="center">
  <img src="docs/screenshots/equalizer.png" alt="Eight-band equalizer with its response curve" width="22%" loading="lazy">
  <img src="docs/screenshots/player-lyrics.png" alt="Synced lyrics panel beneath the player controls" width="22%" loading="lazy">
  <img src="docs/screenshots/track-menu.png" alt="Track menu with music information, bookmarks, and playlist actions" width="22%" loading="lazy">
  <br>
  <sub>Equalizer · Player Lyrics · Track Menu</sub>
</p>

</details>

## Features & technical details

| Area | At a glance |
| --- | --- |
| **Animated artwork** | • Downloaded video covers in Now Playing, the mini-player, and album pages.<br>• Offline playback after download.<br>• Animated-art build only; Lock Screen animation needs iOS 26+ and is controlled by iOS. |
| **Audio formats** | • MP3, AAC, ALAC, FLAC, WAV/WAVE, AIFF/AIF/AIFC, and CAF.<br>• M4A, M4B, and MP4 containers; decoding depends on iOS codec support.<br>• Unprotected files. |
| **Audio engine** | • AVAudioEngine with two AVAudioPlayerNode decks and Core Audio decoding.<br>• Custom Audio Units for EQ and transition processing.<br>• Gapless scheduling for matching formats and timed crossfades. |
| **Playback features** | • Queue, shuffle, repeat, background playback, and headphone/Lock Screen controls.<br>• Waveform seeking, A–B loops, and bookmarks. |
| **Sound & transitions** | • 8-band parametric EQ, presets, and visualizer.<br>• Transitions by album, playlist, or song pair, with waveform previews and editable fade/EQ/filter curves. |
| **Library & discovery** | • Albums, artists, playlists, favorites, and search.<br>• Smart playlists, Smart Radio, and Sound Capsule listening stats. |
| **VYBE** | • Offline mood, style, and name searches using library metadata and saved lyrics.<br>• Multiple reference songs, artist aliases, and BPM/year filters.<br>• Bundled model; no cloud inference. |
| **Lyrics** | • Embedded lyrics, LRC, enhanced LRC, and online lookup.<br>• Synced and word-timed lyrics when available. |
| **Tools** | • Files import and local Wi-Fi Transfer.<br>• Tag editing, automatic metadata matching, artwork/artist images, and missing-BPM lookup or estimation. |
| **Privacy & data** | • Audio, library data, and VYBE processing stay on your device.<br>• Online lyrics/artwork/metadata services receive search metadata.<br>• Personal API keys stay in the device Keychain. |
| **Tech stack** | • Swift, SwiftUI, AVFoundation, Core Audio/AudioToolbox, and MediaPlayer.<br>• Core ML with a compressed MiniLM encoder (~17 MB).<br>• SQLite, local JSON settings, Network.framework, and Keychain.<br>• XcodeGen, GitHub Actions, and XCTest. |

## Install

| Build | Download |
| --- | --- |
| Static artwork | [Static-art builds](https://github.com/MeezaUni/Erhu-iOS/actions/workflows/ios.yml?query=branch%3Awithout-animated-art) |
| Animated artwork | [Animated-art builds](https://github.com/MeezaUni/Erhu-iOS/actions/workflows/ios.yml?query=branch%3Awith-animated-art) |

1. Sign in to GitHub, open a successful build, and download **Erhu-ipa** under **Artifacts**.
2. Extract `Erhu.ipa` and install it with [SideStore](https://sidestore.io/) or [AltStore Classic](https://altstore.io/).
3. Import music with **+**, the Files app, or **Wi-Fi Transfer**.

Free Apple ID: refresh within **7 days**; the usual **3 active apps** limit includes your installer.
See the [installation guide](docs/INSTALLING.md) for setup, updates, and supported imports.

## Development & docs

[Build from source](docs/BUILDING.md) · [Feature status](docs/ANDROID_PORT.md) ·
[VYBE details](docs/VYBE.md) · [Screenshot guide](docs/screenshots/README.md)

## Support

[Test builds, report bugs, or share feedback](https://github.com/MeezaUni/Erhu-iOS/issues).

<!-- OPTIONAL_DONATION_LINK: Add your real Buy Me a Coffee or Ko-fi link here when available. -->

Credits: [Android source & licence](ThirdParty/ANDROID-NOTICE.md) · [Model attribution](ThirdParty/VYBE-MODEL-NOTICE.md).
