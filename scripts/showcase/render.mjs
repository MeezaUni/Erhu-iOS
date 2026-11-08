// Renders the styled README showcase images from the raw iPhone screenshots.
//
//   node scripts/showcase/render.mjs
//
// Reads images/showcase/raw/<name>.png and writes images/showcase/<name>.png (dark theme)
// and images/showcase/light/<name>.png (light theme).
// Needs Playwright with Chromium and the Inter font installed.
import { createRequire } from 'node:module';
import { writeFileSync, mkdtempSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
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
  'audio-controls': ['Audio controls', 'Tune the sound.', 'An 8-band equalizer with presets.'],
  'artwork-fetcher': ['Library tools', 'Find the right cover.', 'Album covers and artist photos, online or from your files.'],
  'artwork-upgrade': ['Library tools', 'Sharper covers.', 'Higher-resolution matches, checked before saving.'],
  'auto-fix-tags': ['Library tools', 'Repair your tags.', 'Review uncertain matches, and revert any change.'],
  'transition-studio': ['Transition Studio', 'Shape every handoff.', 'Album, playlist and track-pair crossfades.'],
  'transition-editor': ['Transition Studio', 'Draw the crossfade.', 'Volume, EQ and filter curves over the waveforms.'],
};

// The cards have a transparent background so the README page colour shows through in every
// GitHub theme. Dark-theme cards go in images/showcase, light-theme cards in images/showcase/light.
const themes = {
  dark: { text: '#f0f6fc', muted: '#9198a1', faint: '#656c76', rule: '#3d444d', frame: '#151b23', edge: '#3d444d' },
  light: { text: '#1f2328', muted: '#59636e', faint: '#818b98', rule: '#d1d9e0', frame: '#e6eaef', edge: '#c8d1da' },
};

const css = (t) => `
  * { margin: 0; box-sizing: border-box; }
  html, body { background: transparent; color: ${t.text}; font-family: Inter, sans-serif; }
  .kicker { font-size: 22px; letter-spacing: 0.22em; text-transform: uppercase; color: ${t.muted}; }
  .rule { height: 1px; background: ${t.rule}; }
  .foot { font-size: 18px; letter-spacing: 0.22em; text-transform: uppercase; color: ${t.faint}; }
  .phone { border-radius: 64px; padding: 10px; background: ${t.frame}; border: 2px solid ${t.edge}; }
  .phone img { display: block; width: 100%; border-radius: 54px; }
  .sub { color: ${t.muted}; }
`;

const page = (t, name, [kicker, title, sub]) => `<!doctype html><html><head><style>${css(t)}
  body { width: 1200px; height: 2200px; position: relative; overflow: hidden; }
  .head { position: absolute; left: 96px; top: 110px; right: 96px; }
  .head h1 { font-family: 'Inter Display', Inter, sans-serif; font-weight: 600; font-size: 76px; letter-spacing: -0.02em; margin-top: 30px; }
  .head p { font-size: 30px; margin-top: 22px; }
  .phone { position: absolute; left: 50%; top: 520px; width: 720px; transform: translateX(-50%); }
  .rule { position: absolute; left: 96px; right: 96px; bottom: 120px; }
  .foot { position: absolute; left: 96px; bottom: 62px; }
</style></head><body>
  <div class="head"><div class="kicker">${kicker}</div><h1>${title}</h1><p class="sub">${sub}</p></div>
  <div class="phone"><img src="file://${join(raw, name + '.png')}"></div>
  <div class="rule"></div><div class="foot">erhu &nbsp;/&nbsp; iOS</div>
</body></html>`;

