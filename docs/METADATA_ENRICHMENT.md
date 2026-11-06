# Automatic metadata filling

Fix Tags can use different catalogues for different fields. Automatic is the default;
the single-source choices restrict catalogue matching to that source.

- The strongest accepted match supplies the title, artist, album and album ordering.
- MusicBrainz recording, release and release-group genres are combined, keeping usable positively
  voted genres and removing duplicates. Deezer album genres and catalogue genres (including
  iTunes `primaryGenreName`) are fallbacks. A bounded additional iTunes search can recover
  genres absent from the initial pool. Wikidata P136 genres are a final keyless fallback, reached
  through a verified MusicBrainz recording or album link; deprecated statements and conflicting
  MusicBrainz identifiers are rejected. Artist-wide genre guesses are not written.
- Release dates can come from verified matching catalogues. Conflicting years are left for review.
- A verified Deezer track's reported BPM is used when available. Otherwise audio is analysed
  locally, with archived AcousticBrainz measurements as a fallback. Uncertain local results get
  a second pass over up to seven non-overlapping 20-second windows spanning the whole file.
  Clear repeated sections may anchor ambiguous half/double-time sections; unresolved octave
  ties and weak/no beat remain missing. These values do not
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

Repairs are **all or nothing per song**. If any selected tag remains missing, the file is not
changed and stays **Needs review**. Found values are held as suggestions in the current queue.
The manual editor shows the remaining fields and can combine known values with those held
suggestions; it saves only once the whole selected repair is complete. Unresolved manual entries
remain in memory and the sheet explains what still needs a value.

The tag writer verifies all requested changes and all selected fields in its temporary edited
copy **before** atomically replacing the original. A failed or incomplete edit cannot leave a
partially repaired file. Repeated fixes retain the queue item's first original backup until the
queue is cleared, so Revert can undo the whole set of changes.

No API keys, paid integrations or audio uploads are added by this workflow. Catalogue
coverage and regional availability vary; an unknown value is left missing rather than guessed.

## Bulk field filling

The top Fix Tags menu includes **Auto-fill best available tags**, with the unresolved track count.
It refreshes available catalogue matches and fills each selected missing field independently.
Pending, Needs review and previously unchanged entries can be retried, including entries with
no saved candidates. Existing values are retained. The matching-source picker applies to the
ordinary search; the auto-fill action checks all available sources.

Genre and tempo can come from a confidently matching recording on another release (for example,
a single or compilation). Ordering requires a matching album edition;
storefront `- Single` and `- EP` suffixes are normalized without dropping deluxe/remaster labels.
When the overall winner has no ordering, matching MusicBrainz, iTunes or Deezer entries can provide it.
A full MusicBrainz recording lookup can recover a tagged release absent from the initial search;
a targeted iTunes search is another bounded fallback. Disc-only repair does not require agreement
with an unrelated existing track number. A catalogue's explicit `discCount: 1` confirms Disc 1;
unknown disc counts never silently become 1.

Progress, Pause and Revert remain available. A no-change run explicitly explains that no values
changed. Unresolved entries offer **Enter remaining tags manually**, which shows the missing
selected fields first. Manual saves recheck completeness and preserve the first original backup.

## Additional source

[Wikidata structured data](https://www.wikidata.org/wiki/Wikidata:Licensing) is CC0.
The fallback uses public entity JSON and the Action API without keys, accounts or scraping.
Only a verified MusicBrainz recording/release-group link supplies an item; title-only searches
and artist-level genre inference are not used. Entity and genre-label results are cached per session.
