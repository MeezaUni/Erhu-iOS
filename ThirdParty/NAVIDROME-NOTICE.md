# Navidrome (Erhu Server)

[Erhu Server](../Server/README.md) is [Navidrome](https://www.navidrome.org)
([source](https://github.com/navidrome/navidrome)), © the Navidrome authors and contributors,
licensed under the GNU General Public License v3.0.

- This repository does not contain or modify Navidrome's source code.
- `Server/launcher` is the Erhu Server app for Windows and macOS. Its builds bundle the official,
  unmodified Navidrome release binary (version and SHA-256 pinned in
  `Server/launcher/navidrome.lock`) and start it as a separate program. The launcher is released
  under the GPL-3.0 (`Server/launcher/LICENSE`), its source is in this repository, and every
  build ships `LICENSE.txt` and a `NOTICE.txt` that credits Navidrome and links to its source.
- `Server/docker-compose.yml`, `.env.example` and `navidrome.toml` are configuration only, for
  running the official Navidrome Docker image (`deluan/navidrome`) or an official installation.
- The Erhu iPhone app talks to Navidrome, or any other compatible server, over the network using
  the public Subsonic / OpenSubsonic API. No Navidrome code is linked into or distributed with
  the app, so the app's own licence is unaffected.
- If a future version modifies Navidrome itself, that modified source must also be published
  under the GPL-3.0, with Navidrome's copyright notices kept.

The unit-test fixtures in `ErhuTests/Server/SubsonicFixtures.swift` are trimmed API responses
recorded from Navidrome's public demo server (demo.navidrome.org) to test response decoding.
