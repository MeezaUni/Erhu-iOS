# Installing Erhu

Erhu requires **iOS 17 or later** and supported, unprotected audio files. You will need a
sideloading installer such as [SideStore](https://sidestore.io/) or
[AltStore Classic](https://altstore.io/). Follow your installer's setup guide; initial setup can
require a computer, and its own iOS requirements may differ.

Choose a build from the [v1.0-beta release](https://github.com/MeezaUni/Erhu-iOS/releases/tag/v1.0-beta):

| Variant | Includes | Download |
| --- | --- | --- |
| Static artwork | Shared player features with still artwork. | [Static IPA](https://github.com/MeezaUni/Erhu-iOS/releases/download/v1.0-beta/Erhu-v1.0-beta-static.ipa) |
| Animated artwork | Shared features plus motion covers. | [Animated IPA](https://github.com/MeezaUni/Erhu-iOS/releases/download/v1.0-beta/Erhu-v1.0-beta-animated.ipa) |

1. Download your chosen `.ipa` directly from the release. Public release downloads do not require a GitHub account.
2. Open it in your sideloading installer and follow its signing and installation steps.

The IPA is unsigned; your installer signs it with your Apple ID. A paid Apple Developer membership
is not required for standard free-account sideloading. With a free Apple ID, apps need refreshing
within **7 days**, and the usual limit is **3 active sideloaded apps**, including the installer itself.

Release assets provide stable downloads. Updates are installed through the same
sideloading installer. Keep the same Apple ID and app identifier when updating to preserve the
existing app's data, and retain a backup of your original music files.

Downloaded motion covers play offline. Finding new covers requires a connection and depends on
provider availability. System animated artwork requires **iOS 26 or later**, and iOS controls
when it is displayed. See the
[animated-cover notes](https://github.com/MeezaUni/Erhu-iOS/blob/with-animated-art/docs/ANIMATED_COVERS.md)
for supported behaviour and limitations.

## Development builds from Actions

For newer development builds, choose [static-art Actions](https://github.com/MeezaUni/Erhu-iOS/actions/workflows/ios.yml?query=branch%3Awithout-animated-art)
or [animated-art Actions](https://github.com/MeezaUni/Erhu-iOS/actions/workflows/ios.yml?query=branch%3Awith-animated-art).
Sign in to GitHub, open a completed green run, and download **Erhu-ipa** under **Artifacts**.
Extract the ZIP to get `Erhu.ipa`, then install it through the same installer. Workflow artifacts
expire; release assets are the simpler download for the published beta.

## Add your music

- Use the **+** import button to pick files from the Files app.
- Copy files into **Files → On My iPhone → Erhu**, then refresh or scan the library.
- Open **Wi-Fi Transfer** in Erhu and follow the address and pairing instructions from another
  device on the same local network. Keep Erhu open while transferring.

Common supported formats include **MP3, M4A/AAC/ALAC, FLAC, WAV, and AIFF**. Format support can
also depend on the file's codec; Wi-Fi Transfer accepts MP3, FLAC, M4A, AAC, WAV, AIF, and AIFF.
Erhu plays your own imported files and does not supply a streaming music catalog.

[Back to the main README](../README.md)
