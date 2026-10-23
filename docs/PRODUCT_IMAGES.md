# Connection images

Strand shows white or silver products in light appearance and black or space grey ones in dark appearance; Ethernet uses one image for both. Every image is a Blender render made by `scripts/render-connection-images.py` from free 3D models (Sketchfab, CC BY 4.0) plus geometry modelled in the script. Renders use Cycles with a neutral studio light, a transparent background and AgX colour, are cropped to the product with a 6% border and scaled to 1000 px on the long side (`sips -Z 1000`; the script renders 2000 px). Cables, the hub, keyboards and mice are rendered straight from above, cables wound into a loose 1.5-turn coil with both plugs pointing up; headphones are a straight front view; the charger is a three-quarter side view so its pins and USB-C port both show. Images illustrate a connection category and never identify a brand: maker logos and lettering are removed from the models.

| Category | Light | Dark |
|---|---|---|
| USB-C (unknown speed, USB 2) | White braided cable, plugs from "USB-C Charging Cable" | Black braided cable |
| 5–40 Gbps | As USB-C with a longer plug housing | |
| 80 Gbps | As 5–40 Gbps with a metal collar | |
| MagSafe 3 | Plug modelled in the script, white braid | Same plug, black braid |
| Charger (any rating) | "iPhone USB-C Charger Box" adapter, white, printed text removed | Same, black |
| Ethernet | "Internet cable \| Ethernet \| Lan" plug on a graphite braid, both appearances | |
| Hub and dock (any brand) | Aluminium USB-C hub modelled in the script, straight top view, silver | Space grey |
| Headphones and USB audio | "Sony wh 1000xm5" over-ear model, lettering removed, white | Black |
| Keyboard | "VortexSeries GT-8 / NJ80" mechanical keyboard, white caps and case | Black caps and case |
| Mouse | "Computer mouse" model by zhe_kan, logo removed, white | Satin black |

Model pages, authors and licences are in `Sources/Strand/Resources/ConnectionImages/sources.json` and credited in `THIRD_PARTY_NOTICES.md`. No free hub model was good enough, so the hub is modelled in the script. Docks show the hub image as well, so every hub-like device reads the same. To re-render, download each model's glTF archive from its Sketchfab page and unpack it into `work/models/<key>/` (`work/` is not committed): `usbc1` USB-C cable (also the hub's plug), `eth3` Ethernet, `chg6` charger, `mk5` keyboard, `hp3` headphones, `ms7` mouse. Then run:

```bash
/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python scripts/render-connection-images.py -- work/models Sources/Strand/Resources/ConnectionImages
```

`--quick` renders previews at half size, and image names after the output folder render only those images. The earlier product photos, including the CalDigit dock photo, remain in git history.
