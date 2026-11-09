#!/usr/bin/env python3
"""Build a Debian trixie installer with an initrd-embedded preseed."""
import argparse
import gzip
import hashlib
import json
import os
import platform
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zlib

FIRMWARE_BASE = 'https://cdimage.debian.org/cdimage/firmware/trixie/current/'

BASE = 'https://deb.debian.org/debian/dists/trixie/main/installer-{arch}/current/images/'


def color(text, style):
    styles = {'heading': '1;36', 'choice': '36', 'success': '32', 'warning': '1;33', 'error': '1;31'}
    if not sys.stdout.isatty() or 'NO_COLOR' in os.environ or os.environ.get('TERM') == 'dumb':
        return text
    return f'\033[{styles[style]}m{text}\033[0m'


def run(*args):
    subprocess.run(list(map(str, args)), check=True)


def choose(prompt, choices, default=None):
    print(color('\n' + prompt, 'heading'))
    for number, (label, value) in enumerate(choices, 1):
        suffix = ' (default)' if number == default else ''
        print(color(f'  {number}. {label}{suffix}', 'choice'))
    while True:
        hint = f' [{default}]' if default is not None else ''
        answer = input(color(f'Choose a number{hint}: ', 'choice')).strip()
        if not answer and default is not None:
            answer = str(default)
        if answer.isdecimal() and 1 <= int(answer) <= len(choices):
            return choices[int(answer) - 1][1]
        print(f'Enter a number from 1 to {len(choices)}.')


def preseed(layout):
    if layout not in ('partition', 'usb'):
        raise ValueError('Unknown Library layout')
    return (Path(__file__).resolve().parent / 'preseed' / f'{layout}.cfg').read_text()


def archive(name, data):
    """A portable newc cpio archive, appended as a gzip initramfs member."""
    result = bytearray()
    for filename, content, mode in [(name, data, 0o100600), ('TRAILER!!!', b'', 0)]:
        encoded = filename.encode() + b'\0'
        fields = [1, mode, 0, 0, 1, 0, len(content), 0, 0, 0, 0, len(encoded), 0]
        result.extend(b'070701' + ''.join(f'{n:08x}' for n in fields).encode())
        result.extend(encoded)
        result.extend(b'\0' * (-len(result) % 4))
        result.extend(content)
        result.extend(b'\0' * (-len(result) % 4))
    return gzip.compress(bytes(result), mtime=0)


def download(url, destination):
    print('Downloading', url)
    with urllib.request.urlopen(url, timeout=120) as source, destination.open('wb') as target:
        shutil.copyfileobj(source, target)


def download_firmware(temp):
    firmware = temp / 'firmware.cpio.gz'
    sums = temp / 'firmware-SHA256SUMS'
    download(FIRMWARE_BASE + 'firmware.cpio.gz', firmware)
    download(FIRMWARE_BASE + 'SHA256SUMS', sums)
    matches = [line.split()[0] for line in sums.read_text().splitlines()
               if len(line.split()) == 2 and line.split()[1].lstrip('*') == 'firmware.cpio.gz']
    digest = hashlib.sha256()
    with firmware.open('rb') as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b''):
            digest.update(chunk)
    if len(matches) != 1 or digest.hexdigest() != matches[0]:
        raise RuntimeError('Debian firmware archive checksum verification failed.')
    return firmware


