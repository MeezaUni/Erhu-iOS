# README showcase images

The images shown in the main [README](../../README.md).

The PNGs here are styled cards (1200 × 2200, hero 2400 × 1500) with a transparent background, so the page
colour shows through. The ones in this folder are for GitHub's dark themes and the ones in [`light/`](light) for
the light theme; the README tags them with `#gh-dark-mode-only` and `#gh-light-mode-only`,
which follow the reader's GitHub theme setting. They are made from the plain iPhone screenshots in
[`raw/`](raw) (1206 × 2457, status bar cropped). To change one, replace its screenshot in `raw/` or edit its
caption in [`scripts/showcase/render.mjs`](../../scripts/showcase/render.mjs), then run:

```sh
node scripts/showcase/render.mjs            # every card
node scripts/showcase/render.mjs home hero  # just these
```

It needs Node, Playwright with Chromium, and the Inter font. `animated-artwork.webp` is built the same way from the trimmed recordings in `raw/animated-*.mp4`
(`node scripts/showcase/render.mjs animated`); it also needs ffmpeg with libwebp.

| File | Screen | README section |
| --- | --- | --- |
| `hero.png` | Home and Now Playing side by side | Header |
| `home.png` | Home with a smart playlist and radio stations | Home and discovery |
| `radio.png` | A radio station page | Home and discovery |
| `vybe.png` | VYBE search results | Home and discovery |
| `library.png` | Library: playlists, favourites, artists | Your library |
| `albums.png` | Albums, sorted by recently played | Your library |
| `now-playing.png` | Now Playing | The listening experience |
| `lyrics.png` | Full-screen synced lyrics | The listening experience |
| `queue.png` | Queue | The listening experience |
| `songs-moods.png` | Songs filtered by the Late night mood | Your library |
| `equalizer.png` | Equalizer with a preset | Audio controls and Transition Studio |
| `artwork-fetcher.png` | Artwork Fetcher | Library tools |
| `auto-fix-tags.png` | Auto Fix Tags with matched and uncertain tracks | Library tools |
| `artwork-upgrade.png` | Upgrade album covers (animated build) | Library tools |
| `transition-studio.png` | An album with Transition Studio and track pairs | Audio controls and Transition Studio |
| `transition-editor.png` | The transition editor with waveforms and curves | Audio controls and Transition Studio |
| `animated-artwork.webp` | Album page, Now Playing and Lock Screen with animated covers (from screen recordings) | Animated artwork |
