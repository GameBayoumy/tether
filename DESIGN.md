---
name: Tether
description: A Mac becomes the headset's Link PC; the window is a small VR room.
colors:
  room-top: "#04060B"
  room-horizon: "#0C1322"
  floor: "#05070D"
  pane: "#141A26"
  pane-far: "#0F141E"
  pane-raised: "#1C2433"
  hairline: "rgba(255,255,255,0.07)"
  text: "#EEF1F6"
  text-secondary: "#A3ACBE"
  text-tertiary: "#7F899E"
  tether-gold: "#E9C27A"
  gold-ink: "#1C1608"
  healthy: "#5BE3A9"
  attention: "#FFB45E"
  fault: "#FF6B6B"
typography:
  wordmark:
    fontFamily: "SF Pro Expanded, system-ui"
    fontSize: "15px"
    fontWeight: 600
    letterSpacing: "0.4px"
  headline:
    fontFamily: "SF Pro Expanded, system-ui"
    fontSize: "28px"
    fontWeight: 500
    letterSpacing: "-0.3px"
  figure:
    fontFamily: "SF Pro Expanded, system-ui"
    fontSize: "40px"
    fontWeight: 300
  pane-title:
    fontFamily: "SF Pro Text, system-ui"
    fontSize: "12px"
    fontWeight: 600
  body:
    fontFamily: "SF Pro Text, system-ui"
    fontSize: "14px"
    fontWeight: 400
  row:
    fontFamily: "SF Pro Text, system-ui"
    fontSize: "12px"
    fontWeight: 400
rounded:
  control: "8px"
  button: "9px"
  pane: "14px"
  viewport: "18px"
spacing:
  row: "6px"
  pane-padding: "16px"
  arc-gap: "26px"
components:
  viewport:
    backgroundColor: "{colors.pane}"
    rounded: "{rounded.viewport}"
  pane:
    backgroundColor: "{colors.pane-far}"
    rounded: "{rounded.pane}"
    padding: "16px"
    width: "252px"
    height: "218px"
  button-primary:
    backgroundColor: "{colors.tether-gold}"
    textColor: "{colors.gold-ink}"
    rounded: "{rounded.button}"
    padding: "8px 16px"
  button-secondary:
    backgroundColor: "{colors.pane-raised}"
    textColor: "{colors.text}"
    rounded: "{rounded.control}"
    padding: "7px 12px"
---

# Design System: Tether

## Overview

**Creative North Star: "A small VR room on your desk"**

The main window is a room seen from inside a headset. A near viewport pane faces you; status panes stand on a curved arc to either side, angled toward you; a perspective floor (the same grid the headset scene uses) runs to a horizon light. Panes and floor drift with the pointer, and a hovered side pane swings round to face you.

The palette is ink and slate with one warm light. Tether gold means exactly one thing: the link is live. When Link starts, the horizon warms to gold and the mark turns gold.

**Key Characteristics:**
- Depth over decoration: solid panes, real perspective, offset-and-blur shadows, no glass.
- One accent, used only for the live link.
- SF Pro Expanded at light weight for figures (with rolling digits); SF Pro Text for everything you read.
- Everything is in the first viewport; nothing scrolls.

## Colors

### Primary
- **Tether Gold** (#E9C27A): the live link. The headline "Live in your headset", the Link switch tint, the primary button, the horizon light and floor grid while streaming, and the mark when live. Never used for anything else.

### State
- **Healthy** (#5BE3A9): connected, charging, active controller, Link service ready.
- **Attention** (#FFB45E): USB 2 cable, permissions needed, heat.
- **Fault** (#FF6B6B): errors, critical battery.

### Neutral
- **Room** (#04060B to #0C1322 at the horizon, #05070D floor): the window.
- **Pane** (#141A26) / **Far pane** (#0F141E) / **Raised** (#1C2433): the viewport, the arc panes, and buttons and footer.
- **Text** (#EEF1F6 / #A3ACBE / #7F899E).

### Named Rules
**The One Light Rule.** Gold is the link. If nothing is streaming, there is no gold on screen.

**The Solid Pane Rule.** Panes are opaque. Depth comes from perspective, scale and shadow, never from blur.

## Typography

**Display:** SF Pro Expanded (wordmark, headlines, figures)
**Text:** SF Pro Text (labels, rows, instructions)

### Hierarchy
- **Headline** (500, 28px expanded): the viewport's one sentence of state.
- **Figure** (300, 26–40px expanded, monospaced digits): battery, speeds, live metrics; digits roll on change.
- **Body** (400, 13.5–15px): instructions.
- **Pane title** (600, 12px, secondary colour) and **rows** (12px, tertiary label and primary value).

## Elevation

Each pane declares elevation once, with a shadow carrying offset and blur (viewport: 0/26/40 at 60% black; side panes: 0/16/22 at 45%) and no border. Side panes also sit back in depth (0.92 scale, 17° rotation toward the viewer).

## Components

### Viewport
560×470 near pane. The top states the headline and next step; live metrics and controls sit at the bottom. The footer carries the Link switch, the state, "Headset view" (which mirrors the headset inside the pane) and a pop-out.

### Arc panes
252×218: Headset, Controllers (left); Cable, System (right). Each leads with one figure, then rows. Placeholder: a dash figure plus a plain sentence saying why.

### Floor marking
Device, serial and cable speed set in expanded type, laid flat on the floor in perspective.

### Mark
A slack cable hanging between a ring (headset) and a dot (Mac). Text colour at rest, gold when live.

## Do's and Don'ts
- **Do** keep one sentence of "what to do next" in the viewport.
- **Do** keep every value real; show a dash and a reason when it's unknown.
- **Don't** add gold anywhere that isn't the live link.
- **Don't** use Meta names or marks in branding.
- **Don't** add blur or glass panes.
