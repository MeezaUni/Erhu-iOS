# Repository profile and community setup

## About box

Use the pencil button beside **About** on the repository home page.
The desired values are also in [repository-details.json](../.github/repository-details.json).
The publication workflow attempts the description/topics updates; GitHub's Actions token may
lack the administration permission needed to change them.

**Description**

> Native iOS music player with offline VYBE discovery, animated artwork, gapless playback, custom transitions, synced lyrics, and an 8-band EQ. Built with SwiftUI.

**Topics**

```text
ios iphone music-player offline-music local-music swift swiftui avfoundation coreml audio equalizer lyrics animated-artwork privacy sideloading
```

| Field | Setting |
| --- | --- |
| Website | Leave unchanged |
| Releases | Show |
| Deployments | Hide while there are no deployments |
| Packages | Hide while there are no packages |

## Community files

| GitHub checklist | File |
| --- | --- |
| Licence | [LICENSE](../LICENSE), full GNU GPL version 3 text |
| Security policy | [SECURITY.md](../SECURITY.md) |
| Contributing | [CONTRIBUTING.md](../CONTRIBUTING.md) |
| Code of conduct | [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md) |
| Issue templates | [Bug report](../.github/ISSUE_TEMPLATE/bug_report.yml) and [feature request](../.github/ISSUE_TEMPLATE/feature_request.yml) |
| Pull request template | [Pull request template](../.github/pull_request_template.md) |

GPLv3 does not require buying a licence or registering the project. GitHub detects the root
`LICENSE` file. Existing Android and model licences/notices remain in place. The GPL text was
copied verbatim from the system's standard GPLv3 licence, including its application appendix.

Enable **private vulnerability reporting** in the repository's security settings if the
workflow cannot enable it. The security policy includes a fallback until that channel is available.
No private email address, response-time guarantee, or paid bounty has been invented.

## Beta publication

The [Publish beta workflow](../.github/workflows/publish-beta.yml) reads
[beta-release.json](../.github/beta-release.json). An explicit change to that request file on the
default branch starts publication; the workflow can also be run manually there for a new beta tag.

It uses the latest retained successful `iOS` workflow artifact for each variant, verifies that
the app code/build configuration matches the current branch, and checks the IPA contents. It
uploads both unchanged IPAs, each build's source archive, GPLv3 text, third-party notices, a
build manifest, and SHA-256 checksums. All assets are uploaded to a draft before it is published
as a prerelease. Existing releases/tags are never overwritten. The website field is not changed.

The GitHub release label and the existing IPAs' embedded app version can differ; release notes
record both app versions and their exact successful workflow runs/commits. No new app binary is
claimed merely because a release label was added.
