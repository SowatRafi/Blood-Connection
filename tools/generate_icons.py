"""Package one reviewed brand illustration into platform-required launcher sizes.

Run after changing design-system/brand/handshake-drop.png (requires CairoSVG).
The app itself has no dependency on this development tool.
"""
import base64
import json
import shutil
from pathlib import Path
import xml.etree.ElementTree as ET

import cairosvg

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "design-system/mark.svg"
ARTWORK = ROOT / "design-system/brand/handshake-drop.png"
ANDROID = "http://schemas.android.com/apk/res/android"
ET.register_namespace("android", ANDROID)


def artwork_layout() -> ET.Element:
    """Embed our local image only in memory so CairoSVG can keep its safe resource policy."""
    source = ET.parse(SOURCE).getroot()
    source.find("{http://www.w3.org/2000/svg}image").set(
        "href", "data:image/png;base64," + base64.b64encode(ARTWORK.read_bytes()).decode("ascii"))
    return source


def render(path: Path, size: int) -> None:
    """Derive every launcher size from the same layout so platform branding cannot drift."""
    path.parent.mkdir(parents=True, exist_ok=True)
    cairosvg.svg2png(bytestring=ET.tostring(artwork_layout()), write_to=str(path), output_width=size, output_height=size)


def adaptive_icon() -> None:
    """Keep the illustration in Android's safe zone; the system supplies its own icon mask."""
    resources = ROOT / "mobile/android/app/src/main/res"
    source = artwork_layout()
    background_rect = source.find("{http://www.w3.org/2000/svg}rect")
    color = background_rect.attrib["fill"]
    source.remove(background_rect)
    # Render only the padded artwork with alpha; this preserves the reviewed hand geometry exactly.
    image_dir = resources / "drawable-nodpi"
    image_dir.mkdir(exist_ok=True)
    cairosvg.svg2png(bytestring=ET.tostring(source), write_to=str(image_dir / "ic_launcher_artwork.png"), output_width=432, output_height=432)
    drawable = resources / "drawable"
    bitmap = ET.Element("bitmap", {f"{{{ANDROID}}}src": "@drawable/ic_launcher_artwork", f"{{{ANDROID}}}gravity": "fill", f"{{{ANDROID}}}filter": "true"})
    ET.ElementTree(bitmap).write(drawable / "ic_launcher_foreground.xml", encoding="utf-8", xml_declaration=True)
    background = ET.Element("shape", {f"{{{ANDROID}}}shape": "rectangle"})
    ET.SubElement(background, "solid", {f"{{{ANDROID}}}color": color})
    ET.ElementTree(background).write(drawable / "ic_launcher_background.xml", encoding="utf-8", xml_declaration=True)
    icon = ET.Element("adaptive-icon")
    # A flat alpha tint would erase the white clasp; expose the full-colour adaptive mark instead.
    for layer, resource in (("background", "background"), ("foreground", "foreground")):
        ET.SubElement(icon, layer, {f"{{{ANDROID}}}drawable": f"@drawable/ic_launcher_{resource}"})
    output = resources / "mipmap-anydpi-v26"
    output.mkdir(exist_ok=True)
    ET.ElementTree(icon).write(output / "ic_launcher.xml", encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    # Keep the source wrapper readable; inline PNG base64 can resemble credentials to secret scanners.
    SOURCE.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
                      '<!-- Generated layout wrapper; the reviewed PNG is the artwork master. -->\n'
                      '<rect width="1024" height="1024" fill="#FAF8F5"/>\n'
                      '<image x="202" y="202" width="620" height="620" href="brand/handshake-drop.png"/>\n</svg>\n', encoding="utf-8")
    mobile_art = ROOT / "mobile/assets/brand/mark.png"
    mobile_art.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ARTWORK, mobile_art)
    # Browsers block external artwork inside img SVGs, so the admin uses a self-contained rendered PNG.
    render(ROOT / "admin/mark.png", 256)
    adaptive_icon()
    # Android's density-specific files avoid runtime resizing on older launchers.
    for density, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        render(ROOT / f"mobile/android/app/src/main/res/mipmap-{density}/ic_launcher.png", size)

    # Apple's asset manifest is the authority for required point sizes and scales.
    iconset = ROOT / "mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for asset in json.loads((iconset / "Contents.json").read_text())["images"]:
        size = round(float(asset["size"].split("x")[0]) * float(asset["scale"].rstrip("x")))
        render(iconset / asset["filename"], size)

    # Browser previews share the same mark rather than the Flutter template logo.
    for size in (192, 512):
        render(ROOT / f"mobile/web/icons/Icon-{size}.png", size)
        render(ROOT / f"mobile/web/icons/Icon-maskable-{size}.png", size)
    render(ROOT / "mobile/web/favicon.png", 32)
