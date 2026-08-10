# Native artifact provenance

- libssh2: 1.11.1, tag libssh2-1.11.1, commit a312b43325e3383c865a87bb1d26cb52e3292641
- OpenSSL: 3.6.3, tag openssl-3.6.3, commit aae016bfd52fcad2bc9657c2c782cfdf73b1ed5f
- Xcode: Xcode 26.6;Build version 17F113
- Compiler: Apple clang version 21.0.0 (clang-2100.1.1.101)
- iPhoneOS SDK: 26.5
- iPhone Simulator SDK: 26.5
- Deployment target: iOS 18.0
- Configuration: Release, static libraries, arm64 device and arm64 Simulator
- OpenSSL features: no shared library, module, legacy provider, deprecated API, DSA, RC2, RC4, DES, CAST, Blowfish, IDEA, SEED, Camellia, ARIA, SM2, SM3, SM4, Whirlpool, or RIPEMD-160
- OpenSSL privacy manifest: upstream os-dep/Apple/PrivacyInfo.xcprivacy
- libssh2 crypto backend: OpenSSL, with DSA, SHA-1 RSA signatures, SHA-1 MACs, MD5, RIPEMD, CBC, Blowfish, RC4, CAST, and 3DES negotiation disabled
- libssh2 patch: Patches/libssh2-modern-algorithms.patch removes SHA-1 key exchange and MAC methods from negotiation
- Build command: make ssh-artifacts
