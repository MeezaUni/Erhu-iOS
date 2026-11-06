# Automatic metadata filling

Fix Tags can use different catalogues for different fields. Automatic is the default;
the single-source choices restrict catalogue matching to that source.

- The strongest accepted match supplies the title, artist, album and album ordering.
- MusicBrainz recording and release-group genres are combined, keeping usable positively
  voted genres and removing duplicates. Deezer album genres and catalogue genres (including
  iTunes `primaryGenreName`) are fallbacks.
- Release dates can come from verified matching catalogues. Conflicting years are left for review.
- A verified Deezer track's reported BPM is used when available. Otherwise audio is analysed
  locally, with archived AcousticBrainz measurements as a last fallback. These values do not
  replace an existing valid tempo tag.
- Additional catalogues must agree on title, artist, album, version and duration before they
  contribute. Track/disc positions are not copied across unrelated album editions.

Deezer is optional. Where it is unavailable, including India, MusicBrainz, iTunes and local
tempo analysis remain usable. A catalogue refusal is remembered for the session so subsequent
field lookups do not keep sending the same refused requests. Transient connection failures
remain retryable rather than being treated as an empty catalogue.

Find tracks with missing tags reads the files' actual metadata for every selected field,
including genre, year, BPM and track/disc numbers. Display fallbacks cannot hide missing tags.
The scan can requeue previously processed tracks that still need the newly selected fields.

After writing, tags are read again. A successful write that leaves selected tags missing is
labelled **Partly fixed**, with the remaining fields listed. Lookup details identify genre
sources and unavailable data. Repeated fixes retain the queue item's original backup until
the queue is cleared, so Revert can undo the whole set of changes.

No API keys, paid integrations or audio uploads are added by this workflow. Catalogue
coverage and regional availability vary; an unknown value is left missing rather than guessed.

## Bulk review

The top Fix Tags menu includes **Auto-select best candidates**, with the eligible track count.
It uses saved results at the current confidence setting, selecting the highest score and
breaking ties by the tagged album, closest duration, then the provider's original order.
Completed, reverted and failed entries are excluded. Low-confidence entries remain for review.

The queue shows progress and supports Pause. Use the same action to continue the remaining
review entries. The file's current tags are checked again before applying a bulk choice.
No per-track confirmation is required, and original backups remain available for Revert.
