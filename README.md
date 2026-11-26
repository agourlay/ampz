# ampz

<p align="center">
  <img src="src/assets/playhead.svg" width="224" height="224" alt="Playhead, the ampz logo: a peach A with a play button cutout">
</p>

<p align="center">
  <a href="https://github.com/agourlay/ampz/actions/workflows/ci.yml"><img src="https://github.com/agourlay/ampz/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
  <a href="https://github.com/agourlay/ampz/releases"><img src="https://img.shields.io/badge/releases-Linux-377A68" alt="Linux releases"></a>
  <a href="#build-from-source"><img src="https://img.shields.io/badge/Zig-0.17.1-F7A41D" alt="Zig 0.17.1"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="License: Apache-2.0"></a>
  <img src="https://img.shields.io/badge/%E2%9C%A8-AI%20generated-7057a3" alt="AI generated">
</p>

ampz is a Linux MP3 player written from scratch in Zig with zero third-party dependencies. It scans a music folder and its subfolders, lets you browse by artist and album, and plays the filtered tracks in order.

## Download and play

Download the Linux binary matching `uname -m` (`x86_64` or `aarch64`) from [GitHub Releases](https://github.com/agourlay/ampz/releases). You’ll need X11 or XWayland and either PulseAudio or PipeWire’s PulseAudio service.

From the download directory, make the player executable and start it with your music folder.

```sh
mv "ampz-$(uname -m)-linux" ampz
chmod +x ampz
./ampz "$HOME/Music"
```

![ampz showing the search bar, artist and album filters, track list, and playback controls](ampz.png)

## Library and controls

ampz reads ID3v1 and ID3v2 tags. For untagged files, it takes the artist, album, and title from `Artist/Album/Title.mp3`. Each credited ID3v2.4 artist is searchable. Track names support Japanese text and color emoji.

Search narrows the current artist and album selection as you type. Words can match different fields in any order. For example, `quartet live` can match “City Quartet” in the artist field and “Live Sessions” in the album field. Search also covers titles and relative paths. ASCII letters match regardless of case.

| Action | Control |
| --- | --- |
| Search | Ctrl+F or / |
| Paste into search | Ctrl+V |
| Leave search | Down or Tab to browse results, Escape to clear |
| Select a track | Up, Down, Page Up, Page Down |
| Play | Enter or double-click a track |
| Pause or resume | Space |
| Previous or next track | Transport arrows |
| Seek | Click the progress bar or press Left or Right to skip five seconds |
| Quit | Q or Escape outside search |

The decoder supports mono and stereo MPEG-1, MPEG-2, and MPEG-2.5 Layer III at indexed constant or variable bitrates. Free-format MP3s are unsupported.

## Configuration

Save your preferred folder once, then start ampz without an argument.

```sh
./ampz --set-music-dir "$HOME/Music"
./ampz
```

ampz stores `music_folder` in `$XDG_CONFIG_HOME/ampz/config.json`. If `XDG_CONFIG_HOME` is empty, unset, or relative, it uses `~/.config/ampz/config.json`. Relative paths in the JSON resolve from the config file’s directory. A command-line folder takes precedence over `AMPZ_MUSIC_DIR`, which takes precedence over the saved folder. [Example config](config.json)

## Build from source

Zig 0.17.1 builds ampz offline with zero third-party dependencies. The executable is written to `zig-out/bin/ampz`.

```sh
zig build
zig build test
```

## Credits

Thanks to [Quod Libet](https://quodlibet.readthedocs.io/) for the browser design, [Zig](https://ziglang.org/) for the toolchain, and [X.Org](https://www.x.org/), [PulseAudio](https://www.freedesktop.org/wiki/Software/PulseAudio/), and [PipeWire](https://pipewire.org/) for the desktop and audio services.

We used [LAME](https://lame.sourceforge.io/) to generate test tones and [FFmpeg](https://ffmpeg.org/) to check the decoded samples. [minimp3](https://github.com/lieff/minimp3) helped with intensity stereo, and [Mutagen](https://mutagen.readthedocs.io/) with tag verification. Decoder references include the [MPEG audio specification](https://csclub.uwaterloo.ca/~pbarfuss/ISO11172-3.pdf), LAME’s [Huffman codes](https://github.com/lameproject/lame/blob/master/libmp3lame/tables.c) and [scalefactor bands](https://github.com/lameproject/lame/blob/master/libmp3lame/quantize_pvt.c), and FFmpeg’s [synthesis coefficients](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/mpegaudiodsp_data.c).

[Noto Sans CJK JP](https://github.com/notofonts/noto-cjk) and [Noto Color Emoji](https://github.com/googlefonts/noto-emoji) supply the glyphs. The Unicode Consortium supplies the emoji sequences.

## License

Run `./ampz --license` to read the licenses included in the binary. ampz’s original code uses the [Apache License 2.0](LICENSE). The fonts and Unicode data have separate [third-party notices](src/fonts/LICENSE.txt).
