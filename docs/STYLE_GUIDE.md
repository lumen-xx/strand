# Strand interface

Native SwiftUI, shared Style tokens, system appearance. Strand lists connected items rather than empty sockets. Names and short verdict chips identify each connection; port names remain secondary captions.

## Tokens

Bricolage Grotesque throughout, matching Nano; bundled locally under the SIL Open Font License. 30 pt bold for the item name, 26 pt semibold for stat values, 17 pt headings, 15 pt semibold titles, 13 pt body, 12 pt captions. Monospaced digits for numbers. Continuous corners: 18 pt rows, 22 pt tiles. Green for fine states, amber for limits, system accent for neutral connections. Every state has words and an accessibility label.

## Window

The whole window is one behind-window blur (`WindowGlass`, an NSVisualEffectView) with a slowly drifting colour wash (`Aurora`) that follows the selected item's verdict colour, plus a faint system-colour tint for legibility. No pane paints an opaque background over the blur. Reduce Transparency replaces all of it with the opaque window colour; Reduce Motion stops the drift.

A 320 pt sidebar lists connected items only: illustration, name, port caption and verdict chip. The detail pane uses a category photograph, Status and available Power cards in one row, followed by reported facts and monitoring graphs. Missing values are hidden, never guessed. Raw values remain visible in a compact table below a divider, without a heading or disclosure control. Caveats live in one info popover in the top-right button group with Copy report and Refresh.

## Settings

Settings occupies the detail column in the existing Strand window, retaining the fixed sidebar and shared background. It never creates a separate window. The top-right controls are Information, Refresh, Settings, in that order; Settings toggles back to the selected connection. Selecting a sidebar item also leaves Settings. The menu panel and Command-comma open this same surface. General, Monitoring and Updates group the existing preferences in softly rounded material surfaces. All four booleans use native switches with spoken labels. Explanations use info buttons; copyright, version and website remain visible in the footer, with the version above the link. Copy report stays available through Edit > Copy Report (Shift-Command-C) and the menu panel. The standard Edit items remain so text fields keep Cut, Copy, Paste and Select All; Command-C on the focused cable list copies the selection's details.

## Monitoring

Settings has “Monitor power and read/write usage”, off by default and persisted. While enabled, sample USB storage counters every two seconds and display rates from successive samples. First samples and counter resets remain unavailable; a measured idle rate shows 0 B/s. Only storage drivers with an IOUSBHostDevice ancestor qualify. Resolve the ancestor USB port's explicit UsbIOPort registry path to its physical PortDescription. Show read/write graphs only when this ID matches the selected item. Unknown mappings and internal disk traffic are hidden; do not infer socket identity from location-ID bit patterns, list order, device names or transport type. Hub devices share their verified upstream cable, with each graph labelled by device.

System input power is explicitly labelled Mac power input. Show it only on the unique connected port with a reported winning power-source option while external input is measured. Multiple candidates or missing mappings hide the graph. The value remains Mac-wide input, not a cable sensor. Changing power-source ownership clears its history; changing a storage counter's physical port clears its rate baseline and history. Missing readings are hidden, never fabricated zeroes. Disabling monitoring clears samples and stops storage-counter reads. Normal connection polling stays active.

## Panel and accessibility

360 pt panel over the system material with the same colour wash. A "Strand" header with a single more menu (Open Strand, Copy report, Settings, Check for Updates, Quit), then connected-item rows with illustration tiles and verdict chips. Content scrolls without indicators around 380 pt; native MenuBarExtra handles focus dismissal. Arrow keys select; Return opens the panel selection; Command-C copies selected details. Context menus contain only Copy details.

Selection persists for live data; newly connected items select and highlight briefly. Respect Reduce Motion by disabling springs and fades. Respect Reduce Transparency using opaque system backgrounds. Materials use Liquid Glass on macOS 26 and native ultra-thin material earlier.

## Fixture previews

Run `swift run Strand --fixture empty`, `charger-cable`, `limited` or `no-emarker`, with `--light`/`--dark`; `--panel-preview` hosts the panel in a window. UI fixtures are illustrative, not hardware measurements. Existing IORegistry parser recordings and release setup stay unchanged.

## 0.2.0 data presentation

Only Status and available Power use cards, in a single HStack. Everything else is a list of reported facts or PD options with explicit Active marking. Missing fields and graphs are absent. The power card's tooltip distinguishes selected PD power from cable rating and instantaneous usage. Native Swift Charts draw two-minute line histories outside cards. Only real measured zeroes draw zero; missing samples create gaps and disconnects clear histories. Power is labelled Mac power input; storage graphs name the device. Monitoring can be disabled in Settings. Strain relief meets the cable body continuously; the drawing uses a relaxed asymmetric bend and restrained shading rather than a large glow.

The window and menu panel share the same behind-window material at 85% strength. Explanations use a dedicated info button with an immediate hover popover, also available by click and keyboard. Cards and values have no explanatory native tooltips.

## Original product photos

