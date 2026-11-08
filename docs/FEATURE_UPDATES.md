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

## Library and playback refinements

- Pale accents use explicit contrasting labels and outlined toggle tracks, including
  system dark appearance.
- Album row numbers count within the displayed album. File names and embedded
  track/disc tags are retained; trusted tags still determine the existing album order.
- Radio headers show the seed artist and up to two distinct artists actually present
  in the station. Saved artist photos fall back to track artwork; the hero gradient
  comes from the main picture and adapts to light/dark appearance.
- **Not synced? Adjust timing** opens a millisecond slider, numeric entry, playback
  preview and Save/Cancel. Positive offsets delay lyrics; negative offsets bring
  them earlier. Highlighting, timed words and line-tap seeking use the same offset.
  Adjustments are local and separate per song/source/text version. Another version's
  saved timing can be copied explicitly. Original lyrics are never rewritten.
- Artwork Fetcher has **Find same image in higher resolution** in both tabs. It checks
  existing images in a cancellable batch, compares whole-image colours/edges and
  lists likely matches with a meaningful resolution increase after the save limit
  (1440 px). Review shows the actual current and replacement images, both resolutions and the
  replacement source before **Use higher-resolution image** / **Keep current**. Changed originals
  or provider images must be reviewed again. Explicit Apply remains required. Different covers/portraits are
  excluded conservatively; the individual picker remains available.
- Transition preview publishes actual rendered positions to the waveform overlay;
  it never advances the playhead from elapsed wall-clock time alone.
- Personal animated branch: **Check all albums for motion covers** is metadata only.
  Available/downloaded albums appear in the list and each video needs an explicit
  Download tap. Stopping or a lookup failure retains matches already found. Long
  library scans depend on provider availability and request limits.

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

## Bundled model compatibility fix

The iOS tests exposed zero output vectors on the simulator GPU and incorrect
reference agreement on its CPU with the older FP16 representation. The same
22M-parameter MiniLM weights now use FP32 arithmetic/output and exact 8-bit
palette storage. Repacking retains the original quantized values; this is a
runtime compatibility fix, not a new training/relevance claim. Its model identity
changes so older search indexes rebuild instead of mixing vector versions.

