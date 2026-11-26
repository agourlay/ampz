"""Build the color atlas from NotoColorEmoji.ttf and Unicode emoji-test.txt."""
import struct
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def tile(font, text):
    # Multi-cell output means this font couldn't shape the sequence as one glyph.
    if abs(font.getlength(text) - font.getlength("😀")) > 1:
        return None
    image = Image.new("RGBA", (136, 128))
    ImageDraw.Draw(image).text((0, 0), text, font=font, embedded_color=True)
    image = image.resize((16, 16), Image.Resampling.LANCZOS)
    pixels = list(struct.iter_unpack("4B", image.tobytes()))
    opaque = [p[:3] for p in pixels if p[3] >= 96]
    if not opaque:
        return None
    colors = Image.new("RGB", (len(opaque), 1))
    colors.putdata(opaque)
    palette = colors.quantize(colors=15)
    rgb = bytes(palette.getpalette()[:45]).ljust(45, b"\0")
    indices = iter(palette.tobytes())
    packed = [next(indices) + 1 if p[3] >= 96 else 0 for p in pixels]
    return rgb + bytes((a << 4) | b for a, b in zip(packed[::2], packed[1::2]))


def main(font_path, sequences_path):
    font = ImageFont.truetype(font_path, 109, layout_engine=ImageFont.Layout.RAQM)
    entries, tiles = {}, {}
    for line in Path(sequences_path).read_text(encoding="utf-8").splitlines():
        definition = line.partition("#")[0].strip()
        if not definition:
            continue
        codes, _ = definition.split(";")
        text = "".join(chr(int(c, 16)) for c in codes.split())
        bitmap = tile(font, text)
        if bitmap:
            entries[text.encode()] = tiles.setdefault(bitmap, len(tiles))

    index, keys = bytearray(), bytearray()
    start = 8 + len(entries) * 8
    for key, glyph in sorted(entries.items()):
        index.extend(struct.pack("<IHH", start + len(keys), len(key), glyph))
        keys.extend(key)
    header = struct.pack("<II", len(entries), start + len(keys))
    Path(__file__).with_name("emoji.bin").write_bytes(header + index + keys + b"".join(tiles))


if __name__ == "__main__":
    main(*sys.argv[1:])