Live device names and link facts come from the same verified physical-port ancestry as monitoring. DisplayPort ProductName takes precedence over a monitor's downstream USB peripherals. A USB product name is used only when one named device occupies that port; otherwise keep the connection name neutral and label each device's facts. USB link speed is an active device signaling rate, separate from cable e-marker capability, storage throughput and Thunderbolt certification. DisplayPort rate, lane count and tunnelling are shown only when reported for an active monitor link.

Rendered product images replace the drawn illustrations in both surfaces: Blender renders of free CC BY models plus a hub and plugs modelled for Strand, made by scripts/render-connection-images.py. Docks use the hub image. Do not tint or stretch the images. Unknown speed and USB 2 use the standard USB-C cable; reported 5/10/20/40 Gbps use the Thunderbolt 4 variant (longer plug housing); 80 Gbps uses the Thunderbolt 5 variant (metal collar). One charger image covers every rating. These are category illustrations, not brand/model identification: maker logos and lettering are removed from every model. Reported names, ratings, parsing and monitoring are unchanged. Model sources and authors are in ConnectionImages/sources.json; render details are in PRODUCT_IMAGES.md.

Cables, the hub, keyboards and mice are straight top views aligned to the frame, cables wound into a loose 1.5-turn coil with both plugs pointing up; headphones are a straight front view; the charger is a three-quarter side view showing its pins and USB-C port.

Graphs show a measured hover sample in the heading immediately left of the latest live value. A subtle dashed guide and sample dot follow the pointer. Leaving the plot clears the hover reading; empty time ranges have no invented values. The technical table sits below one divider, always visible, with labels leading and values trailing. There is no Details heading or expand control.

## Network mode

An animated capsule switch at the top changes between Cables and Network, persisted across launches. Reduce Motion disables the spring. Network keeps the existing native blur, fixed sidebar, shared typography and information icons. Interface addresses and graphs refer only to the selected interface. Listening ports and Connections are explicitly Mac-wide lists. TCP LISTEN is distinct from UDP bindings; local listeners are never labelled externally reachable. Missing process visibility is explained in the info icon. Network refresh runs every three seconds only while Network is selected.

Network navigation starts with Dashboard and a search field matching interface names/IDs/context and socket process/endpoints. Physical expands to macOS-reported Ethernet-class interfaces, including named USB tether services, even without an address; remaining interfaces stay separate. Dashboard sums measured rate deltas only for Wi-Fi/Ethernet hardware interfaces, excluding tunnels, loopback, bridges and AWDL/LLW. Traffic includes LAN use. Device identity is never inferred from a port or interface number.

Listening ports and Connections are grouped by process name in one card each, five rows before “Show more”. IPv4/IPv6 bindings of the same port and identical helper-process sockets collapse into one row; ×N counts only true duplicates. TCP listeners and bound UDP sockets are separate lists; UDP sockets without a port are hidden. Connections show the remote endpoint, its address class (This Mac, Local network, Public address — never resolved or looked up), TCP state and local port. One info icon per page replaces per-row explanations. Interface pages show status, traffic tiles with 64-bit since-startup totals, one combined chart, then Details (type, status, hardware address, wired link speed, MTU, router, DNS) and Addresses with prefix lengths. The 02:00:00:00:00:00 Wi-Fi placeholder address and Wi-Fi base rate are hidden. lsof runs only while a network view is visible.

Ethernet cables show the negotiated link speed in the chip and facts when the driver reports it; it is never presented as a cable category. A newly linked Ethernet adapter is announced like a USB-C connection (optional notification, menu bar tip, selection and highlight); adapters already linked at launch are not. Ethernet traffic graphs appear without the monitoring setting because Network mode reads those counters anyway. A failed port read shows an orange notice above the list and “Ports could not be read” instead of “Plug something in”.

## Related charger, HDMI and headphone jack

The list shows the cable only. Its detail view shows the cable photo and the charger photo side by side with a bolt between them, followed by a Charger section: adapter name, Charging/Not charging, rating, Mac power input, manufacturer, model and firmware. The adapter macOS reports is Mac-wide, so it attaches only to the single connected port with a selected power option, the same rule as the Mac power input graph; the serial number is never shown. A built-in HDMI port appears when macOS reports a port or display link of type HDMI; HDMI on a dock or adapter is converted from DisplayPort and stays under its USB-C port. The 3.5 mm jack appears while the built-in headphone device exists (Apple silicon) or the built-in output's data source is headphones (Intel); it reports whether it is the current output, its sample rate and a headset microphone, never what is plugged in. HDMI and headphones use system symbols because no product photographs are bundled for them. Cable e-marker ratings are shown whenever macOS exposes SOP′ identity; with a charger at the other end the charger normally owns that conversation, so ratings are usually absent and are not guessed.

## Detail order and power tag

