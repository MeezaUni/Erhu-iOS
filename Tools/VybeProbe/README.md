# Standalone iOS model compatibility test

This probe is separate from Erhu. It does not change the app's MiniLM model or
add MediaPipe to the app target. Run the **VYBE iOS compatibility probe** Actions
workflow on `without-animated-art`, or generate this project with XcodeGen,
install its pinned CocoaPod, and test the `Probe` workspace scheme on an iPhone
simulator. The workflow downloads the model and verifies its SHA-256 before
building.

The [successful run](https://github.com/MeezaUni/Erhu-iOS/actions/runs/41885296022)
used MediaPipe Tasks Text 1.0.0, produced 768-dimensional vectors and matched
6/6 synthetic queries. Model load was about 1.68 seconds; twelve embeddings plus
setup took about 72.2 seconds on the Intel simulator. This is a compatibility
check, not a real-library benchmark or an iPhone performance measurement.

The earlier duplicate-calculator crash came from linking the static SDK into
both host and tests. The Podfile now links it only in the test bundle.

## Runtime privacy and model terms

The official SDK archive's `NOTICE` (June 5, 2026) says:

> MediaPipe Tasks APIs send metrics about the performance and utilization of the
> APIs in your app to Google.

It also says input text is processed on device and not sent to Google. No
telemetry-disable setting is exposed by this SDK's public iOS headers. The
synthetic test does not use a listener's music, lyrics, queries or library.

[Official SDK archive, including NOTICE and LICENSE](https://dl.google.com/cpdc/20260727-225048/MediaPipeTasksText-1.0.0.tar.gz).
The SDK and its dependencies have their own notices; do not infer that every
part of a downloaded binary has the same licence. EmbeddingGemma weights are
subject to the [Gemma terms](https://ai.google.dev/gemma/terms), separate from
MediaPipe's code licence. A distributable integration needs appropriate notices
and a clear user choice about metrics before using the runtime.
