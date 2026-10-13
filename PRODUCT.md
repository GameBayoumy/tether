# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native SwiftUI app for macOS 27 on Apple silicon. (Not one of the web/ios/android/adaptive values; recorded as-is.)

## Users

Developers who build for Meta Quest on a Mac, mainly Unity and Unreal developers who would otherwise need a Windows PC for Quest Link. They plug a Quest 2 or Quest 3 into the Mac with a USB-C cable and want it to just work, the way the Windows Meta Quest Link app does. The product is intended for public release.

## Product Purpose

Tether turns a Mac into a Quest Link PC over USB using the headset's own built-in Link, with nothing installed on the headset. Alongside Link, it shows the connected headset's live status (battery, controllers, worn state, OS, storage, USB speed) and mirrors the headset's display into a window on the Mac.

Success: plug the headset in, press Launch in the headset, and Mac content appears in VR, with device health visible at a glance on the Mac.

## Positioning

The only way to run the headset's native Quest Link from macOS: it talks the same USB protocol (XRSP) the Windows app uses, so the headset shows its normal Quest Link prompt for the Mac. No sideloaded APK, no Wi-Fi streaming app.

## Operating Context

- The Mac sits on a desk with the Quest connected by cable; the user moves between the Mac screen and the headset.
- The app runs in the background with a menu-bar item; the main window is opened to check status or start the screen mirror.
- Developer mode / adb is optional: Link works without it; detailed status and the screen mirror need USB debugging.

## Capabilities and Constraints

- Link: automatic USB detection, pairing, the headset's "Quest Link available" prompt, head tracking (~550 poses/s), stereo video of a virtual room with the Mac desktop on a large screen. Currently ~57 fps over USB 2, intra-only H.264.
- Status via adb: headset battery/charge/temperature, controller battery and state, worn/asleep, active app, Wi-Fi IP, Horizon OS version, storage, Link service state.
- Screen mirror via the headset's `screenrecord`, with eye selection, quality presets, screenshots, and a Keep Awake toggle.
- Not yet: controller input mapped to the Mac, audio, OpenXR runtime for Unity/Unreal editors.
- Requires macOS Screen Recording permission to show the desktop in VR.

## Brand Commitments

- Name: "Tether".
- Own identity. The app must not present itself as a Meta app: no Meta name, logo or trademarks in branding. Naming the headset ("Quest") and the headset's own "Quest Link" prompt is fine where needed to describe compatibility.
- Should feel like a premium VR desktop app, not a generic dashboard.

## Evidence on Hand

- Real device data from a Quest 3 on Horizon OS v207 (battery, controllers, storage, Link state).
- No testimonials, user counts, or performance claims beyond what the app measures live.

## Product Principles

1. Native first: use what the headset already has; never ask the user to install anything on it.
2. Plug in and go: detection, pairing and recovery happen automatically; the user only presses Launch in the headset.
3. Honest status: show what the device actually reports, and say plainly what is unknown or needs permission.
4. Stay out of the way: the app lives in the menu bar and only asks for attention when something needs the user.