The detail view reads top to bottom by importance: name, port and tag; photo (with the charger beside it when one powers the Mac); a visible Power limit/Assessment callout when present; Status and Power tiles; key facts (cable speed and power rating, device and display links, Ethernet link speed, audio output; transports other than CC alone); the Charger section; live graphs; then Technical details (identity values, current and voltage ratings, selected option, PD profiles) and the raw table. A connection powering the Mac — a selected power option while external power is reported — shows a bolt with the selected wattage in its tag instead of the dot and status word, and its Status reads Charging or Powering Mac. Read/write and received/sent rates share one two-line chart. An Apple badge with an info button appears when a cable's e-marker reports Apple's vendor ID or the adapter reports Apple as its manufacturer; it states what the hardware reports and never claims verified authenticity.

## Light and dark photos

Connection images follow the appearance: white or silver products in light mode, black or space grey in dark mode; Ethernet uses one image for both, and docks use the hub image. All are on transparent backgrounds, cropped to the product. One charger photo pair covers every rating; the wattage lives in the name, tag and facts. Sources and the light/dark table are in docs/PRODUCT_IMAGES.md.

## Closing ports and connections

macOS cannot close one socket of another process, so a port or connection row's context menu offers Quit and Force Quit for its owning process (every PID merged into that row). Both always confirm in an alert that names the process and PIDs and states that all of its connections close and unsaved work may be lost. Strand's own process and PID 1 are never offered. Processes owned by the system or another user refuse the signal; Strand reports that instead of escalating. Nothing else in Network mode changes the system.

## Docks and hubs

A USB-C port whose devices include USB hub chips (class 9) is a dock when it also drives displays (a Billboard device, class 17, or an active DisplayPort link) or is a Thunderbolt device, otherwise a hub. Thunderbolt docks show their reported maker and model without company suffixes; USB-C docks are "USB-C dock", never a guessed brand. The detail view shows the cable beside the hub image (docks use it too), then a Dock or Hub section with the link to the Mac and each connected device. In the sidebar those devices sit under the dock with an 18 pt indent in compact rows; an Ethernet adapter inside the dock is listed there and stays selectable, other devices select the dock. Device icons come from USB interface classes: audio uses the headphones photo, keyboards, mice, storage, cameras and network adapters use symbols. The menu panel shows the same hover as the window rows.

## Settings groups

Settings has seven surfaces: General (launch at login, open in last used/Cables/Network), Menu bar (show, hide when idle, show charging power beside the icon), Appearance (theme System/Light/Dark applied to every window, colour background), Connections (notify on plug-in and unplug, plug-in popup, select new connections, devices under docks, technical details), Network (refresh every 1/2/3/5 s, hide connections within this Mac, traffic in bits per second; totals stay in bytes), Monitoring and Updates. Toggles use native switches, choices use compact pop-up menus, and every row has an info button. Keys and defaults live in Settings.swift; defaults keep earlier behaviour except the new opt-in notices and menu bar wattage.

Revision: only Thunderbolt devices, which report a maker and model, are docks; every other hub is a "USB-C hub", because most USB-C hubs drive displays and macOS cannot tell a powered USB-C dock from a hub. Under a dock or hub the sidebar lists only cables: Ethernet adapters (selectable items) and headphones/headsets (selecting the hub). Keyboards, storage and other devices appear only in the hub's detail section. Child rows use the title font with 42 pt photos and hang off a 2 pt guide line aligned with the parent's photo.

Revision: a hub's own functions are hidden from device lists and shown as "Built into this hub": devices reporting the hub's USB-PD vendor ID (for example its display adaptor) and card readers without media. Headphones, keyboards and mice behind a dock or hub become their own items with a detail view showing the cable beside the device photo (a mechanical keyboard and a mouse, white in light and black in dark; studio headphones). They follow their hub in list and arrow-key order. Storage and other devices stay in the hub's detail.

Wireless input: categories come from USB classes plus the HID usages a device declares (mouse 2, keyboard 6). A device declaring both is a mouse unless its name says keyboard, because gaming mice declare a keyboard for macros. USB receivers for 2.4 GHz or Bluetooth LE devices are recognised by name (receiver, dongle, wireless, Unifying, Lightspeed, Bolt) and tagged "Wireless mouse/keyboard/headphones"; a receiver serving both mouse and keyboard without a hint is "Receiver" with a radio symbol. macOS does not report the radio type or battery level. A mouse, keyboard, headset or receiver plugged straight into a port shows its photo beside the cable too.

Every scroll view uses .scrollIndicators(.never): with .hidden, SwiftUI still narrows the content for a classic scroll bar (a mouse connected or "Show scroll bars: Always") and shows it on long pages such as Settings, so content and the fixed top-right buttons drifted apart. With .never nothing is reserved or drawn and wheel and trackpad scrolling still work. HID category: a name saying mouse or keyboard decides first, because receivers may list a keyboard interface before the mouse; a wireless receiver offering both without a hint is a receiver; otherwise the lowest-numbered HID interface decides by boot protocol, then declared usages, so wired keyboards with media or knob interfaces stay keyboards and gaming mice with macro keyboards stay mice.
