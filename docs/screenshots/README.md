# Adding screenshots to the main README

The repository's main [README](../../README.md#screenshots) has six intentionally empty screenshot
slots under **Screenshots**, near the top. The cells contain HTML comments, so they do not show
broken images while you are preparing screenshots.

## Files and slots

Upload your screenshots to this folder with these filenames, or change the image paths to match
your chosen names:

| Screenshot | File | Comment to replace in the main README |
| --- | --- | --- |
| Home or library | `home.png` | `<!-- screenshot:home -->` |
| Now Playing | `now-playing.png` | `<!-- screenshot:now-playing -->` |
| VYBE results | `vybe.png` | `<!-- screenshot:vybe -->` |
| Lyrics | `lyrics.png` | `<!-- screenshot:lyrics -->` |
| Themes or settings | `themes.png` | `<!-- screenshot:themes -->` |
| Transition Studio | `transitions.png` | `<!-- screenshot:transitions -->` |

## Add them through GitHub

1. Select the **without-animated-art** branch on GitHub. It is currently the repository's default
   branch, so this README is the one visitors see first.
2. Open `docs/screenshots`, choose **Add file → Upload files**, upload the screenshots, and commit.
3. Open the main `README.md` at the repository root and click the pencil button to edit it.
4. Find `## Screenshots`. Replace each slot's HTML comment with its image tag, keeping the table
   pipes (`|`) around the cell. For example, replace `<!-- screenshot:now-playing -->` with:

   ```html
   <img src="docs/screenshots/now-playing.png" alt="Erhu Now Playing" width="240">
   ```

5. Use **Preview** to check that the images render, then commit the README edit.
6. Repeat the image upload and README edits on **with-animated-art** if you want screenshots on
   both branch pages. Screenshot files live separately on each branch.

Image paths and filenames are case-sensitive. If you upload JPG files instead, use `.jpg` in
both the filename and the image tag. The paths above are relative to the main README; they are
not paths relative to this guide.

Use consistently cropped screenshots with readable text, and resize/compress large files before
uploading. You can fill one slot at a time and leave the remaining comments unchanged.

## Optional support link

The main README also has an `OPTIONAL_DONATION_LINK` comment under **Support**. Once you have a
Buy Me a Coffee or Ko-fi page, replace that whole comment with a real Markdown link, such as:

```markdown
[Support Erhu](https://your-real-support-page)
```

Replace the example URL with your actual page before publishing it. No donation account or
payment link has been created by this documentation change.
