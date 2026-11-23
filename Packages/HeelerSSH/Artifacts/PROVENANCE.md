# Native artifact provenance

- libssh2: c7557852f1b7c0d3b9cffd5390eb33fdf93fb17f, tag master-c755785, commit c7557852f1b7c0d3b9cffd5390eb33fdf93fb17f
- OpenSSL: 3.6.3, tag openssl-3.6.3, commit aae016bfd52fcad2bc9657c2c782cfdf73b1ed5f
- Xcode: Xcode 27.2;Build version 27B52
- Compiler: Apple clang version 21.0.0 (clang-2100.4.1.1)
- iPhoneOS SDK: 27.2
- iPhone Simulator SDK: 27.2
- Deployment target: iOS 18.0
- Configuration: Release, static libraries, arm64 device and arm64 Simulator
- OpenSSL features: no shared library, module, legacy provider, deprecated API, DSA, RC2, RC4, DES, CAST, Blowfish, IDEA, SEED, Camellia, ARIA, SM2, SM3, SM4, Whirlpool, or RIPEMD-160
- OpenSSL privacy manifest: upstream os-dep/Apple/PrivacyInfo.xcprivacy
- libssh2 crypto backend: OpenSSL; MD5, RIPEMD, RSA-SHA1, SHA-1 KEX/MACs,
  Blowfish, RC4, CAST, 3DES, and CBC are off (upstream defaults and
  LIBSSH2_NO_AES_CBC); ML-KEM hybrid key exchanges available; system libz
  linked for delayed post-auth zlib@openssh.com compression (Host-to-App only);
  patched src/transport.c via Patches/libssh2-remote-decomp-check.patch so
  inbound decompression checks session->remote.comp instead of local.comp
- Build command: make ssh-artifacts
