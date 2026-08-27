# Issue #247 Live Activity redesign

Status: Implementation-ready
Date: 2026-08-27
Issue: [#247](https://github.com/zingerbee/Heeler/issues/247)
Scope: visual and interaction spec for `Sources/HeelerWidgets/AgentLiveActivityWidget.swift` only. Wire contract, encryption, start/update/end, and row ordering are unchanged (ADR 0014, `docs/agents/live-activity-contract.md`).

This is not a one-line color swap. Light Mode is broken because the banner is a branded dark slab that ignores the system appearance, and the status inks were authored only for that slab. The redesign keeps Heeler's herdr-aligned status language and the existing aggregate list, and makes the Lock Screen presentation native, calm, information-dense, and legible in both appearances.

## Problem

Heeler's Lock Screen Live Activity always paints Catppuccin Mocha mantle (`#181825`) via `.activityBackgroundTint(AgentActivityChrome.backgroundTint)` in `AgentLiveActivityWidget.swift`. In iOS Light Mode the card sits on a light wallpaper as a dark island. Issue #247 reports that as inconsistent with system appearance: Light Mode should be a light banner with dark, legible text; Dark Mode may keep a dark banner; status chips, links, and the system End control must keep contrast in both.

The widget comment at `AgentActivityStatusStyle` states the reason: Live Activities "sit on the dark tint below, so the light-mode latte inks would disappear." That is circular. The mocha pastels were chosen because the background was hardcoded dark. On a light surface those same pastels fail WCAG:

| Pair | Contrast | Threshold |
| --- | --- | --- |
| Mocha working `#F9E2AF` on white | 1.27:1 | fails 4.5:1 text |
| Mocha done `#A6E3A1` on white | 1.49:1 | fails 4.5:1 text |
| Mocha blocked `#F38BA8` on white | 2.32:1 | fails 4.5:1 text |
| Same mocha working on current mantle `#181825` | 13.81:1 | passes, which is why Dark Mode currently looks fine |

The Console already solved this with `AgentStatusPalette`: Mocha on dark, Latte on light, plus darker Latte *inks* so capsule text clears 4.5:1 (`AgentStatusPaletteTests.inksStayLegibleOnTheirWashes`). The widget never received that split.

## Current-state constraints

Grounded in issue #247, ADR 0014, `docs/agents/live-activity-contract.md`, and `Sources/HeelerWidgets/AgentLiveActivityWidget.swift`.

- **One Live Activity per Host, aggregate list.** Not one activity per Agent. Envelope order is pin-aware, then `blocked > done > working`. The widget must not re-sort.
- **Eligible statuses on the wire:** `working`, `blocked`, `done`. Idle and unknown are hidden. There is no `error`, `waiting`, or `disconnected` string in `ContentState`.
- **Lock Screen budget:** ~160 pt height (Apple may truncate above that). Four two-line rows when `counts.total <= 4`, else three rows plus `+N more`. Horizontal padding is already 14 pt (HIG standard). Vertical padding 12 pt. Row spacing 8 pt.
- **Hierarchy per row:** task `title` on top (status glyphs stripped), identity (`name` else `kind`) indented beneath; missing title promotes identity. Host name is never rendered.
- **Deep links:** each row is a `Link` to that Agent's detail (`heeler://agent/{hostID}/{paneID}`). Taps outside a row, and every Dynamic Island compact/minimal tap, open the Console (`heeler://agent/{hostID}`).
- **Counts chips** in urgency order: blocked, working, done. Zero counts omitted. Chips are `fixedSize()` so the title truncates first.
- **Blocked is the only "please look" state:** title uses status ink, row gets a 6 pt continuous rounded wash. Working and done are painted, not announced as events.
- **Counts-only fallback** when the envelope is absent or undecryptable (Watch Smart Stack, pre-first-unlock, unknown kid). Headline is the generic app name `"Heeler"`.
- **Stale-date** is `timestamp + 900` seconds. `context.isStale` is unused. Ended activities dismiss immediately (`dismissal-date = timestamp`).
- **Dynamic Island background cannot be customized.** HIG: compact, minimal, and expanded sit on an opaque black island. Status color on the island must remain the dark (Mocha) pastels even after Lock Screen Light Mode is fixed.
- **No new dependencies, no contract change, no Host identity, no per-Agent activities.** Widget already compiles `HerdrAPITypes.swift` (so `AgentStatus` exists there) and does not import app-only UI files.
- **iOS 18+, iPhone.** StandBy scales the Lock Screen presentation 2x. Always-On reduces luminance. Physical Lock Screen was not exercised for this spec.

## Research method

Visual references were opened, inspected, and screenshot in an `ego-browser` task space named `issue-247 live activity research`. Search snippets were not treated as evidence. Refero search results were login-walled; Pttrns required signup; `screenlane.com` redirected to Page Flows and had no Live Activity library. Those three sites are recorded as not used.

Contrast figures in this document were computed from the hex values in `AgentStatusPalette` / `AgentActivityStatusStyle` using WCAG 2 relative luminance, not estimated.

## Reference table

| # | URL | Website / product | Observed | Relevance to Heeler |
| --- | --- | --- | --- | --- |
| 1 | [HIG: Live Activities](https://developer.apple.com/design/human-interface-guidelines/live-activities) | Apple | Default Lock Screen is light in Light Mode, dark in Dark Mode. Custom backgrounds "sparingly." Compact/minimal/expanded backgrounds cannot be customized; island is black opaque. 14 pt Lock Screen margin. Medium-or-heavier type. Do not replicate notification layouts. Match the app in *both* appearances. Logo mark without a container; never the full app icon. Compact leading and trailing must read as one fact and open the same screen. Height 84–160 pt. | Primary constraint. Current Mocha mantle is the opposite of "use custom tint sparingly." Island stays black, so Latte inks cannot be used there. |
| 2 | [`activityBackgroundTint(_:)`](https://developer.apple.com/documentation/swiftui/view/activitybackgroundtint(_:)) | Apple | `color: Color?`. "To use the system's default background material, pass `nil`." Pair with `activitySystemActionForegroundColor` when a custom tint is set. | Implementation: pass `nil` for both chrome modifiers. Do not pass `Color.clear`. |
| 3 | [`activitySystemActionForegroundColor(_:)`](https://developer.apple.com/documentation/swiftui/view/activitysystemactionforegroundcolor(_:)) | Apple | End-button text. Pass `nil` for the system default. | Current Mocha text (`#CDD6F4`) is only correct on the hardcoded dark slab. |
| 4 | [HIG: Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode) | Apple | Respect the system appearance. Semantic / dynamic colors. Avoid hard-coded values. Minimum 4.5:1, 7:1 for small custom text. Dark is not a mechanical inversion of Light. | Widget currently ignores Light Mode entirely. Console palette already follows this; widget should too. |
| 5 | [Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities) | Apple | System may truncate above 160 pt. Example uses a *translucent* tint (`.opacity(0.25)`), not an opaque brand fill. Pass `context.isStale`. Accessibility labels are required per presentation. Compact leading/trailing form one cohesive view. | Keep the 4/3-row budget. Surface staleness. Do not add a 25% brand wash; default material is calmer and StandBy-safe. |
| 6 | [WWDC23: Design dynamic Live Activities](https://developer.apple.com/videos/play/wwdc2023/10194/) | Apple | Session framing: glanceable Lock Screen, StandBy, Dynamic Island; chapters at Lock Screen 1:18, StandBy 6:00, Dynamic Island 7:37. Resources point at the HIG and ActivityKit article above. | Confirms Lock Screen is the starting canvas and that island layouts expand from compact, they do not restyle from scratch. |
| 7 | [Live Activities on Zomato App](https://dribbble.com/shots/19855562-Live-Activities-on-Zomato-App) | Dribbble / Zomato | Dark branded banner: restaurant name as secondary, large status verb ("Preparing your order"), ETA as supporting, sequential progress. Designer write-up: glanceable status, mood board, state wireframes. | **Apply:** one glanceable status story, secondary identity. **Do not copy:** opaque branded dark fill, wordmark, or a progress rail (Heeler is not a sequential delivery). |
| 8 | [Live Activity — Bank Card Delivery](https://dribbble.com/shots/26400783-Live-Activity-Bank-Card-Delivery) | Dribbble | Same layout in light *and* dark: light card with near-black title, dark card with white title. Headline is the state. Stepper icons, not a paragraph. Brand mark uncontained, top-leading. | **Apply:** one layout, two appearance palettes; state as headline; identity as secondary. **Do not copy:** rover illustration, stepper, or a custom light gray fill — system material already does that job. |
| 9 | [Flight Tracking Live Activity](https://dribbble.com/shots/23686537-Live-Activity-Dynamic-Island-for-Flight-Tracking-App) | Dribbble | Dark Lock Screen card on a light wallpaper: origin/destination as the two poles, on-time in green, remaining time as the trailing metric, one progress bar. | **Apply:** dark *content* can sit on light wallpaper only when the *card* itself is the system material (this shot still uses an opaque dark card, which is the #247 bug). Green as "on time / done," a single primary metric. **Do not copy:** the dark slab or the progress bar. |
| 10 | [Industry Examples of Live Activities](https://dribbble.com/shots/21011697-Industry-Examples-of-Live-Activities) | Dribbble / OneSignal | Light *and* dark cards in one board. Delivery examples: light surface, small status chip, thin progress. Sports: dense numerals, tiny status dots. Countdown: huge type. Promo cards: rejected by HIG ("don't display ads"). | **Apply:** light cards exist in the wild; chips + dots encode status; density belongs in type, not chrome. **Do not copy:** sale/promo layouts. |
| 11 | [iOS Lock Screen Live Activity (Tier App)](https://dribbble.com/shots/22610933-iOS-Lock-Screen-Live-Activity-Tier-App) | Dribbble | Dark branded banner with a hero number (`20m` / `9.3km`), two caption metrics, wordmark top-trailing. Working vs arrived are two layouts of the same skeleton. | **Apply:** hero number only when one metric *is* the activity (Heeler's analog is the count, and only in compact/minimal). **Do not copy:** hero type on the Lock Screen list, or a dark-only brand plate. |
| 12 | [Live Activities widget — iOS 16](https://dribbble.com/shots/18460566-Live-Activities-widget-iOS-16) | Dribbble / Starbucks | Dark green branded banner on a *light* Lock Screen, wordmark, pickup location. Reads as an app sticker, not a system activity. | **Reject as a model.** This is the same failure mode as Heeler today: brand fill that ignores the wallpaper. |
| 13 | [Apple Design Resources: Live Activities](https://www.figma.com/community/file/1367915437752334285/live-activities) | Figma Community / Apple | Official 2026 kit. Community comment (Kassandra Dower): kit still uses 18 pt Lock Screen margin and 48 pt island radius; HIG is 14 pt and 44 pt. | Trust the HIG numbers, not the kit's older spacing. Heeler already uses 14 pt horizontal padding — keep it. |
| 14 | [Dynamic Island & Live Activities](https://www.figma.com/community/file/1362423678739956425/dynamic-island-live-activities) | Figma Community / Jasper | Pixel-perfect compact / minimal / expanded on black. Compact: circular progress leading, time trailing, snug to the camera. Expanded wraps the camera. Templates for 393 and 430 pt widths. | **Apply:** island content is bold, snug, balanced; compact is a single metric split across the camera. Heeler's split is "urgency count | total count." |
| 15 | [Flighty compact Dynamic Island](https://mobbin.com/screens/4744a5f8-23f1-442b-93e1-0da560854f16) | Mobbin / Flighty | Production compact on a light Home Screen: leading `2:58h` in green, trailing yellow `B22` capsule. Black island, no extra padding against the camera, both sides similar width, color carries meaning. Tagged "Dynamic Island." | **Apply:** island always black; Mocha pastels on black; leading = most urgent live fact, trailing = identity/count. **Do not copy:** gate capsules or airline marks. |
| 16 | [Instacart compact Dynamic Island](https://mobbin.com/screens/fa7b983b-0f8c-4de1-8983-fe18948eac69) | Mobbin / Instacart | Production compact: uncontained carrot mark leading, `1h 16min` trailing, white Home Screen. Quiet. One fact. | **Apply:** no container around a glyph; trailing metric in regular white; do not put a Heeler app icon in a circle. Heeler has no ETA, so the trailing metric stays the agent total. |
| 17 | [Delivery live activity in the Dynamic Island](https://www.behance.net/gallery/164717497/Delivery-live-activity-in-the-Dynamic-Island-on-iPhone) | Behance | Expanded island: brand mark leading, huge "Almost here!", "Arriving at 9:51 AM" secondary, `10 min` trailing, progress rail. Black expanded surface. | **Apply:** expanded is an enlargement of compact (status + metric), not a new poster. **Do not copy:** marketing headline, brand disc, or progress rail. |

Apple HIG Lock Screen gallery (same page as #1) also showed system examples: Food Truck, Maps, Music, Sports, Find Items, Timer. Shared traits: system-sized type, short labels, no decorative chrome, light cards in Light Mode.

## Design principles

1. **System surface, Heeler language.** Lock Screen chrome is the system Live Activity material. Heeler identity lives in status hue (the same Catppuccin roles as the Console and herdr), not in a branded plate.
2. **One appearance model, two palettes.** The layout does not change between Light and Dark. Only tokens flip, the same way `AgentStatusPalette` already does.
3. **Island is a different surface.** Dynamic Island is always black. It keeps Mocha inks even when the Lock Screen is Latte. Do not drive island color from `colorScheme`.
4. **Glance, then identity.** Status and counts are the first read. Task title is the second. Agent name/kind is the third. Host is never shown.
5. **Blocked is the only shout.** Working and done stay quiet. Blocked uses ink on the title and a wash behind the row. Color is never the only signal: VoiceOver already speaks the status word; keep that.
6. **No extra chrome.** No app icon, no wordmark, no progress bar, no map, no buttons. The only actions are the existing deep links and the system End control.
7. **Fit the 160 pt budget; do not fill it.** Four rows when they fit, three plus overflow otherwise. Shorter inventories stay short.
8. **Do not copy another product's artwork.** Distill structure (headline / secondary / metric / snug island) and throw away brand fills, mascots, and steppers.

## Rejected alternatives

| Alternative | Why rejected |
| --- | --- |
| Keep Mocha mantle in Light Mode | This is the bug. HIG default is appearance-adaptive. Mocha working text on white is 1.27:1. |
| Custom Latte crust/base as Light tint, Mocha mantle as Dark tint | HIG: custom tints sparingly. StandBy prefers the default so the activity can scale into the bezel. A Catppuccin fill still reads as a sticker. System material already tracks wallpaper, tinted Lock Screens, and Always-On. |
| `Color.clear` / fully transparent banner | Not the API for "system material." The documented value is `nil`. Clear also kills contrast on busy wallpapers. |
| Translucent brand tint at 0.25 opacity (ActivityKit sample) | Sample is illustrating the modifier, not mandating a brand wash. Heeler has no single brand fill that works on every wallpaper at 0.25. |
| Starbucks / Zomato / Tier opaque brand plate | Same failure as today. Issue #247's expected behavior is system-consistent Light/Dark, not a prettier dark card. |
| Hero number / progress bar / map (Tier, Flighty concept, Uber Eats expanded) | Heeler tracks many Agents, not one trip. ADR 0014 already chose an aggregate list. A fake progress bar would lie. |
| One Live Activity per Agent | Rejected in ADR 0014 (push topology and 160 pt budget). Out of scope. |
| Show Host identity | Contract: never rendered. Wire still carries `host` for producers. |
| Buttons (pause, contact, open) | HIG: one essential control, once-or-pause actions. Heeler's lock-screen action is "open the Agent." `Link` already does that. |
| App icon in a circle | HIG: logo mark without container; never the full icon. Heeler has no lock-screen mark that earns the space; counts do. |
| Latte inks on the Dynamic Island | Island background is black and cannot be changed. Dark Latte inks (`#9F5300`, `#C70030`) on black are the wrong direction (3.5:1 and look like muddy brown/red, not herdr). |
| Mocha pastels as Lock Screen text in Light Mode | 1.27–2.32:1 on white. Console already rejected this; that is why Latte inks exist. |
| Replicate notification layout (app icon + title + body) | HIG: don't. Keep the two-line agent list. |

## Semantic tokens

Prefer system / dynamic colors wherever they satisfy the intent. Custom colors are only the Catppuccin status pair already used in the Console.

### Surfaces and chrome

| Token | Light | Dark | Implementation |
| --- | --- | --- | --- |
| `surface.lockScreen` | System Live Activity material | System Live Activity material | `.activityBackgroundTint(nil)` |
| `action.systemEnd` | System default | System default | `.activitySystemActionForegroundColor(nil)` |
| `surface.island` | Opaque black (system) | Opaque black (system) | Do not tint. Cannot be customized. |
| `text.primary` | `Color.primary` | `Color.primary` | System. On the island this is light-on-black. |
| `text.secondary` | `Color.secondary` | `Color.secondary` | Overflow, identity, counts-only caption. |
| `text.blocked` | Status ink (below) | Status ink (below) | Only on blocked titles. |

Remove `AgentActivityChrome.backgroundTint` and `AgentActivityChrome.systemAction`. Do not replace them with other hexes.

### Status (same hues as `AgentStatusPalette`)

Wash = capsule / row fill. Ink = text, dots, compact glyphs.

| Status | Role | Dark (Mocha) | Light (Latte) |
| --- | --- | --- | --- |
| blocked | wash | `#F38BA8` | `#D20F39` |
| blocked | ink | `#F38BA8` | `#C70030` |
| done | wash | `#A6E3A1` | `#40A02B` |
| done | ink | `#A6E3A1` | `#0D7900` |
| working | wash | `#F9E2AF` | `#DF8E1D` |
| working | ink | `#F9E2AF` | `#9F5300` |
| idle / unknown / other | wash | `#7F849C` | `#6C6F85` |
| idle / unknown / other | ink | `#A6ADC8` | `#5C5F77` |

Unknown strings in the envelope (defensive) use the muted pair, never blocked or done. Idle never appears in the activity; the muted pair is for `countsOnly` chrome and stale copy.

**Where each pair applies:**

- **Lock Screen:** resolve from `colorScheme` / `UITraitCollection.userInterfaceStyle`. Light → Latte, Dark → Mocha.
- **Dynamic Island (compact, minimal, expanded):** always Mocha, regardless of system appearance.

**Wash opacity:** 0.15 on Lock Screen chips and blocked-row fills (match `AgentStatusBadge`, which uses 0.15). Island chips may keep 0.22 on the compact blocked capsule so the fill reads on black; 0.16 is too timid there.

### Measured contrast (WCAG 2, sRGB)

Ink on solid surfaces, computed from the hexes above:

| Pair | Ratio | Passes |
| --- | --- | --- |
| Latte working ink on white | 5.66:1 | AA text, AA non-text (dot 3:1) |
| Latte blocked ink on white | 6.05:1 | AA |
| Latte done ink on white | 5.60:1 | AA |
| Latte muted ink on white | 6.25:1 | AA |
| Latte working ink on 0.16 wash over white | 4.90:1 | AA text |
| Latte blocked ink on 0.16 wash over white | 4.59:1 | AA text |
| Mocha working on system dark `#1C1C1E` | 13.39:1 | AA |
| Mocha blocked on system dark | 7.35:1 | AA |
| Mocha working on black (island) | 16.53:1 | AA |
| Mocha blocked on black (island) | 9.07:1 | AA |

Always-On and Increase Contrast were not measured on device. System material and dynamic colors are the mitigation; physical-device check is still required.

## Redesign spec

### Lock Screen anatomy

```
┌──────────────────────────────────────────────┐  14 pt inset
│ [primary row: dot + title                    │
│              identity]          [chips →]    │  header: first agent + chips
│ [row 2: dot + title / identity]              │  8 pt stack spacing
│ [row 3: …]                                   │
│ [row 4 or "+N more"]                         │
│ [optional stale caption]                     │
└──────────────────────────────────────────────┘
  padding: 14 horizontal, 12 vertical
  height: system-sized, never above 160 pt
```

Keep `AgentActivityLockScreenView`'s structure. Changes are tokens, type weight, compact-leading logic (island), stale caption, and previews.

**Header.** First envelope agent is the headline row, same `AgentActivityLinkedRow` as today. Chips stay trailing, `fixedSize()`, never wrap. When `lockScreenAgents` is empty (counts-only), headline is `Text(presentation.headerTitle)` at `.subheadline.weight(.semibold)`, `Color.primary`, `lineLimit(1)`.

**Rows.** Uniform two-line rows in envelope order. Do not enlarge the first row's type relative to the rest; the current "headline is just the first row" treatment is correct for an aggregate list and matches the contract. Blocked wash stays.

**Overflow.** `+\(n) more` at `.caption2`, `text.secondary`. No chevron, no fake disclosure.

**Stale.** If `context.isStale`, a final caption: `May be out of date`, `.caption2`, `text.secondary`. Do not replace rows with this string. Pass `isStale` from `ActivityConfiguration` into the view; it is available on `ActivityViewContext`.

**DEBUG decrypt reason** stays Debug-only.

**Padding.** Keep 14 / 12. Do not "fix" it to the Apple Figma kit's 18 pt.

**Corner / materials.** Do not draw a custom rounded rectangle. The system provides the banner shape. Previews may fake a 22 pt continuous rounded rect so the canvas is readable; that shape is not production chrome.

### Dynamic Island

**Compact.** One fact split across the camera, both sides linking to the Console (already true; keep it).

| Side | Content | Type | Color |
| --- | --- | --- | --- |
| Leading | Highest-urgency *non-zero* count as a snug capsule: blocked, else working, else done | `.caption.weight(.bold).monospacedDigit()` | Mocha ink for that status, 0.22 Mocha wash, `Capsule` |
| Trailing | `counts.total` | `.body.weight(.semibold).monospacedDigit()` | `Color.primary` |

Replace the current generic `ellipsis` labeled "Working". That glyph lies when the inventory is all-done. Accessibility: leading `"\(n) blocked|working|done"`, trailing `"\(total) agents"`.

Keep content snug; no extra padding against the camera. Capsule horizontal padding 5, vertical 1 (already).

**Minimal.** `counts.total`, monospaced. Weight `.bold` when `blocked > 0`, else `.semibold`. Foreground Mocha blocked ink when blocked, else `Color.primary`. No capsule (too wide for the detached pill). Accessibility: `"\(total) agents"` plus `"\(blocked) blocked"` when blocked > 0.

**Expanded.** Keep current regions:

- Center: primary agent as `AgentActivityHeadlineView` (or `"Heeler"` when counts-only), linked to that Agent.
- Bottom: secondary agents (`rowLimit - 1` = 2), overflow line, then chips.

Island type stays slightly larger than Lock Screen rows for the primary (`.subheadline` / `.footnote`) and `.caption` for secondaries. Status dots: 8 pt primary, 7 pt rows. All inks Mocha. Chips Mocha.

**Key line.** `.keylineTint` on the `DynamicIsland`: Mocha blocked ink when `counts.blocked > 0`, else Mocha muted ink `#A6ADC8`. HIG: tint the island key line to match content when the background is dark.

**No** expanded buttons, no leading/trailing expanded artwork, no app icon.

### Typography

HIG: medium weight or higher for key information; small text sparingly.

| Element | Style | Weight | Color |
| --- | --- | --- | --- |
| Lock Screen / expanded title | `.subheadline` (primary), `.caption` (rows) | `.semibold` if blocked, else `.semibold` primary / `.regular` rows | `text.blocked` or `text.primary` |
| Identity line | `.footnote` primary, `.caption` rows | Regular | `text.secondary` |
| Chips | `.caption2` | `.semibold` | Status ink |
| Overflow, stale | `.caption2` | Regular | `text.secondary` |
| Compact trailing / minimal | `.body` | `.semibold` / `.bold` if blocked | See island rules |
| Compact leading | `.caption` | `.bold` | Status ink |

Do not introduce a custom font. System text styles only, so Dynamic Type and the Lock Screen optical size stay native.

### Iconography

- Status **dot**: 8×8 pt primary, 7×7 pt rows, `Circle().fill(ink)`, `accessibilityHidden(true)` (status is in the label).
- **No** SF Symbol app logo. Compact leading is a count, not `ellipsis`.
- If a working-only compact leading needs a glyph because the count is `1` and a single digit looks lost, still show `1` in the capsule. Do not bring the ellipsis back.

### Chips

Unchanged behavior, retokened:

- Render `counts.chipItems` in contract order (blocked, working, done).
- `"\(count) \(status)"` with the status word as the wire string (`blocked`, `working`, `done`), not a localized paraphrase in this pass (the widget is English, matching current copy).
- `fixedSize()`, padding 6 / 2, capsule, ink on 0.15 wash (Lock Screen) or Mocha ink on 0.16–0.22 wash (island).
- Combined accessibility label as today.

### Links and system actions

- Keep `Link` per agent row and `widgetURL` on the banner / compact / minimal for Console.
- Keep `.buttonStyle(.plain)` and `.tint(.primary)` in *previews only*, so canvas Links are not accent-tinted. Production Lock Screen is already chromeless.
- Do not add `Button` / App Intent controls.
- System End: default color (`nil`). Verify on device that the generated End label is readable on both appearances; that is an acceptance item, not a token to pre-empt.

### Truncation

- Titles and names: `lineLimit(1)`, tail truncation. Wire already caps at 80 graphemes; UI still truncates at the row width.
- Chips never compress. Header `Spacer(minLength: 8)` stays so a long title yields to chips, not the reverse.
- Overflow `+N more` is not truncated.
- Compact/minimal: monospaced digits, no shrinking below `.caption` / `.body`. Do not use `minimumScaleFactor` except the existing counts-only island headline (`0.7`).

### Accessibility

- Keep `.accessibilityElement(children: .combine)` on the Lock Screen with the existing narration: primary, chips, remaining rows, overflow.
- Append `"may be out of date"` when `isStale`.
- Status must remain in the spoken string (`"reviewer, blocked, Approve the transport…"`). Dots stay hidden.
- Compact/minimal already have labels; update them to match the new leading (status word, not "Working" for a done-only inventory).
- Do not rely on color alone: blocked wash + semibold + spoken status.
- VoiceOver on a physical Lock Screen was not exercised.

## Content-state matrix

Map the package's requested names onto the *actual* model. Do not invent wire statuses.

| Requested name | Actual model | Lock Screen | Compact / minimal | Expanded |
| --- | --- | --- | --- | --- |
| Working | `status == "working"` in envelope; `counts.working` | Latte/Mocha working ink on the dot; title `text.primary`; no wash | If no blocked: leading shows working count in Mocha yellow capsule | Same row language, Mocha |
| Waiting | **Blocked.** herdr Blocked = waiting for human input (`CONTEXT.md`). No `waiting` string. | Blocked ink on title, 0.15 wash, 6 pt corner, 3/6 pt inset | Leading shows blocked count (highest urgency) | Blocked primary uses Mocha pink title |
| Done | `status == "done"`; `counts.done` | Done ink on the dot only; title stays `text.primary` (state, not "just finished") | Leading shows done count only when blocked = working = 0 | Same |
| Attention / error | **Blocked is attention.** There is no error status in `ContentState`. Unknown envelope strings use muted, never red. | Do not introduce a fourth hue | Do not paint blocked red for decrypt failure | Same |
| Stale / disconnected | (a) `context.isStale` after 15 min without update; (b) `countsOnly` when the envelope cannot be opened | (a) rows remain, caption "May be out of date"; (b) `"Heeler"` + chips, no rows, no fake names | Still show counts. Counts are plaintext and survive (a) and (b). | `"Heeler"` in center when no primary agent |
| Ended | Activity ends immediately (`dismissal-date = timestamp`). No ended presentation. | Not drawn. Do not add a summary banner. | Removed from the island immediately (system). | Removed |

Idle and unknown Agents are not in the activity. An empty eligible inventory ends the activity (ADR 0014). Do not design an idle lock-screen state.

## SwiftUI implementation guidance

Stay inside `Sources/HeelerWidgets/AgentLiveActivityWidget.swift` plus the smallest token sharing needed so widget hues cannot drift from `AgentStatusPalette`.

1. **Chrome.** In `AgentLiveActivityWidget.body`, replace the two modifiers with `nil` (or delete them; default is system material / system End color). Remove `AgentActivityChrome` if nothing else references it.

2. **Pass `context.isStale`** into `AgentActivityLockScreenView` and `AgentActivityIsland.make`. Thread it next to `presentation` and `hostID`. Do not put it on the wire.

3. **Status style.** Replace the mocha-only `AgentActivityStatusStyle.ink(for:)` with two entry points, e.g. `lockScreenInk(for:)` and `islandInk(for:)`, plus matching `wash` colors. Lock Screen uses a dynamic `UIColor` / `Color` that flips Latte/Mocha with `userInterfaceStyle`. Island functions return Mocha only.

4. **Do not invent new hexes.** Reuse the eight status pairs in `AgentStatusPalette`. Preferred: compile `Sources/Heeler/Console/AgentStatusPalette.swift` into the `HeelerWidgets` target (`project.yml` `HeelerWidgets.sources`). It already imports UIKit only and uses `AgentStatus` from `HerdrAPITypes`, which the widget already compiles. Then `Color(status.inkUIColor)` works in the widget. Acceptable fallback if that file pull is awkward: duplicate the hex table in `AgentActivityStatusStyle` with a comment that `AgentStatusPaletteTests` is the source of truth, and add a widget-side test or a shared hex constant file later. Do not add a package.

5. **Compact leading.** Replace the `ellipsis` branch with the first non-zero of `blocked`, `working`, `done`. Keep the capsule treatment.

6. **Previews.** Stop forcing `.environment(\.colorScheme, .dark)` as the only gallery. Provide Light and Dark for at least: mixed + overflow, single working, counts-only, blocked-primary, stale (fake `isStale: true`), long title (80 graphemes). Light previews use a light rounded rect approximating system material, not Mocha mantle. Keep `.buttonStyle(.plain)` and `.tint(.primary)`.

7. **No new frameworks.** No extra SF Symbols catalog, no extra fonts, no ActivityKit API beyond modifiers already in the file plus `keylineTint` and `isStale`.

8. **Contract and coordinator stay put.** Do not change envelope shape, chip copy, row caps, deep links, or dismissal policy.

Sketch (illustrative, not to paste blindly):

```swift
ActivityConfiguration(for: AgentActivityAttributes.self) { context in
    AgentActivityLockScreenView(
        presentation: AgentActivityDecryptor.presentation(for: context.state),
        hostID: context.attributes.hostID,
        isStale: context.isStale
    )
    .activityBackgroundTint(nil)
    .activitySystemActionForegroundColor(nil)
} dynamicIsland: { context in
    AgentActivityIsland.make(
        presentation: AgentActivityDecryptor.presentation(for: context.state),
        hostID: context.attributes.hostID
    )
}
```

Widget `Link` views remain; `AgentActivityLinked` / `AgentActivityConsoleLinked` stay as the MainActor `widgetURL` seam.

## Preview and acceptance matrix

Xcode canvas previews are the development check. They **do not** replace a physical Lock Screen. Label every Lock Screen row below as **device-required**.

| # | Case | Light | Dark | Where | Pass if |
| --- | --- | --- | --- | --- | --- |
| P1 | Mixed blocked / working / done + overflow | Canvas | Canvas | Lock Screen preview | Light banner is light; chips and dots use Latte inks; blocked row wash is visible; `+N more` secondary |
| P2 | Single unnamed working | Canvas | Canvas | Lock Screen | Identity-only row, no wash, working dot visible |
| P3 | Four rows, all fit | Canvas | Canvas | Lock Screen | No overflow line; four two-line rows; height feels inside 160 pt |
| P4 | Counts-only | Canvas | Canvas | Lock Screen | Headline "Heeler", chips only, no ghost rows |
| P5 | Long title (80 graphemes) + three chips | Canvas | Canvas | Lock Screen | Title truncates; chips fully visible |
| P6 | Stale | Canvas | Canvas | Lock Screen | Caption "May be out of date"; rows still shown |
| P7 | Blocked compact | Canvas (island is always dark) | — | Compact | Leading blocked count capsule, trailing total, both Console links |
| P8 | Working-only compact (no blocked) | Canvas | — | Compact | Leading working count, not an ellipsis |
| P9 | Done-only compact | Canvas | — | Compact | Leading done count, not "Working" |
| P10 | Minimal blocked | Canvas | — | Minimal | Total in blocked Mocha ink, bold |
| P11 | Expanded mixed | Canvas | — | Expanded | Primary + up to two secondaries + chips; Mocha inks; key line blocked when blocked > 0 |
| P12 | Contrast, Light Lock Screen | Compute + canvas | — | Lock Screen | Ink/wash pairs match the table (≥ 4.5:1 text, ≥ 3:1 dots) |
| P13 | Contrast, Dark Lock Screen | — | Compute + canvas | Lock Screen | Mocha inks on system dark |
| P14 | Contrast, island | — | Compute | Compact/minimal/expanded | Mocha inks on black |
| D1 | Light Mode Lock Screen on device | **Device-required** | | Lock Screen | Banner is light; End control readable; wallpaper not fighting a dark slab |
| D2 | Dark Mode Lock Screen on device | | **Device-required** | Lock Screen | Dark system material, not necessarily `#181825`; chips readable |
| D3 | Always-On reduced luminance | **Device-required** | **Device-required** | Lock Screen | Status dots still distinguishable |
| D4 | Increase Contrast | **Device-required** | **Device-required** | Lock Screen | No lost text on washes |
| D5 | StandBy (Lock Screen ×2) | **Device-required** | **Device-required** | StandBy | Default material blends; 14 pt inset does not clip |
| D6 | Tap row / tap chrome | **Device-required** | | Lock Screen | Row → Agent detail; outside row → Console |
| D7 | Compact tap both sides | **Device-required** | | Dynamic Island | Both sides → Console |
| D8 | Light Mode while island is showing | **Device-required** | | Dynamic Island | Island stays black with Mocha inks; Lock Screen (if shown) is Latte |

Not exercised in this research pass: physical device, Always-On, StandBy, Increase Contrast, VoiceOver, Night Mode StandBy, Watch Smart Stack. Canvas previews in Xcode were not generated here (no builds, per package).

## Decisions for implementation

No remaining product choices. Implement the following as specified:

1. Lock Screen background = system material (`activityBackgroundTint(nil)`). End button = system color (`activitySystemActionForegroundColor(nil)`).
2. Lock Screen status tokens = existing `AgentStatusPalette` Latte/Mocha pairs, dynamic with appearance. Island status tokens = Mocha only.
3. Keep the aggregate list, four/three-row budget, pin-aware envelope order, two-line title/identity, no Host name, existing deep links, no buttons, no logo, no progress bar.
4. Compact leading = highest-urgency non-zero count (blocked, else working, else done). Never the working ellipsis.
5. Show `May be out of date` when `context.isStale`. Do not add ended, error, waiting, or disconnected presentations.
6. Chip wash opacity 0.15 on Lock Screen; blocked-row wash 0.15; island compact capsule 0.22.
7. 14 pt horizontal, 12 pt vertical, 8 pt Lock Screen stack spacing, 7/8 pt dots.
8. Share or duplicate `AgentStatusPalette` hexes; do not pick new hues.
9. Add Light *and* Dark canvas previews, including stale and long titles.
10. Physical Lock Screen Light/Dark remains a required acceptance check before treating #247 as done.

Wire contract, ADR 0014, plugin, and relay are out of scope.
