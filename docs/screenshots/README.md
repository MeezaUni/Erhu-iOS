# README screenshots

The main [README](../../README.md#screenshots) displays eight screenshots in two rows of four under **Screenshots**, with seven
more inside an expandable **More screens** gallery. All images live in this folder and are
referenced using relative paths. These documentation files are outside the app target and do
not add to the IPA size.

## Current images

The uploaded images were renamed for readability. Their image contents are unchanged.

| Screenshot | Current filename | Original upload | Placement |
| --- | --- | --- | --- |
| Home | `home.png` | `IMG_6158.png` | Main gallery |
| Now Playing | `now-playing.png` | `IMG_6159.png` | Main gallery |
| VYBE search results | `vybe1.png` | `IMG_6176.png` | Main gallery |
| Full-screen lyrics | `lyrics.png` | `IMG_6162.png` | Main gallery |
| Themes and settings | `themes.png` | `IMG_6163.png` | More screens |
| Transition Studio | `transitions.png` | `IMG_6165.png` | Main gallery |
| Library | `library.png` | `IMG_6157.png` | More screens |
| Album | `album1.png` | `IMG_6178.png` | Main gallery |
| Artist | `artist.png` | `IMG_6170.png` | Main gallery |
| Visualizer | `visualizer.png` | `IMG_6173.png` | More screens |
| Equalizer curve | `equalizer.png` | `IMG_6174.png` | More screens |
| Equalizer bands | `equalizer-bands.png` | `IMG_6175.png` | More screens |
| Lyrics in the player | `player-lyrics.png` | `IMG_6161.png` | More screens |
| Track menu | `track-menu.png` | `IMG_6171.png` | More screens |
| Lock Screen | `lock-screen.png` | `IMG_6168.png` | Main gallery |

The VYBE image shows a submitted search, both matched song references, and similar tracks
from the library. All gallery slots are filled.

## Replace an image through GitHub

1. Select **without-animated-art**, currently the repository's default branch.
2. Open `docs/screenshots`, then choose **Add file → Upload files**.
3. Upload the replacement using the same filename as the existing screenshot and commit it.
   The README already refers to that filename, so no Markdown edit is needed.
4. Repeat on **with-animated-art** to keep both branch galleries up to date.

If you use a different filename or file extension, also edit the image's `src` in the main
`README.md` under **Screenshots**. Paths and filenames are case-sensitive. For example:

```html
<img src="docs/screenshots/vybe1.png" alt="VYBE results for a search using two reference songs" width="180" loading="lazy">
```

Use **Preview** before committing a README edit. The path above is relative to the main README,
not this guide. Keep the table pipes (`|`) around each image cell when editing a gallery row.

## Add another screenshot

Upload the image to this folder, then add a cell or row to the main README's gallery with an
image tag and a descriptive caption/alt text. Use `width="180"` to keep phone screenshots
consistent. Extra screens can go inside the existing `<details>` block so the main gallery
stays compact. Resize/compress large screenshots before uploading if you want smaller downloads.

## Optional support link

The main README has an `OPTIONAL_DONATION_LINK` comment under **Support**. Once you have a
Buy Me a Coffee or Ko-fi page, replace that whole comment with your real Markdown link.
No donation account or payment link has been created by these documentation changes.