def build(arch, layout, out):
    if not shutil.which('xorriso'):
        raise RuntimeError('Install xorriso (Linux package manager, macOS Homebrew, or Windows WSL).')
    out.mkdir(parents=True, exist_ok=True)
    output = out / f'debian-trixie-{arch}-library.iso'
    if output.exists():
        print(color(f'Installer image already exists: {output}', 'heading'))
        action = choose('What would you like to do?', [
            ('Rebuild using the settings just selected', 'rebuild'),
            ('Use the existing image (keep its previous settings)', 'reuse'),
            ('Cancel', 'cancel'),
        ], default=1)
        if action == 'reuse':
            return output
        if action == 'cancel':
            raise RuntimeError('Build cancelled. Existing image kept.')
    config = preseed(layout).encode()
    temp_root = Path(__file__).resolve().parent / 'tmp'
    temp_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='build-', dir=temp_root) as temp:
        temp = Path(temp)
        config_file = temp / 'preseed.cfg'
        config_file.write_bytes(config)
        rebuilt = temp / 'installer.iso'
        iso = temp / 'mini.iso'
        url = BASE.format(arch=arch)
        download(url + 'netboot/mini.iso', iso)
        sums = temp / 'SHA256SUMS'
        download(url + 'SHA256SUMS', sums)
        matches = [line.split()[0] for line in sums.read_text().splitlines()
                   if line.split()[-1].lstrip('*').removeprefix('./') == 'netboot/mini.iso']
        if len(matches) != 1 or hashlib.sha256(iso.read_bytes()).hexdigest() != matches[0]:
            raise RuntimeError('Debian mini.iso checksum verification failed.')
        firmware = download_firmware(temp)
        initrd = temp / 'initrd.gz'
        run('xorriso', '-osirrox', 'on', '-indev', iso, '-extract', '/initrd.gz', initrd)
        initrd.chmod(0o600)
        combined = temp / 'combined-initrd.gz'
        with combined.open('wb') as stream:
            for part in (initrd, firmware):
                with part.open('rb') as source:
                    shutil.copyfileobj(source, stream)
            stream.write(archive('preseed.cfg', config))
            installer = Path(__file__).resolve().parent / 'installer'
            stream.write(archive('library-select-target.sh', (installer / 'select-target.sh').read_bytes()))
            stream.write(archive('library-target.templates', (installer / 'target.templates').read_bytes()))
            stream.write(archive('library-root-access.sh', (installer / 'root-access.sh').read_bytes()))
            stream.write(archive('library-clone-library.sh', (installer / 'clone-library.sh').read_bytes()))
        with gzip.open(combined, 'rb') as check:
            while check.read(4 * 1024 * 1024):
                pass
        os.replace(combined, initrd)
        run('xorriso', '-indev', iso, '-outdev', rebuilt, '-boot_image', 'any', 'replay',
            '-map', initrd, '/initrd.gz', '-map', config_file, '/preseed.cfg')
        # Stage on the destination filesystem so replacing an existing ISO is atomic.
        with tempfile.TemporaryDirectory(prefix='.publish-', dir=out) as publish:
            staged = Path(publish) / output.name
            shutil.copyfile(rebuilt, staged)
            os.replace(staged, output)
        (out / 'preseed.cfg').write_bytes(config)
    print(color(f'Installer ready: {output}', 'success'))
    print('Boot Install. Partition changes on the installation target are applied automatically.')
    if layout == 'usb':
        print('In manual partitioning, format the separate data USB as ext4, label Library, mount /Library.')
        print('Keep the 32,000 MB root partition on the OS disk; do not select the installer USB.')
    return output


def drive_description(disk):
    model = (disk.get('model') or 'USB drive').strip()
    return f"{model} — {int(disk['size']) / (1024 ** 3):.1f} GiB ({disk['path']})"


def select_linux_usb():
    print(color('\nCreate a bootable USB drive, or save the installer image for later.', 'heading'))
    disks = json.loads(subprocess.check_output([
        'lsblk', '--json', '--tree', '--bytes', '-o', 'PATH,TYPE,SIZE,MODEL,TRAN,RM'
    ]))['blockdevices']
    drives = [disk for disk in disks
              if disk['type'] == 'disk' and disk.get('tran') == 'usb' and disk.get('rm')]
    print(color('  0. Save image only (do not write a USB drive)', 'success'))
    for number, disk in enumerate(drives, 1):
        print(color(f'  {number}. Create bootable USB on {drive_description(disk)}', 'choice'))
    if not drives:
        print('No removable USB drives found. Connect a USB drive and run again to write it.')
    while True:
        answer = input(color('Choose a number [0 = save image only]: ', 'choice')).strip() or '0'
        if answer.isdecimal() and 0 <= int(answer) <= len(drives):
            return drives[int(answer) - 1]['path'] if int(answer) else None
        print(f'Enter a number from 0 to {len(drives)}.')


