# Navidrome (Erhu Server)

[Erhu Server](../Server/README.md) is [Navidrome](https://www.navidrome.org)
([source](https://github.com/navidrome/navidrome)), © the Navidrome authors and contributors,
licensed under the GNU General Public License v3.0.

- This repository does not contain or modify Navidrome's code. `Server/` holds configuration
  files only (`docker-compose.yml`, `.env.example`, `navidrome.toml`) that run the official
  Navidrome Docker image (`deluan/navidrome`) or an official Navidrome installation.
- The Erhu app talks to Navidrome, or any other compatible server, over the network using the
  public Subsonic / OpenSubsonic API. No Navidrome code is linked into or distributed with the
  app.
- If a future version of Erhu Server modifies Navidrome and is distributed, that modified
  server's source code must be published under the GPL-3.0, with Navidrome's copyright notices
  kept.

The unit-test fixtures in `ErhuTests/Server/SubsonicFixtures.swift` are trimmed API responses
recorded from Navidrome's public demo server (demo.navidrome.org) to test response decoding.
