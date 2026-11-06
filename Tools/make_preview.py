"""Assemble actual AppKit frames. Cropping/scaling only; no character redraws."""
from pathlib import Path
import argparse
import json
from PIL import Image, ImageChops, ImageDraw

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--frames', type=Path, default=root/'build/pock/frames-v1.2')
parser.add_argument('--poses', type=Path, default=root/'build/pock/poses-v1.2')
parser.add_argument('--reaction', type=Path, default=root/'build/pock/reaction-v1.2')
args = parser.parse_args()
output = root/'dist'
output.mkdir(exist_ok=True)

def load_frames(folder):
    manifest = json.loads((folder/'manifest.json').read_text())
    frames = [Image.open(folder/f'frame-{index:03d}.png').convert('RGB') for index in range(manifest['frames'])]
    return manifest, frames

def focus(frame, scale=4):
    bounds = ImageChops.difference(frame, Image.new('RGB', frame.size, 'black')).getbbox()
    left = max(0, min(frame.width-64, (bounds[0]+bounds[2])//2-32))
    return frame.crop((left,0,left+64,30)).resize((64*scale,30*scale),Image.Resampling.NEAREST)

def save_gif(frames, path, duration):
    # Include every activity's colors, not just the opening running frame.
    colors = set()
    for frame in frames:
        colors.update(color for _,color in frame.getcolors(maxcolors=256))
    palette = Image.new('P',(1,1))
    rgb = [value for color in sorted(colors) for value in color]
    palette.putpalette((rgb+[0]*768)[:768])
    indexed = [frame.quantize(palette=palette,dither=Image.Dither.NONE) for frame in frames]
    indexed[0].save(path,save_all=True,append_images=indexed[1:],duration=max(10,round(duration*100/len(frames))*10),loop=0,optimize=False,disposal=2)

manifest, frames = load_frames(args.frames)
save_gif(frames,output/'Clawd-preview.gif',manifest['duration'])
save_gif([focus(frame) for frame in frames],output/'Clawd-actions.gif',manifest['duration'])
reaction_manifest, reaction = load_frames(args.reaction)
save_gif([focus(frame) for frame in reaction],output/'Clawd-mad.gif',reaction_manifest['duration'])

poses = json.loads((args.poses/'poses.json').read_text())['poses']
sheet = Image.new('RGB',(4*256,4*154),(15,15,15))
draw = ImageDraw.Draw(sheet)
for index, pose in enumerate(poses):
    frame = Image.open(args.poses/pose['file']).convert('RGB')
    x=(index%4)*256; y=(index//4)*154
    sheet.paste(focus(frame),(x,y+24))
    draw.text((x+8,y+5),pose['name'],fill='white')
sheet.save(output/'Clawd-actions-contact.png')
print(output/'Clawd-preview.gif')
print(output/'Clawd-actions.gif')
print(output/'Clawd-mad.gif')
print(output/'Clawd-actions-contact.png')
