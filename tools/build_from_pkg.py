#!/usr/bin/env python3
"""From the user's own Digger HD package to a Mac app and iPad / Apple TV
builds, with nothing done by hand. The Mac builder app (builder/) runs this.

  1. extract   the .pkg (vendor/ps3recomp/tools/pkg_extract.py)
  2. check     it is Digger HD (PARAM.SFO TITLE_ID NPEB00121)
  3. decrypt   EBOOT.BIN and scenes.sdat with the installed RPCS3
  4. firmware  the MP3/ATRAC decoders from RPCS3's installed firmware
  5. lift      the PPU code (ppu_loader.py, ppu_lifter.py)
  6. spu       the job-queue policy module and the firmware MP3 decoder
  7. runtime   vendor/ps3recomp at v0.18.0 with patches/ applied
  8. icons     tools/make_icons.py
  9. mac       build and assemble "Digger HD.app"
 10. ios/tvos  build, bundle, sign (tools/ios_bundle.sh), install

Progress goes to stdout as "STEP <n>/<total> <name>: <text>", and the run ends
with "DONE <summary>" or "ERROR <reason>". Everything is written under --work
(default work/ in the repository); finished steps are skipped on a re-run when
their inputs have not changed.

Usage:
  build_from_pkg.py <game.pkg> [--mac] [--ios] [--tvos]
                    [--install-ios UDID] [--install-tvos UDID] [--cover IMAGE]
"""
import argparse
import hashlib
import os
import shutil
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / 'vendor' / 'ps3recomp'
TITLE_ID = 'NPEB00121'
EBOOT_SHA256 = '90a74374149fe4ef'          # the release the lift and patches are tested on
PS3RECOMP_TAG = 'v0.18.0'
PS3RECOMP_URL = 'https://github.com/sp00nznet/ps3recomp.git'

DEFAULT_RPCS3 = '/Applications/RPCS3.app/Contents/MacOS/rpcs3'
DEFAULT_FIRMWARE = Path.home() / 'Library/Application Support/rpcs3/dev_flash'


def local_config():
    """config.local.json beside the repository root (not committed): this
    machine's paths -- "xcode", "ios_libs", "sign_id", "profile_ios",
    "profile_tvos", "work". Anything missing falls back to a default."""
    p = ROOT / 'config.local.json'
    if p.is_file():
        import json
        return json.loads(p.read_text())
    return {}


def default_xcode():
    try:
        return subprocess.run(['xcode-select', '-p'], capture_output=True, text=True).stdout.strip()
    except OSError:
        return ''


class Fail(Exception):
    pass


