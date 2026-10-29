#!/usr/bin/env python3
"""Unattended play test for the recompiled Digger HD.

Launches the game silently with a fresh save directory, drives the pad through
PAD_SCRIPT (cellPad re-reads the file as it grows), recognises the screen from
the frames the renderer dumps, and fails on a stall, a FIFO error, a crash or
a screen that does not arrive in time.

Screens are told apart by comparing a thumbnail of the newest frame with
reference thumbnails in tests/refs/<screen>/*.png. Those are cut from the
user's own game by `--calibrate`, which runs the same route and keeps every
dumped frame for labelling; they are not committed.

Usage:
  playtest.py [--scenario level] [--play-seconds 60] [--keep-frames]
  playtest.py --calibrate --seconds 120
"""
import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / 'build' / 'DiggerHDRecomp'
GAME = ROOT / 'run' / 'hdd0' / 'game' / 'NPEB00121'
DEV_FLASH = ROOT / 'run' / 'dev_flash'
REFS = ROOT / 'tests' / 'refs'
RUNS = ROOT / 'tests' / 'runs'

# CELL_PAD_CTRL_* bits (libs/input/cellPad.h).
BTN = {
    'select': 1 << 0, 'start': 1 << 3, 'up': 1 << 4, 'right': 1 << 5,
    'down': 1 << 6, 'left': 1 << 7, 'l2': 1 << 8, 'r2': 1 << 9,
    'l1': 1 << 10, 'r1': 1 << 11, 'triangle': 1 << 12, 'circle': 1 << 13,
    'cross': 1 << 14, 'square': 1 << 15,
}

# Log lines that end a run as failed.
FATAL = (
    'FIFO JUMP to unmapped',
    'drain stalled',
    'tail flush stalled',
    'halting the SPU',
    'Segmentation fault',
    'unresolved indirect call',
)

THUMB = (64, 36)
STALL_SECONDS = 3


def mono_ms():
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC) // 1_000_000


def thumb(path):
    img = Image.open(path).convert('L').resize(THUMB, Image.BILINEAR)
    return np.asarray(img, dtype=np.float32) / 255.0


def load_refs():
    refs = {}
    if REFS.is_dir():
        for d in sorted(REFS.iterdir()):
            if d.is_dir():
                refs[d.name] = [thumb(p) for p in sorted(d.glob('*.png'))]
    return {k: v for k, v in refs.items() if v}


def classify(frame, refs):
    best, best_d = None, 1e9
    for name, thumbs in refs.items():
        for t in thumbs:
            d = float(np.mean(np.abs(frame - t)))
            if d < best_d:
                best, best_d = name, d
    return best, best_d


class Pad:
    """Appends timed presses to the PAD_SCRIPT file."""

    def __init__(self, path):
        self.path = path
        self.lines = ['# written by playtest.py']
        self.flush()

    def flush(self):
        tmp = self.path.with_suffix('.tmp')
        tmp.write_text('\n'.join(self.lines) + '\n')
        os.replace(tmp, self.path)

    def press(self, *names, hold_ms=200, delay_ms=150):
        mask = 0
        for n in names:
            mask |= BTN[n]
        t = mono_ms() + delay_ms
        self.lines.append(f'{t} {mask:#06x}')
        self.lines.append(f'{t + hold_ms} 0')
        self.flush()
        return t + hold_ms


