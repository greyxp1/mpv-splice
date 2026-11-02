"""Single-file exports through FFmpeg, leaving unchanged cuts on the smart path."""

import re
import subprocess
import tempfile
from fractions import Fraction


PROFILES = [
    dict(id='original', label='Original quality', format='source', video='source', audio='copy'),
    dict(id='share', label='Share · H.264 / MP4', format='mp4', video='h264', audio='aac'),
    dict(id='av1', label='AV1 / MP4', format='mp4', video='av1', audio='libopus'),
    dict(id='hevc', label='HEVC / MP4', format='mp4', video='hevc', audio='aac'),
    dict(id='webm', label='WebM / VP9', format='webm', video='libvpx-vp9', audio='libopus'),
    dict(id='gif', label='Animated GIF', format='gif', video='gif', audio='none'),
    dict(id='audio', label='Audio / M4A', format='ipod', video='none', audio='aac'),
]
EXTENSIONS = {'matroska': 'mkv', 'ipod': 'm4a', 'mpegts': 'ts', 'adts': 'aac'}


def capabilities() -> dict:
    import av
    encoders = subprocess.check_output(['ffmpeg', '-hide_banner', '-encoders'], text=True)
    muxers = subprocess.check_output(['ffmpeg', '-hide_banner', '-muxers'], text=True)
    result = dict(profiles=PROFILES, extensions=EXTENSIONS, video=[], audio=[], formats=[])
    for kind, name, description in re.findall(r'^\s*([VA])[A-Z.]{5}\s+(\S+)\s+(.+)$', encoders, re.M):
        result['video' if kind == 'V' else 'audio'].append(dict(id=name, label=f'{name} · {description}'))
    multiple = {'dash', 'fifo', 'hls', 'image2', 'image2pipe', 'null', 'segment', 'stream_segment', 'tee'}
    for name, description in re.findall(r'^\s*E\s+(\S+)\s+(.+)$', muxers, re.M):
        if name not in multiple:
            result['formats'].append(dict(id=name, label=f'{name} · {description}'))
            extensions = av.format.ContainerFormat(name).extensions
            if extensions and name not in EXTENSIONS:
                result['extensions'][name] = name if name in extensions else sorted(extensions)[0]
    return result


def needs_encoding(settings: dict) -> bool:
    return bool(settings.get('crop') or settings.get('size') or settings.get('fps')
                or settings.get('args') or settings.get('video', 'source') not in ('source', 'copy')
                or settings.get('audio', 'copy') != 'copy')


def auto_encoder(codec: str, width: int, height: int, pix_fmt: str) -> str:
    import av
    choices = {'h264': 'libx264', 'hevc': 'libx265', 'av1': 'libsvtav1'}
    if codec not in choices:
        return codec
    try:
        encoder = av.CodecContext.create(codec + '_nvenc', 'w')
        encoder.width, encoder.height = width, height
        encoder.pix_fmt = 'p010le' if pix_fmt == 'yuv420p10le' else pix_fmt
        encoder.time_base = Fraction(1, 30)
        if codec == 'hevc' and '444' in pix_fmt:
            encoder.options['profile'] = 'rext'
        encoder.open()
        return codec + '_nvenc'
    except (av.FFmpegError, ValueError):
        return 'libaom-av1' if codec == 'av1' and '444' in pix_fmt else choices[codec]


