# Native artifact provenance

- Source: mosh (Blink iOS port) + protobuf 2.6.1, built in `~/src/mosh-spike`
  (`build-all.sh`; patches recorded in the spike's `patches/`).
- Spike mosh device-slice archive SHA-256: `1d0f34fb4b09e0a2a705e388935e143fc058fadf28e8eb3e316e07483e1e826e`
- Assembled by `Scripts/build-native.sh`: libtool-merged
  libmoshios + libprotobuf per slice, repacked into the original framework
  skeleton, combined with `xcodebuild -create-xcframework`.
- Slices: arm64 (iPhoneOS) + arm64 (iPhoneSimulator), MinimumOSVersion 18.0.
- Xcode: `Xcode 27.0;Build version 27A266a`
- Link requirements surfaced to the consumer: `-lc++ -lz` (libc++ and zlib;
  everything else is system). CommonCrypto-backed, no OpenSSL dependency.