class Run:
    def __init__(self, args):
        self.a = args
        self.work = Path(args.work).resolve()
        self.work.mkdir(parents=True, exist_ok=True)
        self.game = self.work / 'game' / TITLE_ID
        self.elf = self.game / 'USRDIR' / 'EBOOT.elf'
        self.flash = self.work / 'dev_flash'
        self.spu = self.work / 'spu-inputs'
        self.icons = self.work / 'icons'
        self.out = self.work / 'out'
        self.logs = self.work / 'logs'
        self.logs.mkdir(exist_ok=True)
        self.steps = ['extract', 'check', 'decrypt', 'firmware', 'lift', 'spu', 'runtime', 'icons']
        if args.mac:
            self.steps.append('mac')
        if args.ios:
            self.steps.append('ios')
        if args.tvos:
            self.steps.append('tvos')
        self.n = 0
        self.done = []

    # ---- helpers ------------------------------------------------------------
    def step(self, text):
        name = self.steps[self.n]
        self.n += 1
        print(f'STEP {self.n}/{len(self.steps)} {name}: {text}', flush=True)

    def info(self, text):
        print(f'  {text}', flush=True)

    def sh(self, cmd, log, env=None, cwd=None):
        """Run cmd, its output into logs/<log>; fail with the log's tail."""
        path = self.logs / log
        with open(path, 'w') as f:
            r = subprocess.run([str(c) for c in cmd], stdout=f, stderr=subprocess.STDOUT,
                               env=env, cwd=cwd)
        if r.returncode != 0:
            tail = path.read_text(errors='replace').strip().splitlines()[-12:]
            raise Fail(f'{Path(str(cmd[0])).name} failed (log: {path})\n    ' + '\n    '.join(tail))
        return path

    @staticmethod
    def sha256(path):
        h = hashlib.sha256()
        with open(path, 'rb') as f:
            for block in iter(lambda: f.read(1 << 20), b''):
                h.update(block)
        return h.hexdigest()

    def stamp_ok(self, name, value):
        p = self.work / f'.{name}.stamp'
        return p.is_file() and p.read_text() == value

    def stamp(self, name, value):
        (self.work / f'.{name}.stamp').write_text(value)

    # ---- steps --------------------------------------------------------------
    def extract(self):
        pkg = Path(self.a.pkg).resolve()
        if not pkg.is_file():
            raise Fail(f'no such package: {pkg}')
        self.step(f'unpacking {pkg.name}')
        digest = self.sha256(pkg)
        if self.stamp_ok('extract', digest) and (self.game / 'USRDIR' / 'EBOOT.BIN').is_file():
            self.info('already unpacked')
            return
        if self.game.exists():
            shutil.rmtree(self.game)
        self.game.mkdir(parents=True)
        self.sh([sys.executable, VENDOR / 'tools' / 'pkg_extract.py', pkg, self.game], 'extract.log')
        if not (self.game / 'USRDIR' / 'EBOOT.BIN').is_file():
            raise Fail('the package has no USRDIR/EBOOT.BIN -- is it a PS3 game package?')
        self.stamp('extract', digest)

    def check(self):
        self.step('reading PARAM.SFO')
        sfo = (self.game / 'PARAM.SFO').read_bytes()
        magic, _ver, key_off, data_off, count = struct.unpack('<4sIIII', sfo[:20])
        if magic != b'\0PSF':
            raise Fail('PARAM.SFO is not a PSF file')
        fields = {}
        for i in range(count):
            k_off, _fmt, length, _max, d_off = struct.unpack('<HHIII', sfo[20 + i * 16:36 + i * 16])
            key = sfo[key_off + k_off:].split(b'\0', 1)[0].decode()
            fields[key] = sfo[data_off + d_off:data_off + d_off + length].rstrip(b'\0').decode(errors='replace')
        title, tid = fields.get('TITLE', '?'), fields.get('TITLE_ID', '?')
        self.info(f'{title} ({tid}, version {fields.get("APP_VER", "?")})')
        if tid != TITLE_ID:
            raise Fail(f'this builder makes Digger HD ({TITLE_ID}); the package is {title} ({tid})')

    def decrypt(self):
        self.step('decrypting EBOOT.BIN and scenes.sdat with RPCS3')
        usr = self.game / 'USRDIR'
        if not (self.elf.is_file() and (usr / 'scenes.sdat.dec').is_file()):
            rpcs3 = Path(self.a.rpcs3)
            if not rpcs3.is_file():
                raise Fail(f'RPCS3 not found at {rpcs3}: it decrypts the game (install it, or pass --rpcs3)')
            self.sh([rpcs3, '--decrypt', usr / 'EBOOT.BIN', '--decrypt', usr / 'scenes.sdat'],
                    'decrypt.log', cwd=self.work)
            if not self.elf.is_file():
                raise Fail('RPCS3 did not write EBOOT.elf (see logs/decrypt.log)')
            # The runtime reads a decrypted EDAT from "<file>.dec", newer than the file.
            shutil.copyfile(usr / 'scenes.sdat.unedat', usr / 'scenes.sdat.dec')
            (usr / 'scenes.sdat.unedat').unlink()
        digest = self.sha256(self.elf)
        if not digest.startswith(EBOOT_SHA256):
            raise Fail(f'EBOOT.elf is a different release (SHA-256 {digest[:16]}); '
                       f'this build is made for {EBOOT_SHA256}')
        self.info(f'EBOOT.elf SHA-256 {digest[:16]} -- the tested release')

    def firmware(self):
        self.step("copying the firmware's MP3/ATRAC decoders")
        src = Path(self.a.firmware) / 'sys' / 'external'
        dst = self.flash / 'sys' / 'external'
        dst.mkdir(parents=True, exist_ok=True)
        for name in ('flashMP3.pic', 'flashATRAC.pic'):
            if not (src / name).is_file():
                raise Fail(f'{src / name} is missing: install the PS3 firmware in RPCS3 '
                           f'(File > Install Firmware), or pass --firmware')
            shutil.copyfile(src / name, dst / name)

    def lift(self):
        self.step('lifting the PPU code (about half a minute)')
        digest = self.sha256(self.elf)
        rec = self.work / 'recompiled'
        if self.stamp_ok('lift', digest) and (rec / 'ppu_recomp.h').is_file():
            self.info('already lifted')
            return
        out = self.work / 'loader'
        out.mkdir(exist_ok=True)
        if rec.exists():
            shutil.rmtree(rec)
        rec.mkdir()
        tools = VENDOR / 'tools'
        self.sh([sys.executable, tools / 'ppu_loader.py', self.elf, '-o', out], 'loader.log')
        self.sh([sys.executable, tools / 'ppu_lifter.py', self.elf,
                 '--functions', out / 'EBOOT.functions.json',
                 '--hle-stubs', out / 'EBOOT.imports.json', '--output', rec], 'lift.log')
        self.info(next((l.strip() for l in (self.logs / 'lift.log').read_text().splitlines()
                        if 'functions lifted' in l), 'lifted'))
        self.stamp('lift', digest)

    def spu_inputs(self):
        self.step('wrapping the job-queue policy module, lifting the MP3 decoder')
        self.spu.mkdir(exist_ok=True)
        self.sh([sys.executable, ROOT / 'tools' / 'wrap_jobqueue_pm.py', self.elf,
                 VENDOR / 'tools', self.spu / 'jobqueue_pm.elf'], 'jobqueue_pm.log')
        self.sh([sys.executable, ROOT / 'tools' / 'lift_flashmp3.py',
                 self.flash / 'sys' / 'external' / 'flashMP3.pic', VENDOR, self.spu / 'flashmp3'],
                'flashmp3.log')

    def runtime(self):
        self.step(f'checking ps3recomp {PS3RECOMP_TAG} with the port\'s patches')
        patches = sorted(str(p) for p in (ROOT / 'patches').glob('*.patch'))
        if not (VENDOR / '.git').exists():
            self.info(f'cloning ps3recomp {PS3RECOMP_TAG}')
            self.sh(['git', 'clone', '--depth', '1', '--branch', PS3RECOMP_TAG, PS3RECOMP_URL, VENDOR],
                    'clone.log')
        applied = subprocess.run(['git', '-C', VENDOR, 'apply', '--reverse', '--check'] + patches,
                                 capture_output=True).returncode == 0
        if applied:
            self.info(f'{len(patches)} patches in place')
            return
        clean = subprocess.run(['git', '-C', VENDOR, 'apply', '--check'] + patches,
                               capture_output=True).returncode == 0
        if not clean:
            raise Fail('vendor/ps3recomp has changes the patches do not account for; '
                       'it must be ps3recomp ' + PS3RECOMP_TAG + ' plus patches/')
        self.sh(['git', '-C', VENDOR, 'apply'] + patches, 'patch.log')
        self.info(f'applied {len(patches)} patches')

    def make_icons(self):
        self.step('making the icons')
        cmd = [sys.executable, ROOT / 'tools' / 'make_icons.py', self.game, self.icons]
        cover = self.a.cover or (ROOT / 'run' / 'icon' / 'cover.jpg')
        if cover and Path(cover).is_file():
            cmd += ['--cover', cover]
            self.info(f'from {Path(cover).name}')
        else:
            self.info("from the package's own ICON0/PIC1")
        self.sh(cmd, 'icons.log')

    def cmake_args(self):
        return ['-DCMAKE_BUILD_TYPE=Release', f'-DPS3RECOMP_DIR={VENDOR}',
                f'-DRECOMP_DIR={self.work / "recompiled"}', f'-DFLASHMP3_DIR={self.spu / "flashmp3"}',
                f'-DPython3_EXECUTABLE={sys.executable}',
                f'-DPORT_SPU_INPUTS={self.elf};{self.spu / "jobqueue_pm.elf"}']

    def mac(self):
        self.step('building the Mac app (a few minutes the first time)')
        env = dict(os.environ)
        env.pop('DEVELOPER_DIR', None)
        bld = self.work / 'build-mac'
        self.sh(['cmake', '-S', ROOT / 'port', '-B', bld, '-G', 'Ninja'] + self.cmake_args(),
                'mac-configure.log', env=env)
        self.sh(['cmake', '--build', bld], 'mac-build.log', env=env)
        app = self.out / 'Digger HD.app'
        if app.exists():
            shutil.rmtree(app)
        macos, res = app / 'Contents' / 'MacOS', app / 'Contents' / 'Resources'
        macos.mkdir(parents=True)
        res.mkdir()
        shutil.copy2(bld / 'DiggerHDRecomp', macos / 'DiggerHDRecomp')
        shutil.copytree(self.game, res / 'game' / TITLE_ID, symlinks=True)
        shutil.copytree(self.flash, res / 'dev_flash')
        shaders = ROOT / 'run' / 'shader-cache'
        if shaders.is_dir():
            shutil.copytree(shaders, res / 'shaders')
        shutil.copy2(self.icons / 'AppIcon.icns', res / 'AppIcon.icns')
        launcher = macos / 'DiggerHD'
        launcher.write_text(MAC_LAUNCHER)
        launcher.chmod(0o755)
        (app / 'Contents' / 'Info.plist').write_text(MAC_INFO_PLIST)
        self.sh(['codesign', '--force', '--deep', '--sign', '-', app], 'mac-sign.log')
        self.done.append(f'Mac: {app}')

    def device(self, plat):
        tv = plat == 'tvos'
        self.step(f'building for {"Apple TV" if tv else "iPad / iPhone"}')
        env = dict(os.environ)
        env['DEVELOPER_DIR'] = self.a.xcode
        libs = Path(self.a.ios_libs)
        prefix = [libs / 'tvos-prefix'] if tv else [libs / 'shader-ios-prefix', libs / 'sdl2-ios-prefix']
        missing = [str(p) for p in prefix if not p.is_dir()]
        if missing:
            raise Fail('missing iOS libraries (SDL2, glslang, SPIRV-Cross built for the device; '
                       'see README "iPad / iPhone / Apple TV"): ' + ', '.join(missing))
        env['PKG_CONFIG_LIBDIR'] = str(prefix[0] / 'lib' / 'pkgconfig')
        sdl = prefix[-1] / 'lib' / 'cmake' / 'SDL2'
        bld = self.work / f'build-{plat}'
        self.sh(['cmake', '-S', ROOT / 'port', '-B', bld, '-G', 'Ninja',
                 f'-DCMAKE_SYSTEM_NAME={"tvOS" if tv else "iOS"}', '-DCMAKE_OSX_ARCHITECTURES=arm64',
                 '-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0',
                 '-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH', '-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH',
                 '-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH',
                 '-DCMAKE_PREFIX_PATH=' + ';'.join(str(p) for p in prefix),
                 '-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew', f'-DSDL2_DIR={sdl}',
                 f'-Dglslang_DIR={prefix[0] / "lib" / "cmake" / "glslang"}'] + self.cmake_args(),
                f'{plat}-configure.log', env=env)
        self.sh(['cmake', '--build', bld], f'{plat}-build.log', env=env)
        profile = self.a.profile_tvos if tv else self.a.profile_ios
        if not Path(profile).is_file():
            raise Fail(f'no provisioning profile at {profile} (pass --profile-{plat} or set it in config.local.json)')
        benv = dict(env, GAME_DIR=str(self.game), FLASH_DIR=str(self.flash), ICON_DIR=str(self.icons),
                    PROFILE=str(profile),
                    ENTITLEMENTS=str(ROOT / 'port' / 'ios' /
                                     ('DiggerHD-tvOS.entitlements' if tv else 'DiggerHD.entitlements')))
        udid = self.a.install_tvos if tv else self.a.install_ios
        if self.a.sign_id:
            benv['SIGN_ID'] = self.a.sign_id
        cmd = [ROOT / 'tools' / 'ios_bundle.sh', bld / 'DiggerHD.app', self.out / plat]
        if udid:
            cmd.append(udid)
            self.info(f'installing on {udid}')
        self.sh(cmd, f'{plat}-bundle.log', env=benv)
        self.done.append(f'{"Apple TV" if tv else "iPad"}: {self.out / plat / "DiggerHD.app"}'
                         + (' (installed)' if udid else ''))

    def run(self):
        self.extract()
        self.check()
        self.decrypt()
        self.firmware()
        self.lift()
        self.spu_inputs()
        self.runtime()
        self.make_icons()
        if self.a.mac:
            self.mac()
        if self.a.ios:
            self.device('ios')
        if self.a.tvos:
            self.device('tvos')


