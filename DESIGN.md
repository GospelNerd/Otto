# Otto — DESIGN.md

The design system file for anyone, human or agent, designing or building Otto's interface. It is
written to be usable without the codebase: you should be able to draw an on-brand Otto screen in
Paper from this file alone. When it disagrees with the code, the code wins and this file gets fixed.
The engineering companion is `docs/DESIGN_SYSTEM.md` (how the tokens are consumed in SwiftUI).
The working process is the `otto-design` skill in `.agents/skills/otto-design/`.

## 1. Product context

Otto is a native macOS app that runs AI agents (Claude Code, Codex, OpenCode, Pi, Otto's own
harness) as sessions, bots and teams, with an in-app browser, documents, dashboards, automations
and voice. People use it to hand real work to agents and supervise the result. The interface
therefore has two jobs: let someone give work quickly, and show them, calmly, what needs them.

Two places:

- **Home**: the daily brief, pinned cards, approvals that need a person, and a composer.
- **Chat**: a left sidebar (places, bots, sessions) beside a content pane that is a conversation
  or one of the places: Activity, Automations, Browser, Dashboards, Documents, Files & notes.

Everything sits on a live, themed backdrop (artwork or a procedural landscape). Surfaces are
translucent layers over that backdrop, not opaque panels. That is the single most recognisable
thing about Otto, and the first thing a mockup gets wrong.

## 2. Colour: nine slots, eighteen themes

Colour is the only formally tokenised value. Every theme defines exactly nine slots. Map by
meaning, never by hue:

| Slot | Role |
|---|---|
| `ink` | Deepest background, window base, scrims |
| `surface` | Card and panel backgrounds |
| `raised` | Title bars, inputs, chips, rows that sit on a card |
| `paper` | Primary text and icons (dark on light themes) |
| `muted` | Secondary text, captions, inactive icons |
| `signal` | The one accent: primary action, selection, focus, success, counts |
| `amber` | Working, pending, permission prompts, stuck |
| `red` | Errors, failures, destructive actions, action traces |
| `cyan` | Information, links, browser and agent affordances |

Hex values (sRGB, rounded from the linear triples in `Sources/OttoModels/Themes.swift`):

