# Ogg Vorbis and Opus decoding

The app links Xiph's BSD-licensed libogg, libvorbis and libopus/libopusfile through
Stephen F. Booth's Swift Package Manager XCFramework wrappers. No codec service,
account, paid SDK or external inference is used.

Pinned wrapper commits:

| Package | Revision | Binary SHA-256 (verified against its Package.swift) |
| --- | --- | --- |
| [ogg](https://github.com/sbooth/ogg-binary-xcframework) | `48cbf24e7fb5d329b1f5e24cd2e5b048585ff770` | `0c06ea645c6ca187e66442717eb856c09e2b969545e880300639b41f7b83ae98` |
| [vorbis](https://github.com/sbooth/vorbis-binary-xcframework) | `842020eabcebe410e698c68545d6597b2d232e51` | `063843e2bfd1e85e445e3d03d4263268118dfb91406f5e74c33ce68a02865247` |
| [opus](https://github.com/sbooth/opus-binary-xcframework) | `8e23828b9d88f0ff1ff2d7c4bcb65739a4bdeff8` | `bae1b26f2e0e3e45c9fe001b73302d7cc9cb0f8a8db8f75956c87e2bb062a73e` |

The Opus framework also contains libopusenc. All five upstream copyright/licence
notices are retained in `Erhu/Resources/Licenses/Xiph-codecs.txt` and ship in the
app. Corresponding build sources/configuration are available from
https://github.com/sbooth/AudioXCFrameworks.

The original Ogg files remain unchanged. Headers/comments are read directly;
playback prepares a float PCM CAF in the OS-evictable decoded-audio cache. Cold
preparation runs off the UI thread and can require substantially more disk space
than the compressed original. Files currently in/near playback are protected
from cache pruning; other entries are pruned toward a 1 GiB budget. Insufficient
space, corrupt streams and unsupported channel layouts produce an error without
publishing a partial cache. The current decoder supports mono/stereo streams.

The same CAF reader feeds seeking, EQ, waveforms, BPM analysis and transitions.
Native source formats continue using their existing Core Audio decoder. Ogg tag
reading is supported; writing tags back into Ogg is outside this change.
