# UI redesign validation · 2026-10-09

## Completed

- Debug and packaged arm64 release builds compile.
- Existing StrandChecks passes against unchanged recorded IORegistry fixtures and live IOKit.
- `swift run Strand --fixture limited --check-ui` validates all four JSON presentation scenarios, selection and arrow bounds, hiding empty ports, omitting absent stats, accessibility label content, and not interpreting USB2 transport as a cable speed rating.
- Parser sources, SwiftPM configuration, updates configuration, release scripts and signing setup are unchanged.
- No release was prepared or published. The local packaged app retains the existing version/build configuration.

## Awaiting direct UI verification

Desktop computer-use access fails with “Sky Computer Use native pipe closed before response”. Two native view capture approaches omitted sidebar/list layers and produced incorrect material effects. These captures were rejected and the experimental capture code removed. There is no valid reviewed screenshot set yet.

The following are implemented but not directly verified: actual menu-panel focus dismissal; keyboard events and Command-C dispatch; clipboard contents; persisted selection across app relaunch; plug-in highlight and animations; VoiceOver speech; Reduce Motion and Reduce Transparency appearances; light/dark contrast and layout in all scenarios. Model selection behaviour and accessibility strings have focused checks, not full interaction coverage.

## Reproduce previews

From ~/dev/strand:

    swift run Strand --fixture empty --light
    swift run Strand --fixture charger-cable --dark
    swift run Strand --fixture limited --light
    swift run Strand --fixture no-emarker --dark

Add `--panel-preview` for a window hosting the menu panel content. Use the real menu bar item to check native dismissal and Return opening. Each fixture can be shown in both appearances using `--light`/`--dark` without changing system settings.

## Hardware limits

JSON scenarios with speed, wattage and bottleneck claims are illustrative UI data, not measurements. Recorded IORegistry data and the unchanged parser cannot establish cable e-marker ratings, a verified physical-port PD contract, or the weakest link. Live UI omits these stats and claims. Real hardware is needed to verify connection/disconnection selection and highlights, cable identity availability, charger capabilities and per-port mapping; this redesign does not add parsing for those capabilities.

Release remains pending a valid screenshot review and the user's explicit approval.

## Compact information revision

Removed the detail illustration, sidebar heading and collapsible split view. Sidebar is fixed at 260 pt. Information and caveats use hover info icons. Added an off-by-default persisted monitoring toggle, system-wide Mac input power and USB-storage read/write rate sampling. Storage samples require USB device ancestry, excluding internal SSD counters. Added focused checks for rate deltas, measured idle, missing samples, counter resets and formatting. No external USB storage is attached on this Mac, so real transfer and removal behaviour remain unverified. Per-cable power, generic USB traffic and physical socket mapping are unavailable; no such values are invented. Desktop screenshot verification remains blocked.

## Menu panel sizing correction

The geometry-preference sizing loop could leave connected content at its initial 1 pt height in MenuBarExtra. Replaced it with 96 pt rows, 4 pt row spacing and a 320 pt scrolling cap calculated directly from the item count. Focused checks cover zero, one, two and many items. Debug/packaged builds and fixture checks pass; actual panel screenshots remain unavailable through desktop UI access.

## 0.2.0 verification (supersedes earlier blocked notes)

Reviewed native light/dark screenshots for all four recorded UI scenarios in both the window and a preview window hosting the exact menu panel content (16 images). Reviewed the telemetry graphs and the shared 85% background material. Info controls now use one hover-popover implementation; clicking the running app’s information button visibly opened its content. Pointer-hover timing and actual MenuBarExtra focus dismissal still require manual confirmation.

Parser and presentation checks pass, including missing data, selected PD option, graph gaps, zero readings and retention. The direct IORegistry API on this Mac reports USB-C Port 1 source options of 5 V/3 A and 9 V/2.22 A, with the latter selected. No readable cable e-marker or USB storage is attached. Real e-marker/EPR and storage-transfer behavior remain unverified. Preview graph samples are explicitly illustrative. Bundle uses LSUIElement and accessory activation; closing the last window does not terminate the menu-bar process.

Published v0.2.0/build 5: downloaded release archive and live raw appcast both pass signature verification. Packaged Sparkle fetched and cryptographically accepted the published feed (five items). App size is 5.4 MB. Closing the native window left the same Strand process alive. Graph info button activation was separately confirmed by its displayed popover.

## Original Apple photo revision

Verified all downloaded photos have genuine alpha transparency. Presentation checks cover unknown and 480 Mbps, 5/10/20/40/80 Gbps, MagSafe, charger fallback and loading all nine mapped photos. Images retain Apple's original pixels and are bundled for offline use. No ratings or device identities are derived from images. Reviewed native window and panel previews with light/dark backgrounds.

## Graph hover and Details table

Checks pass for nearest measured hover sample, zero, empty history, time bounds and missing intervals. Details splits only the first colon, preserving values containing colons and repeated PD profile labels. Reviewed native screenshots showing three hovered values beside latest readings, guides/dots, and the four-row two-column PD table with its divider. Hover previews use `--fixture telemetry --show-graphs --hover-graphs`; table preview uses `--fixture details-table --show-graphs --show-details`. Direct pointer automation intermittently failed with noWindowsAvailable/user-changed errors; the deterministic hover preview verifies layout, not a complete pointer sweep across every graph. Collection and parsing are unchanged.
