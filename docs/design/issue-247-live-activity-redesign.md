# Issue #247 Live Activity redesign

Status: Implemented; identity decisions superseded by #260
Date: 2026-08-27
Issue: [#247](https://github.com/zingerbee/Heeler/issues/247)
Scope: widget UI in `Sources/HeelerWidgets/AgentLiveActivityWidget.swift`, Lock Screen row-cap helpers in `Sources/HeelerWidgets/AgentActivityDecryptor.swift`, compiling the existing `Sources/Heeler/Console/AgentStatusPalette.swift` into the widget target, and the `project.yml` / `Heeler.xcodeproj` regeneration that target change requires. Wire contract, encryption, start/update/end, envelope row ordering, and chip enumeration order are unchanged (ADR 0014, `docs/agents/live-activity-contract.md`).

> Issue #260 later superseded this document's row identity, hierarchy, spacing,
> and Blocked-background decisions. Current Live Activity rows render
> a colored status dot beside `workspace`, with `friendly kind` underneath,
> identical leading alignment, and no row background. ADR 0014 and
> `docs/agents/live-activity-contract.md` are authoritative; the system-color,
> link, lifecycle, and row-budget decisions below still apply.

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
- **Attention order is Blocked, then Done, then Working.** Console sort buckets and the Live Activity envelope both use this because Blocked is waiting on an answer, Done has a result to read, and Working needs nothing (`Sources/Heeler/Console/ConsoleAgent.swift` `consoleSortBucket`; `docs/agents/live-activity-contract.md`). Any widget presentation that shows a *single* status count uses this order. Chip capsules are different: they enumerate every non-zero count and keep today's order (`blocked`, `working`, `done` in `chipItems`).
- **Eligible statuses on the wire:** `working`, `blocked`, `done`. Idle and unknown are hidden. There is no `error`, `waiting`, or `disconnected` string in `ContentState`. The widget cannot represent disconnection as its own state (see Content-state matrix).
- **Lock Screen budget:** Apple may truncate above 160 pt. The first row keeps the two-line hierarchy; up to three secondary rows use a compact single line. The Lock Screen shows at most four independently linked rows, with overflow and stale state sharing one caption2 line. Padding is 14 pt horizontal / 8 pt vertical; row spacing is 2 pt.
- **Hierarchy per row:** task `title` on top (status glyphs stripped), identity (`name` else `kind`) indented beneath; missing title promotes identity. Host name is never rendered.
- **Deep links:** each row is a `Link` to that Agent's detail (`heeler://agent/{hostID}/{paneID}`). Taps outside a row, and every Dynamic Island compact/minimal tap, open the Console (`heeler://agent/{hostID}`).
- **Counts chips** enumerate non-zero counts in existing `chipItems` order (`blocked`, `working`, `done`). Zero counts omitted. Chips are `fixedSize()` so the title truncates first.
- **Blocked is the only "please look" visual.** Title uses status ink, row gets a 6 pt continuous rounded wash. Done outranks Working for compact-leading *count* selection but stays quiet on the list (dot only, no wash). Working is painted, not announced as an event.
- **Counts-only fallback** when the envelope is absent or undecryptable (Watch Smart Stack, pre-first-unlock, unknown kid). Headline is the generic app name `"Heeler"`. This is not a disconnected state.
- **Stale content** is `context.isStale` from ActivityKit. Push updates set `stale-date = timestamp + 900`. Local `Activity.request` / `activity.update` from the app use `staleDate: nil` (`LiveActivityControlling.swift`), so a locally driven activity does not become stale on that timer. Ended activities dismiss immediately (`dismissal-date = timestamp`).
- **Dynamic Island background cannot be customized.** HIG: compact, minimal, and expanded sit on an opaque black island. Status color on the island must remain the dark (Mocha) pastels even after Lock Screen Light Mode is fixed. Shared row/chip views must take an explicit surface so Light Mode cannot feed them Latte inks.
- **No new dependencies, no contract change, no Host identity, no per-Agent activities.** Widget already compiles `HerdrAPITypes.swift` (so `AgentStatus` exists there). `AgentStatusPalette.swift` is the single hex owner and is compiled into the widget target (see Palette ownership).
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
| 14 | [Dynamic Island & Live Activities](https://www.figma.com/community/file/1362423678739956425/dynamic-island-live-activities) | Figma Community / Jasper | Pixel-perfect compact / minimal / expanded on black. Compact: circular progress leading, time trailing, snug to the camera. Expanded wraps the camera. Templates for 393 and 430 pt widths. | **Apply:** island content is bold, snug, balanced; compact is a single metric split across the camera. Heeler's split is "attention count | total count." |
| 15 | [Flighty compact Dynamic Island](https://mobbin.com/screens/4744a5f8-23f1-442b-93e1-0da560854f16) | Mobbin / Flighty | Production compact on a light Home Screen: leading `2:58h` in green, trailing yellow `B22` capsule. Black island, no extra padding against the camera, both sides similar width, color carries meaning. Tagged "Dynamic Island." | **Apply:** island always black; Mocha pastels on black; leading = most attention-worthy live fact, trailing = identity/count. **Do not copy:** gate capsules or airline marks. |
| 16 | [Instacart compact Dynamic Island](https://mobbin.com/screens/fa7b983b-0f8c-4de1-8983-fe18948eac69) | Mobbin / Instacart | Production compact: uncontained carrot mark leading, `1h 16min` trailing, white Home Screen. Quiet. One fact. | **Apply:** no container around a glyph; trailing metric in regular white; do not put a Heeler app icon in a circle. Heeler has no ETA, so the trailing metric stays the agent total. |
| 17 | [Delivery live activity in the Dynamic Island](https://www.behance.net/gallery/164717497/Delivery-live-activity-in-the-Dynamic-Island-on-iPhone) | Behance | Expanded island: brand mark leading, huge "Almost here!", "Arriving at 9:51 AM" secondary, `10 min` trailing, progress rail. Black expanded surface. | **Apply:** expanded is an enlargement of compact (status + metric), not a new poster. **Do not copy:** marketing headline, brand disc, or progress rail. |

Apple HIG Lock Screen gallery (same page as #1) also showed system examples: Food Truck, Maps, Music, Sports, Find Items, Timer. Shared traits: system-sized type, short labels, no decorative chrome, light cards in Light Mode.

## Design principles

1. **System surface, Heeler language.** Lock Screen chrome is authored to follow the device's iOS Light/Dark appearance. Heeler identity lives in status hue (the same Catppuccin roles as the Console and herdr), not in a branded plate. On iOS 26 and 27, ActivityKit can incorrectly report `.dark` through SwiftUI in system Light Mode; the widget therefore uses unresolved UIKit semantic colors rather than that environment value. iOS 27 can also fail to invalidate an existing Live Activity after the system appearance changes. There is no public appearance-refresh API, so issue #247 remains open pending an Apple fix.
2. **One appearance model, two palettes, one hex owner.** The layout does not change between Light and Dark. Only tokens flip, from `AgentStatusPalette`. The widget never duplicates those hexes.
3. **Island is a different surface.** Dynamic Island is always black. It keeps Mocha inks even when the Lock Screen is Latte. Shared views take an explicit `AgentActivitySurface`; they must not read ambient `colorScheme` to pick status color.
4. **Attention order is Blocked, then Done, then Working.** Same as Console and the envelope. Compact leading and any other single-count pick follow it. Blocked is the only shouted *visual* (wash + ink title).
5. **Glance, then identity.** Status and counts are the first read. Task title is the second. Agent name/kind is the third. Host is never shown.
6. **Rows deep-link to Agents.** No app icon, wordmark, progress bar, map, or action buttons. Apple supports multiple `Link` controls in Lock Screen and expanded Live Activity presentations. One to three rows use the default 44 pt iOS control height; four rows use Apple's 28 pt minimum dense control height. Taps outside a row open Console.
7. **Fit the 160 pt budget; do not fill it.** Lock Screen shows up to four rows using compact secondary rows, with overflow and the stale caption sharing one caption2 line. Shorter inventories stay short.
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
| Duplicate the hex table in the widget | Two owners drift. `AgentStatusPalette` is the single owner; the widget compiles that file. |
| Drive island inks from `colorScheme` / dynamic `UIColor` | Light Mode would select Latte on the black island. Surface is an explicit parameter, not the ambient appearance. |
| Compact leading `blocked`, else `working`, else `done` | Reverses Console/envelope attention. Done has a result to read; Working needs nothing. |
| Four rows plus a separate stale caption | Exceeds the existing ~160 pt ceiling. Stale reduces the row cap and shares the overflow line. |
| Infer "disconnected" from counts-only | Counts-only is decrypt/envelope failure, not Host connection. The widget has no disconnected field. |
| Replicate notification layout (app icon + title + body) | HIG: don't. Keep the two-line agent list. |

## Palette ownership

**One owner: `Sources/Heeler/Console/AgentStatusPalette.swift`.** Do not duplicate hexes in `AgentActivityStatusStyle`. Do not extract a third constants file.

The widget appex cannot link the app target. Compile the palette file into the widget the same way `HerdrAPITypes.swift` already is:

1. In `project.yml`, under `HeelerWidgets.sources`, add:
   `Sources/Heeler/Console/AgentStatusPalette.swift`
2. Regenerating the committed Xcode project is required. CI builds `Heeler.xcodeproj` and never runs xcodegen (`CLAUDE.md`). After the `project.yml` edit, run `xcodegen generate` (the `Makefile` `PROJECT` path already does this on documented `make` targets) and **commit the regenerated `Heeler.xcodeproj`** alongside `project.yml`.
3. Do not change `AgentStatusPalette`'s Mocha/Latte values. App `AgentStatusPaletteTests` remains the hex and contrast source of truth.

`AgentStatusPalette` exposes dynamic `UIColor`s that follow `userInterfaceStyle`. That is correct for Lock Screen and **wrong** for the island. The widget must not pass `Color(status.inkUIColor)` into island views. Resolution goes through the surface seam below.

### Surface seam

```swift
enum AgentActivitySurface {
    /// Lock Screen banner. Status colors follow the system appearance
    /// (Latte in Light, Mocha in Dark) via AgentStatusPalette.
    case lockScreen
    /// Compact, minimal, and expanded Dynamic Island. Always Mocha,
    /// resolved against a dark trait collection, ignoring ambient Light Mode.
    case island
}
```

`AgentActivityStatusStyle` is the only widget API for status color. It takes `surface` on every call:

```swift
enum AgentActivityStatusStyle {
    static func ink(for status: String, on surface: AgentActivitySurface) -> Color
    static func wash(for status: String, on surface: AgentActivitySurface) -> Color
}
```

- `.lockScreen` → `Color(uiColor: AgentStatus(rawValue:).inkUIColor)` / `tintUIColor` (dynamic).
- `.island` → the same `UIColor`, then `.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))` before wrapping in `Color`. Ambient Light Mode cannot select Latte.

Unknown status strings use the muted pair, same as the palette's `default`.

### Shared components that must take `surface`

These views render on both Lock Screen and expanded island today. Each gains a `surface: AgentActivitySurface` parameter and passes it into `AgentActivityStatusStyle` and any child. No default: a missing argument is a compile error, which is the point.

| View | Lock Screen call site | Island call site |
| --- | --- | --- |
| `AgentActivityRowView` | header + compact `ForEach` | Expanded `ForEach` of `secondaryAgents` |
| `AgentActivityHeadlineView` | not used on Lock Screen | Expanded `.center` |
| `AgentActivityCountChips` | Lock Screen header trailing | Expanded `.bottom` |

Island-only views (`AgentActivityCompactLeading`, compact trailing, minimal) pass `.island` into `AgentActivityStatusStyle` directly. They never use `Color(status.inkUIColor)` unscoped.

Rows are presentation-only. The Lock Screen view and `DynamicIsland` each apply one Console `widgetURL` to their complete presentation.

## Semantic tokens

Prefer system / dynamic colors wherever they satisfy the intent. Custom colors are only the Catppuccin status pair already owned by `AgentStatusPalette`.

### Surfaces and chrome

| Token | Light | Dark | Implementation |
| --- | --- | --- | --- |
| `surface.lockScreen` | Dynamic `UIColor.systemBackground` | Dynamic `UIColor.systemBackground` | Keep unresolved; draw it in the root view and also pass it to `.activityBackgroundTint` |
| `action.systemEnd` | Dynamic `UIColor.label` | Dynamic `UIColor.label` | Keep unresolved and pass through `Color(uiColor:)` to `.activitySystemActionForegroundColor` |
| `surface.island` | Opaque black (system) | Opaque black (system) | Do not tint. Cannot be customized. |
| `text.primary` | `Color.primary` | `Color.primary` | System. On the island this is light-on-black. |
| `text.secondary` | `Color.secondary` | `Color.secondary` | Overflow, identity, stale caption. |
| `text.blocked` | Status ink for `.lockScreen` or `.island` | Status ink for that surface | Only on blocked titles. |

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

Unknown strings in the envelope (defensive) use the muted pair, never blocked or done. Idle never appears in the activity; the muted pair is for counts-only chrome and stale copy.

**Where each pair applies** is `AgentActivitySurface`, not a comment on the call site:

- **`.lockScreen`:** Light → Latte, Dark → Mocha, via the palette's dynamic `UIColor`.
- **`.island`:** always Mocha, via dark-trait resolution.

**Wash opacity:** 0.15 on Lock Screen chips and blocked-row fills (match `AgentStatusBadge`, which uses 0.15). Island compact capsule uses 0.22 Mocha wash so the fill reads on black.

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
│ [row 2: dot + title · identity]               │  5 pt stack spacing
│ [row 3: …]                                   │
│ [row 4 / trailing caption2]                   │  see row-cap rules
└──────────────────────────────────────────────┘
  padding: 14 horizontal, 10 vertical
  height: system-sized, never above 160 pt
```

Keep `AgentActivityLockScreenView`'s stack. Changes are tokens, `surface: .lockScreen` on shared views, row deep links, a single trailing caption2, and previews.

**Header.** First visible agent is the full-density `AgentActivityRowView(..., surface: .lockScreen)`. Chips stay trailing, `AgentActivityCountChips(..., surface: .lockScreen)`, `fixedSize()`, never wrap. When no agents are visible (counts-only), headline is `Text(presentation.headerTitle)` at `.subheadline.weight(.semibold)`, `Color.primary`, `lineLimit(1)`.

**Rows.** The first row retains title over identity. Secondary rows place `title · identity` on one line in envelope order. Blocked wash stays. Each row is a full-width `Link` to that Agent; the complete activity keeps a Console `widgetURL` fallback for taps outside the rows.

**Row cap and overflow (stale-aware).** Replace the current `lockScreenAgents` / `lockScreenOverflowCount` (which key only on `counts.total`) with helpers that also take `isStale`. Suggested shape on `AgentActivityPresentation`:

```swift
func lockScreenAgents(isStale: Bool) -> [AgentActivityDetails.AgentDetail]
func lockScreenOverflowCount(isStale: Bool) -> Int
```

Cap:

| `isStale` | `counts.total` | Visible agent rows | Trailing caption2 |
| --- | --- | --- | --- |
| false | 0 | 0 (counts-only headline) | none, unless Debug decrypt copy |
| false | 1…4 | `total` (all fit) | none |
| false | ≥ 5 | 4 | `+N more` (`N = total − 4`) |
| true | 0 | 0 | `May be out of date` |
| true | 1…4 | `total` | `May be out of date` |
| true | ≥ 5 | 4 | `+N more · May be out of date` (`N = total − 4`) |

Overflow count is always `max(0, counts.total − visibleRows)` and is zero in counts-only, same as today.

Overflow and stale share one `.caption2` / `text.secondary` line, with a middle dot (` · `) when both apply. Do not draw a separate stale line. When `isStale && total >= 5`, show four rows and fold overflow into the trailing line.

**Maximum-height cases (all must stay ≤ 160 pt):**

1. Fresh, `total == 4`: one full row plus three compact rows, no caption2.
2. Fresh, `total >= 5`: one full row plus three compact rows and `+N more`.
3. Stale, `total >= 5`: one full row plus three compact rows and `+N more · May be out of date`.

DEBUG decrypt reason stays Debug-only and is out of the production height budget.

**Padding.** Keep 14 / 10. Do not "fix" it to the Apple Figma kit's 18 pt.

**Corner / materials.** Do not draw a custom rounded rectangle. The system provides the banner shape. Previews may fake a 22 pt continuous rounded rect so the canvas is readable; that shape is not production chrome.

**`isStale` is Lock Screen-only.** Pass `context.isStale` into `AgentActivityLockScreenView`. Do not add it to `AgentActivityIsland.make`. Island presentations do not show a stale caption.

### Dynamic Island

Island builders pass `surface: .island` into every shared row, headline, and chip. Compact and minimal call `AgentActivityStatusStyle` with `.island` directly.

**Compact.** One fact split across the camera. The whole presentation uses the same Console `widgetURL`.

| Side | Content | Type | Color |
| --- | --- | --- | --- |
| Leading | First non-zero count in attention order: blocked, else done, else working | `.caption.weight(.bold).monospacedDigit()` | Mocha ink for that status, 0.22 Mocha wash, `Capsule` |
| Trailing | `counts.total` | `.body.weight(.semibold).monospacedDigit()` | `Color.primary` |

Replace the current generic `ellipsis` labeled "Working". That glyph lies when the inventory is all-done, and picking Working before Done hid a result the user can read. Accessibility: leading `"\(n) blocked|done|working"`, trailing `"\(total) agents"`.

Keep content snug; no extra padding against the camera. Capsule horizontal padding 5, vertical 1 (already).

**Minimal.** `counts.total`, monospaced. Weight `.bold` when `blocked > 0`, else `.semibold`. Foreground Mocha blocked ink when blocked, else `Color.primary`. No capsule (too wide for the detached pill). Accessibility: `"\(total) agents"` plus `"\(blocked) blocked"` when blocked > 0.

**Expanded.** Keep current regions:

- Center: primary agent as `AgentActivityHeadlineView(agent:surface: .island)` (or `"Heeler"` when counts-only).
- Bottom: secondary agents (`rowLimit - 1` = 2) via `AgentActivityRowView(..., surface: .island)`, overflow line, then `AgentActivityCountChips(..., surface: .island)`.
- Interaction: Agent rows use per-Agent `Link` targets in the expanded presentation. One Console `widgetURL` on the complete `DynamicIsland` handles compact, minimal, and expanded chrome taps.

Island type stays slightly larger than Lock Screen rows for the primary (`.subheadline` / `.footnote`) and `.caption` for secondaries. Status dots: 8 pt primary, 7 pt rows. All inks Mocha via `.island`.

**Key line.** `.keylineTint` on the `DynamicIsland`: Mocha blocked ink when `counts.blocked > 0`, else Mocha muted ink `#A6ADC8`. HIG: tint the island key line to match content when the background is dark. Resolve through `AgentActivityStatusStyle` with `.island`.

**No** expanded buttons, no leading/trailing expanded artwork, no app icon, no stale caption.

### Typography

HIG: medium weight or higher for key information; small text sparingly.

| Element | Style | Weight | Color |
| --- | --- | --- | --- |
| Lock Screen / expanded title | `.subheadline` (primary), `.caption` (rows) | `.semibold` if blocked, else `.semibold` primary / `.regular` rows | `text.blocked` or `text.primary` |
| Identity line | `.footnote` primary, `.caption` rows | Regular | `text.secondary` |
| Chips | `.caption2` | `.semibold` | Status ink for the view's `surface` |
| Overflow / stale trailing line | `.caption2` | Regular | `text.secondary` |
| Compact trailing / minimal | `.body` | `.semibold` / `.bold` if blocked | See island rules |
| Compact leading | `.caption` | `.bold` | Status ink on `.island` |

Do not introduce a custom font. System text styles only, so Dynamic Type and the Lock Screen optical size stay native.

### Iconography

- Status **dot**: 8×8 pt primary, 7×7 pt rows, `Circle().fill(ink)`, `accessibilityHidden(true)` (status is in the label).
- **No** SF Symbol app logo. Compact leading is a count, not `ellipsis`.
- If a compact leading count is `1`, still show `1` in the capsule. Do not bring the ellipsis back.

### Chips

Unchanged enumeration, retokened through `surface`:

- Render `counts.chipItems` in existing order (`blocked`, `working`, `done`). This is an inventory, not a single-status pick, so it does not use attention order.
- `"\(count) \(status)"` with the status word as the wire string, not a localized paraphrase in this pass (the widget is English, matching current copy).
- `fixedSize()`, padding 6 / 2, capsule, ink on 0.15 wash (Lock Screen) or Mocha ink on 0.22 wash (compact capsule; expanded chips 0.16 Mocha is acceptable if 0.22 is too loud in the expanded bottom stack — pick 0.16 for expanded chips, 0.22 for compact leading only).
- Combined accessibility label as today.

### Interaction and system actions

- Apply one Console `widgetURL` to the complete Lock Screen view and one to the complete `DynamicIsland`.
- Use full-width per-row `Link` controls. One to three Lock Screen rows use 44 pt minimum height; four rows use the documented 28 pt dense minimum. Link targets must not overlap. Compact and minimal presentations keep one Console target.
- Do not add `Button` / App Intent controls.
- System End: default color (`nil`). Verify on device that the generated End label is readable on both appearances; that is an acceptance item, not a token to pre-empt.

### Truncation

- Titles and names: `lineLimit(1)`, tail truncation. Wire already caps at 80 graphemes; UI still truncates at the row width. This applies to a long `name` on the identity line and to a missing-title row where identity is promoted to the first line.
- Chips never compress. Header `Spacer(minLength: 8)` stays so a long title or promoted name yields to chips, not the reverse.
- Overflow / stale trailing line is not truncated.
- Compact/minimal: monospaced digits, no shrinking below `.caption` / `.body`. Do not use `minimumScaleFactor` except the existing counts-only island headline (`0.7`).

### Accessibility

- Keep `.accessibilityElement(children: .combine)` on the Lock Screen with the existing narration: primary, chips, remaining rows, overflow.
- When stale, append `"may be out of date"` to that combined label (whether or not overflow is on the same visible line).
- Status must remain in the spoken string (`"reviewer, blocked, Approve the transport…"`). Dots stay hidden.
- Compact/minimal already have labels; update leading to the attention-order status word (not "Working" for a done-only or done+working inventory).
- Do not rely on color alone: blocked wash + semibold + spoken status.
- VoiceOver on a physical Lock Screen was not exercised.

## Content-state matrix

Map the package's requested names onto the *actual* model. Do not invent wire statuses.

| Requested name | Actual model | Lock Screen | Compact / minimal | Expanded |
| --- | --- | --- | --- | --- |
| Working | `status == "working"`; `counts.working` | Working ink on the dot via `.lockScreen`; title `text.primary`; no wash | Leading shows working count only when `blocked == 0` and `done == 0` | Same row language, `.island` Mocha |
| Waiting | **Blocked.** herdr Blocked = waiting for human input (`CONTEXT.md`). No `waiting` string. | Blocked ink on title, 0.15 wash, 6 pt corner, 3/6 pt inset | Leading shows blocked count whenever `blocked > 0` | Blocked primary uses Mocha pink title |
| Done | `status == "done"`; `counts.done` | Done ink on the dot only; title stays `text.primary` (state, not "just finished") | Leading shows done count when `blocked == 0` and `done > 0` (including when working is also non-zero) | Same |
| Attention / error | **Blocked is attention.** There is no error status in `ContentState`. Unknown envelope strings use muted, never red. | Do not introduce a fourth hue | Do not paint blocked red for decrypt failure | Same |
| Stale | `context.isStale == true`. Happens after content that *carried a stale date* crosses that date. Push updates set `stale-date = timestamp + 900`. Local request/update uses `staleDate: nil`, so those snapshots do not become stale on the 15-minute push timer. | Trailing caption2 per the row-cap table; rows still shown | Unchanged counts; no stale caption | Unchanged; no stale caption |
| Disconnected | **No distinct representable widget state.** `ContentState` has only counts and an optional envelope. The coordinator holds the last activity while Agent inventory is unknown (`HostLiveActivityCoordinator.shouldDeferApply` / `isUnknownAgentInventory`). Do not infer disconnection from counts-only. | Last successfully delivered presentation, or counts-only if that is what was last delivered | Same | Same |
| Counts-only | Envelope absent or undecryptable (`AgentActivityDecryptor`) | `"Heeler"` + chips, no agent rows, no fake names. Not a disconnected glyph. | Counts | `"Heeler"` in center when no primary agent |
| Ended | Activity ends immediately (`dismissal-date = timestamp`). No ended presentation. | Not drawn. Do not add a summary banner. | Removed from the island immediately (system). | Removed |

Idle and unknown Agents are not in the activity. An empty eligible inventory ends the activity (ADR 0014). Do not design an idle lock-screen state.

## SwiftUI implementation guidance

1. **Chrome.** In `AgentLiveActivityWidget.body`, draw unresolved `UIColor.systemBackground` in the root Lock Screen view and also pass it to `.activityBackgroundTint`; pass unresolved `UIColor.label` to the system action modifier. Use unresolved `UIColor.label` and `UIColor.secondaryLabel` for Lock Screen text, and keep the Catppuccin status colors dynamic. Do not inject a fixed `colorScheme`, resolve colors early, or consult Heeler's Appearance setting. Dynamic Island remains system-black and keeps its explicit Mocha treatment. This prepares the view for the correct system trait but cannot force iOS 27 to refresh an existing activity.

2. **Palette file in the widget target.** Add `Sources/Heeler/Console/AgentStatusPalette.swift` to `HeelerWidgets.sources` in `project.yml`. Run `xcodegen generate` and commit `Heeler.xcodeproj` with that change. Do not duplicate hexes.

3. **Surface parameter.** Add `AgentActivitySurface` and route every status color through `AgentActivityStatusStyle.ink/wash(for:on:)`. Thread `surface` into `AgentActivityRowView`, `AgentActivityHeadlineView`, and `AgentActivityCountChips`. Lock Screen call sites pass `.lockScreen`; every island call site passes `.island`.

4. **`isStale` is Lock Screen-only.** Pass `context.isStale` into `AgentActivityLockScreenView` only. Do not add it to `AgentActivityIsland.make`.

5. **Row cap.** `AgentActivityPresentation.lockScreenAgents` draws at most four independently linked rows. The Lock Screen view uses those helpers and draws at most one trailing caption2.

6. **Compact leading.** Replace the `ellipsis` branch with the first non-zero of `blocked`, then `done`, then `working`. Keep the capsule treatment. Mocha via `.island`.

7. **Previews.** Stop forcing `.environment(\.colorScheme, .dark)` as the only gallery. Provide Light and Dark for the acceptance rows below, including stale maximum-height, 80-grapheme title, 80-grapheme name with title, and 80-grapheme name with title missing (identity promoted). Light Lock Screen previews use a light rounded rect approximating system material, not Mocha mantle. Island previews stay on black and must still use Mocha when the canvas environment is Light. Keep `.buttonStyle(.plain)` and `.tint(.primary)`.

8. **No new frameworks.** No extra SF Symbols catalog, no extra fonts, no ActivityKit API beyond modifiers already in the file plus `keylineTint` and Lock Screen `isStale`.

9. **Contract and coordinator stay put.** Do not change envelope shape, `chipItems` order, URL parsing, or dismissal policy. Do not add a disconnected flag.

Sketch (illustrative):

```swift
ActivityConfiguration(for: AgentActivityAttributes.self) { context in
    AgentActivityLockScreenContainer(
        presentation: AgentActivityDecryptor.presentation(for: context.state),
        hostID: context.attributes.hostID,
        isStale: context.isStale
    )
} dynamicIsland: { context in
    AgentActivityIsland.make(
        presentation: AgentActivityDecryptor.presentation(for: context.state),
        hostID: context.attributes.hostID
    )
}
```

Rows stay presentation-only. `AgentActivityLockScreenView` and the returned `DynamicIsland` each own one Console `widgetURL`.

### Focused verification (implementer)

Do not treat a full `make test` as required for this visual change. Run:

- Existing `AgentStatusPaletteTests` (hexes and 4.5:1 ink-on-wash still hold after the file is shared).
- Any existing widget/presentation tests that assert `lockScreenAgents` counts; update them for the `isStale` parameter and the stale cap.
- Canvas rows P1–P11, P5a/P5b, and P6/P6b. Confirm an island preview in a Light environment still uses Mocha (`#F38BA8` / `#A6E3A1` / `#F9E2AF`), not Latte.
- Physical Lock Screen Light/Dark remains required before closing #247 (D1, D2, D8).

## Preview and acceptance matrix

Xcode canvas previews are the development check. They **do not** replace a physical Lock Screen. Label every Lock Screen device row below as **device-required**.

| # | Case | Light | Dark | Where | Pass if |
| --- | --- | --- | --- | --- | --- |
| P1 | Mixed blocked / working / done + overflow (fresh, `total >= 6`) | Canvas | Canvas | Lock Screen preview | Light banner is light; chips and dots use Latte inks; blocked row wash is visible; `+N more` secondary; no stale caption |
| P2 | Single unnamed working | Canvas | Canvas | Lock Screen | Identity-only row, no wash, working dot visible |
| P3 | Four rows, all fit (fresh, `total == 4`) | Canvas | Canvas | Lock Screen | No overflow line; one full row plus three compact rows |
| P4 | Counts-only, not stale | Canvas | Canvas | Lock Screen | Headline "Heeler", chips only, no ghost rows, no stale caption |
| P5 | Long title (80 graphemes) + three chips | Canvas | Canvas | Lock Screen | Title truncates; chips fully visible |
| P5a | Long agent name (80 graphemes) with a title | Canvas | Canvas | Lock Screen | Title on line 1, name on line 2, name truncates, chips fully visible |
| P5b | Long agent name (80 graphemes), title missing (identity promoted) | Canvas | Canvas | Lock Screen | Name is the only line, truncates, chips fully visible |
| P6 | Stale, `total >= 5` (maximum-height stale) | Canvas | Canvas | Lock Screen | One full row plus three compact rows; one caption2 `+N more · May be out of date` |
| P6b | Stale, `total <= 3` | Canvas | Canvas | Lock Screen | All rows visible; caption2 is only `May be out of date` |
| P7 | Blocked compact | Canvas (force Light environment too) | — | Compact | Leading blocked count capsule, trailing total, Mocha ink even if canvas is Light, one Console destination |
| P8 | Done + working, no blocked | Canvas | — | Compact | Leading **done** count, not working, not an ellipsis |
| P9 | Working-only (`blocked == done == 0`) | Canvas | — | Compact | Leading working count, not an ellipsis |
| P10 | Minimal blocked | Canvas Light environment | — | Minimal | Total in blocked Mocha ink, bold |
| P11 | Expanded mixed in a Light environment | Canvas Light | — | Expanded | Primary + up to two secondaries + chips; **Mocha** inks, not Latte; key line blocked when blocked > 0 |
| P12 | Contrast, Light Lock Screen | Compute + canvas | — | Lock Screen | Ink/wash pairs match the table (≥ 4.5:1 text, ≥ 3:1 dots) |
| P13 | Contrast, Dark Lock Screen | — | Compute + canvas | Lock Screen | Mocha inks on system dark |
| P14 | Contrast, island | — | Compute | Compact/minimal/expanded | Mocha inks on black |
| D1 | Light Mode Lock Screen on device | **Device-required** | | Lock Screen | Banner is light; End control readable; wallpaper not fighting a dark slab |
| D2 | Dark Mode Lock Screen on device | | **Device-required** | Lock Screen | Dark system material, not necessarily `#181825`; chips readable |
| D3 | Always-On reduced luminance | **Device-required** | **Device-required** | Lock Screen | Status dots still distinguishable |
| D4 | Increase Contrast | **Device-required** | **Device-required** | Lock Screen | No lost text on washes |
| D5 | StandBy (Lock Screen ×2) | **Device-required** | **Device-required** | StandBy | Default material blends; 14 pt inset does not clip |
| D6 | Tap Agent rows and surrounding chrome | **Device-required** | | Lock Screen | Each row → matching Agent detail; surrounding chrome → Console; no target overlap |
| D7 | Compact tap both sides | **Device-required** | | Dynamic Island | Both sides → Console |
| D8 | Light Mode while island is showing | **Device-required** | | Dynamic Island | Island stays black with Mocha inks; Lock Screen (if shown) is Latte |

Not exercised in this research pass: physical device, Always-On, StandBy, Increase Contrast, VoiceOver, Night Mode StandBy, Watch Smart Stack. Canvas previews in Xcode were not generated here (no builds, per package).

## Decisions for implementation

No remaining product or ownership choices. Implement the following as specified:

1. Lock Screen background, End button, semantic text, and status colors remain unresolved dynamic UIKit colors so they follow iOS Light/Dark when ActivityKit supplies and refreshes the correct appearance. ActivityKit's SwiftUI `colorScheme` and Heeler's Appearance setting are not consulted. Existing-activity refresh remains blocked by the verified iOS 27 regression.
2. Hex owner is `AgentStatusPalette.swift`. Add that file to `HeelerWidgets.sources` in `project.yml`, regenerate and commit `Heeler.xcodeproj`. Do not duplicate hexes.
3. Every shared row, headline, and chip takes `surface: AgentActivitySurface`. Lock Screen passes `.lockScreen`. Compact, minimal, and expanded pass `.island`, which resolves Mocha against a dark trait collection. Ambient Light Mode must not tint the island.
4. Keep the aggregate list, pin-aware envelope order, full first row, compact secondary rows, and no Host name, buttons, logo, or progress bar. Use per-Agent links on Lock Screen and expanded presentations, plus one Console fallback link for each presentation. Chip enumeration stays `blocked`, `working`, `done`.
5. Compact leading = first non-zero count in attention order: blocked, then done, then working. Never the working ellipsis. Never Working before Done.
6. Lock Screen: show up to four rows. Stale trailing caption2 is `May be out of date`, or `+N more · May be out of date` when `total >= 5`. Pass `isStale` only into the Lock Screen view.
7. Disconnected has no widget presentation. Counts-only is decrypt/envelope failure, not disconnection. Stale is only `context.isStale` after content that included a stale date.
8. Chip wash opacity 0.15 on Lock Screen; blocked-row wash 0.15; island compact capsule 0.22; expanded island chips 0.16.
9. 14 pt horizontal, 8 pt vertical, 2 pt Lock Screen stack spacing, 7/8 pt dots. Row target height is 44 pt for up to three rows and 28 pt for four rows.
10. Canvas previews: Light and Dark Lock Screen, including P5/P5a/P5b long title and long name (with and without title), P6 stale maximum height, and island previews in a Light environment (Mocha).
11. Physical Lock Screen Light/Dark remains a required acceptance check before treating #247 as done.

Wire contract, ADR 0014, plugin, and relay are out of scope.
