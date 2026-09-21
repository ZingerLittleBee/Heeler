# Native artifact provenance

- Source: mosh (Blink iOS port) + protobuf 2.6.1, built in `~/src/mosh-spike`
  (`build-all.sh`; patches recorded in the spike's `patches/`).
- Spike mosh device-slice archive SHA-256: `0d3be21784122b172fc864c143ad642546de8eeebdc5c006954b80ba040d9f8c`
- Assembled by `Scripts/build-native.sh`: libtool-merged
  libmoshios + libprotobuf per slice, repacked into the original framework
  skeleton, combined with `xcodebuild -create-xcframework`.
- Slices: arm64 (iPhoneOS) + arm64 (iPhoneSimulator), MinimumOSVersion 18.0.
- Xcode: `Xcode 27.0;Build version 27A266a`
- Link requirements surfaced to the consumer: `-lc++ -lz` (libc++ and zlib;
  everything else is system). CommonCrypto-backed, no OpenSSL dependency.
