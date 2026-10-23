# Read-only hardware spike

Captured on this Apple silicon MacBook Air on 2026-10-09 using `ioreg -a -r` and read-only IOKit property reads. No helpers, privileged user clients or system configuration changes.

## Observed

- AppleHPMInterfaceType10: USB-C ports 1 and 2. PortTypeDescription, PortNumber, PortDescription, ConnectionActive and TransportsActive identify the physical interface and current reported connection. These are USB-C/Thunderbolt-capable sockets, not separate additional Thunderbolt sockets.
- AppleHPMInterfaceType11: one MagSafe 3 port.
- AppleSmartBattery: ExternalConnected, AdapterDetails, PowerTelemetryData, PortControllerInfo. Controller records include PortControllerNPDOs, PortControllerPortPDO and PortControllerActiveContractRdo.
- AppleT8122TypeCPhy: two PHYs; mostly empty lane/transport dictionaries while disconnected.
- IOThunderboltPort: internal adapters and lane records. Counting these as physical sockets would overcount. Link speed codes are not treated as Gbps or cable ratings.

## Freshness matters

Disconnected USB-C port 2 retained SOPMfgString=DJI. Disconnected battery records retained nonzero PDO arrays and RDOs. Even HPDAsserted and IOAccessoryUSBActive can remain true while ConnectionActive is false. Strand suppresses stale identity and PD records when disconnected; it never uses cached PDOs as a live charger menu.

The user then connected a USB-C cable with its other end loose. A second recording still showed all three ConnectionActive values false and ExternalConnected false. This host cannot distinguish that cable from an empty socket through these readings.

## Not verified / not implemented as inferred data

No SOP'/SOP'' e-marker identity payload was exposed in either capture. Cable maximum speed, 3 A/5 A rating, voltage rating, maximum watts and cable vendor are Not reported. SOPMfgString identifies the attached partner, not the cable manufacturer.

The PortControllerInfo array does not expose a verified physical-port mapping here. Its PDO provenance and freshness with a connected charger are unverified. Strand decodes recorded PDO bitfields in diagnostic records, but does not claim a full source-capability menu or highlight an active profile. The RDO object position alone cannot prove an active contract. SystemPowerIn is a system input reading in milliwatts, not battery charging power or a negotiated limit.

A weakest-link verdict requires verified cable, charger and port limits; unavailable in these recordings. No conclusion is guessed. Real charger/device connection, plug/unplug, e-marked USB 2/USB 3/USB4 cables, 3 A/5 A and EPR hardware remain required to validate and extend the field adapters.

## Fixtures

ports-disconnected.plist and battery-disconnected.plist: relevant recorded IORegistry fields; battery identifiers removed. ports-dangling.plist and battery-dangling.plist: the dangling-cable recording, with false connection state. synthetic-connected.plist is explicitly synthetic test input, not hardware evidence. typec-disconnected.plist contains the base-class query result and may be empty. Full raw dump stays local and gitignored in work/.

## References

IOKit property snapshots: https://developer.apple.com/documentation/iokit/1514310-ioregistryentrycreatecfpropertie
PDO bitfield units: https://github.com/torvalds/linux/blob/master/include/dt-bindings/usb/pd.h
USB PD specification library: https://www.usb.org/documents?search=power+delivery

## 0.2.0 follow-up: direct API is richer than ioreg plist output

On 2026-10-09 a powered USB-C connection exposed `IOPortFeaturePowerSource` descendants. `ioreg -a` omitted their non-plist properties, while `IORegistryEntryCreateCFProperties` returned `PowerSourceName`, `PowerSourceOptions` (NSSet), and `WinningPowerSourceOption`. The per-port USB-PD source advertised 5 V/3 A/15 W and 9 V/2.22 A/19.98 W, with 9 V selected. TypeC and Brick ID fallback sources exist alongside it and must not be mistaken for additional PD options. `Fixtures/ports-pd-recorded.plist` records these facts, with sets normalized to arrays and unrelated properties removed.

The adapter recursively visits descendants of each AppleHPMInterface, retaining the physical-port association. Recognized near/far marker classes are `IOPortTransportComponentCCUSBPDSOPp` / `IOPortTransportComponentCCUSBPDSOPpp`. Discovery identities decode only complete VDO arrays, with little-endian Data words. Partner SOP manufacturer strings are never cable vendor IDs. Unknown layouts remain raw. Passive/active cable identities are synthetic-tested, not hardware-verified. Gen2 signaling does not disambiguate 10 versus 20 Gbps operation; show the signaling class. 50 V tolerance does not establish a 250 W cable rating.

References used to establish schema and bitfields (implementation written independently):
- https://github.com/tzzs/cablescope/blob/main/Sources/CableKit/Services/PortControllerService.swift (direct registry classes and properties)
- https://github.com/torvalds/linux/blob/master/include/dt-bindings/usb/pd.h (Cable VDO fields)
- https://chromium.googlesource.com/chromiumos/platform/ec/+/HEAD/include/usb_pd_vdo.h (Gen4 and recognized cable layouts)
- https://community.infineon.com/t5/Knowledge-Base-Articles/How-to-modify-the-USB-Highest-Speed-bits-of-Cable-VDO-to-UBS4-Gen4-for-CMG1-CMG2/ta-p/776969 (Gen4 encoding)