class Game:
    def __init__(self, run_dir, keep_frames):
        self.run_dir = run_dir
        self.keep_frames = keep_frames
        self.log_path = run_dir / 'game.log'
        self.frame_path = run_dir / 'frame.ppm'
        self.frames_dir = run_dir / 'frames'
        self.frames_dir.mkdir()
        self.pad = Pad(run_dir / 'pad.txt')
        env = dict(os.environ)
        env.update({
            'PS3_TITLE': 'Digger HD (test)',
            'PS3_HDD0_ROOT': str(run_dir / 'hdd0'),
            'PS3_HDD1_ROOT': str(run_dir / 'hdd1'),
            'PS3_DEV_FLASH': str(DEV_FLASH),
            'PS3_VFS_ROOT': str(GAME),
            'PS3_GAMEDATA_ROOT': str(run_dir / 'gamedata'),
            'PAD_SCRIPT': str(self.pad.path),
            'PS3RECOMP_METAL_FPS': '1',
            'PS3RECOMP_METAL_FRAME_DUMP': str(self.frame_path),
            'GCM_RECDBG': '1',
            'AUDIO_WAV': str(run_dir / 'mix.f32'),
            'AUDIO_RATE': '1',
        })
        (run_dir / 'hdd0' / 'game').mkdir(parents=True)
        os.symlink(GAME, run_dir / 'hdd0' / 'game' / 'NPEB00121')
        (run_dir / 'hdd1').mkdir()
        self.log = open(self.log_path, 'wb')
        self.proc = subprocess.Popen(
            [str(BINARY), str(GAME / 'USRDIR' / 'EBOOT.elf')],
            cwd=run_dir, env=env, stdout=self.log, stderr=subprocess.STDOUT)
        self.read_pos = 0
        self.fps = []            # (host time, display fps, guest fps)
        self.fatal = None
        self.frame_mtime = 0
        self.frame_count = 0
        self.last_frame = None

    def poll_log(self):
        with open(self.log_path, 'rb') as f:
            f.seek(self.read_pos)
            data = f.read()
        cut = data.rfind(b'\n') + 1
        self.read_pos += cut
        for raw in data[:cut].splitlines():
            line = raw.decode('utf-8', 'replace')
            if line.startswith('[RSX FPS]'):
                fields = dict(p.split('=') for p in line.split()[2:] if '=' in p)
                self.fps.append((time.time(), float(fields.get('display', 0)),
                                 float(fields.get('guest', 0))))
            if self.fatal is None:
                for pat in FATAL:
                    if pat in line:
                        self.fatal = line.strip()

    def poll_frame(self):
        try:
            m = self.frame_path.stat().st_mtime_ns
        except FileNotFoundError:
            return None
        if m == self.frame_mtime:
            return None
        self.frame_mtime = m
        try:
            img = Image.open(self.frame_path)
            img.load()
        except Exception:
            return None   # caught mid-write; the next dump replaces it
        self.frame_count += 1
        png = self.frames_dir / f'{self.frame_count:04d}.png'
        img.convert('RGB').resize((320, 180), Image.BILINEAR).save(png)
        self.last_frame = png
        if not self.keep_frames:
            old = self.frames_dir / f'{self.frame_count - 8:04d}.png'
            if old.exists():
                old.unlink()
        return png

    def stalled(self):
        """No guest frame for STALL_SECONDS consecutive reports, after frames began."""
        if not any(g > 0 for _, _, g in self.fps):
            return False
        tail = self.fps[-STALL_SECONDS:]
        return len(tail) == STALL_SECONDS and all(g == 0 for _, _, g in tail)

    def alive(self):
        return self.proc.poll() is None

    def stop(self):
        if self.alive():
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.log.close()


def audio_report(path):
    """Loudness of the captured mix (f32 stereo 48 kHz), per second."""
    try:
        a = np.fromfile(path, dtype='<f4')
    except FileNotFoundError:
        return {'seconds': 0, 'loud_seconds': 0, 'rms_db': []}
    n = len(a) // (2 * 48000)
    if n == 0:
        return {'seconds': 0, 'loud_seconds': 0, 'rms_db': []}
    sec = a[:n * 96000].reshape(n, 96000)
    rms = np.sqrt(np.mean(sec * sec, axis=1))
    db = [round(float(20 * np.log10(max(r, 1e-9))), 1) for r in rms]
    return {'seconds': n, 'loud_seconds': int(np.sum(rms > 1e-3)), 'rms_db': db}


def tick(game, report):
    """One monitoring step; returns a failure string or None."""
    game.poll_log()
    png = game.poll_frame()
    if game.fatal:
        return 'fatal log line: ' + game.fatal
    if game.stalled():
        return f'stall: no guest frame for {STALL_SECONDS} s'
    if not game.alive():
        return f'game exited with code {game.proc.returncode}'
    return png


def run_route(game, refs, args, report):
    """Title -> menu -> (dialog) -> level, then play."""
    state, since = None, time.time()
    deadline = {'intro': 90, 'title': 30, 'menu': 30, 'dialog': 20, 'pause': 20, 'gameover': 30}
    next_press = 0
    play_until = None
    rng = np.random.default_rng(args.seed)
    while True:
        r = tick(game, report)
        if isinstance(r, str):
            return r
        if r:
            screen, dist = classify(thumb(r), refs)
            report['screens'].append({'t': round(time.time() - report['t0'], 1),
                                      'frame': Path(r).name, 'screen': screen,
                                      'dist': round(dist, 4)})
            if screen != state:
                state, since = screen, time.time()
                print(f'[playtest] {report["screens"][-1]["t"]:6.1f}s screen={screen} '
                      f'dist={dist:.3f}', flush=True)
        now = time.time()
        if state == 'level' and args.probe_fire:
            # Press each candidate alone, well apart, so the log can tell
            # which one the game reads as fire.
            report['reached_level'] = True
            for name in ('cross', 'square', 'circle', 'triangle', 'r1', 'l1', 'r2', 'l2'):
                for _ in range(3):
                    game.pad.press(name, hold_ms=300, delay_ms=50)
                    t_end = time.time() + 1.2
                    while time.time() < t_end:
                        r = tick(game, report)
                        if isinstance(r, str):
                            return r
                        time.sleep(0.1)
            return None
        if state == 'level':
            if play_until is None:
                play_until = now + args.play_seconds
                report['reached_level'] = True
            if now >= play_until:
                return None
            if now >= next_press:
                d = rng.choice(['up', 'down', 'left', 'right'])
                extra = ('cross',) if rng.random() < 0.3 else ()
                game.pad.press(d, *extra, hold_ms=int(rng.integers(300, 1200)), delay_ms=50)
                next_press = now + 0.4
            time.sleep(0.1)
            continue
        if state in deadline and now - since > deadline[state]:
            return f'stuck on screen {state} for {deadline[state]} s'
        if now >= next_press:
            if state == 'gameover':
                # Square starts a new game from the game-over screen.
                game.pad.press('square')
                next_press = now + 3
            elif state == 'pause':
                # The route never presses START in a level; a pause is the
                # game's own (focus loss) or a stray press. Resume with circle.
                game.pad.press('circle')
                next_press = now + 3
            elif state == 'title':
                game.pad.press('start')
                next_press = now + 3
            elif state == 'menu':
                game.pad.press('cross')
                next_press = now + 3
            elif state == 'dialog':
                game.pad.press('square')
                next_press = now + 3
        if now - report['t0'] > args.timeout:
            return f'timeout after {args.timeout} s on screen {state}'
        time.sleep(0.1)