MAC_LAUNCHER = r'''#!/bin/sh
# Digger HD for the Mac: the recompiled game, its own files in the bundle,
# what it writes (saves, caches, the log) in Application Support.
here="$(cd "$(dirname "$0")/.." && pwd)"
data="$HOME/Library/Application Support/Digger HD"
game="$here/Resources/game/NPEB00121"
mkdir -p "$data/hdd0/game" "$data/hdd1" "$data/gamedata" "$data/shaders"
ln -sfn "$game" "$data/hdd0/game/NPEB00121"
cd "$data" || exit 1
export PS3_TITLE="Digger HD" PS3_HDD0_ROOT="$data/hdd0" PS3_HDD1_ROOT="$data/hdd1" \
       PS3_GAMEDATA_ROOT="$data/gamedata" PS3_VFS_ROOT="$game" \
       PS3_DEV_FLASH="$here/Resources/dev_flash" \
       PS3_SHADER_CACHE="$data/shaders" PS3_SHADER_CACHE_RO="$here/Resources/shaders"
exec "$here/MacOS/DiggerHDRecomp" "$game/USRDIR/EBOOT.elf" > "$data/log.txt" 2>&1
'''

MAC_INFO_PLIST = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleDevelopmentRegion</key><string>en</string>
\t<key>CFBundleDisplayName</key><string>Digger HD</string>
\t<key>CFBundleExecutable</key><string>DiggerHD</string>
\t<key>CFBundleIconFile</key><string>AppIcon</string>
\t<key>CFBundleIdentifier</key><string>eu.postnikov.diggerhd.mac</string>
\t<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
\t<key>CFBundleName</key><string>Digger HD</string>
\t<key>CFBundlePackageType</key><string>APPL</string>
\t<key>CFBundleShortVersionString</key><string>0.1</string>
\t<key>CFBundleVersion</key><string>1</string>
\t<key>LSApplicationCategoryType</key><string>public.app-category.arcade-games</string>
\t<key>LSMinimumSystemVersion</key><string>14.0</string>
\t<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
'''


def main():
    cfg = local_config()
    libs = Path(cfg.get('ios_libs', ROOT / 'work' / 'ios-libs'))
    ap = argparse.ArgumentParser(description='Build Digger HD from your own .pkg')
    ap.add_argument('pkg')
    ap.add_argument('--work', default=cfg.get('work', str(ROOT / 'work')))
    ap.add_argument('--mac', action='store_true')
    ap.add_argument('--ios', action='store_true')
    ap.add_argument('--tvos', action='store_true')
    ap.add_argument('--install-ios', metavar='UDID')
    ap.add_argument('--install-tvos', metavar='UDID')
    ap.add_argument('--cover', help='cover image for the icons (otherwise the package art)')
    ap.add_argument('--rpcs3', default=DEFAULT_RPCS3)
    ap.add_argument('--firmware', default=str(DEFAULT_FIRMWARE))
    ap.add_argument('--xcode', default=cfg.get('xcode', os.environ.get('DEVELOPER_DIR', default_xcode())))
    ap.add_argument('--ios-libs', default=str(libs))
    ap.add_argument('--sign-id', default=cfg.get('sign_id', ''),
                    help='signing identity SHA-1 (default: the first Apple Development one)')
    ap.add_argument('--profile-ios', default=cfg.get('profile_ios', str(libs / 'profiles' / 'ios.mobileprovision')))
    ap.add_argument('--profile-tvos', default=cfg.get('profile_tvos', str(libs / 'profiles' / 'tvos.mobileprovision')))
    a = ap.parse_args()
    if a.install_ios:
        a.ios = True
    if a.install_tvos:
        a.tvos = True
    r = Run(a)
    try:
        r.run()
    except Fail as e:
        print(f'ERROR {e}', flush=True)
        return 1
    print('DONE ' + ('; '.join(r.done) if r.done else 'prepared (no build asked for)'), flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
