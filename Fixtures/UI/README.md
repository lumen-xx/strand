# Presentation fixtures

These JSON scenarios exercise UI only. They are illustrative, not recorded e-marker/Power Delivery measurements. The existing .plist IORegistry recordings remain the parser's evidence.

- empty: no connected items, matching the recorded disconnected state.
- charger-cable: illustrative 96 W charger and 40 Gbps cable.
- limited: illustrative USB 2.0 / 60 W cable and 96 W charger.
- no-emarker: connected CC-only cable with missing ratings, matching the live connection's information limits.

Run from the repository: swift run Strand --fixture limited --dark
Add --panel-preview for a window hosting the exact menu panel view.

`telemetry` adds explicitly illustrative capability/profile values and histories. Use `--fixture telemetry --show-graphs --light` (or `--dark`) to review all three graphs.

Use `--hover-graphs` with a fixture to seed a measured hover sample for screenshot review. `details-table` covers repeated PD profile labels and selected values; `--show-details --show-graphs` scrolls to the always-visible compact table. These debug arguments do not affect normal launches.

`photo-magsafe`, `photo-thunderbolt4` and `photo-thunderbolt5` preview the three edited overhead category images. `--settings-preview` opens the embedded settings view in the detail column. These are UI illustrations, not detected hardware.

`graph-routing` has a monitor/power connection on Port 1 and a separate SSD connection on Port 2. Its seeded Mac input history belongs only to Port 1; SSD read/write histories belong only to Port 2. Arrow keys switch between them. These histories are illustrative.

`other-ports` previews a MagSafe connection with its related charger in the detail view, a built-in HDMI display and headphones in the 3.5 mm jack. Values are illustrative.

`dock` previews an identified Thunderbolt dock (illustrative CalDigit TS4 with devices behind it) and an unnamed USB hub. Values are illustrative.
