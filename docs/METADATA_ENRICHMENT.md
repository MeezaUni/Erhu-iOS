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
- Additional catalogues must agree on recording title, artist, version and duration before they
  contribute recording-level values. Release-level values additionally require a matching album. Track/disc positions are not copied across unrelated album editions.

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

## Bulk field filling

The top Fix Tags menu includes **Auto-fill best available tags**, with the unresolved track count.
It refreshes available catalogue matches and fills each selected missing field independently.
Partly fixed, pending and previously unchanged entries can be retried, including entries with
no saved candidates. Existing values are retained. The matching-source picker applies to the
ordinary search; the auto-fill action checks all available sources.

Genre and tempo can come from a confidently matching recording on another release (for example,
a single or compilation). Track/disc numbers stay together and require a matching album edition;
storefront `- Single` and `- EP` suffixes are normalized without dropping deluxe/remaster labels.
When the overall winner has no ordering, matching MusicBrainz, iTunes or Deezer entries can provide it.

Progress, Pause and Revert remain available. A no-change run explicitly explains that no values
changed. Unresolved entries offer **Enter remaining tags manually**, which shows the missing
selected fields first. Manual saves recheck completeness and preserve the first original backup.
