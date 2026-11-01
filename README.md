# Erhu for iOS <a href="#install"><img src="https://img.shields.io/badge/Install_Erhu-2ea44f?style=for-the-badge&logo=apple&logoColor=white" alt="Install Erhu" width="110"></a>

**Why Erhu?** A native iPhone music player for your own files, with offline discovery, custom transitions, and artwork-based themes. No Erhu account or music subscription required. Free to sideload on iOS 17+.

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
        <li>MP3, AAC, ALAC, FLAC, WAV/WAVE, AIFF/AIF/AIFC, and CAF.</li>
        <li>M4A, M4B, and MP4 containers; unprotected files with iOS-supported codecs.</li>
        <li>Dual-deck AVAudioEngine with Core Audio decoding.</li>
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
        <li><strong>Library &amp; discovery:</strong> albums, artists, playlists, favorites, search, smart mixes, radio, and listening stats.</li>
        <li><strong>VYBE:</strong> offline mood/name searches, multiple references, artist aliases, and BPM/year filters.</li>
        <li><strong>Synced lyrics:</strong> embedded lyrics, LRC/enhanced LRC, online lookup, and word timing when available.</li>
        <li><strong>Tools:</strong> Files/Wi-Fi import, tag editing, metadata matching, artwork/artist images, and BPM lookup or estimation.</li>
      </ul>
    </td>
    <td width="50%" valign="top">
      <ul>
        <li>Audio files and library data stay on your device.</li>
        <li>On-device VYBE; no cloud inference.</li>
        <li>Online lyrics/artwork/metadata providers receive search metadata.</li>
        <li>Personal API keys are stored in the device Keychain.</li>
      </ul>
    </td>
  </tr>
</table>

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

## Install

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
        <li>SQLite, local JSON settings, and Keychain.</li>
        <li>XcodeGen, GitHub Actions, and XCTest.</li>
      </ul>
    </td>
  </tr>
</table>

## Development & docs

[Build from source](docs/BUILDING.md) · [Feature status](docs/ANDROID_PORT.md) ·
[VYBE details](docs/VYBE.md) · [Screenshot guide](docs/screenshots/README.md)

[Contributing](CONTRIBUTING.md) · [Security policy](SECURITY.md) · [Code of conduct](CODE_OF_CONDUCT.md)

## Support

[Test builds, report bugs, or share feedback](https://github.com/MeezaUni/Erhu-iOS/issues).

<!-- OPTIONAL_DONATION_LINK: Add your real Buy Me a Coffee or Ko-fi link here when available. -->
