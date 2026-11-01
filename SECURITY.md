# Security policy

## Supported builds

| Build | Security fixes |
| --- | --- |
| Latest published beta and current development branches | Maintained |
| Older beta releases and old workflow artifacts | Update to the latest build |

Erhu is a volunteer project. Response and fix times depend on severity and maintainer availability.

## Report a vulnerability privately

Use [GitHub's private vulnerability report](https://github.com/MeezaUni/Erhu-iOS/security/advisories/new)
when **Security → Report a vulnerability** is available. Do not put exploit details in a public issue.

If private reporting is unavailable, open a public issue titled **Private security contact requested**
without describing the vulnerability. A maintainer can arrange a private reporting channel.
No security email address or paid bug bounty is currently advertised by this project.

Include:

- The affected release/commit, iOS version, and static-art or animated-art variant.
- A clear description of the impact and steps to reproduce it.
- A minimal, synthetic sample or proof of concept when possible.
- Whether the issue involves imported files, tag/image/theme parsing, Wi-Fi Transfer, API keys,
  or an external provider.

Remove personal music, private paths, account details, pairing codes, and API keys from reports.
Test only on devices, files, and networks you own or are authorized to assess. Coordinate a fix
with maintainers before publishing a working exploit.

## Security boundaries

- Audio, library storage, and VYBE inference are local to the device.
- Online lyrics, metadata, and artwork providers receive search metadata.
- Optional provider keys are stored in the device Keychain.
- Wi-Fi Transfer uses a temporary, paired **plain HTTP** session on the local network. Use a
  trusted network; the transfer is not an encrypted internet service.
- Release IPAs are unsigned and must be signed by your sideloading installer. Checksums help
  verify that a download matches the published asset; they do not replace trust in its source.
