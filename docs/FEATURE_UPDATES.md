# Approved iOS feature work — November 2026

Common changes are applied to both artwork branches. `without-animated-art`
remains the main public version. The Apple motion-cover lookup, playback and
compression tools exist only in `with-animated-art`.

| Feature | Behavior |
| --- | --- |
| Updates | Settings → About Erhu → Check for updates. A cached foreground check runs at most daily after a successful check. Beta releases are included, API failures are shown, and the download matches the artwork variant. Installation is manual. |
| Wi-Fi Transfer | Start remains explicit. A running foreground session stays on until Stop, backgrounding, sustained network loss or a listener failure. No idle/three-hour cutoff interrupts a foreground session. Brief address lookup failures are tolerated. |
| Introduction | A short, skippable first-launch guide; reopen it from About Erhu. Existing preferences and music are retained. |
| VYBE visibility | The saved toggle controls VYBE navigation, radio actions/stations and selected personal mixes. |
| Radio | Browse a station's songs before playback. Only Play or a song tap starts its queue. Stations use music already in the library. |
| Lyrics | Download/Remove actions distinguish durable offline lyrics from temporary responses. Older saved lyrics are preserved. Embedded lyrics and the existing provider chain remain available. |
| Typeface | System, rounded, serif and monospaced native designs; Dynamic Type is retained. The appearance page points to iPhone Settings for system accessibility/transparency options. No glass-strength slider or bundled commercial fonts. |
| Ogg Vorbis / Opus | Read tags and play mono/stereo originals through Xiph decoding and the existing engine. A disposable PCM cache enables seeking, waveforms, EQ and transitions. Cold preparation is cancellable and off the UI thread; sufficient disk space is required. [Codec details and licences](../ThirdParty/XIPH-CODECS.md). |
| Animated compression | Personal animated branch only: opt-in square SDR H.264 → HEVC conversion, full-frame decoding, structural/timing/colour checks and a visual preview. The original remains until the listener chooses the compressed cover. Unsupported/no-saving results retain it. Portrait artwork is kept. |

## Keyless provider setup

- Keep iTunes Search, MusicBrainz, Cover Art Archive and Deezer for metadata/artwork.
- Keep LRCLIB and the existing plain-text lyrics fallback. No new paid lyrics provider.
- Remove Last.fm, Fanart.tv, Discogs and their API-key settings/implementation.
- Commons is a keyless image fallback. Results require recognizable free-licence
  metadata; attribution-required images need creator information. Selected
  Commons credits are saved before applying the image and are accessible in
  Settings → About Erhu → Image credits.
- Image search opens the browser with album + artist + “album cover image” or
  artist + “artist photo”. It does not scrape search results or automatically
  treat those images as licensed for reuse. Photos import stays explicit.

Keyless services still have provider terms, quotas and image/lyrics rights. This
is not a certification that every catalogue image is open-licensed. Wikimedia
metadata also depends on the correctness of the source entry; the original
source/licence page is shown for review. No provider fee or API key is required
by this setup.

## Latest Android artwork comparison

Reviewed `lochanpthakke/erhu` branch `kshitij` at `8d443f9` (2026-11-04).
The relevant artwork improvements are now adapted for both iOS branches:

- Album/artist matching, accent/punctuation normalization, edition and year review.
- Release-specific approved front covers from CAA; release-group fallback requires
  confirming the edition. Back/unapproved covers are excluded.
- Actual decoded image dimensions, malformed/oversized-image rejection and
  exact-byte duplicate suppression when release metadata agrees.
- A disposable 64 MiB image cache, up to 256 query records, seven-day freshness
  and usable stale results when online refresh fails. Nothing in this cache
  deletes or changes embedded/custom artwork.
- A complete image preview and explicit Apply for online results and Photos.
  Apply uses the bytes previewed; a changed image URL is not silently accepted.
- Streaming response limits, request pacing/cooldowns, cancellation and a
  45-second search budget.

This is an iOS adaptation, not a full Kotlin port. It does not yet extract embedded
MusicBrainz identifiers, calculate perceptual duplicates, or run Android's
saved accuracy benchmark. TheAudioDB's production key/licence requirement
conflicts with the keyless setup, so that provider is omitted. Commons remains
licence-filtered; artist photos remain separate from album matching.
Android's final commit only fixes test scheduling and needs no app behavior port.
Native iOS regression tests cover matching, image validation, offline persistence,
cache bounds and a changed-image URL. Test execution is tracked in iOS Actions.

## Larger VYBE model experiment

The currently shipped model remains the bundled Apache-2.0 MiniLM. The official
approximately 184 MB EmbeddingGemma `.task` is being tested separately with the
shipping MediaPipe iOS SDK, without adding an unverified runtime to the app.
The experiment verifies the published model checksum and exercises real local
query/document embeddings. Results are in the VYBE iOS compatibility probe
workflow; infrastructure failures do not establish model incompatibility.

No larger-model download button is advertised until a usable runtime is
validated. Gemma weights have separate Google terms; they are not GPL/Apache
weights merely because the download is hosted on GitHub. Better text embeddings
also cannot establish a song's sound when its description lacks relevant data.

If local fine-tuning is preferred, [download the laptop training kit](downloads/VYBE-training-kit.zip)
and read [its instructions](../Tools/vybe_lab/README.md). It fine-tunes MiniLM with
human-labelled query/positive/negative descriptions, keeps query groups out of
the training split for evaluation, and includes an experimental Core ML export
path. No private data or weights are uploaded by these scripts. Full training
and native validation require the ML environment and actual examples; syntax
and data-splitting checks alone are not a model-quality result.

## Release metadata

`ERHU_RELEASE_TAG` in `project.yml` records the published release baseline, separate
from the numeric bundle version. Update it when preparing a new tagged release;
do not compare the historical `0.1.0` bundle string directly with `v1.0-beta`.
The original Beta 1 release assets are retained. Use a successful branch-specific
iOS Actions artifact for current development code.