const hero = (t) => `<!doctype html><html><head><style>${css(t)}
  body { width: 2400px; height: 1500px; position: relative; overflow: hidden; }
  .left { position: absolute; left: 120px; top: 120px; width: 760px; }
  .brand { font-family: 'Inter Display', Inter, sans-serif; font-weight: 600; font-size: 200px; letter-spacing: -0.05em; margin-top: 60px; line-height: 1; }
  h1 { font-family: 'Inter Display', Inter, sans-serif; font-weight: 600; font-size: 84px; line-height: 1.08; letter-spacing: -0.02em; margin-top: 110px; }
  p { font-size: 32px; line-height: 1.5; margin-top: 50px; }
  .rule { position: absolute; left: 120px; width: 600px; top: 1130px; }
  .foot { position: absolute; left: 120px; top: 1170px; }
  .phone { position: absolute; }
  .a { left: 1040px; top: 270px; width: 520px; }
  .b { left: 1640px; top: 130px; width: 600px; }
</style></head><body>
  <div class="left"><div class="kicker">iPhone music player</div><div class="brand">erhu</div>
    <h1>Your music.<br>Played locally.</h1>
    <p class="sub">Albums, lyrics and on-device discovery.<br>Built around your own music.</p></div>
  <div class="rule"></div><div class="foot">Beta 1 &nbsp;/&nbsp; iPhone captures</div>
  <div class="phone a"><img src="file://${join(raw, 'home.png')}"></div>
  <div class="phone b"><img src="file://${join(raw, 'now-playing.png')}"></div>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), 'showcase-'));
const browser = await chromium.launch();
const ctx = await browser.newContext({ deviceScaleFactor: 1 });
const tab = await ctx.newPage();
const only = process.argv.slice(2);
const jobs = Object.entries(themes).flatMap(([theme, t]) =>
  [...Object.entries(shots).map(([n, c]) => [n, page(t, n, c), 1200, 2200]), ['hero', hero(t), 2400, 1500]]
    .map(([n, html, w, h]) => [n, html, w, h, theme === 'dark' ? out : join(out, theme)]))
  .filter(([n]) => only.length === 0 || only.includes(n));
mkdirSync(join(out, 'light'), { recursive: true });
for (const [name, html, width, height, folder] of jobs) {
  const file = join(dir, name + '-' + width + folder.length + '.html');
  writeFileSync(file, html);
  await tab.setViewportSize({ width, height });
  await tab.goto('file://' + file);
  await tab.evaluate(() => Promise.all([...document.images].map(i => i.decode())));
  await tab.screenshot({ path: join(folder, name + '.png'), omitBackground: true });
  console.log('wrote', join(folder, name + '.png').slice(root.length + 1));
}
// The animated-artwork card: text and three phone frames rendered transparent, then the clips in
// raw/animated-*.mp4 looped into the screens with ffmpeg and saved as an animated WebP, which keeps
// the soft transparent edges a GIF cannot.
const clips = [['animated-album', 'Album'], ['animated-player', 'Now Playing'], ['animated-lock-screen', 'Lock Screen &nbsp;/&nbsp; iOS 26']];
const animated = (t) => `<!doctype html><html><head><style>${css(t)}
  body { width: 1600px; height: 1400px; position: relative; overflow: hidden; }
  .head { position: absolute; left: 72px; top: 72px; }
  .head h1 { font-family: 'Inter Display', Inter, sans-serif; font-weight: 600; font-size: 64px; letter-spacing: -0.02em; margin-top: 24px; }
  .head p { font-size: 26px; margin-top: 18px; }
  .kicker { font-size: 20px; }
  .col { position: absolute; top: 330px; width: 440px; }
  .phone { border-radius: 40px; padding: 10px; }
  .screen { width: 416px; height: 849px; }
  .label { margin-top: 28px; font-size: 16px; letter-spacing: 0.22em; text-transform: uppercase; color: ${t.faint}; }
  .rule { position: absolute; left: 72px; right: 72px; top: 1300px; }
  .foot { position: absolute; left: 72px; top: 1330px; font-size: 16px; }
</style></head><body>
  <div class="head"><div class="kicker">Animated artwork</div><h1>Covers that move.</h1>
    <p class="sub">Album pages, Now Playing and the Lock Screen. Animated-artwork build only.</p></div>
  ${clips.map(([, label], i) => `<div class="col" style="left:${72 + i * 508}px"><div class="phone"><div class="screen"></div></div><div class="label">${label}</div></div>`).join('')}
  <div class="rule"></div><div class="foot">erhu &nbsp;/&nbsp; animated build</div>
</body></html>`;

if (only.length === 0 || only.includes('animated')) {
  const mask = join(dir, 'mask.png');
  writeFileSync(join(dir, 'mask.html'), '<body style="margin:0;background:transparent"><div style="width:416px;height:849px;border-radius:30px;background:#fff"></div>');
  await tab.setViewportSize({ width: 416, height: 849 });
  await tab.goto('file://' + join(dir, 'mask.html'));
  await tab.screenshot({ path: mask, omitBackground: true });
  for (const [theme, t] of Object.entries(themes)) {
    const base = join(dir, `animated-${theme}.png`);
    writeFileSync(join(dir, `animated-${theme}.html`), animated(t));
    await tab.setViewportSize({ width: 1600, height: 1400 });
    await tab.goto('file://' + join(dir, `animated-${theme}.html`));
    const slots = await tab.evaluate(() => [...document.querySelectorAll('.screen')].map(e => {
      const r = e.getBoundingClientRect(); return [Math.round(r.x), Math.round(r.y)];
    }));
    await tab.screenshot({ path: base, omitBackground: true });
    const target = join(theme === 'dark' ? out : join(out, theme), 'animated-artwork.webp');
    const graph = ['[1]alphaextract,split=3[m0][m1][m2]'];
    clips.forEach((_, i) => graph.push(`[${i + 2}]fps=15,scale=416:849,format=rgba[c${i}]`, `[c${i}][m${i}]alphamerge[r${i}]`));
    graph.push(`[0][r0]overlay=${slots[0][0]}:${slots[0][1]}[b0]`, `[b0][r1]overlay=${slots[1][0]}:${slots[1][1]}[b1]`,
      `[b1][r2]overlay=${slots[2][0]}:${slots[2][1]},scale=1200:-1:flags=lanczos,format=yuva420p`);
    execFileSync('ffmpeg', ['-v', 'error', '-y', '-loop', '1', '-i', base, '-loop', '1', '-i', mask,
      ...clips.flatMap(([n]) => ['-stream_loop', '-1', '-i', join(raw, n + '.mp4')]),
      '-filter_complex', graph.join(';'), '-t', '6', '-c:v', 'libwebp_anim', '-quality', '70', '-loop', '0', target]);
    console.log('wrote', target.slice(root.length + 1));
  }
}

await browser.close();
