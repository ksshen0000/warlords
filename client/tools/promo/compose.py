"""Cut the recorded frame sequences into one promo: title cards, fades and captions (PIL), then encode
an H.264 mp4 (ffmpeg if installed, otherwise GStreamer's x264enc).

    python3 compose.py cut.json frames_root out.mp4

cut.json: {"fps": 30, "size": [1920, 1080], "segments": [
    {"title": ["大字", "小字"], "dur": 3.0},
    {"clip": "field", "from": 2.0, "to": 9.0, "captions": [[0.5, 6.0, "千军对阵", "步、弓、骑协同作战"]]}, ...]}
A clip is the directory frames_root/<clip>/ of PNGs written by Godot's Movie Maker (f00000000.png …);
caption times are relative to the start of the segment.
"""
from __future__ import annotations

import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter, ImageFont

SANS = "/usr/share/fonts/google-noto-sans-cjk-fonts/NotoSansCJK-Bold.ttc"
SANS_R = "/usr/share/fonts/google-noto-sans-cjk-fonts/NotoSansCJK-Regular.ttc"
TITLE = "/usr/share/fonts/fandol/FandolSong-Bold.otf"
GOLD = (242, 199, 92)
CREAM = (239, 230, 210)
FADE = 0.45


def font(path: str, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(path, size, index=2 if path.endswith(".ttc") else 0)   # 2 = SC in Noto CJK ttc


def ease(x: float) -> float:
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)


