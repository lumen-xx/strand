# Strand 0.1.0 validation

Verified on this Apple silicon MacBook Air on 2026-10-09:

- Read-only IORegistry capture before and after connecting a USB-C cable with its other end loose. Both states report USB-C ports 1 and 2 and MagSafe 3 inactive; no external power.
- StrandChecks passes: recorded physical-port parsing, stale identity/PD suppression, missing connection state, deduplication, synthetic connected transport, fixed/PPS/unsupported PDOs, system power units, live IOKit access and dangling cable recording. Synthetic input is not real hardware validation.
- Debug and release builds succeed. Bundle arm64 only, macOS minimum 14.0, LSUIElement, com.opyuii.strand, Sparkle exact 2.10.0.
- Ad-hoc code signature deep/strict verification passes. Logical bundle size 3,437,167 bytes, below 40 MB.
- Published ZIP and feed downloaded again from GitHub and both signatures reverified. A modified feed was rejected.
- Sparkle signing key generated in Keychain account strand. ZIP EdDSA signature and appcast embedded signature verified independently by sign_update. Packaged Sparkle runtime fetched the published raw GitHub feed and returned signingValidationStatus=succeeded with one item. This is a real feed check using the packaged framework, not an update installation/relaunch test.
- GitHub source repository is private; binary-only releases repository public. v0.1.0 published as a preview prerelease.
- Strand process running from dist/Strand.app after attempted desktop launch.

Not verified:

- Direct screenshots and UI interactions on the menu-bar panel, full window, settings, focus dismissal, Copy report and update windows: desktop automation returned “Sky Computer Use native pipe closed before response” twice, including after a reset. No screenshots are claimed or fabricated.
- Interactive download/install/relaunch of an update. Feed acceptance and cryptographic archive verification passed separately.
- Attached charger, peripheral, e-marker data, source-capability provenance, controller-to-socket mapping, selected contract, cable rating or weakest link. Unavailable fields are displayed as Not reported.
- Launch-at-login registration and notice settings were not toggled, to preserve the user's system settings.
- macOS 14 runtime and pre-26 material rendering were not directly exercised on this host.

The delivered preview contains the native surfaces, monitoring, report, settings and signed release flow. Verified cable/charger bottleneck identification remains unavailable, pending exposed data and real hardware validation.
