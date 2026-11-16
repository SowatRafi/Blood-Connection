# Selected Blood Connection logo

An initiative by Bindubashini Boys’ 2015 & Friends.

`handshake-drop.png` is the exact transparent image selected by the user with “I will use this” on 16 November 2026. It was copied byte for byte from the supplied PNG; its hands, wrist details, colours and transparency were not redrawn. SHA-256: `2e4356ce94116847a04834006e630be2063f19b67a4dcac8273b5f4850bf1508`.

The selected image takes precedence over the earlier experimental directions. Keep this master intact. Run `python tools/generate_icons.py` to derive the mobile asset, admin PNG and platform icon sizes. This open-source CairoSVG packaging step applies layout and scaling only. The SVG source wrapper references the PNG; it is not an editable vector tracing. A rendered admin PNG avoids external-image restrictions in browser SVGs and duplicated base64 strings in source. The app has no image-generation service dependency or runtime logo download.

Normal builds use the committed icons. To regenerate them, install the development tool with `python -m pip install CairoSVG==2.9.0` and provide Cairo's native library for your operating system. This version produced the checked-in assets; it is not an application runtime dependency.

The 1024-unit layout uses a warm-white background and a 620-unit artwork box at (202,202). Flutter uses the same padding and cached decoding. Android gets separate background and transparent foreground layers, allowing its launcher to apply the mask. Its visible artwork fits the central 66dp safe region. A monochrome layer is omitted because tinting the whole raster alpha would erase the white hands. iOS icons have an opaque background as required by the existing asset catalog.

## Creation provenance

The original concept was produced using the built-in image-generation tool. The user subsequently supplied the final selected PNG. No further generative edit was applied after that selection. Earlier rejected variations are not app assets. This is a record of the artwork source, not a claim of trademark exclusivity.

Original generation prompt (transparent background enabled):

> Use case: logo-brand. Create a new premium mobile-app logo for Blood Connection, a charitable blood-donation connection app. Single isolated emblem on a genuinely transparent background, square composition, no text. A rich crimson (#B42346) blood-drop silhouette encloses an unmistakably REAL HANDSHAKE, two human right hands firmly clasping each other, rendered as a refined flat ivory/white emblem with crimson anatomical separation lines. This MUST look like two real human hands shaking: natural opposing wrists, overlapping thumbs at the top, fingers wrapping around the other palm, believable knuckles and grip, exactly two hands, no merged or extra digits. Viewed from the front at a slight three-quarter angle, a conventional horizontal handshake, balanced sleeve cuffs at either side. Natural anatomy simplified by an expert brand illustrator, not a robotic geometric zigzag or two puzzle pieces. The two people helping one another through blood donation and human connection should be immediately understandable. Bold clear silhouette, graceful blood drop, elegant confident contours, enough negative space for the clasp to read clearly at mobile icon size. Professional healthcare identity, warm, dignified, distinctive and welcoming. Keep a clean two-colour flat/vector-like finish. No gradients, no shadows, no 3D, no photoreal skin texture, no hearts, no faces, no religious symbols, no separate cupped/praying hands, no chain links, no watermarks, no letters. Emblem should fill about80% of the square with even transparent margins. Output one complete logo only.