def write_linux(image, device):
    if sys.platform != 'linux':
        raise RuntimeError('Native disk writing is available on Linux. Use Etcher on macOS/Windows.')
    device = str(Path(device).resolve())
    info = json.loads(subprocess.check_output(['lsblk', '--json', '--tree', '--bytes', '-o',
                         'PATH,TYPE,SIZE,MODEL,TRAN,RM,MOUNTPOINTS', device]))['blockdevices']
    if len(info) != 1:
        raise RuntimeError('Select exactly one whole USB disk.')
    disk = info[0]
    if disk['path'] != device or disk['type'] != 'disk' or disk['tran'] != 'usb' or not disk['rm']:
        raise RuntimeError('Only a removable whole USB disk is allowed.')
    nodes = []
    def walk(node):
        nodes.append(node)
        for child in node.get('children', []):
            walk(child)
    walk(disk)
    if any(m in ('/', '/boot', '/boot/efi', '/home', '/Library') for n in nodes for m in n.get('mountpoints', []) if m):
        raise RuntimeError('Refusing a disk containing a system mount.')
    if int(disk['size']) < image.stat().st_size:
        raise RuntimeError('USB is smaller than the installer image.')
    print(color(f'\nSelected USB drive: {drive_description(disk)}', 'heading'))
    print(color('Creating the installer USB will erase all files on this drive.', 'warning'))
    if not choose('Erase this USB drive and create the installer?', [
        ('Cancel — keep the USB drive unchanged', False),
        (f'Erase {drive_description(disk)} and create the installer', True),
    ], default=1):
        raise RuntimeError('Erase cancelled.')
    if os.geteuid() != 0:
        raise RuntimeError('Disk writing needs root: rerun with sudo and --image PATH --device DEVICE.')
    for node in reversed(nodes):
        if any(node.get('mountpoints', [])):
            run('umount', node['path'])
    with image.open('rb') as source, open(device, 'wb', buffering=0) as target:
        shutil.copyfileobj(source, target, 4 * 1024 * 1024)
        os.fsync(target.fileno())
    with image.open('rb') as source, open(device, 'rb', buffering=0) as target:
        while chunk := source.read(4 * 1024 * 1024):
            if target.read(len(chunk)) != chunk:
                raise RuntimeError('USB read-back verification failed.')
    print(color('USB written and read-back verified. Safely remove it before booting the target.', 'success'))


def get_balena():
    installed = shutil.which('balena')
    if installed:
        return installed
    if sys.platform != 'darwin':
        raise RuntimeError('Automatic balena setup in this builder supports macOS only.')
    machine = platform.machine().lower()
    architectures = {'arm64': 'arm64', 'aarch64': 'arm64', 'x86_64': 'x64', 'amd64': 'x64'}
    if machine not in architectures:
        raise RuntimeError(f'Unsupported Mac architecture: {machine}')
    architecture = architectures[machine]
    tools = Path(__file__).resolve().parent / 'tmp' / 'tools'
    tools.mkdir(parents=True, exist_ok=True)
    cache = tools / f'balena-macOS-{architecture}'
    executable = cache / 'balena' / 'bin' / 'balena'
    if executable.is_file():
        return str(executable)
    request = urllib.request.Request('https://api.github.com/repos/balena-io/balena-cli/releases/latest',
                                     headers={'User-Agent': 'bootstrap_debian'})
    with urllib.request.urlopen(request, timeout=120) as response:
        release = json.load(response)
    assets = [asset for asset in release['assets']
              if asset['name'].endswith(f'-macOS-{architecture}-standalone.tar.gz')]
    if len(assets) != 1:
        raise RuntimeError('Cannot locate official balena standalone package for this Mac.')
    asset = assets[0]
    digest = asset.get('digest', '')
    if not digest.startswith('sha256:') or len(digest) != 71:
        raise RuntimeError('Balena release has no SHA256 digest; refusing unverified setup.')
    print(color('Setting up portable balena CLI. No separate installation is needed.', 'heading'))
    with tempfile.TemporaryDirectory(prefix='balena-setup-', dir=tools) as work:
        work = Path(work)
        package = work / 'balena.tar.gz'
        download(asset['browser_download_url'], package)
        hasher = hashlib.sha256()
        with package.open('rb') as source:
            for chunk in iter(lambda: source.read(4 * 1024 * 1024), b''):
                hasher.update(chunk)
        if hasher.hexdigest() != digest.split(':', 1)[1]:
            raise RuntimeError('Balena download checksum verification failed.')
        extracted = work / 'extracted'
        extracted.mkdir()
        run('tar', '-xzf', str(package), '-C', str(extracted))
        candidate = extracted / 'balena' / 'bin' / 'balena'
        if not candidate.is_file():
            raise RuntimeError('Balena archive does not contain its expected launcher.')
        run(str(candidate), 'version')
        if cache.exists():
            raise RuntimeError(f'Incomplete balena cache at {cache}; remove it and retry.')
        os.replace(extracted, cache)
    return str(executable)


