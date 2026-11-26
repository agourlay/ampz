"""Rebuild japanese.bin from NotoSansCJK-Regular.ttc using Pillow and fc-query."""

import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def main(font_path):
    font = ImageFont.truetype(font_path, 16, index=0)
    if font.getname()[0] != "Noto Sans CJK JP":
        raise ValueError("The first face must be Noto Sans CJK JP")
    blocks = (
        (0x3000, 0x30FF), (0x31F0, 0x31FF), (0x3400, 0x9FFF),
        (0xF900, 0xFAFF), (0xFF01, 0xFF9F), (0x1AFF0, 0x1B16F),
        (0x20000, 0x323AF),
    )
    charset = subprocess.check_output(
        ["fc-query", "-i", "0", "--format", "%{charset}", font_path], text=True
    )
    data = bytearray()
    for span in charset.split():
        bounds = [int(value, 16) for value in span.split("-")]
        for code in range(bounds[0], bounds[-1] + 1):
            if any(low <= code <= high for low, high in blocks):
                image = Image.new("1", (16, 16))
                ImageDraw.Draw(image).text((0, 14), chr(code), font=font, fill=1, anchor="ls")
                data.extend(code.to_bytes(3, "little"))
                data.extend(image.tobytes())
    Path(__file__).with_name("japanese.bin").write_bytes(data)


if __name__ == "__main__":
    main(sys.argv[1])
