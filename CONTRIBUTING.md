# Contributing to Erhu

Bug reports, device testing, documentation, and focused code improvements are welcome.

## Before you start

- Search existing issues and pull requests before opening a duplicate.
- Use the bug-report or feature-request form for public feedback.
- Follow the [code of conduct](CODE_OF_CONDUCT.md).
- Report vulnerabilities using [SECURITY.md](SECURITY.md), not a public bug report.

## Branches and setup

| Branch | Purpose |
| --- | --- |
| `without-animated-art` | Shared player features with static artwork; default branch |
| `with-animated-art` | Shared features plus motion-cover downloads and playback |

See [building from source](docs/BUILDING.md). The Xcode project is generated from `project.yml`;
do not commit the generated `.xcodeproj` or local build output.

For shared changes, target the default branch and explain whether the animated-art branch also
needs the fix. Motion-only changes belong on `with-animated-art`. Maintainers can carry shared
changes between variants; do not merge the entire Android or animated-art tree into the static branch.

## Submitting changes

1. Keep a pull request focused on one problem or feature.
2. Describe the existing behavior, the change, and how you verified it.
3. For app changes, build the affected variant and run relevant XCTest coverage. Include a
   device check when the change concerns rendering, audio routes, or system Now Playing.
4. For documentation, check links, filenames, image paths, and GitHub rendering.
5. Mention any database, file-format, import, or playback compatibility effects.

Use synthetic or appropriately licensed test media. Keep API keys, signing credentials,
personal libraries, local paths, and generated IPAs out of commits. Preserve existing third-party
licences and attribution when changing adapted code or model resources.

## Licence

The project is distributed under [GPLv3](LICENSE). Contributions are provided under the project
licence unless an existing third-party component specifies its own terms. Copyright remains
with the relevant authors; no copyright assignment is requested here.
