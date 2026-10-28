"""Generate the original geometric Ink Studio launcher icon (requires Pillow)."""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1] / "app"
icon = Image.new("RGBA", (512, 512), (32, 61, 59, 255))
draw = ImageDraw.Draw(icon)
draw.ellipse((305, 105, 383, 183), fill="#f6d56c")
draw.polygon([(70, 365), (202, 195), (288, 305), (342, 240), (447, 365)], fill="#f6d56c")
draw.line([(85, 404), (428, 404)], fill="#f5f4ef", width=12)
for density, size in {"mdpi":48, "hdpi":72, "xhdpi":96, "xxhdpi":144, "xxxhdpi":192}.items():
    target = ROOT / f"android/app/src/main/res/mipmap-{density}/ic_launcher.png"
    icon.resize((size, size), Image.Resampling.LANCZOS).save(target)
icon.save(ROOT / "windows/runner/resources/app_icon.ico", sizes=[(16,16),(32,32),(48,48),(64,64),(128,128),(256,256)])
