"""Assemble actual AppKit-rendered PNGs, without redrawing the character."""
from pathlib import Path
import json
from PIL import Image, ImageChops

root = Path(__file__).resolve().parents[1]
frames_dir = root / "build/pock/frames-v1.1"
output = root / "dist"
manifest = json.loads((frames_dir / "manifest.json").read_text())
frames = [Image.open(frames_dir / f"frame-{index:03d}.png").convert("RGB") for index in range(manifest["frames"])]
palette = frames[0].quantize(colors=32)
gif_frames = [frame.quantize(palette=palette, dither=Image.Dither.NONE) for frame in frames]
gif_frames[0].save(output / "Clawd-preview.gif", save_all=True, append_images=gif_frames[1:], duration=manifest["duration"] * 1000 / len(frames), loop=0, optimize=False, disposal=2)
sheet = Image.new("RGB", (manifest["width"], 45 * 8), "black")
actors = Image.new("RGB", (36 * 6 * 4, 30 * 6 * 2), "black")
for row in range(8):
    frame = frames[round(row * (len(frames) - 1) / 7)]
    sheet.paste(frame, (0, row * 45))
    bounds = ImageChops.difference(frame, Image.new("RGB", frame.size, "black")).getbbox()
    actor = frame.crop((bounds[0] - 3, 0, bounds[0] + 33, 30)).resize((36 * 6, 30 * 6), Image.Resampling.NEAREST)
    actors.paste(actor, ((row % 4) * 36 * 6, (row // 4) * 30 * 6))
sheet.save(output / "Clawd-contact-sheet.png")
actors.save(output / "Clawd-actor-poses.png")
print(output / "Clawd-preview.gif")
