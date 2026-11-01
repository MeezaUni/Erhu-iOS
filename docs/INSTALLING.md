# Installing Erhu

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

[Back to the main README](../README.md)