class Cutter:
    def __init__(self, cut: dict, root: str, out_dir: str):
        self.fps = int(cut.get("fps", 30))
        self.size = tuple(cut.get("size", [1920, 1080]))
        self.cut = cut
        self.root = root
        self.out = out_dir
        self.n = 0
        W, H = self.size
        self.f_cap = font(SANS, int(H * 0.05))
        self.f_sub = font(SANS_R, int(H * 0.026))
        self.f_title = font(TITLE, int(H * 0.15))
        self.f_tsub = font(SANS_R, int(H * 0.03))
        # dark band under the captions
        band = Image.new("L", self.size, 0)
        d = ImageDraw.Draw(band)
        for y in range(int(H * 0.62), H):
            d.line([(0, y), (W, y)], fill=int(170 * max(0.0, (y - H * 0.62) / (H * 0.38)) ** 1.4))
        self.band = band

    def emit(self, im: Image.Image) -> None:
        im.convert("RGB").save(os.path.join(self.out, f"{self.n:05d}.jpg"), quality=94)
        self.n += 1

    def title(self, seg: dict) -> None:
        W, H = self.size
        lines = seg["title"]
        dur = float(seg.get("dur", 3.0))
        frames = int(dur * self.fps)
        for i in range(frames):
            t = i / self.fps
            a = ease(t / 0.8) * ease((dur - t) / 0.8)
            im = Image.new("RGB", self.size, (12, 12, 14))
            d = ImageDraw.Draw(im)
            big = lines[0]
            bw = d.textlength(big, font=self.f_title)
            # a little slow push-in: letter-spacing shrinks over the card
            y = H * 0.40
            col = tuple(int(c * a) for c in GOLD)
            d.text(((W - bw) / 2, y - self.f_title.size * 0.6), big, font=self.f_title, fill=col)
            for k, small in enumerate(lines[1:]):
                sw = d.textlength(small, font=self.f_tsub)
                c2 = tuple(int(c * a * 0.9) for c in CREAM)
                d.text(((W - sw) / 2, y + self.f_title.size * 0.55 + k * self.f_tsub.size * 1.7), small, font=self.f_tsub, fill=c2)
            self.emit(im)

    def clip(self, seg: dict) -> None:
        files = sorted(glob.glob(os.path.join(self.root, seg["clip"], "*.png")))
        a, b = int(seg["from"] * self.fps), int(seg["to"] * self.fps)
        files = files[a:b]
        dur = len(files) / self.fps
        caps = seg.get("captions", [])
        fin = seg.get("fade_in", FADE)
        fout = seg.get("fade_out", FADE)
        for i, f in enumerate(files):
            t = i / self.fps
            im = Image.open(f).convert("RGB")
            if im.size != self.size:
                im = im.resize(self.size, Image.LANCZOS)
            live = [c for c in caps if c[0] <= t < c[1]]
            if live:
                c = live[0]
                al = ease((t - c[0]) / 0.5) * ease((c[1] - t) / 0.5)
                im = Image.composite(Image.new("RGB", self.size, (0, 0, 0)), im,
                                     self.band.point(lambda v: int(v * al)))
                self._caption(im, c[2], c[3] if len(c) > 3 else "", al, t - c[0])
            k = min(ease(t / fin) if fin > 0 else 1.0, ease((dur - t) / fout) if fout > 0 else 1.0)
            if k < 1.0:
                im = Image.blend(Image.new("RGB", self.size, (0, 0, 0)), im, k)
            self.emit(im)

    def _caption(self, im: Image.Image, big: str, small: str, al: float, lt: float) -> None:
        W, H = self.size
        x = int(W * 0.06) + int(18 * (1 - ease(lt / 0.6)))
        y = int(H * 0.80)
        layer = Image.new("RGBA", self.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        # gold rule to the left
        d.rectangle([x - 22, y + 6, x - 16, y + self.f_cap.size + (self.f_sub.size + 14 if small else 0)],
                    fill=GOLD + (int(255 * al),))
        sh = Image.new("RGBA", self.size, (0, 0, 0, 0))
        ds = ImageDraw.Draw(sh)
        ds.text((x + 2, y + 3), big, font=self.f_cap, fill=(0, 0, 0, int(200 * al)))
        if small:
            ds.text((x + 2, y + self.f_cap.size + 16), small, font=self.f_sub, fill=(0, 0, 0, int(200 * al)))
        sh = sh.filter(ImageFilter.GaussianBlur(3))
        d.text((x, y), big, font=self.f_cap, fill=CREAM + (int(255 * al),))
        if small:
            d.text((x, y + self.f_cap.size + 14), small, font=self.f_sub, fill=GOLD + (int(235 * al),))
        im.paste(sh, (0, 0), sh)
        im.paste(layer, (0, 0), layer)

    def run(self) -> None:
        for seg in self.cut["segments"]:
            (self.title if "title" in seg else self.clip)(seg)


def encode(frames: str, fps: int, out: str) -> None:
    if shutil.which("ffmpeg"):
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(fps), "-i", os.path.join(frames, "%05d.jpg"),
                        "-c:v", "libx264" if _has_x264() else "libopenh264", "-vf", "scale=out_range=tv:out_color_matrix=bt709,format=yuv420p", "-colorspace", "bt709", "-color_range", "tv", "-crf", "18",
                        "-preset", "slow", "-movflags", "+faststart", out], check=True)
        return
    subprocess.run(["gst-launch-1.0", "-q", "multifilesrc", f"location={frames}/%05d.jpg", "index=0",
                    f"caps=image/jpeg,framerate={fps}/1", "!", "jpegdec", "!", "videoconvert", "!",
                    "video/x-raw,format=I420", "!", "x264enc", "speed-preset=slow", "bitrate=14000", "key-int-max=60", "!",
                    "video/x-h264,profile=high", "!", "mp4mux", "faststart=true", "!", "filesink", f"location={out}"], check=True)


def _has_x264() -> bool:
    r = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"], capture_output=True, text=True)
    return "libx264" in r.stdout


def main() -> None:
    cut = json.load(open(sys.argv[1]))
    root, out = sys.argv[2], sys.argv[3]
    tmp = tempfile.mkdtemp(prefix="promo_", dir=os.path.dirname(os.path.abspath(out)))
    c = Cutter(cut, root, tmp)
    c.run()
    print(f"{c.n} frames ({c.n / c.fps:.1f}s), encoding…")
    encode(tmp, c.fps, out)
    shutil.rmtree(tmp)
    print("wrote", out)


if __name__ == "__main__":
    main()