def calibrate(game, args, report):
    """Press START then cross every few seconds and keep every frame."""
    t_end = time.time() + args.seconds
    n = 0
    while time.time() < t_end:
        r = tick(game, report)
        if isinstance(r, str):
            return r
        n += 1
        if n % 40 == 0:
            game.pad.press('start' if (n // 40) % 2 else 'cross')
        time.sleep(0.1)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--scenario', default='level')
    ap.add_argument('--play-seconds', type=float, default=60)
    ap.add_argument('--timeout', type=float, default=300)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--keep-frames', action='store_true')
    ap.add_argument('--probe-fire', action='store_true')
    ap.add_argument('--calibrate', action='store_true')
    ap.add_argument('--seconds', type=float, default=120)
    args = ap.parse_args()

    RUNS.mkdir(parents=True, exist_ok=True)
    run_dir = RUNS / time.strftime('%Y%m%d-%H%M%S')
    run_dir.mkdir()
    report = {'run': str(run_dir), 't0': time.time(), 'screens': [],
              'reached_level': False}
    refs = load_refs()
    if not args.calibrate and not refs:
        sys.exit('no reference frames in tests/refs; run --calibrate and label them')

    game = Game(run_dir, keep_frames=args.keep_frames or args.calibrate)
    print(f'[playtest] run dir {run_dir}', flush=True)
    failure = 'harness error'
    try:
        failure = calibrate(game, args, report) if args.calibrate else run_route(game, refs, args, report)
    finally:
        if failure and game.alive():
            # The game flushes its log every 50 ms; let the lines around the
            # failure land, and keep where every thread stands.
            time.sleep(1.5)
            subprocess.run(['sample', str(game.proc.pid), '2', '-file',
                            str(run_dir / 'sample.txt')],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        game.stop()
        game.poll_log()
    fps = [g for _, _, g in game.fps if g > 0]
    report.update({
        'result': 'fail' if failure else 'pass',
        'failure': failure,
        'frames': game.frame_count,
        'guest_fps_median': float(np.median(fps)) if fps else 0.0,
        'guest_fps_min': float(min(fps)) if fps else 0.0,
        'last_frame': str(game.last_frame) if game.last_frame else None,
    })
    if failure:
        with open(game.log_path, 'rb') as f:
            tail = f.read()[-20000:].decode('utf-8', 'replace').splitlines()
        report['log_tail'] = [l for l in tail if not l.startswith(('[cellSpurs] _SendSignal',
                                                                     '[audio-ring]'))][-60:]
    report['audio'] = audio_report(run_dir / 'mix.f32')
    if not failure and not args.calibrate and report['reached_level'] and \
            report['audio']['loud_seconds'] < report['audio']['seconds'] // 2:
        failure = (f"audio mostly silent: {report['audio']['loud_seconds']} of "
                   f"{report['audio']['seconds']} s above -60 dB")
        report['result'] = 'fail'
        report['failure'] = failure
    report.pop('t0')
    (run_dir / 'report.json').write_text(json.dumps(report, indent=1))
    print(f'[playtest] {report["result"].upper()}'
          + (f': {failure}' if failure else '')
          + f' | frames {game.frame_count} | guest fps median {report["guest_fps_median"]:.1f}'
          + f' | reached level: {report["reached_level"]}'
          + f' | audio {report["audio"]["loud_seconds"]}/{report["audio"]["seconds"]} s loud', flush=True)
    sys.exit(1 if failure else 0)


if __name__ == '__main__':
    main()
