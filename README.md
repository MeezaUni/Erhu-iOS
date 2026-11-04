<h1><img src="docs/branding/erhu-cube.png" alt="erhu app icon" width="64"> <img src="docs/branding/erhu-wordmark.png" alt="erhu" width="160"> <sub>for iOS</sub></h1>

**Why Erhu?** A native iPhone music player for your own files, with offline discovery, custom transitions, and artwork-based themes. No Erhu account or music subscription required. Free to sideload on iOS 17+.

<a href="#install"><img src="https://img.shields.io/badge/Install_Beta_1-2ea44f?style=for-the-badge&logo=apple&logoColor=white" alt="Install Beta 1" width="150"></a>

[Android edition](https://github.com/lochanpthakke/erhu) · [Report a bug](https://github.com/MeezaUni/Erhu-iOS/issues)

## Features

<table>
  <tr>
    <th width="50%" align="left">Design &amp; UI</th>
    <th width="50%" align="left">Audio formats &amp; engine</th>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <ul>
        <li>Native SwiftUI, artwork carousel, and mini-player.</li>
        <li>Artwork colours, light/dark/system appearance, and imported themes.</li>
        <li>Downloaded video covers; offline after saving (animated-art build).</li>
        <li>Lock Screen animation: iOS 26+, controlled by iOS.</li>
      </ul>
    </td>
    <td width="50%" valign="top">
      <ul>
        <li>MP3, AAC, ALAC, FLAC, WAV/WAVE, AIFF/AIF/AIFC, and CAF; Ogg Vorbis/Opus in mono or stereo.</li>
        <li>M4A, M4B, and MP4 containers; unprotected files with iOS-supported codecs.</li>
        <li>Dual-deck AVAudioEngine with Core Audio and local Xiph decoding for Ogg.</li>
        <li>Custom EQ/transition Audio Units, gapless scheduling for matching formats, and timed crossfades.</li>
      </ul>
    </td>
  </tr>
</table>

<table>
  <tr>
    <th width="50%" align="left">Features &amp; tools</th>
    <th width="50%" align="left">Privacy &amp; data</th>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <ul>
        <li><strong>Playback:</strong> queue, shuffle, repeat, background/headphone/Lock Screen controls, waveform seeking, A–B loops, and bookmarks.</li>
        <li><strong>Sound &amp; transitions:</strong> 8-band EQ, presets, visualizer, and album/playlist/song-pair transitions with editable curves.</li>
        <li><strong>Library &amp; discovery:</strong> albums, artists, playlists, favorites, search, smart mixes, browseable radio stations, and listening stats.</li>
        <li><strong>VYBE:</strong> offline mood/name searches, multiple references, artist aliases, and BPM/year filters.</li>
        <li><strong>Synced lyrics:</strong> embedded lyrics, LRC/enhanced LRC, online lookup, and explicit offline downloads.</li>
        <li><strong>Tools:</strong> Files/Wi-Fi import, tag editing, metadata matching, artwork/artist images, and BPM lookup or estimation.</li>
      </ul>
    </td>
    <td width="50%" valign="top">
      <ul>
        <li>Audio files and library data stay on your device.</li>
        <li>On-device VYBE; no cloud inference.</li>
        <li>Online lyrics/artwork/metadata providers receive search metadata.</li>
        <li>Keyless metadata/artwork search; no paid provider integrations or API-key setup.</li>
      </ul>
    </td>
  </tr>
</table>

## Screenshots

Real iPhone captures. Select a screenshot to open it at full size.

### Home and the listening experience

<p align="center">
  <a href="docs/screenshots/home.png"><img src="docs/screenshots/home.png" alt="Erhu home with smart playlists and featured albums" width="22%" loading="lazy"></a>
  <a href="docs/screenshots/now-playing.png"><img src="docs/screenshots/now-playing.png" alt="Now Playing with artwork, playback controls, and lyrics" width="22%" loading="lazy"></a>
  <a href="docs/screenshots/lock-screen.png"><img src="docs/screenshots/lock-screen.png" alt="iPhone Lock Screen showing expanded cover artwork and playback controls" width="22%" loading="lazy"></a>
  <a href="docs/screenshots/vybe1.png"><img src="docs/screenshots/vybe1.png" alt="VYBE search matching Dramatic Girl and Carried Away with similar tracks from the library" width="22%" loading="lazy"></a>
  <br>
  <sub>Home · Now Playing · Lock Screen · VYBE</sub>
</p>

### Your library, lyrics and transitions

<p align="center">
  <a href="docs/screenshots/lyrics.png"><img src="docs/screenshots/lyrics.png" alt="Full-screen synced lyrics with the current line highlighted" width="22%" loading="lazy"></a>
  <a href="docs/screenshots/album1.png"><img src="docs/screenshots/album1.png" alt="Album page with artwork, track list, and Transition Studio" width="22%" loading="lazy"></a>
  <a href="docs/screenshots/artist.png"><img src="docs/screenshots/artist.png" alt="Artist page with albums and tracks" width="22%" loading="lazy"></a>
  <a href="docs/screenshots/transitions.png"><img src="docs/screenshots/transitions.png" alt="Transition Studio with source waveforms and editable transition curves" width="22%" loading="lazy"></a>
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

## Install

**Latest development builds:** [Static](https://github.com/MeezaUni/Erhu-iOS/actions?query=workflow%3AiOS+branch%3Awithout-animated-art) · [Animated](https://github.com/MeezaUni/Erhu-iOS/actions?query=workflow%3AiOS+branch%3Awith-animated-art). Open a successful run and download **Erhu-ipa** for the newest features.

**Beta 1**, the earlier tagged release, remains available below. Both variants are unsigned IPAs for iOS 17+, installed with your own Apple ID through a sideloading tool.

| Build | Download |
| --- | --- |
| Static artwork | [Download IPA](https://github.com/MeezaUni/Erhu-iOS/releases/download/v1.0-beta/Erhu-v1.0-beta-static.ipa) |
| Animated artwork | [Download IPA](https://github.com/MeezaUni/Erhu-iOS/releases/download/v1.0-beta/Erhu-v1.0-beta-animated.ipa) |

1. Download the IPA for your chosen variant above, or open the [v1.0-beta release](https://github.com/MeezaUni/Erhu-iOS/releases/tag/v1.0-beta).
2. Install it with [SideStore](https://sidestore.io/) or [AltStore Classic](https://altstore.io/).
3. Import music with **+**, the Files app, or **Wi-Fi Transfer**.

Free Apple ID: refresh within **7 days**; the usual **3 active apps** limit includes your installer.
See the [installation guide](docs/INSTALLING.md) for setup, updates, and supported imports.

## Tech stack

<table>
  <tr>
    <th width="50%" align="left">App &amp; audio</th>
    <th width="50%" align="left">AI, data &amp; build</th>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <ul>
        <li>Swift and SwiftUI.</li>
        <li>AVFoundation, Core Audio/AudioToolbox, and MediaPlayer.</li>
        <li>Network.framework for local Wi-Fi Transfer.</li>
      </ul>
    </td>
    <td width="50%" valign="top">
      <ul>
        <li>Core ML with compressed MiniLM (~17 MB).</li>
        <li>SQLite, local JSON settings, and retained Commons image credits.</li>
        <li>XcodeGen, GitHub Actions, and XCTest.</li>
      </ul>
    </td>
  </tr>
</table>

## Development & docs

[Build from source](docs/BUILDING.md) · [Feature status](docs/ANDROID_PORT.md) ·
[Android comparison](docs/ANDROID_COMPARISON.md) · [Latest feature notes](docs/FEATURE_UPDATES.md) · [VYBE details](docs/VYBE.md) · [Screenshot guide](docs/screenshots/README.md)

Swift/SwiftUI, Core Audio and Core ML. On a Mac with Xcode and XcodeGen:

```sh
xcodegen generate
open Erhu.xcodeproj
```

GitHub Actions also builds an IPA and runs the simulator tests for both artwork branches.

[Contributing](CONTRIBUTING.md) · [Security policy](SECURITY.md) · [Code of conduct](CODE_OF_CONDUCT.md)

## Feedback

[Test builds, report bugs, or share feedback](https://github.com/MeezaUni/Erhu-iOS/issues). Include your iPhone model, iOS version, app build and artwork variant.

<!-- OPTIONAL_DONATION_LINK: Add your real Buy Me a Coffee or Ko-fi link here when available. -->

## License

[GNU GPL v3](LICENSE). Shared Android code and branding are documented in the [third-party notice](ThirdParty/ANDROID-NOTICE.md).
