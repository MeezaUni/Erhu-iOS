// Renders the styled README showcase images from the raw iPhone screenshots.
//
//   node scripts/showcase/render.mjs
//
// Reads images/showcase/raw/<name>.png and writes images/showcase/<name>.png.
// Needs Playwright with Chromium and the Inter font installed.
import { createRequire } from 'node:module';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const { chromium } = createRequire(import.meta.url)('playwright');

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const raw = join(root, 'images/showcase/raw');
const out = join(root, 'images/showcase');

const shots = {
  home: ['Home and discovery', 'Start with your library.', 'Smart playlists, radio stations and recent albums.'],
  radio: ['Home and discovery', 'Radio from one song.', 'Stations built from the music you already have.'],
  vybe: ['Home and discovery', 'Search by feeling.', 'VYBE runs on your iPhone. Nothing is uploaded.'],
  'now-playing': ['The listening experience', 'Let the record lead.', 'Artwork, playback controls and lyrics in one view.'],
  lyrics: ['The listening experience', 'Sing along.', 'Synced lyrics, saved for offline listening.'],
  queue: ['The listening experience', 'Up next, your way.', 'Reorder, remove and loop what plays next.'],
  library: ['Your library', 'Everything in one place.', 'Playlists, favourites and artists.'],
  albums: ['Your library', 'Pick up where you left off.', 'Albums sorted by what you played last.'],
  'songs-moods': ['Your library', 'Songs for the moment.', 'Filter by genre and ten moods.'],
  glass: ['Menus and audio controls', 'Glass that floats.', 'Track actions without leaving Now Playing.'],
  equalizer: ['Menus and audio controls', 'Tune the sound.', 'An 8-band equalizer with presets.'],
  'artwork-fetcher': ['Library tools', 'Find the right cover.', 'Album covers and artist photos, online or from your files.'],
  'artwork-upgrade': ['Library tools', 'Sharper covers.', 'Higher-resolution matches, checked before saving.'],
  'transition-studio': ['Transition Studio', 'Shape every handoff.', 'Album, playlist and track-pair crossfades.'],
  'transition-editor': ['Transition Studio', 'Draw the crossfade.', 'Volume, EQ and filter curves over the waveforms.'],
};

const css = `
  * { margin: 0; box-sizing: border-box; }
  html, body { background: #212830; color: #f2f2f0; font-family: Inter, sans-serif; }
  .kicker { font-size: 22px; letter-spacing: 0.22em; text-transform: uppercase; color: #9a9b9f; }
  .rule { height: 1px; background: #353d47; }
  .foot { font-size: 18px; letter-spacing: 0.22em; text-transform: uppercase; color: #6c6d72; }
  .phone { border-radius: 64px; padding: 10px; background: #1a1f25; border: 2px solid #3e4652; }
  .phone img { display: block; width: 100%; border-radius: 54px; }
`;

const page = (name, [kicker, title, sub]) => `<!doctype html><html><head><style>${css}
  body { width: 1200px; height: 2200px; position: relative; overflow: hidden; }
  .head { position: absolute; left: 96px; top: 110px; right: 96px; }
  .head h1 { font-family: 'Inter Display', Inter, sans-serif; font-weight: 600; font-size: 76px; letter-spacing: -0.02em; margin-top: 30px; }
  .head p { font-size: 30px; color: #a9aaae; margin-top: 22px; }
  .phone { position: absolute; left: 50%; top: 520px; width: 720px; transform: translateX(-50%); }
  .rule { position: absolute; left: 96px; right: 96px; bottom: 120px; }
  .foot { position: absolute; left: 96px; bottom: 62px; }
</style></head><body>
  <div class="head"><div class="kicker">${kicker}</div><h1>${title}</h1><p>${sub}</p></div>
  <div class="phone"><img src="file://${join(raw, name + '.png')}"></div>
  <div class="rule"></div><div class="foot">erhu &nbsp;/&nbsp; iOS</div>
</body></html>`;

const hero = `<!doctype html><html><head><style>${css}
  body { width: 2400px; height: 1500px; position: relative; overflow: hidden; }
  .left { position: absolute; left: 120px; top: 120px; width: 760px; }
  .brand { font-family: 'Inter Display', Inter, sans-serif; font-weight: 600; font-size: 200px; letter-spacing: -0.05em; margin-top: 60px; line-height: 1; }
  h1 { font-family: 'Inter Display', Inter, sans-serif; font-weight: 600; font-size: 84px; line-height: 1.08; letter-spacing: -0.02em; margin-top: 110px; }
  p { font-size: 32px; line-height: 1.5; color: #a9aaae; margin-top: 50px; }
  .rule { position: absolute; left: 120px; width: 600px; top: 1130px; }
  .foot { position: absolute; left: 120px; top: 1170px; }
  .phone { position: absolute; }
  .a { left: 1040px; top: 270px; width: 520px; }
  .b { left: 1640px; top: 130px; width: 600px; }
</style></head><body>
  <div class="left"><div class="kicker">iPhone music player</div><div class="brand">erhu</div>
    <h1>Your music.<br>Played locally.</h1>
    <p>Albums, lyrics and on-device discovery.<br>Built around your own music.</p></div>
  <div class="rule"></div><div class="foot">Beta 1 &nbsp;/&nbsp; iPhone captures</div>
  <div class="phone a"><img src="file://${join(raw, 'home.png')}"></div>
  <div class="phone b"><img src="file://${join(raw, 'now-playing.png')}"></div>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), 'showcase-'));
const browser = await chromium.launch();
const ctx = await browser.newContext({ deviceScaleFactor: 1 });
const tab = await ctx.newPage();
const only = process.argv.slice(2);
const jobs = [...Object.entries(shots).map(([n, t]) => [n, page(n, t), 1200, 2200]), ['hero', hero, 2400, 1500]]
  .filter(([n]) => only.length === 0 || only.includes(n));
for (const [name, html, width, height] of jobs) {
  const file = join(dir, name + '.html');
  writeFileSync(file, html);
  await tab.setViewportSize({ width, height });
  await tab.goto('file://' + file);
  await tab.evaluate(() => Promise.all([...document.images].map(i => i.decode())));
  await tab.screenshot({ path: join(out, name + '.png') });
  console.log('wrote', name);
}
await browser.close();
