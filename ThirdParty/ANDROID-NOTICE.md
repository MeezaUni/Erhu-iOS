The Apple motion artwork adapters in `Erhu/Core/AnimatedArtwork` are adapted from
MeezaUni/empee3, commit f291c7dc41d5725efcdf646677c048f282f78a4b:

- core/network/.../apple/AnimatedArtworkNetworkDataSourceImpl.kt
- core/network/.../apple/AppleMusicTokenProvider.kt
- core/network/.../apple/HlsPlaylistParser.kt
- core/network/.../apple/FragmentedMp4Timeline.kt

The scrolling bottom-controls behavior in `Erhu/App/LibraryChromeState.swift` and
`LibraryBottomChrome.swift` also follows this source's library chrome and capsule navigation:

- feature/library/.../LibraryChromeState.kt
- feature/library/.../LibraryBottomChrome.kt
- feature/library/.../LibraryNavigationBar.kt

Original source: https://github.com/MeezaUni/empee3
The source repository supplies the GNU General Public License version 3, retained in
`ANDROID-LICENSE`. The Swift adaptation was added on the `personal` branch in October 2026.

Upstream Android project: https://github.com/lochanpthakke/empee3

## Shared branding

The erhu logo and wordmark are copied unchanged from the Android project's
commit `304cd7935e6b72c74168711fb29597d2a033dd4e`:

- `images/branding/erhu-cube.png` → README branding and iOS AppIcon.
- `images/branding/erhu-wordmark.png` → README wordmark.
- `app/src/main/res/drawable-nodpi/erhu_logo.png` → in-app About logo.

Source: https://github.com/lochanpthakke/erhu/tree/304cd7935e6b72c74168711fb29597d2a033dd4e
The source repository distributes these assets with its GPL-3.0 project; its
licence is retained in `ANDROID-LICENSE`. The Android project describes this as
its temporary app icon. No artwork or logo redesign is included here.
