# Building Erhu

Builds run on GitHub's macOS runners, so you can get an IPA without owning a Mac. The
[iOS workflow](../.github/workflows/ios.yml) generates the Xcode project, builds an unsigned IPA,
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
project configuration lives in [project.yml](../project.yml).

Useful technical notes:

- [Android → iOS feature status](ANDROID_PORT.md)
- [Playback and transitions](ALBUM_ORDER_AND_TRANSITIONS.md)
- [Lyrics](LYRICS.md)
- [VYBE and model validation](VYBE.md)
- [Adding README screenshots](screenshots/README.md)

[Back to the main README](../README.md)