def export(input_path: str, selection: tuple, output: str, settings: dict, progress) -> None:
    import av
    import shlex
    with av.open(input_path) as media:
        source = next(iter(media.streams.video), None)
        source_codec = source.codec_context.codec.canonical_name if source else None
        width = settings.get('source_width') or (source.width if source else 0)
        height = settings.get('source_height') or (source.height if source else 0)
        source_fmt = source.codec_context.pix_fmt if source else 'yuv420p'
    video = settings.get('video', 'source')
    audio = settings.get('audio', 'copy')
    original = video == 'source'
    if original:
        video = source_codec or 'none'
    if not source and video not in ('none', 'copy'):
        raise ValueError('Input has no video stream')
    filters = []
    if crop := settings.get('crop'):
        x, y, w, h = map(int, crop)
        if min(x, y) < 0 or min(w, h) < 2 or x + w > width or y + h > height:
            raise ValueError('Crop is outside the video')
        width, height = w, h
        filters.append(f'crop={w}:{h}:{x}:{y}:exact=1')
    if size := settings.get('size'):
        match = re.fullmatch(r'(\d+)x(\d+)', size)
        if not match or min(map(int, match.groups())) < 2:
            raise ValueError('Size must be WIDTHxHEIGHT')
        width, height = map(int, match.groups())
        filters.append(f'scale={width}:{height}:force_original_aspect_ratio=decrease:force_divisible_by=2:reset_sar=1')
    if fps := settings.get('fps'):
        if not 0 < float(Fraction(str(fps))) <= 240:
            raise ValueError('Frame rate must be between 0 and 240')
        filters.append(f'fps={fps}')
    if filters and video == 'copy':
        raise ValueError('Choose a video encoder to apply edits')
    duration = float(selection[1] - selection[0])
    command = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin', '-n',
               '-ss', str(float(selection[0]))]
    if settings.get('rotation') is not None:
        command += ['-display_rotation', str(-settings['rotation'])]
    command += ['-i', input_path, '-t', str(duration),
               '-map', '0:v:0?', '-map', '0:a?', '-sn', '-dn']
    if video == 'none':
        command += ['-vn']
    else:
        pix_fmt = settings.get('pix_fmt') or (source_fmt if original else
                  'yuv420p' if video in ('h264', 'hevc', 'av1', 'libvpx-vp9') else None)
        if video != 'copy':
            if pix_fmt and ('420' in pix_fmt or '422' in pix_fmt) and not settings.get('size'):
                filters.append('scale=trunc(iw/2)*2:trunc(ih/2)*2')
                width, height = width // 2 * 2, height // 2 * 2
            video = auto_encoder(video, width, height, pix_fmt or 'yuv420p')
        if video == 'gif':
            filters += ['split[palette_in][pixels];[palette_in]palettegen[palette];[pixels][palette]paletteuse']
        command += ['-c:v', video]
        quality = {'high': 10 if original else 18, 'balanced': 23, 'small': 28}[settings.get('quality', 'high')]
        if video.endswith('_nvenc'):
            command += ['-preset', 'p4', '-rc', 'vbr', '-cq', str(quality), '-b:v', '0']
            if video == 'hevc_nvenc' and '444' in (pix_fmt or ''):
                command += ['-profile:v', 'rext']
        elif video in ('libx264', 'libx265'):
            command += ['-preset', 'fast', '-crf', str(quality)]
        elif video in ('libsvtav1', 'libaom-av1', 'libvpx-vp9'):
            command += ['-crf', str(quality + 6), '-b:v', '0']
            command += ['-preset', '8'] if video == 'libsvtav1' else ['-cpu-used', '6']
        if pix_fmt and video not in ('copy', 'gif'):
            command += ['-pix_fmt', pix_fmt]
        if filters:
            command += ['-vf', ','.join(filters)]
    command += ['-an'] if audio == 'none' else ['-c:a', audio]
    if audio not in ('none', 'copy'):
        command += ['-b:a', '192k']
    format_name = settings.get('format', 'source')
    if format_name == 'mp4':
        command += ['-movflags', '+faststart']
    if format_name != 'source':
        command += ['-f', format_name]
    extra = shlex.split(settings.get('args', ''))
    command += extra + ['-progress', 'pipe:1', output]
    total = max(1, round(duration * 1_000_000))
    progress(0, total)
    with tempfile.TemporaryFile(mode='w+t') as errors:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=errors, text=True)
        for line in process.stdout:
            if line.startswith('out_time_us='):
                value = line.split('=', 1)[1].strip()
                if value.lstrip('-').isdigit():
                    progress(max(0, min(total, int(value))), total)
        if process.wait():
            errors.seek(0)
            raise RuntimeError(errors.read()[-4000:].strip() or 'FFmpeg export failed')
    progress(total, total)