def flash_balena(image):
    executable = get_balena()
    temp_root = Path(__file__).resolve().parent / 'tmp'
    temp_root.mkdir(parents=True, exist_ok=True)
    # balena documents .img input. A Debian hybrid ISO can be written as raw .img bytes.
    with tempfile.TemporaryDirectory(prefix='flash-', dir=temp_root) as work:
        raw = Path(work) / 'installer.img'
        try:
            os.link(image, raw)
        except OSError:
            shutil.copyfile(image, raw)
        command = [executable, 'local', 'flash', str(raw)]
        if sys.platform == 'darwin' and os.geteuid() != 0:
            command.insert(0, 'sudo')
        print(color('Select the installer USB in balena, then confirm erasing it. Administrator access is required.', 'warning'))
        run(*command)
        print('Balena finished. Check its validation result before removing the USB.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arch', choices=['amd64', 'arm64'])
    parser.add_argument('--layout', choices=['partition', 'usb'])
    parser.add_argument('--output', type=Path, default=Path('output'))
    parser.add_argument('--image', type=Path, help='Write an already built image without rebuilding')
    parser.add_argument('--no-write', action='store_true', help='Build image without asking to flash a USB')
    parser.add_argument('--device', help='Linux whole removable USB disk, e.g. /dev/sda')
    args = parser.parse_args()
    image = args.image
    if image is None:
        arch = args.arch or choose('What hardware will run Debian?', [
            ('x86-64 — Intel or AMD 64-bit PC', 'amd64'),
            ('ARM64 — AArch64 hardware with UEFI', 'arm64'),
        ])
        layout = args.layout or choose('Where should /Library be stored?', [
            ('Same disk — 32 GB for Debian, remaining space for /Library', 'partition'),
            ('Separate USB drive for /Library (configure during installation)', 'usb'),
        ])
        image = build(arch, layout, args.output.resolve())
    image = image.resolve(strict=True)
    device = args.device
    if device is None and sys.platform == 'linux' and not args.no_write and sys.stdin.isatty():
        device = select_linux_usb()
    if device:
        write_linux(image, device)
    elif sys.platform == 'darwin' and not args.no_write and sys.stdin.isatty():
        action = choose('Create a bootable USB drive, or save the installer image?', [
            ('Save image only', 'save'),
            ('Create bootable USB with balena CLI (select drive next)', 'balena'),
        ], default=1)
        if action == 'balena':
            flash_balena(image)
        else:
            print(color(f'Installer image saved: {image}', 'success'))
    else:
        print(color(f'Installer image saved: {image}', 'success'))
        print('To create a bootable USB later, open this image in balenaEtcher, select your USB drive, then click Flash.')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError, KeyboardInterrupt, EOFError, zlib.error) as exc:
        print(f'Error: {exc}', file=sys.stderr)
        sys.exit(1)
