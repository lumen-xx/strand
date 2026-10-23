# Strand

A native macOS menu-bar and window inspector for detected USB-C/Thunderbolt and MagSafe ports. Apple silicon, macOS 14 or newer. Version 0.5.7.

Strand reads IORegistry through IOKit without permissions, helper daemons, or configuration changes. It shows each reported physical port, its current detected connection and active transports, provides system power diagnostics and copies a text report. Launch at login, plug-in notices and automatic update checks are optional and off by default.

## What this preview can report

Strand lists detected connections and hides unavailable readings. It reads near/far cable e-marker identity and per-port USB-PD source options when macOS exposes them. The current Mac has verified 15 W and 19.98 W source options with a selected 9 V / 2.22 A option; no cable identity was reported. E-marker parsing is fixture-tested, not yet verified with real e-marked hardware. Cable signaling, current, vendor/product IDs and voltage ceilings are shown only for recognized identity data. EPR voltage tolerance is not presented as a guessed wattage rating. Unknown VDO versions remain raw.

Status and available Power appear together; other values are a list. Enable monitoring in Settings for two-minute graphs of Mac input power and available USB-storage read/write rates. These are system/device readings, not total per-cable usage. Graphs with no data are hidden. Closing the window leaves Strand in the menu bar; there is no Dock icon.

See docs/IOREGISTRY.md for evidence and limitations. This preview does not promise to identify ratings macOS does not publish.

## Install and use

Download Strand-0.5.7.zip from https://github.com/lumen-xx/strand/releases/tag/v0.5.7, extract, and drag Strand.app to Applications. The app is signed with a stable local identity (Strand Local Signing, created once by scripts/signing-identity.sh) and not notarized. If macOS blocks opening, use its standard Open Anyway control after reviewing the source. Launch Strand for the menu-bar connector icon and inspector. Select a connected item, or choose Open Strand. Copy report collects the reported facts and limitations.

The app can also be launched directly from `dist/Strand.app` after building. A cable must connect to another device/charger before the Mac may detect it.

## Build and verify

Requires the Swift 6.2/macOS 26 SDK to compile Liquid Glass branches; the package uses swift-tools-version 5.9 and macOS 14 deployment.

```sh
swift run StrandChecks
bash scripts/build-app.sh
open dist/Strand.app
```

App output is arm64 with embedded Sparkle 2.10.0, bundle id com.opyuii.strand, LSUIElement true and a size gate under 40 MB. Regenerate the icon with `swift scripts/icon.swift work` followed by `iconutil -c icns work/Strand.iconset -o Sources/Strand/Resources/AppIcon.icns`.

## Updates and releases

Choose Check for Updates… in the menu bar or app menu. Automatic checks are opt-in. Preview updates are allowed. The signed appcast ships with every release; the feed is https://github.com/lumen-xx/strand/releases/latest/download/appcast.xml. Copies of 0.5.7 and earlier read the old lumen-xx/strand-releases feed, which no longer exists: download the next release once by hand to get updates again.

`updates/config.json` follows Dice's schema. The private signing key lives only in the login Keychain under account `strand`. Do not generate a replacement key for an existing release stream.

```sh
bash scripts/prepare-release.sh 0.2.1 6
bash scripts/publish-release.sh 0.2.1
```

The scripts adapted from Voidamp package the app, sign the archive and feed with Sparkle, and verify both signatures before publication. A small appcast writer avoids generate_appcast's cache outside the project; Sparkle's upstream sign_update signs both outputs. Publishing creates the GitHub release in lumen-xx/strand with the archive and its signed appcast, marked latest. Increasing build numbers are required.

### Network mode

Use the Cables / Network switch to inspect this Mac’s interfaces, local addresses, received/sent traffic, listening TCP ports and visible TCP/UDP sockets. Process names and PIDs are shown where macOS permits them. No network scanning, packet capture, helper or elevated permissions. Socket visibility may be incomplete. Listening ports are local bindings, not a test of firewall or internet reachability. Tunnel traffic may also appear on an underlying interface; Strand does not sum these counters.

## Licence

Strand's source is released under the MIT License (see LICENSE). Bundled third-party components keep their own licences, listed in THIRD_PARTY_NOTICES.md: Sparkle (MIT), Bricolage Grotesque (SIL Open Font License 1.1) and the connection images, which are renders of CC BY 4.0 models and need their authors credited when redistributed.
