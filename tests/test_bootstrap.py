import gzip
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('bootstrap', Path(__file__).parents[1] / 'bootstrap_debian.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


class BootstrapTests(unittest.TestCase):
    def test_initramfs_preseed_archive(self):
        content = b.preseed('partition').encode()
        raw = gzip.decompress(b.archive('preseed.cfg', content))
        self.assertEqual(raw[:6], b'070701')
        size = int(raw[54:62], 16)
        namesize = int(raw[94:102], 16)
        self.assertEqual(raw[110:110 + namesize], b'preseed.cfg\0')
        start = (110 + namesize + 3) & ~3
        self.assertEqual(raw[start:start + size], content)
        self.assertIn(b'TRAILER!!!\0', raw)

    def test_layout_and_confirmation(self):
        config = b.preseed('partition')
        self.assertIn('label{ Library } mountpoint{ /Library }', config)
        self.assertIn('32000 32000 32000', config)
        self.assertIn('d-i passwd/username string library', config)
        self.assertIn('d-i passwd/root-password password library', config)
        self.assertIn('d-i passwd/user-password password library', config)
        self.assertIn('partman/confirm boolean true', config)
        self.assertIn('partman/confirm_nooverwrite boolean true', config)
        self.assertIn('partman-partitioning/confirm_write_new_label boolean true', config)
        self.assertIn('partman/choose_partition select finish', config)
        self.assertNotIn('partman/choose_partition select finish', b.preseed('usb'))
        self.assertIn('gnome-desktop', config)
        self.assertIn('d-i partman/early_command string /bin/sh /library-select-target.sh', config)
        self.assertIn('d-i partman-lvm/device_remove_lvm boolean true', config)
        self.assertIn('d-i partman-md/device_remove_md boolean true', config)
        self.assertIn('d-i finish-install/reboot_in_progress note', config)
        self.assertIn('d-i grub-installer/with_other_os boolean true', config)
        self.assertIn('popularity-contest popularity-contest/participate boolean false', config)
        self.assertIn('git task-gnome-desktop', config)
        self.assertNotIn('partman-auto/disk', config)
        self.assertNotIn('mountpoint{ /Library }', b.preseed('usb'))

    def test_firmware_download_checksum(self):
        payload = b'firmware archive test bytes'
        def fake_download(url, destination):
            if url.endswith('SHA256SUMS'):
                destination.write_text(hashlib.sha256(payload).hexdigest() + '  firmware.cpio.gz\n')
            else:
                destination.write_bytes(payload)
        with tempfile.TemporaryDirectory() as tmp, patch.object(b, 'download', side_effect=fake_download):
            self.assertEqual(b.download_firmware(Path(tmp)).read_bytes(), payload)
        def corrupt_download(url, destination):
            fake_download(url, destination)
            if not url.endswith('SHA256SUMS'):
                destination.write_bytes(b'corrupt')
        with tempfile.TemporaryDirectory() as tmp, patch.object(b, 'download', side_effect=corrupt_download):
            with self.assertRaisesRegex(RuntimeError, 'checksum verification failed'):
                b.download_firmware(Path(tmp))
        self.assertIn('d-i hw-detect/load_firmware boolean true', b.preseed('partition'))
        self.assertIn('d-i apt-setup/non-free-firmware boolean true', b.preseed('partition'))

    def test_desktop_setup_does_not_block_install_completion(self):
        import subprocess
        import os
        for layout in ('partition', 'usb'):
            command = next(line.split(' string ', 1)[1] for line in b.preseed(layout).splitlines()
                           if line.startswith('d-i preseed/late_command '))
            self.assertNotIn('--strict', command)
            # Debconf transports values using escaped newlines: avoid shell backslash escapes.
            self.assertNotIn(chr(92), command)
            self.assertNotIn(chr(10), command)
            subprocess.run(['sh', '-n', '-c', command], check=True)
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                compiler = root / 'usr/bin/glib-compile-schemas'
                compiler.parent.mkdir(parents=True)
                compiler.write_text('test compiler')
                compiler.chmod(0o755)
                command = command.replace('/target/', str(root) + '/')
                # Isolate optional desktop handling from the separately tested root-access setup.
                command = command.replace('/bin/sh /library-root-access.sh /target', 'true')
                command = command.replace('/bin/sh /library-clone-library.sh /target', 'true')
                # Simulate a compiler failure: optional desktop settings must not abort finish-install.
                for name, body in [('in-target', 'exit 1'), ('logger', 'echo "$*"')]:
                    helper = root / name
                    helper.write_text('#!/bin/sh\n' + body + '\n')
                    helper.chmod(0o755)
                env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'])
                result = subprocess.run(['sh', '-ec', command], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('WARNING: GNOME schema compilation failed', result.stdout)
                override = root / 'usr/share/glib-2.0/schemas/90-library-desktop.gschema.override'
                self.assertIn('sleep-inactive-ac-type="nothing"', override.read_text())
                self.assertIn('lock-enabled=false', override.read_text())

    def test_portable_balena_setup_and_cache(self):
        import io
        payload = b'test standalone package'
        release = {'assets': [{'name': 'balena-cli-v1-macOS-arm64-standalone.tar.gz',
            'browser_download_url': 'https://example.test/balena.tar.gz',
            'digest': 'sha256:' + hashlib.sha256(payload).hexdigest()}]}
        calls = []
        def fake_run(*args):
            calls.append(args)
            if args[0] == 'tar':
                launcher = Path(args[-1]) / 'balena/bin/balena'
                launcher.parent.mkdir(parents=True)
                launcher.write_text('test launcher')
        with tempfile.TemporaryDirectory() as tmp, patch.object(b, '__file__', str(Path(tmp) / 'bootstrap_debian.py')), patch.object(
            b.shutil, 'which', return_value=None
        ), patch.object(b.sys, 'platform', 'darwin'), patch.object(b.platform, 'machine', return_value='arm64'), patch.object(
            b.urllib.request, 'urlopen', return_value=io.BytesIO(json.dumps(release).encode())
        ) as request, patch.object(b, 'download', side_effect=lambda url, path: path.write_bytes(payload)), patch.object(
            b, 'run', side_effect=fake_run
        ):
            launcher = b.get_balena()
            self.assertTrue(Path(launcher).is_file())
            self.assertIn('tmp/tools/balena-macOS-arm64', launcher)
            self.assertEqual(b.get_balena(), launcher)
            self.assertEqual(request.call_count, 1)
            self.assertEqual(calls[-1][1], 'version')

    def test_installer_disk_selection_excludes_usb_and_requires_confirmation(self):
        import os
        import subprocess
        source = (Path(b.__file__).parent / 'installer/select-target.sh').read_text()
        for selection, confirm, succeeds in [('nvme0n1', 'true', True), ('sdb', 'true', False), ('nvme0n1', 'false', False)]:
            with self.subTest(selection=selection, confirm=confirm), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                sysfs = root / 'sys/class/block'
                sysfs.mkdir(parents=True)
                dev = root / 'dev'
                dev.mkdir()
                for name, bus in [('nvme0n1', 'pci'), ('sdb', 'pci/usb1')]:
                    physical = root / 'devices' / bus / name
                    (physical / 'device').mkdir(parents=True)
                    (physical / 'removable').write_text('0')
                    (physical / 'size').write_text('209715200')
                    (physical / 'device/model').write_text('Test Disk')
                    (sysfs / name).symlink_to(physical)
                    (dev / name).touch()
                (root / 'mounts').write_text('')
                trace = root / 'trace'
                conf = root / 'confmodule'
                conf.write_text('db_subst() { echo "$*" >> "$TRACE"; }; db_fset() { :; }; db_input() { :; }; db_go() { :; }; db_set() { echo "$*" >> "$TRACE"; }; db_get() { case "$1" in library/target) RET="$SELECTION";; library/erase-confirm) RET="$CONFIRM";; esac; }\n')
                helpers = root / 'bin'
                helpers.mkdir()
                for name, body in [('list-devices', 'echo "$DISKS"'), ('debconf-loadtemplate', ':'), ('logger', ':')]:
                    helper = helpers / name
                    helper.write_text('#!/bin/sh\n' + body + '\n')
                    helper.chmod(0o755)
                script = source.replace('/usr/share/debconf/confmodule', str(conf)).replace('/sys/class/block', str(sysfs)).replace('/proc/mounts', str(root / 'mounts'))
                # Fake regular files stand in for block-device nodes; no actual disk is opened.
                script = script.replace('[ -b "$disk" ]', '[ -f "$disk" ]')
                env = dict(os.environ, PATH=str(helpers)+os.pathsep+os.environ['PATH'], TRACE=str(trace),
                    DISKS=str(dev/'nvme0n1')+' '+str(dev/'sdb'), SELECTION=str(dev/selection)+' - Test Disk  - 100 GiB', CONFIRM=confirm)
                result = subprocess.run(['sh', '-c', script], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, succeeds, result.stderr)
                log = trace.read_text()
                if succeeds:
                    self.assertIn('partman-auto/disk '+str(dev/'nvme0n1'), log)
                    self.assertIn('grub-installer/bootdev '+str(dev/'nvme0n1'), log)
                else:
                    self.assertNotIn('partman-auto/disk ', log)
                self.assertNotIn(str(dev/'sdb'), log)

    def test_root_ssh_and_gdm_settings(self):
        import subprocess
        helper = Path(b.__file__).parent / 'installer/root-access.sh'
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'etc/ssh').mkdir(parents=True)
            pam = root / 'etc/pam.d/gdm-password'
            pam.parent.mkdir(parents=True)
            original = 'auth required pam_succeed_if.so user != root quiet_success\n@include common-auth\nsession required pam_unix.so\n'
            pam.write_text(original)
            (pam.parent / 'gdm-autologin').write_text(original)
            gdm = root / 'etc/gdm3/daemon.conf'
            gdm.parent.mkdir(parents=True)
            gdm.write_text('[daemon]\nAutomaticLogin=library\nAutomaticLoginEnable=false\nWaylandEnable=false\n[security]\nDisallowTCP=true\n')
            config = root / 'etc/ssh/sshd_config'
            config.write_text('# Debian SSH settings\nUsePAM yes\n')
            for _ in range(2):
                subprocess.run(['sh', str(helper), str(root)], check=True)
            self.assertEqual(config.read_text().count('Include '), 1)
            settings = (root / 'etc/ssh/sshd_config.d/00-library-root.conf').read_text()
            self.assertIn('PermitRootLogin yes', settings)
            self.assertIn('PasswordAuthentication yes', settings)
            self.assertIn('PermitEmptyPasswords no', settings)
            self.assertFalse(any(line.startswith('auth ') and 'user != root' in line for line in pam.read_text().splitlines()))
            self.assertIn('@include common-auth', pam.read_text())
            self.assertIn('session required pam_unix.so', pam.read_text())
            self.assertEqual(Path(str(pam)+'.library-original').read_text(), original)
            import configparser
            desktop = configparser.ConfigParser()
            desktop.read(gdm)
            self.assertEqual(desktop['daemon']['AutomaticLogin'], 'root')
            self.assertTrue(desktop['daemon'].getboolean('AutomaticLoginEnable'))
            self.assertFalse(desktop['daemon'].getboolean('TimedLoginEnable'))
            self.assertEqual(desktop['daemon']['WaylandEnable'], 'false')
            self.assertEqual(desktop['security']['DisallowTCP'], 'true')
            self.assertFalse(any(line.startswith('auth ') and 'user != root' in line for line in (pam.parent / 'gdm-autologin').read_text().splitlines()))

    def test_library_clone_downloads_without_running_bootstrap(self):
        import os
        import subprocess
        script = Path(b.__file__).parent / 'installer/clone-library.sh'
        for fail in ('0', '1'):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                helpers = root / 'bin'
                helpers.mkdir()
                trace = root / 'trace'
                for name, body in [('logger', ':'), ('in-target', 'echo "$*" >> "$TRACE"; [ "$FAIL" = 0 ] || exit 1; mkdir -p "$TEST_ROOT/root/Library-Creator_x86"')]:
                    helper = helpers / name
                    helper.write_text('#!/bin/sh\n' + body + '\n')
                    helper.chmod(0o755)
                env = dict(os.environ, PATH=str(helpers)+os.pathsep+os.environ['PATH'], TRACE=str(trace), FAIL=fail, TEST_ROOT=str(root))
                subprocess.run(['sh', str(script), str(root)], env=env, check=True)
                log = trace.read_text()
                self.assertIn('clone https://github.com/holly-the-dude/Library-Creator_x86.git /root/Library-Creator_x86', log)
                self.assertNotIn('./bootstrap', log)
                if fail == '0':
                    subprocess.run(['sh', str(script), str(root)], env=env, check=True)
                    self.assertEqual(trace.read_text(), log)

    def test_writer_rejects_unsafe_targets_before_confirmation(self):
        cases = [dict(type='part', tran='usb', rm=True, mountpoints=[]),
                 dict(type='disk', tran='nvme', rm=False, mountpoints=[]),
                 dict(type='disk', tran='usb', rm=True, mountpoints=['/']),
                 dict(type='disk', tran='usb', rm=True, mountpoints=[], children=[
                     dict(path='/dev/test1', mountpoints=['/home'])])]
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / 'test.iso'
            image.write_bytes(b'ISO')
            for case in cases:
                disk = dict(path='/dev/test', size=1000, **case)
                with self.subTest(case=case), patch.object(b.sys, 'platform', 'linux'), patch.object(
                    b.subprocess, 'check_output', return_value=json.dumps({'blockdevices': [disk]}).encode()
                ), patch('builtins.input', side_effect=AssertionError('must not prompt')):
                    with self.assertRaises(RuntimeError):
                        b.write_linux(image, '/dev/test')


if __name__ == '__main__':
    unittest.main()
