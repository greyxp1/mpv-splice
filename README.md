# Splice

Frame-accurate cutting and single-video editing for mpv, forked from
[skeskinen/smartcut](https://github.com/skeskinen/smartcut). Unchanged trims copy
complete GOPs and re-encode only the GOPs around each cut point, at
near-lossless quality so they blend with the rest of the clip.

## Usage

Copy the `mpv-splice` directory to mpv's `scripts` directory and put
`mpv-splice-backend` and `ffmpeg` in `PATH`. Requires mpv 0.41 or newer.
The plugin includes its ModernZ-derived interface and replaces other OSC scripts.
The Nix package points to its backend and can go straight into mpv's script list.

Press `e` to toggle editing with trim handles and a crop rectangle. Press `i`
and `o` to mark the range, or click its timestamps to enter it. The three-dot
menu opens Export settings or playback controls. Enter, Escape or `e` leaves
editing while keeping the edits. Exports keep the source file untouched.
Press `C` to cancel an export.

Drag the crop rectangle's edges or corners to resize, or drag inside to move
it. Arrow keys move one pixel and Shift-arrows resize. Hold Ctrl for ten-pixel
steps. Shift-drag draws a new rectangle. The preview dims the excluded area
without changing the video framing.

Original quality keeps the source codec and colour detail. Cropping, resizing
and conversion re-encode the selected range and can lose quality.

Defaults can be changed in `script-opts/mpv-splice.conf`:

```ini
backend=mpv-splice-backend
cancel_key=C
output_prefix=cut_
```

## Notes

HEVC and AV1 boundaries use NVENC on NVIDIA GPUs, which is 10 to 20 times
faster than the software encoders used otherwise.

H.264 open GOPs may need re-encoding until the next IDR frame. Files with an
audio track that ends before the cut may be read to the end.

Existing files are never overwritten. A cut is written to a hidden directory
next to the source and published with a hard link. If the output name is taken
by then, or the filesystem has no hard links (FAT and some network mounts), the
completed cut stays in the hidden directory and its path is shown.

The backend is MIT-licensed. The UI derives from ModernZ and uosc under LGPL-2.1.
