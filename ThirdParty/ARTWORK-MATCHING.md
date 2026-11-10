# Artwork matching reference

The edition-aware matching and cache/preview design were adapted from the
GPL-3.0 Android Erhu implementation in
[lochanpthakke/erhu, kshitij at 8d443f9](https://github.com/lochanpthakke/erhu/tree/8d443f9b654e30841e46b3f4a00c25d6a16aa5e6/core/network/src/main/java/com/erhu/erhu/core/network/artwork).
It is used in the proprietary iOS app with the permission recorded in
[docs/LICENSING-PERMISSIONS.md](../docs/LICENSING-PERMISSIONS.md). The Swift implementation
uses native ImageIO, URLSession and its own cache; Android measurement results
are not iOS test results. See [the iOS adaptation notes](../docs/FEATURE_UPDATES.md).
