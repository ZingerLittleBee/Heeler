# Terminal QR Rendering and Payload Size

Date: 2026-08-13

Research note for the Pairing Code QR in `plugin/src/terminal-qr.js`. Every
claim below cites the source that owns it: a file and line in the project's own
repository, a spec clause, or an RFC section. Where the primary source was
behind a paywall or a bot wall, that is stated rather than papered over.

## TL;DR

Three findings change what we should do, in descending order of confidence.

**1. Our quiet zone is half of what the spec requires, and it is nearly free to
fix.** `terminal-qr.js:17` sets `QUIET_ZONE_MODULES = 2`. Denso Wave, who
invented QR Code and authored the standard, states that "QR Code requires a
four-module wide margin at all sides of a symbol" and that two modules is the
Micro QR figure, not the QR figure. libqrencode, mdp/qrterminal, and
skip2/go-qrcode all default to 4. Russ Cox — author of the encoder qrterminal
uses — filed mdp/qrterminal#5 specifically about a 1-module border, reporting
that "many readers I tried back in 2012 could not recognize the code." Going
from 2 to 4 costs our current render **two columns and one row** (33x17 becomes
35x18). Do this regardless of anything else on this page.

**2. Payload compaction is worth doing, but not for the reason we assumed.** It
does *not* unlock half-blocks. Half-blocks need the symbol at version 3 or
smaller (29 modules) to fit 20 rows, which is roughly a 48-byte payload — far
below the ~130 bytes a compacted envelope would reach. What compaction actually
buys is (a) sextants become viable, which is a large terminal-compatibility win
over octants, and (b) error correction can rise from L to M or Q inside the same
cell budget. The second is the more valuable of the two.

**3. Sextants are the only candidate whose module squareness depends on the
font.** Half-blocks (1 module wide x 2 tall per cell) and octants (2x4) both
produce square modules in a 1:2 cell and degrade gracefully as line height
varies. Sextants (2x3) produce modules stretched vertically by `2H/3W`, which is
1.33 at a 1:2 cell and 1.47 at a 1:2.2 cell. ZXing's finder-pattern cross-check
rejects a candidate whose vertical run differs from its horizontal run by more
than 40% (`FinderPatternFinder.java`, `crossCheckVertical`). So sextants sit
just inside the tolerance at nominal line height and cross it if the user's
terminal has loose leading. That is a real risk, not a theoretical one.

### Recommendation

Keep octants as the rendering, and change the payload and the parameters around
it:

