# Erhu for iOS

A local music player for iPhone, with offline discovery, custom transitions, and artwork-based themes.
Built with Swift and SwiftUI by the Erhu team.

Bring your own music files and explore them through albums, artists, playlists, and VYBE.
Playback and VYBE run on your device. No Erhu account or music subscription is required.

**Erhu is currently distributed through sideloading.** An App Store release may be considered
later as the project grows. The sideloaded app is free to use.

[Get Erhu](#install-on-your-iphone) · [Features](#features) · [VYBE](#vybe-offline-discovery) ·
[Screenshots](#screenshots) · [Build from source](#build-from-source)

## Screenshots

<!--
SCREENSHOT_SLOTS: These cells are intentionally empty; there are no missing image URLs.
Upload your images to docs/screenshots/, then replace each screenshot comment with an <img>.
Instructions, filenames, and an example are in docs/screenshots/README.md.
-->

| Home & library | Now Playing | VYBE |
| :---: | :---: | :---: |
| <!-- screenshot:home --> | <!-- screenshot:now-playing --> | <!-- screenshot:vybe --> |

| Lyrics | Themes & settings | Transition Studio |
| :---: | :---: | :---: |
| <!-- screenshot:lyrics --> | <!-- screenshot:themes --> | <!-- screenshot:transitions --> |

## Features

| Area | What you can do |
| --- | --- |
| Library | Browse songs, albums, and artists; manage playlists and favorites; search your collection and revisit recent searches. |
| Playback | Gapless playback, queue controls, shuffle, repeat, background audio, and Lock Screen/headphone controls. |
| Transitions | Set up crossfades and custom transitions by album, playlist, or song pair, with waveform previews and controls for timing, curves, EQ, and filters. |
| Sound | Use the 8-band equalizer, presets, visualizer, waveform seeking, A–B loops, and bookmarks. |
| Discovery | Explore VYBE, Smart Radio, smart playlists, and listening stats through Sound Capsule. |
| Lyrics | Read embedded lyrics, LRC and enhanced LRC files, or fetch online lyrics; display synced and word-timed lyrics when available. |
| Appearance | Choose light, dark, or system appearance; use artwork colours and imported colour themes across the player, settings, and tools. |
| Library tools | Transfer files over Wi-Fi, edit supported tags, match metadata, find artwork and artist images, and fill missing BPM values. |
| Animated artwork | Choose the separate animated-art build for downloaded motion covers in the player and supported system Now Playing artwork. |

See the [feature and port status](docs/ANDROID_PORT.md) for implementation details and remaining work.

## VYBE: offline discovery

Describe a mood, a sound, or what you want to hear. VYBE searches the music already in your library
using an on-device model, artist and title lookups, tagged genres and tempo, and saved lyrics.
The model ships with the app; there is no separate model download or cloud inference.

Try searches such as:

- `like Bound 2`
- `songs similar to Baby Keem's Dramatic Girl and Bound 2 by Kanye`
- `late-night R&B without rap`
- `chill music under 100 BPM`

Name lookup supports shortened titles, small spelling corrections, artist-qualified songs,
and search aliases such as Ye / Kanye / Kanye West. Multiple references are resolved separately
and used together for recommendations. Ambiguous names offer selectable matches.

VYBE works from your library's metadata and saved lyrics; it does not listen to the audio to
determine its mood. Better tags help, and explicit BPM/year filters require those values to be
present. New or changed tracks are indexed in the background, and an active search updates when
indexing finishes. See [how VYBE works](docs/VYBE.md) for the model, storage budget, and limitations.

## Install on your iPhone

Erhu requires **iOS 17 or later** and supported, unprotected audio files. You will need a
sideloading installer such as [SideStore](https://sidestore.io/) or
[AltStore Classic](https://altstore.io/). Follow your installer's setup guide; initial setup can
require a computer, and its own iOS requirements may differ.

Choose a build:

| Variant | Includes | Download builds |
| --- | --- | --- |
| [Static artwork](https://github.com/MeezaUni/Erhu-iOS/tree/without-animated-art) | The player and shared features with still artwork throughout. | [Static-art Actions](https://github.com/MeezaUni/Erhu-iOS/actions/workflows/ios.yml?query=branch%3Awithout-animated-art) |
| [Animated artwork](https://github.com/MeezaUni/Erhu-iOS/tree/with-animated-art) | The same shared features plus motion-cover lookup, downloads, and video playback. | [Animated-art Actions](https://github.com/MeezaUni/Erhu-iOS/actions/workflows/ios.yml?query=branch%3Awith-animated-art) |

1. Open the Actions link for your chosen variant and select a **completed run with a green check mark**.
2. Scroll to **Artifacts** and download **Erhu-ipa**. GitHub requires you to sign in to download
   workflow artifacts.
3. Extract the downloaded ZIP to get `Erhu.ipa`.
4. Open the IPA in your sideloading installer and follow its signing and installation steps.

The IPA is unsigned; your installer signs it with your Apple ID. A paid Apple Developer membership
is not required for standard free-account sideloading. With a free Apple ID, apps need refreshing
within **7 days**, and the usual limit is **3 active sideloaded apps**, including the installer itself.

Build artifacts expire, so use a recent successful run. Updates are installed through the same
sideloading installer. Keep the same Apple ID and app identifier when updating to preserve the
existing app's data, and retain a backup of your original music files.

Downloaded motion covers play offline. Finding new covers requires a connection and depends on
provider availability. System animated artwork requires **iOS 26 or later**, and iOS controls
when it is displayed. See the
[animated-cover notes](https://github.com/MeezaUni/Erhu-iOS/blob/with-animated-art/docs/ANIMATED_COVERS.md)
for supported behaviour and limitations.

## Add your music

- Use the **+** import button to pick files from the Files app.
- Copy files into **Files → On My iPhone → Erhu**, then refresh or scan the library.
- Open **Wi-Fi Transfer** in Erhu and follow the address and pairing instructions from another
  device on the same local network. Keep Erhu open while transferring.

Common supported formats include **MP3, M4A/AAC/ALAC, FLAC, WAV, and AIFF**. Format support can
also depend on the file's codec; Wi-Fi Transfer accepts MP3, FLAC, M4A, AAC, WAV, AIF, and AIFF.
Erhu plays your own imported files and does not supply a streaming music catalog.

## Privacy and online features

Your audio files and VYBE processing stay on your device. VYBE queries are not sent to a cloud
model. Basic playback and indexed discovery work offline.

Online lyrics, metadata, artwork, artist-image lookups, and motion-cover downloads contact
external providers. Those requests can include search metadata such as song titles, artist names,
album names, and durations. Availability depends on the provider and your connection.

Some optional sources need your own API key. Last.fm, Fanart.tv, and Discogs keys are entered
under **Settings → Metadata & Artwork → Online sources** and stored in the device's Keychain;
they are not bundled with the app. Wi-Fi Transfer opens a browser upload page on your local
network and receives files directly while Erhu is open and the transfer session is running.

## Project status and feedback

Erhu is under active development. Builds include automated iOS simulator tests, but device
testing and feedback are still important, especially for audio routes, transitions, and motion artwork.

Report problems through [GitHub Issues](https://github.com/MeezaUni/Erhu-iOS/issues). Include your
iOS version, build variant, steps to reproduce, and what you expected. For playback or import
problems, include the file format. Screenshots or a short recording help with layout issues.
Keep private files, account details, and API keys out of public reports.

## Support

You can support Erhu by testing builds, reporting bugs, sharing feedback, or contributing fixes.

<!-- OPTIONAL_DONATION_LINK: Replace this comment with your real support link, for example:
[Buy me a coffee](YOUR_REAL_SUPPORT_URL)
Do not publish the example URL as a working link.
-->

## Build from source

Builds run on GitHub's macOS runners, so you can get an IPA without owning a Mac. The
[iOS workflow](.github/workflows/ios.yml) generates the Xcode project, builds an unsigned IPA,
runs the simulator tests, and uploads **Erhu-ipa** and **Erhu-test-results**. Documentation-only
commits may skip CI.

For local development, use a Mac with a compatible Xcode and install XcodeGen:

```sh
git clone https://github.com/MeezaUni/Erhu-iOS.git
cd Erhu-iOS
git switch without-animated-art
brew install xcodegen
xcodegen generate
open Erhu.xcodeproj
```

Switch to `with-animated-art` before generating the project if you want motion-cover support.
For device builds, select your development team under **Signing & Capabilities**. Run the test
target from Xcode on an available iPhone simulator. The generated `.xcodeproj` is ignored;
project configuration lives in [project.yml](project.yml).

Useful technical notes:

- [Android → iOS feature status](docs/ANDROID_PORT.md)
- [Playback and transitions](docs/ALBUM_ORDER_AND_TRANSITIONS.md)
- [Lyrics](docs/LYRICS.md)
- [VYBE and model validation](docs/VYBE.md)
- [Adding README screenshots](docs/screenshots/README.md)

## Credits and notices

Erhu is developed by the Erhu team. Android source history and retained licence notices are
documented in [the Android notice](ThirdParty/ANDROID-NOTICE.md) and
[its retained licence](ThirdParty/ANDROID-LICENSE).

VYBE's bundled MiniLM encoder is derived from a model distributed under Apache 2.0. Model
provenance, conversion details, and attribution are in
[the model notice](ThirdParty/VYBE-MODEL-NOTICE.md) and its
[bundled licence](Erhu/Resources/Vybe/vybe-model-license.txt).
