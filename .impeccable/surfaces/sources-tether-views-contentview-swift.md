---
version: 1
slug: "sources-tether-views-contentview-swift"
primary_target: "Sources/Tether/Views/ContentView.swift"
related_targets: []
---

# Surface: Tether main window

Mode: operate. Audience: Quest developers on a Mac with the headset on a USB-C cable. Task: see whether the headset is tethered and healthy, start Link, glance at battery/controllers/cable, open the live headset view. Frequency: glanced at often, opened briefly.

## Direction contract

THESIS: The window is a small VR room. A near viewport pane faces you; status panes stand on a curved arc to either side, angled toward you; a perspective floor runs to a horizon light. It refuses the category default of a flat dashboard of cards.

OWN-WORLD: Ink room (#04060B to a #0C1322 horizon), solid slate panes (#141A26 near, #0F141E far), no glass. One warm accent, Tether gold #E9C27A, which only means "the link is live". Healthy mint #5BE3A9, attention #FFB45E. SF Pro Expanded for the wordmark and figures (light weight, monospaced digits), SF Pro Text for labels. A ring-and-tether mark; no Meta marks or name.

STORY: Plug in and the room's panes fill with live readings. The viewport tells you the one thing to do (choose Launch in the headset). When Link goes live, the horizon warms to gold and the viewport shows live metrics, or the headset's own view.

FIRST VIEWPORT: The whole room: viewport centre, four angled panes, floor and horizon. Nothing below the fold.

SIGNATURE: Depth with parallax. Panes and floor shift with the pointer, and a hovered side pane swings to face you. The horizon light warms to gold when Link goes live.

REFUSALS: No stat-card grid, no glassmorphism, no neon glow, no gradient text, no eyebrow labels, no Meta branding.

SEED: ba508eeb (assigned candidate 3, Depth Room; raise from the split-flap challenger: live values change with a mechanical digit roll)