- Raise `QUIET_ZONE_MODULES` to 4 now. Cost: 2 columns, 1 row.
- Keep the `\e[47m\e[30m` white-background wrapper. This is already correct and
  is the one decision in this file that the evidence unambiguously supports; see
  [Polarity](#polarity-inverted-vs-white-background) for why unwrapped block
  glyphs are a coin flip.
- Compact the envelope to ~130 bytes binary, then **spend the savings on error
  correction, not on shrinking the QR**. At ~130 bytes, EC M renders as 29x15
  octant cells — smaller than what we ship today at EC L *and* with double the
  error correction. This mirrors what SatoshiPortal/bullbitcoin-mobile#2049 did
  after a real camera scan failure.
- Do **not** switch to sextants purely as a compatibility play without first
  measuring the actual cell aspect ratio in herdr's rendering path. The 33%
  vertical stretch is inside ZXing's budget with no cushion.
- If universal half-block rendering ever becomes a hard requirement, treat it as
  a payload-architecture change rather than a rendering change: the QR would
  have to carry a <=48-byte reference and the credential would be fetched over
  the connection it establishes. That is the Tailscale and Discord pattern, and
  it is the only route to a half-block QR in a 20-row popup.

### Cell math

Budget: roughly 66 columns x 20 rows (the `pair` pane is `width = "80%"`,
`height = "90%"` per `plugin/herdr-plugin.toml:22-23`). All figures use a
4-module quiet zone. Computed with the repo's own `qrcode` dependency.

| Payload | EC | Version | Modules | ANSI 2-space | Half `▀▄█` | Sextant | Octant |
| --- | --- | --- | --- | --- | --- | --- | --- |
| current 308-char envelope | L | v11 | 61 | 138x69 | 69x35 | 35x23 | **35x18** |
| current 308-char envelope | M | v13 | 69 | 154x77 | 77x39 | 39x26 | **39x20** |
| current 308-char envelope | Q | v16 | 81 | 178x89 | 89x45 | 45x30 | 45x23 |
| compacted ~130B binary | L | v6 | 41 | 98x49 | 49x25 | **25x17** | **25x13** |
| compacted ~130B binary | M | v8 | 49 | 114x57 | 57x29 | **29x19** | **29x15** |
| compacted ~130B binary | Q | v9 | 53 | 122x61 | 61x31 | 31x21 | **31x16** |
| compacted ~64B binary | L | v4 | 33 | 82x41 | 41x21 | **21x14** | **21x11** |
| compacted ~64B binary | M | v5 | 37 | 90x45 | 45x23 | **23x15** | **23x12** |

Bold entries fit 66x20. The shipping renderer today (octant, quiet zone 2,
EC L) measures 33x17.

Note the shape of the table: **the half-block column never fits**, at any
payload size we would realistically reach. Even a 64-byte payload is 41x21, one
row over. This is the single most important number on this page, because
half-blocks are what essentially every comparable project ships.

## Per-project findings

### What dominates in practice

Half-blocks, by a wide margin, for phone-scanned login QRs. whatsmeow — the
library behind most WhatsApp bridges — documents exactly two recipes in
`client_test.go:59-60`:

```go
// e.g. qrterminal.GenerateHalfBlock(evt.Code, qrterminal.L, os.Stdout)
// or just manually `echo 2@... | qrencode -t ansiutf8` in a terminal
```

Both are half-block. Neither is small. WhatsApp's 277-character payload lands on
QR version 11 — the same version as our 308-character envelope — which
`GenerateHalfBlock` renders as **69 columns x 35 rows**. Nobody minds, because
it goes to a full terminal rather than a popup. Our 66x20 constraint is the
unusual part of this problem, not our payload.

### Rendering table

| Project | Glyphs | Polarity | Quiet zone | Capability detection | Source |
| --- | --- | --- | --- | --- | --- |
| libqrencode `-t ANSI` / `ANSI256` | two spaces per module with bg color | dark-on-light, explicit `\e[47m`/`\e[40m` (or 256-color `231`/`16`) | 4 | none | `qrenc.c:749-831`, default at `:1427-1432` |
| libqrencode `-t UTF8` | `▀▄█` + space | **dark module = blank**, assumes light foreground on dark bg | 4 (rendered as `margin/2` rows of double-height glyphs, so still 4 modules) | none | `qrenc.c:847-930`; margin loop at `:838` |
| libqrencode `-t ANSIUTF8` | same glyphs, plus forced `\e[40;37;1m` | safe — carries its own black bg and white fg | 4 | none | `qrenc.c:872-882` |
| libqrencode `-t UTF8i` / `ANSIUTF8i` | glyph roles swapped | dark module = `█`, for light-background terminals | 4 | none | `qrenc.c:860-870` |
| mdp/qrterminal `Generate` | two spaces per module with bg color | safe, explicit bg | 4, clamped to min 1 | Sixel probe via `\e[c` | `qrterminal.go:14-15, 29, 132-152, 209-211` |
| mdp/qrterminal `GenerateHalfBlock` | `▀▄█` + space | dark module = `" "`, assumes light fg on dark bg | 4 | none | `qrterminal.go:18-21, 154-198, 252-263` |
| skip2/go-qrcode `ToString` | `██` per module | dark module = `"  "`, assumes light fg on dark bg | 4 | none | `qrcode.go:555-568`; `version.go` `quietZoneSize() = 4` |
| skip2/go-qrcode `ToSmallString` | `▀▄█` + space | same | 4 | none | `qrcode.go:573-608` |
| Tailscale `tailscale up --qr` | wraps skip2 with `auto`/`ascii`/`large`/`small` | `inverse = false` | 4 (inherited) | **the best in class** — see below | `util/qrcodes/qrcodes.go`, `qrcodes_linux.go:23-82` |
| node-qrcode `{type:'terminal'}` default | two spaces per module with bg color | safe, explicit bg | **1**, and `margin` is ignored | none | `lib/renderer/terminal/terminal.js:9-30` |
| node-qrcode `{type:'terminal', small:true}` | `▀▄█` + space with fg/bg setup | `inverse` option, default light-on-dark-ish | **1** | none | `lib/renderer/terminal/terminal-small.js:9-22, 70-75` |
| node-qrcode `{type:'utf8'}` | `▀▄█` + space | **dark module = `█`** — opposite of libqrencode and go-qrcode | 4 | none | `lib/renderer/utf8.js:3-8` |
| gtanner/qrcode-terminal default | two spaces per module with bg color | safe, explicit bg | **1** | none | `lib/main.js:3-4, 81-89` |
| gtanner/qrcode-terminal `{small:true}` | `▀▄█` + space | dark module = `" "` | **1** | none | `lib/main.js:55-74` |
| qrcp | delegates to `ToSmallString` | exposes `inverseColor` flag | 4 | none | `qr/qr.go` |
| whatsmeow (documented recipe) | `qrterminal.GenerateHalfBlock` or `qrencode -t ansiutf8` | either | 4 | none | `client_test.go:59-60` |

Nobody in this list uses braille, quadrants, sextants, or octants. Our octant
renderer is, as far as this survey found, without precedent in a shipping
project. That cuts both ways: it is why it fits our popup, and it is why there
is no field evidence for it.

### Tailscale's capability detection is worth copying in spirit

`util/qrcodes/qrcodes_linux.go:23-82` is the only real terminal-capability
detection found anywhere in this survey. It:

1. checks `LC_CTYPE`/`LANG` for a `.UTF-8` suffix, falling back to ASCII if
   absent;
2. checks `isatty`;
3. on a raw Linux console, issues a `KDGKBMODE` ioctl to confirm Unicode
   keyboard mode;
4. issues a `GIO_UNIMAP` ioctl to read the console font's actual
   Unicode-to-glyph map and confirms that `█`, `▀`, and `▄` are really present
   before using them.

The comment naming the bug that forced this is at `:26-28`, pointing at
tailscale/tailscale#12935 ("make simpler QR codes on less capable terminals?"),
which reported unusable output on a qemu VGA console under `TERM=vt220`. The
fixing PR (#18182) states plainly: "The default Fixed and Terminus fonts don't
contain half-block characters (`▀` and `▄`), but do contain the full-block
character (`█`)."

We cannot run ioctls from inside a herdr popup, and our situation is different
(we depend on Unicode 16 glyphs, not Unicode 1.1 ones). But the lesson holds:
**a project that shipped half-blocks still found terminals that could not render
them**, and it responded by adding a fallback rather than by asserting
compatibility.

## Payload encoding

### Mode efficiency

The three relevant QR modes, per RFC 9285 §4/§4.1 which normatively cites
ISO/IEC 18004 §7.3.4 and Table 2:

- numeric: 10 bits per 3 digits = 3.33 bits/char
- alphanumeric: 11 bits per 2 chars = 5.5 bits/char, over the 45-character set
  `0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:` (uppercase only)
- byte: 8 bits/char

Capacities at EC L, verified by recomputation from the ISO error-correction
tables as embedded in nayuki/QR-Code-generator `QrCode.java:773-790`:

| Version | Modules | byte (L) | alnum (L) | numeric (L) |
| --- | --- | --- | --- | --- |
| 5 | 37x37 | 106 | 154 | 255 |
| 6 | 41x41 | 134 | 195 | 322 |
| 7 | 45x45 | 154 | 224 | 370 |
| 8 | 49x49 | 192 | 279 | 461 |
| 9 | 53x53 | 230 | 335 | 552 |
| 10 | 57x57 | 271 | 395 | 652 |
| 11 | 61x61 | 321 | 468 | 772 |

### Base45 would make our QR bigger, not smaller

This is the most important correction to the framing of the original question.

**Base45 costs 8.25 QR data bits per source byte; raw byte mode costs 8.00.**
Base45 encodes 2 bytes into 3 alphanumeric characters (RFC 9285 §4), and each
alphanumeric character costs 5.5 bits, so 2 bytes cost 16.5 bits. Byte mode
costs 16. RFC 9285 never claims to beat byte mode — it claims to beat Base64
(10.67 bits/byte), and its stated motivation (§1) is that "Even in Byte mode, a
typical QR code reader tries to interpret a byte sequence as text encoded in
UTF-8 or ISO/IEC 8859-1. Thus, QR codes cannot be used to encode arbitrary
binary data directly."

That argument is about reader compatibility, not density. It was contested
directly in the draft's issue tracker (Netnod/base45#4, 2021-06-13): "Base45 is
an encoding for binary data which uses 8.25 bits per byte... while 8-bit Bytes
Mode could be a much more straightforward 'encoding' which would use 8 bits per
byte." The RFC author's response was that QR's byte mode "is in reality a
character mode as well," and that "many of us wanted Aztec encoding and not QR,
but in the discussions more people wanted QR than Aztec." The Dutch health
ministry found the overhead unacceptable and forked
(minvws/base45-go#1): "we use a base45 encoding that uses the exact same method
as base58, and which has the exact same efficiency as QR binary mode. The EU
variant isn't of the same efficiency as QR binary mode."

For our 130-byte target, concretely, at EC L:

| Encoding | Chars | QR data bits | Version | Modules |
| --- | --- | --- | --- | --- |
| raw byte mode | 130 | 1052 | v6 | 41x41 |
| Base45 -> alphanumeric | 195 | 1086 | v6 | 41x41 |
| Base32 -> alphanumeric | 208 | 1157 | v7 | 45x45 |
| Base64 -> byte mode | 176 | 1420 | v8 | 49x49 |
| uppercase hex -> alphanumeric | 260 | 1443 | v8 | 49x49 |
| Base45 misdetected as byte mode | 195 | 1572 | v9 | 53x53 |

Base45 and raw byte mode land on the same version, with Base45 using 34 more
bits and leaving only 2 bits of headroom under v6's 1088-bit ceiling. The last
row is the practical trap: if any character in the payload falls outside the
45-character alphanumeric set, the encoder drops the whole segment to byte mode
and the result is two versions *worse* than doing nothing.

**Conclusion for us: encode the compacted envelope as raw bytes. Do not
Base45-encode it.** Our current payload is base64url inside an ASCII envelope,
which is the Base64 row of that table — the worst realistic option.

### EU DCC, for the record

The chain is CBOR -> COSE_Sign1 -> ZLIB/DEFLATE -> Base45 -> `"HC1:"` prefix ->
QR, specified in ehn-dcc-development/eu-dcc-hcert-spec `hcert_spec.md` §4.2.1
and §4.2.2. §4.2.2 mandates the mode and recommends the level: "An error
correction rate of 'Q' (around 25%) is RECOMMENDED. The Alphanumeric (Mode
2/QR Code symbols 0010) MUST be used in conjunction with Base45." The
reference implementation asserts on it (`python-hcert` `hcert/optical.py:64-65`).
The Commission Implementing Decision (EU) 2021/1073 Annex I could not be read
directly — EUR-Lex returns a bot challenge — so all DCC citations here are to
the eHN GitHub org rather than to the legal text.

Two empirical findings from the official test vectors
(`eu-digital-green-certificates/dgc-testdata`) are worth carrying over:

- **The deflate step does not compress.** Measured across six national vectors,
  zlib output was *larger* than its input in five of six cases (e.g. SE/1:
  340 -> 345 bytes; BE/1: 336 -> 347). The payload is a high-entropy ECDSA
  signature plus compact CBOR; deflate contributes only its own framing. Any
  compression step we add to a signature-dominated payload will behave the same.
- **`"HC1:"` is not an alphanumeric-mode trick.** The DCC spec contains no such
  argument; the recorded reason (hcert-spec PR #47) is to "mimic a URI scheme
  and prohibit automatic searches when scanned."

### What comparable pairing QRs actually carry

| System | Payload | Type | Length | Version @ L | Half-block @ qz4 | Octant @ qz4 |
| --- | --- | --- | --- | --- | --- | --- |
| WhatsApp multi-device | `https://wa.me/settings/linked_devices#ref,noise,identity,adv,type` | URL (since 2026-05) | 277 chars | v11 | 69x35 | 35x18 |
| Signal device link | `sgnl://linkdevice?uuid=…&pub_key=…&capabilities=…` | app-only URI | 112-137 chars | v6 | 49x25 | 25x13 |
| Discord remote auth | `https://discord.com/ra/<43-char fingerprint>` | URL | ~66 chars | v4 | 41x21 | 21x11 |
| Tailscale | `https://login.tailscale.com/a/<hex>` | URL | 42-46 chars | v3 | **37x19** | 19x10 |
| WireGuard | raw `wg-quick` `.conf` text | opaque, no deep-link | 249-351 bytes | v10-v12 | 73x37 | 37x19 |
| EU DCC | `HC1:` + Base45 | opaque | 481-604 chars | v17-v19 @ Q | — | — |
| **Heeler today** | `HERDR-PAIR:1:<base64url JSON>` | opaque | 308 chars | v11 | 69x35 | 35x18 |

Sources: whatsmeow `pair.go:115-120` (the exact `fmt.Sprintf` with five
comma-separated base64 fields; the URL wrapper and fifth field were added
2026-05-11 in commit `876de1e9` — before that it was an opaque 237-char string);
Signal-Desktop `ts/util/signalRoutes.std.ts:335-359` and signal-cli
`DeviceLinkUrl.java:47-57`; Tailscale `util/qrcodes/qrcodes.go:25` (EC level M,
hardcoded) and the URL shapes documented at `cmd/tailscale/cli/up.go:274`.
Discord's format has **no primary source** — `discord/discord-api-docs` has zero
hits for `/ra/` or `remote_auth`, and the only documentation is the
community reverse-engineering project `discord-userdoccers`; treat it as
low-confidence. WireGuard has three negative results worth recording: the
official `wireguard-tools` repo has zero hits for `qrencode`/`qrcode`, both
official apps only *scan* QRs and never generate them, and the widely repeated
`qrencode -t ansiutf8 < peer.conf` recipe is folklore rather than documentation.

The pattern across the ones that stay small is the same: **the QR carries a
short reference to server-held state, not the credential itself.** Discord's
fingerprint approach is the cleanest — the QR holds only a SHA-256 digest of an
ephemeral public key, the key exchange runs over a separate WebSocket, and the
token flows back through the already-authenticated device. The payload is
constant at ~66 bytes regardless of credential size, and a photographed QR is
not directly usable.

Heeler's envelope is structurally the opposite: it is self-contained precisely
because there is no third party, and the addresses it carries are the thing the
phone needs before it can talk to anything. That is a defensible design, but it
is the reason we are at v11 while Tailscale is at v3.

### Uppercasing to reach alphanumeric mode

Real and well documented, but only for payloads that are already
case-insensitive. BIP-173 (`bip-0173.mediawiki:189-196`) is the canonical
statement: "inside QR codes uppercase SHOULD be used, as those permit the use of
''alphanumeric mode'', which is 45% more compact than the normal ''byte mode''."
Adopted downstream by BOLT11 (`11-payment-encoding.md:38`), LNURL LUD-01
(`01.md:10`), and Cashu NUT-26 (`26.md:18`).

Two corrections that matter if we ever cite this: BIP-173's "45% more compact"
is the wrong direction — 8/5.5 = 1.4545 means alphanumeric fits 45% *more data
per bit*, but the volume reduction is 1 - 5.5/8 = **31.25%**. And RFC 3986
§6.2.2.1 makes only `scheme://host` case-insensitive; path, query, and fragment
are case-sensitive, so uppercasing a whole URL is not generally safe.

For numeric mode there is exactly one production precedent: SMART Health Cards
maps each JWS character to two digits (`docs/index.md:562`) for a documented 20%
gain over byte mode, using a two-segment QR (`shc:/` in byte mode, payload in
numeric mode). And there is one strong counter-example: EMVCo's merchant-
presented QR spec §4.12.1.1 *forbids* everything but byte mode — "all the data
shall be encoded using Byte Mode. Alphanumeric Mode, Numeric mode, Kanji,
Structured Append, and FCN1 mode shall not be used."

None of this applies to us. Our payload is binary; byte mode is already optimal.

## Scannability evidence

### Quiet zone

ISO/IEC 18004:2024 §5.3.1 (readable in the free ISO preview): "The symbol shall
be surrounded on all four sides by a quiet zone border." The clause that states
the width (§5.3.8 in the 2024 numbering, §6.3.8 in 2015) is **not** in the free
preview, so the four-module figure is cited to Denso Wave, the inventor and
spec author: "QR Code requires a four-module wide margin at all sides of a
symbol," and separately "a two-module wide margin is enough for Micro QR Code."

The field evidence is mdp/qrterminal#5, filed by Russ Cox: "the QR spec says
that the code itself must be placed in a 4-pixel-wide white border or 'quiet
zone'... The example on your front page only has a 1-pixel border, which may not
be enough for some readers," followed by a concrete failure — Facebook put a QR
on a roof with an insufficient border, and "many readers I tried back in 2012
could not recognize the code in the image." The maintainer fixed it in v1.0.0.

Note that `QRCode.toString(text, {type:'terminal'})` in node-qrcode — the
library we depend on — ships a 1-module quiet zone and silently ignores the
`margin` option (`lib/renderer/terminal/terminal.js:7` comments out the options
lookup entirely). We do not use that renderer, but it is a reminder that the
dependency will not supply a correct quiet zone for us.

### Polarity: inverted vs white background

ISO/IEC 18004:2024 §5.2 (free preview) is explicit, and contradicts the common
folklore:

> **Reflectance reversal**: Symbols are intended to be read when marked so that
> the image is either dark on light or light on dark... The specifications in
> this document are based on dark images on a light background, therefore in the
> case of symbols produced with reflectance reversal references to dark or light
> modules should be taken as references to light or dark modules respectively.

This capability was added in the 2006 second edition (per the Introduction).
Whether a *conforming decoder* must attempt reversal is in a clause not covered
by the preview and could not be verified.

Decoder reality, however, is split:

| Decoder | Inverted support | Source |
| --- | --- | --- |
| ZXing (Java) | off by default, requires the `ALSO_INVERTED` hint (added in PR #1371, 2021) | `DecodeHintType.java` |
| zxing-cpp | **on by default** | `ReaderOptions.h:113-114`, "Try detecting inverted ('reversed reflectance') codes... (default: true)" |
| zbar | supported but off by default, needs `-Stest-inverted` | `zbar.h:188`; PR #33 |

ZXing's maintainer states in issue #1844 that "inverted QR codes are not
technically valid QR codes" — which is wrong against ISO 18004:2006 and later,
but is an accurate description of what ZXing Java does.

For iOS the evidence is thin and indirect. Apple's `VNDetectBarcodesRequest`
documentation says nothing about polarity. An Apple DTS engineer wrote in
Developer Forums thread 112660 that "Assuming that the barcode symbology
supports white-bars-on-dark-backgrounds, the reading speed should be similar
regardless of the color of the bars," and a 2015 developer report (thread 5376)
confirms inverted QR working under `AVCaptureMetadataOutput`. That points the
right way but is not a guarantee.

**The decisive evidence is a shipped bug fix.** gtanner/qrcode-terminal PR #8
(merged, released as 0.9.5):

> The generated QR codes in the original version didn't work when using a
> terminal with black text on white background. This change makes the library
> use an actual color code for black (or at least dark grey) background for the
> black color, just as it was using the color code for white.

node-qrcode then copied that approach with an explicit comment at
`lib/renderer/terminal/terminal.js:9`: "use same scheme as
https://github.com/gtanner/qrcode-terminal because it actually works! =)". And
node-qrcode's maintainer, on issue #185: "utf8 doesn't contain color information
for the renderer, like ansii escapes do in terminals. Qrcode can't get this
'right' for you because the result is just text."

This matters because the bare-glyph renderers do not agree with each other on
which way is up. libqrencode `-t UTF8`, mdp/qrterminal `GenerateHalfBlock`,
skip2/go-qrcode `ToString`, and gtanner `{small:true}` all render a **dark
module as blank** and a light module as `█` — i.e. they assume a light
foreground on a dark terminal. node-qrcode's `utf8.js` does the exact opposite
(`BB: '█'`). A user with the wrong terminal theme gets a photographic negative
from half of these libraries.

Our `\e[47m\e[30m` wrapper (`terminal-qr.js:13`) sidesteps this entirely by
carrying its own background. Keep it.

Tailscale's `const inverse = false // Modern scanners can read QR codes of any
colour.` deserves a caveat: it was introduced by sfllaw in PR #18182 (merged
2026-01-08) and **no reviewer discussed it**. It is an uncited developer
assertion, not a measured result. Given ZXing Java and zbar both default to *not*
trying inversion, it is optimistic.

### Braille

The evidence is empty rather than negative. A GitHub-wide search found only two
braille QR projects (`kitty-crow/braille-qr`, 0 stars, created 2026-07-28;
`marcus7777/QRinBraillePatternDots`, 2 stars), neither of which states anything
about whether a phone can scan the output. Multiple issue searches for braille
QR scan failures returned nothing.

The mechanical argument against it is strong, though, and comes from the
terminals' own rendering code. Braille glyphs are dots with mandatory gaps and
never fill the cell. xterm.js's rasterizer says so directly
(`CustomGlyphRasterizer.ts:127-141`): "Columns: left=1-2, right=5-6 (leaving 0
and 7 as margins, 3-4 as gap)", and it draws circles with
`radius = Math.min(xEighth, yEighth)` inside an 80%-height inset. Ghostty's
`src/font/sprite/draw/braille.zig` computes `w = min(width/4, height/8)` with
half-spacing margins — same result.

So U+28FF (all eight dots) still does not produce a solid cell, and adjacent
dark modules never merge. ZXing's finder detection depends on the contiguous
1:1:3:1:1 run-length ratio (`FinderPatternFinder.java:186-206`); a 3-module dark
run rendered in braille becomes three dots separated by light gaps, which breaks
that ratio at the binarization stage unless camera blur happens to fill them in.
The existing rejection of braille in `terminal-qr.js:5-6` ("braille... sparse
dots") is well founded.

### Aspect ratio

ISO/IEC 18004:2024 §5.3.1 requires "nominally square modules." No numerical
tolerance appears in the free preview; print-quality tolerances live in the
normatively referenced ISO/IEC 15415, which was not accessible.

The operative number comes from ZXing instead. `FinderPatternFinder.java`
`crossCheckVertical` compares the vertical extent of a candidate finder pattern
against the horizontal extent already measured:

```java
// If we found a finder-pattern-like section, but its size is
// more than 40% different than the original, assume it's a false positive
if (5 * Math.abs(stateCountTotal - originalStateCountTotal) >= 2 * originalStateCountTotal) {
  return Float.NaN;
}
```

That is the anisotropy budget: **±40%**. Downstream, `Detector.java:229-259`
collapses the horizontal and vertical module-size estimates into a single scalar
before `computeDimension` (`:198-217`) snaps the result to `mod 4`, so a
symmetric stretch mostly cancels — but the snap tolerates only ±1. Once the
dimension is right, the full perspective transform absorbs the scaling.

Mapping that onto a terminal cell of width `W` and height `H`:

| Glyph | Modules/cell | Module aspect (h:w) | At `H/W = 2` | At `H/W = 2.2` |
| --- | --- | --- | --- | --- |
| half-block | 1 x 2 | `H / 2W` | 1.00 | 1.10 |
| sextant | 2 x 3 | `2H / 3W` | 1.33 | 1.47 |
| octant | 2 x 4 | `H / 2W` | 1.00 | 1.10 |

Half-blocks and octants are square at nominal metrics and stay well inside the
budget as line height varies. Sextants start at 33% and cross ZXing's 40%
threshold at `H/W = 2.1`. Common monospace metrics (0.6em
advance, 1.2em line height) put `H/W` at exactly 2.0, so sextants would work —
but any terminal or herdr configuration with looser leading eats the remaining
7 percentage points.

### Glyph availability

Verified against `unicode.org/Public/UCD/latest/ucd/DerivedAge.txt`:

```
2500..2595    ; 1.1    box drawing + half/full blocks (▀ ▄ █)
2596..259F    ; 3.2    quadrants
2800..28FF    ; 3.0    braille
1FB00..1FB92  ; 13.0   sextants (1FB00..1FB3B, 60 chars)
1CD00..1CEB3  ; 16.0   octants (1CD00..1CDE5, 230 chars)
```

The octant count confirms our table construction: 230 octant code points plus
the 26 patterns reused from older blocks equals the 256 entries in
`OCTANT_TABLE`, matching `OCTANT_EXCEPTIONS` at `terminal-qr.js:24-32`.

Terminal support, from each terminal's own glyph-synthesis source:

| Terminal | Half-blocks | Sextants | Octants | Source |
| --- | --- | --- | --- | --- |
| Ghostty | yes | yes | yes | `src/font/sprite/draw/{block,symbols_for_legacy_computing,symbols_for_legacy_computing_supplement}.zig` |
| kitty | yes | yes (>=0.19.3) | yes (**0.40.0**, 2025-03-08) | `docs/changelog.rst` |
| WezTerm | yes | yes | yes | `customglyph.rs:3682-3688`, `OCTANT_PATTERNS: [u8; 230]` |
| foot | yes | yes | yes | `box-drawing.c:2287, 2673, 3252` |
| Alacritty | yes | yes | **no** | `builtin_font.rs:31` — range ends at `1fb3b` |
| iTerm2 | yes | yes | **no** | `iTermBoxDrawingBezierCurveFactory.m` — zero hits for "octant" |
| VS Code (xterm.js WebGL) | yes | yes | **no** | `CustomGlyphDefinitions.ts` — has a `1FB00-1FB3B` region, no `1CD00` region |
| Terminal.app | font-dependent, often broken | unknown | unknown | closed source; see below |

Terminal.app has no first-party statement, but gtanner/qrcode-terminal has a
cluster of reports: #21 ("QR code looks strange in my terminal and cannot be
scanned", macOS Terminal + Monaco), where a commenter notes "This is not only an
issue with 'Monaco'. I could reproduce this with almost any monospaced font on
my machine except 'Courier New'", another confirms "It looks strange in the mac
terminal, but displays well in iterm"; plus #32, #23 (Windows cmd), and #44.
So even *half-blocks* — Unicode 1.1 characters — are unreliable on Terminal.app.

**This is the strongest argument against octants**: they render on four
terminals (Ghostty, kitty >= 0.40, WezTerm, foot) and fail on the three most
common ones after those (iTerm2, VS Code, Alacritty). Sextants add all three
back. Octants are 23 months old as of this writing.

## Open questions

- What is the actual cell aspect ratio in the terminals herdr users run? This
  single number decides whether sextants are safe. It should be measured, not
  assumed.
- Can a herdr popup detect the host terminal at all (e.g. via `TERM`,
  `TERM_PROGRAM`, or a DA1 query round-trip through the pane)? Tailscale's
  ioctl approach is unavailable to us, but `TERM_PROGRAM` alone would separate
  iTerm2 and VS Code from Ghostty and kitty, which is most of the decision.
- Is the ~130-byte compacted envelope actually achievable? The estimate assumes
  binary IP addresses, a raw 32-byte fingerprint, and a raw 32-byte seed. If the
  seed can become a 16-byte single-use token that the plugin maps to a key
  locally, the payload drops to ~110 bytes without weakening a 2-minute
  single-use credential — worth checking against ADR 0007.
- Does raising EC from L to M change the real-world scan rate for our render? The
  bullbitcoin evidence says it can be decisive, but that was a print/screen
  scan, not a terminal one.

## Sources

**Specifications**

- ISO/IEC 18004:2024, free preview (clauses 5.1, 5.2, 5.3.1): https://cdn.standards.iteh.ai/samples/83389/dee29007cb62437f9767323e6af02f90/ISO-IEC-18004-2024.pdf
- ISO/IEC 18004:2015, free preview (TOC, §6.2, §6.3.8): https://cdn.standards.iteh.ai/samples/62021/ff5c1d3362cd40268efeaa692b724138/ISO-IEC-18004-2015.pdf
- Denso Wave, quiet zone: https://www.qrcode.com/en/howto/code.html and https://www.qrcode.com/en/codes/microqr.html
- Denso Wave, versions: https://www.qrcode.com/en/about/version.html
- RFC 9285, The Base45 Data Encoding: https://www.rfc-editor.org/rfc/rfc9285.html
- RFC 3986 §3.1, §6.2.2.1: https://www.rfc-editor.org/rfc/rfc3986
- EU DCC hcert spec §4.2.1, §4.2.2: https://github.com/ehn-dcc-development/eu-dcc-hcert-spec/blob/main/hcert_spec.md
- EMVCo QRCPS-MPM v1.1 §4.12.1.1 (byte mode mandated)
- Unicode UCD: https://www.unicode.org/Public/UCD/latest/ucd/DerivedAge.txt and `Blocks.txt`

**Terminal renderers**

- libqrencode `qrenc.c`: https://raw.githubusercontent.com/fukuchi/libqrencode/master/qrenc.c
- mdp/qrterminal: https://github.com/mdp/qrterminal/blob/master/qrterminal.go
- skip2/go-qrcode: https://github.com/skip2/go-qrcode/blob/master/qrcode.go
- node-qrcode: https://github.com/soldair/node-qrcode/tree/master/lib/renderer
- gtanner/qrcode-terminal: https://github.com/gtanner/qrcode-terminal/blob/master/lib/main.js
- Tailscale `util/qrcodes`: https://github.com/tailscale/tailscale/tree/main/util/qrcodes
- qrcp: https://github.com/claudiodangelis/qrcp/blob/main/qr/qr.go

**Decoders**

- ZXing `FinderPatternFinder.java`: https://github.com/zxing/zxing/blob/master/core/src/main/java/com/google/zxing/qrcode/detector/FinderPatternFinder.java
- ZXing `Detector.java`: https://github.com/zxing/zxing/blob/master/core/src/main/java/com/google/zxing/qrcode/detector/Detector.java
- zxing-cpp `ReaderOptions.h`: https://github.com/zxing-cpp/zxing-cpp/blob/master/core/src/ReaderOptions.h
- zbar `zbar.h`, PR #33: https://github.com/mchehab/zbar
- ZXing issues #1378, #1844; PR #1371

**Payload formats**

- whatsmeow `pair.go`, `client_test.go`: https://github.com/tulir/whatsmeow
- Signal-Desktop `ts/util/signalRoutes.std.ts`; signal-cli `DeviceLinkUrl.java`
- libsignal `rust/core/src/curve.rs`, `rust/net/src/proto/chat_provisioning.proto`
- BIP-173: https://github.com/bitcoin/bips/blob/master/bip-0173.mediawiki
- SMART Health Cards `docs/index.md`: https://github.com/smart-on-fhir/health-cards
- Netnod/base45 issue #4; minvws/base45-go issue #1
- nayuki/QR-Code-generator (capacity tables): https://github.com/nayuki/QR-Code-generator

**Field reports**

- mdp/qrterminal#5 (quiet zone, Russ Cox), PR #8
- gtanner/qrcode-terminal PR #8 (forced background), issues #21, #23, #32, #44
- soldair/node-qrcode issues #33, #127, #185
- tailscale/tailscale issue #12935, PRs #17084, #18182
- sparrowwallet/sparrow#1358; SatoshiPortal/bullbitcoin-mobile#2049
- Apple Developer Forums threads 112660, 5376

**Could not be accessed**

- ISO/IEC 18004 §5.3.8 / §6.3.8 (quiet zone width) and the decoder conformance
  clauses — behind the ISO paywall; the free preview stops short of both.
- Commission Implementing Decision (EU) 2021/1073 Annex I — EUR-Lex returns a
  bot challenge to non-browser clients.
- Discord's remote-auth protocol — no first-party documentation exists.