The standalone production-embedder probe in
[run 41902986570](https://github.com/MeezaUni/Erhu-iOS/actions/runs/41902986570)
passed reference agreement, empty-input handling, eight style queries and the
25 MB compiled-model budget. The probe uses the production Swift embedder and
tokenizer. This is simulator evidence; physical-device timing and real-library
relevance still depend on the device and available descriptions.

## Larger VYBE model experiment

The bundled Apache-2.0 MiniLM remains the default. A standalone test of the
approximately 184 MB official EmbeddingGemma bundle passed with MediaPipe Tasks
Text 1.0.0 on the Intel iOS simulator in
[run 41885296022](https://github.com/MeezaUni/Erhu-iOS/actions/runs/41885296022):
768-dimensional vectors, 6/6 synthetic query matches, approximately 1.68 seconds
model load and 72.2 seconds for the twelve document/query embeddings plus setup.
This verifies basic compatibility, not actual-library quality or iPhone speed.
The earlier pre-test crash was a duplicate static-framework link in the harness;
that was corrected before the successful test.

The SDK's shipped `NOTICE`, dated June 5, 2026, says it sends performance and
usage metrics to Google, while processing text on device. Its public iOS
headers expose no telemetry-disable option. That SDK is currently confined to
the standalone probe, not linked into the app. Adding its optional download/
switch flow is held pending the user's privacy preference; successful inference
alone does not justify introducing undisclosed telemetry.

Gemma weights have separate Google terms; they are not GPL/Apache weights merely
because the download is hosted on GitHub. Better text embeddings also cannot
establish a song's sound when its description lacks relevant data.

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


## Home, scoped repairs and launch updates

- Smart-playlist banners wrap on manual swipes in either direction, with one dot per real page.
- Featured Setlists combines album and radio destinations. Radio tiles use circular artwork on a lighter artwork-derived surface. Recently played shelves follow it.
- Fix tags online starts a run limited to the selected album, artist, playlist or song. Other queued songs stay pending. Collection pages show progress and scoped results, with manual review still available in place. Atomic, all-selected-fields tag writes and Revert remain intact.
- Equivalent explicit guest credits (including parenthesized “with”) and single/EP suffixes no longer cause false same-recording/edition ties. Version markers and different album editions remain protected.
- iTunes field recovery checks the local storefront and the US storefront and uses primaryGenreName. A final genre fallback reads public Discogs release/master genres and styles only through curated MusicBrainz links, then verifies the album and artist again. No credentials or Deezer availability are required. Discogs rate limits are respected and release responses are cached. Sources are recorded in repair details. See [Discogs API](https://www.discogs.com/developers/) and [MusicBrainz URL relationships](https://musicbrainz.org/doc/Style/Relationships/URLs).
- BPM remains a verified provider value or a dependable local estimate; ambiguous or changing tempos are not invented to increase completion counts. Disc numbers come from the matched edition rather than assuming every release is disc 1.
- Every app opening revalidates GitHub Releases in the background using ETag, coalescing duplicate launch callbacks and respecting rate limits. Only newer IPAs matching the installed artwork variant produce a prompt. The prompt includes release notes, publication date when supplied, Download update, Skip for now, and Do not show this version again. Ignoring persists for that tag only; later updates still appear. Manual checks in About remain available.


## Library search and pull-down search

Unicode names stay intact and empty normalized strings never count as matches. Search ranks exact names before prefixes and bounded typo correction (including swapped adjacent letters); numbers remain exact. An album query returns matching albums and their own tracklists; an artist query returns matching artists and their credited songs/albums; a song query returns matching songs plus their albums without expanding unrelated album tracks. Exact artist/album names lead ambiguous same-name song matches. A supplied artist qualifier narrows a title query. Processing is cancellable and runs off the main thread.

Global and section search share a floating Liquid Glass field (material fallback before iOS 26), a clear-text control and a circular close X. Section headers use the page background instead of a separate bar. Pull down to reveal search below the title and above the existing controls. Scrolling up tucks the field away while preserving its query; X closes it and clears the query. Artists have pull-down search without sorting/filter controls. VYBE's existing spelling correction now also handles misspelled artist qualifiers and short words adjacent to a longer typo, preserving its ambiguity choices and exact numeric matching.


## Home and interaction corrections

The carousel draws one dot for each real playlist; wraparound sentinel pages do not create extra dots or highlights. Featured Setlists chooses an album or its station once per release, with additional stations from other releases. Its small shelf measures all cards and uses a consistent caption layout, avoiding cropped radio subtitles.

Sort/filter controls and their search button are part of the page's scrolling header. A top pull reveals local search; scrolling carries it and the controls away without a pinned overlay or a mid-scroll layout reset. The search clear target is 44 points, and decorative glass/borders cannot intercept clear or close taps. The global close button explicitly closes its router sheet. Native tap-and-swipe tests cover search with a visible keyboard, scrolling controls, carousel dots and the label-free transition switch.

Tool/settings/Transition Studio destinations now use the same vertical-scroll chrome tracking as collection pages. Player dismissal finishes artwork ownership at native animation completion, preserving stale-completion guards; the closing overlay retains hit testing until removed so touches cannot reach the mini-player underneath midway through the flight.

## Search drawer behavior

Albums, Songs, Artists, Playlists and Favorites share a scroll-linked search drawer. The title stays above the search field while it is revealed or tucked away; sort/filter controls remain below it and scroll away with the page. The drawer keeps a constant amount of scroll space, so hiding it never removes a row midway through a gesture. Returning to a page preserves its scroll position, and larger text sizes preserve the visible results.

## Saved tool progress and batch artwork upgrades

Fix Tags saves its queue, lookup diagnostics, held repair values, unfinished auto-fill IDs and originals for Revert across relaunches. An interrupted lookup returns to Pending; completed tracks stay completed. Missing-tag checks also checkpoint each file. Continue includes new imports without silently retrying completed tracks. Clearing the queue explicitly removes its saved progress and originals.

Artwork Fetcher checkpoints each album, including albums that already have artwork. File paths, sizes and modification dates invalidate checks when files change; newly imported albums are included. Artist-photo matching retains completed and negative checks, while transient errors remain retryable. Start a new check discards the corresponding scan history. Higher-resolution searches retain pending comparisons and negative results across reopening. Apply to all revalidates each original and replacement with the individual comparison safeguards and leaves failed or changed images for review.