| Theme | Material | ink | surface | raised | paper | muted | signal | amber | red | cyan |
|---|---|---|---|---|---|---|---|---|---|---|
| Field Notes (fallback) | scrim | #0E1010 | #161717 | #1D1F1E | #E3DECC | #8C9187 | #C2F047 | #F29933 | #F25240 | #4CD1C7 |
| Highfell (new workspaces) | glass light | #EDE8D6 | #F7F2E3 | #FFFAED | #24291C | #5C614F | #216B33 | #8C590D | #AD291F | #0D616B |
| **Shorelight (Max's theme, review on this)** | glass dark | #081A1C | #0D2426 | #143033 | #F2EBD6 | #94B2AB | #FAC24C | #EB8C4C | #F26954 | #61CCD1 |
| Halcyon | glass dark | #131018 | #1F1A24 | #2B2129 | #F5E8D1 | #ADA19E | #E8874A | #F2B852 | #F0594C | #66C9C2 |
| Ringfall | glass dark | #06111F | #0B1A2B | #12263B | #DBEDFA | #91ADC4 | #4CDBEB | #F2AD45 | #F55E6B | #61C7FF |
| Farfield | glass dark | #060F0D | #0B1A16 | #13261F | #EBF2E6 | #99AD9E | #73D966 | #F28C40 | #F25C4C | #66BFF2 |
| Aurora | glass dark | #080D1A | #0E1626 | #172136 | #E6F2F7 | #8FA8BD | #73F0B2 | #F2B24C | #F56670 | #66D9F2 |
| Nightspire | glass dark | #0E0D0B | #171513 | #211E1B | #F0E6D4 | #A3998A | #FCBD3D | #ED9442 | #F05C47 | #70C7BD |
| Afterglow | scrim | #12081C | #1C0D29 | #291438 | #F5E8FA | #B299CC | #FC6BBD | #F7A847 | #FA5761 | #66E6F2 |
| Velvet | matte | #0E0B11 | #1A161D | #26202A | #F2EBF0 | #B8A6B8 | #ED99A8 | #F2AD5C | #F56B6B | #8CCCD9 |
| Nightscreen | matte | #0B0A12 | #13111C | #1D1A29 | #EDEAF5 | #A39EB8 | #ABADF5 | #F0B259 | #F26E6E | #5EC4D9 |
| Nightglass | window glass | #121217 | #1A1A21 | #262630 | #F2F2F7 | #A3A6B2 | #ABADF5 | #F2B25C | #F57070 | #85CCE0 |
| Graphite | scrim | #0D0D0E | #161617 | #1F1F21 | #E6E6EB | #94969E | #85BDFA | #F0AD4C | #F2615C | #6BCCDB |
| Silverbough | glass light | #E6EDEB | #F2F7F5 | #FCFFFC | #1A2924 | #546661 | #1A6642 | #8C6114 | #A82E29 | #0D5C66 |
| Mistfall | glass light | #F0F0ED | #F7F7F5 | #FFFFFC | #1F1F21 | #616166 | #334080 | #8C4C1A | #A62621 | #145966 |
| Duneveil | glass light | #F0E3CC | #F7EDDB | #FFF7E8 | #2E1F14 | #6B5947 | #8C4214 | #8F590D | #A8291A | #0D5E61 |
| Glasswing | window glass | #EDF0F5 | #F0F2F7 | #FAFBFF | #262630 | #575966 | #5C4C9E | #966114 | #C72E33 | #1A6B85 |
| Daylight | scrim | #F4F4F2 | #FBFBFA | #FFFFFF | #161718 | #5C5E63 | #1A5CC7 | #8C540A | #B2211C | #0A6170 |

Contrast floors every theme must pass: paper on ink ≥ 7.0, muted on ink ≥ 4.5, signal on ink ≥ 4.5.
Text on a `signal` fill is `ink`. Text on `cyan`, `amber` or `red` fills is `ink` on dark themes.

## 3. Surfaces and the glass look

There are no blur materials in the app. "Glass" is opacity layering over the live backdrop:

| Surface | Recipe |
|---|---|
| Backdrop | Theme artwork or landscape, behind everything, under a 3-stop `ink` gradient scrim |
| Sidebar | `ink` at 42–74% over the backdrop, 1px hairline on its right edge |
| Content pane | `surface` at 55–92% |
| Card | `raised` at 90–94%, 1px hairline, radius 12 |
| Row on a card | `raised` at 55%, radius 8–10 |
| Input, address bar, code | `ink` at 48–60%, radius 7–9 |
| Toolbar, chip | `raised` at 94% |
| Scrim behind a palette or sheet | black at 62% |

Hairlines: `paper` at 6–16% over theme surfaces, white at 3.5–12% over dark chrome. Never a solid
grey border.

Shadows: black at 22–52%, radius 12–34, y 5–10. Deeper and larger when selected or floating.

Radii cluster by role, and nested radii are concentric (outer = inner + padding):
2–3 accent and quote bars · 5–8 rows, chips, tool calls · 9–10 cards, tables, callouts ·
12–13 cards and message bubbles · 16 command palette · 18 large sheets · capsule for pills.

Spacing uses a loose 4-point rhythm: 24 pane padding, 16–18 card padding, 12 row padding,
8 gaps between cards, 6 between rows, 3–4 between a title and its caption.

## 4. Typography: two fonts

- **Inter Variable** (`ottoDisplay`) for everything people read: titles, body, buttons, rows.
  Regular weight by default, semibold for titles and primary buttons. 12–14 for body and rows,
  15–18 for titles, 24 for a place header, 19 for the command palette field.
- **SF Mono** (`ottoMono`) for labels, data, times, counts and metadata.

The signature **micro-label**: an uppercase SF Mono label at 7–9 pt, black or bold weight,
tracking 0.8–1.6, in `muted` (or `signal`/`cyan` when it is a live count). Used for every section
header, chip and status word. Example: `NEEDS YOU · 4`, `SESSIONS`, `BOTS`.

Line height: titles about 1.1, body 1.5. Tabular figures on anything that counts or ticks.
Sentence case everywhere except micro-labels. A global font scale (0.8–1.3) multiplies all sizes.

## 5. Motion

- The backdrop breathes slowly (Ken Burns and shimmer) at a 24 fps cap.
- Interactive states use interruptible transitions or springs with no bounce. One-shot sequences
  (first paint of a list) may use staggered keyframes: opacity, 8 px rise, slight blur, 60–100 ms
  apart. Exits are smaller and quicker than enters.
- Press feedback scales to 0.96, never below 0.95.
- Reduce-motion freezes the backdrop and removes entrances. Reduced transparency replaces glass
  with solid `ink`. Both are non-negotiable.
- The **agent-control aura** (a rotating angular gradient border sweeping a web view every 3.6 s,
  `signal` when acting, `cyan` when observing) is the one canonical "an agent is driving" effect.
  Reuse it; do not invent new ones.

## 6. Components, as they appear in the app

- **Top bar**: a segmented Home | Chat pill at the left with the profile and sidebar toggles,
  the Work/Personal profile switcher, theme and inbox buttons at the right. Dark chrome, no fill.
- **Home**: a wide-tracked date micro-label (`THURSDAY 29 OCTOBER`), a 44 pt greeting
  ("What's on your mind?"), a one-line `muted` subtitle, then the composer card: `ink` at 88%,
  radius 16, placeholder "Ask, make, or explore something...", with "New session" and the
  harness picker on its bottom row. Under it a row of quick links with SF Symbols (To-do,
  Files & notes, Automations, Cloud). Sections ("For your review 2", "Make it yours") are 17 pt
  semibold titles with a `signal` count, not micro-labels.
- **Sidebar** (about 216–300 wide): search field, "+ New", the places list with SF Symbols,
  `BOTS` and `SESSIONS` micro-label groups, session rows with a provider avatar, two-line title
  and last message, a Voice footer and a Settings row with an active-agent count.
  Active row: `paper` at 7.5%. Counts: a `signal` capsule with `ink` text.
- **Place header**: a 24 pt title, a 12 pt `muted` subtitle, actions or search at the right.
- **Card (Home)**: near-opaque `ink` at about 88% so the artwork reads through only faintly,
  radius 12, 20–24 padding, title 15 semibold, caption 12 `muted` ("Aria · 3 hours ago").
  A 3 px `signal` bar on the leading edge when the card needs a person. Inner content such as a
  draft sits on `raised` at 60%, radius 9. Cards in a Chat place use `raised` at 90–94% instead.
- **Status capsule**: a micro-label (`NEEDS YOU`) in `signal` inside a `signal` 35% outline capsule,
  top right of the card. Counts next to a section title are a bare `signal` micro-label.
- **Row**: `raised` at 55%, radius 10, an 8 px status dot, name, `muted` detail, trailing link.
- **Buttons**: the house style is quiet. Card actions are small `raised` pills (radius 7,
  6×12 padding) with an SF Symbol and a 12.5 pt label: `✓ Approve`, `Comment`, `Edit`, `✕ Reject`,
  all the same weight; the trailing "Open chat" is a plain `muted` text link. A `signal` fill with
  `ink` text is reserved for the one primary action on a screen (send, save, the selected palette
  row). Destructive confirmations use `red` text. Hit areas stay at 40 px even when the pill is
  smaller.
- **Message bubbles**: user messages right-aligned on `raised`, radius 13; assistant messages
  full-width under a mono provider header (glyph + name). Tool calls on `raised` at 55%.
- **Permission prompt**: `amber` at 9% fill, 22% stroke, with Allow and Deny.
- **Review card (Home)**: what the agent wants to do, the draft, and Approve, Comment, Reject;
  stays on Home while the approved action runs, then reads Done or Stopped.
- **Composer**: a full-width field on `raised` with attach and send, a status line underneath
  in micro-label style (permission mode · account · identity) and the theme picker at the right.
- **Command palette**: 760×540 on `surface`, radius 16, black 62% scrim. The selected row inverts
  to a `signal` fill with `ink` text.
- **Browser**: toolbar on `raised` 94%, mono address field on `ink` 48%, vertical tab sidebar on
  `ink` 74%, `cyan` for https and active chrome buttons.
- **Settings**: the deliberate exception. Native SwiftUI forms, system accent, system fonts.

## 7. Semantics

success, selection, focus, counts → `signal` · busy, pending, stuck → `amber` · error, failure,
destructive → `red` · information, links, agent and browser affordances → `cyan` ·
text → `paper` and `muted`. Never introduce a colour outside the nine slots.

## 8. Do and don't

- Do design on the live backdrop with glass surfaces. Don't draw opaque flat panels.
- Do use micro-labels for structure. Don't add heavy headings or dividers.
- Do keep one accent per screen doing the work. Don't scatter signal, cyan and amber decoratively.
- Do write copy in plain sentence case, short, in Otto's voice ("Nothing needs you").
- Don't ship the generic look: purple gradients, stock card grids, rounded-everything, emoji icons.
- Don't add blur materials, new fonts, new radii or colours "just for this screen".
- Don't restyle Chat chrome as a side effect of a fix. Show the change on Shorelight with a real
  transcript before it ships.
