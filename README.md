# Bare-metal Debian installation for the Library

Turn an x86-64 PC, laptop, or UEFI ARM64 machine into an offline Library.
`bootstrap_debian` creates a Debian 13 **trixie** installer USB, installs the
GNOME desktop and required starting tools, and downloads
[Library-Creator_x86](https://github.com/holly-the-dude/Library-Creator_x86)
into `/root/Library-Creator_x86`. After Debian boots, run that repository's
bootstrap to install the Library services and starter content.

There are two stages: **install Debian**, then **set up the Library**.
The Library bootstrap is not automatically executed during Debian installation.
The same Library checkout supports native AMD64 and ARM64; despite its name,
this is not the separate Raspberry Pi Library-Creator project.

## 1. Prepare the hardware

You need:

- An x86-64 Intel/AMD machine (`amd64`), or AArch64 hardware with UEFI (`arm64`).
  Neither 32-bit x86 nor 32-bit ARM is supported. This installer does not supply
  Raspberry Pi boot firmware or board-specific display drivers.
- An internal installation disk larger than 32 GB, with additional room for
  container builds and content. The recipe reserves **32,000 MB for Debian**;
  GNOME, container layers, Office and routing imports also consume OS space.
  Large builds may require increasing that recipe before creating the image.
- A USB drive for the Debian installer, plus an optional separate content USB.
  These are different drives. The installer USB is erased when written.
- Internet access for Debian installation, the Git clone, Library package/image
  builds, and content downloads. Ethernet is useful while setting up Wi-Fi.
- A keyboard and display for target-disk selection and initial setup.
  An AP-capable Wi-Fi adapter is needed only if you want a Library hotspot.

The installer asks you to select an **internal disk by device, model and
capacity**, then confirm erasing it (default **No**). It replaces that disk's
partitions and permits removal of existing LVM/RAID layouts, including an old
Linux installation. USB/removable disks and installer media are excluded from
this target menu. This is repartitioning/formatting, not a secure overwrite of
every sector. Back up anything you need from the selected disk first.

Choose where content will live:

| Builder choice | Debian layout | Library setup |
| --- | --- | --- |
| Same disk (`partition`) | 32,000 MB ext4 `/`, EFI partition where required, remaining space as ext4 labeled `Library`, mounted at `/Library` | Use the existing mounted `/Library`; do not format it again. |
| Separate USB (`usb`) | 32,000 MB `/`, remaining space as `/home` | In Debian's manual partitioner, configure the separate data USB as ext4, label `Library`, mount `/Library`; or mount it there before Library setup. |

No swap partition is created. Debian may ask you to acknowledge that choice.
The separate USB option leaves partitioning open for manual configuration.
Never select the running installer USB as the content disk.

## 2. Build the installer image

Keep the complete `debian_bootstrap` folder together, including `preseed/` and
`installer/`. The wizard uses numbered selections for hardware, content layout,
and USB creation. Erase menus default to cancellation.

### Linux

```sh
sudo apt install python3 xorriso
cd debian_bootstrap
./bootstrap_debian
```

### macOS

With Homebrew installed:

```sh
brew install python xorriso
cd debian_bootstrap
./bootstrap_debian
```

Linux/macOS require Python 3.9+ and xorriso.

### Windows

Run **`bootstrap_debian.cmd`** from a local folder without spaces, such as
`C:\debian_bootstrap`. It uses Windows PowerShell; **no WSL or Python installation
is required**. PowerShell downloads portable MSYS2/xorriso tools into `tmp/tools`.
It checks the runtime release SHA256 digest, and MSYS2 verifies package
signatures. Nothing is added to the system PATH. UNC network shares are not
supported.

### Output and rebuilding

The output directory contains `preseed.cfg` and
`debian-trixie-ARCH-library.iso`. If an image already exists, choose **Rebuild
using the settings just selected**, **Use existing image**, or **Cancel**.
Rebuilding replaces the old ISO only after the new build succeeds. Existing
images and previously written USBs retain their old settings until rebuilt
and reflashed.

Optional command-line choices:

```sh
python3 bootstrap_debian.py --arch amd64 --layout partition --output output-amd64 --no-write
python3 bootstrap_debian.py --arch arm64 --layout usb --output output-arm64 --no-write
```

```powershell
.\bootstrap_debian.cmd -Arch amd64 -Layout partition -NoWrite
```

Downloads and extracted files use a per-build folder under `tmp`, removed when
the build finishes or fails. Portable tools remain under `tmp/tools` for reuse.
Debian's current installer and the cloned Library source can change over time;
these commands fix the selected options, not the upstream versions.

## 3. Write the installer USB

**Linux:** choose a removable USB from the numbered list showing its name,
capacity and device path. Choose **0** to save the image only. Writing requires
root; if building as your regular user, write the saved image afterward:

```sh
sudo python3 bootstrap_debian.py --image output/debian-trixie-amd64-library.iso --device /dev/sda
```

Replace `/dev/sda` with the actual installer USB. The writer checks the device,
asks for confirmation, unmounts its partitions, writes, flushes and reads back
the image. It rejects non-removable, non-USB and common system disks.

**macOS:** select **Create bootable USB with balena CLI**. If needed, the program
downloads the official Intel or Apple Silicon standalone package, verifies its
SHA256 release digest and keeps it in `tmp/tools`. It invokes `sudo balena local
flash`; balena provides drive selection, erase confirmation and validation.

**Windows:** choose the built-in writer or balena CLI. Windows requests
Administrator access before writing. The built-in writer rechecks the disk's
identity and the image checksum, locks/dismounts its volumes, writes and verifies
the image. The balena option downloads and checks the official Windows x64
standalone package if needed, then opens its drive selector.

An existing balena installation is used when available. Its documented `.img`
input is supplied using a temporary, byte-identical copy/link of the hybrid
ISO; the saved ISO is unchanged. No manual balena installation is required.
The [Etcher desktop app](https://etcher.balena.io/) is also an option.

To write a saved image later on macOS:

```sh
./bootstrap_debian --image output/debian-trixie-amd64-library.iso
```

## 4. Install Debian on the target machine

1. Boot the installer USB. For a UEFI machine, choose its **UEFI** boot entry.
2. Choose **Install**, not **Graphical install**. Only the text installer's
   initrd is customized with firmware, scripts and preseed.
3. Select the internal installation disk and confirm replacing its contents.
   The same disk is used for GRUB, and UEFI firmware boot entries are updated.
4. If using a separate content USB, configure its filesystem and `/Library`
   mount in manual partitioning before finishing that step.
5. Let Debian install and download the Library repository. It automatically
   reboots after completion; remove the installer USB so it boots the OS disk.

The installed system includes:

- Debian trixie, GNOME, Git, SSH, sudo and CA certificates.
- Users `root` and `library`, both with password **`library`**.
- Automatic GNOME login as **root**, plus root password login through SSH.
- US English locale, US keyboard, US/Mountain timezone, DHCP networking.
- Disabled popularity-contest participation.
- Disabled automatic screen locking and AC sleep; display blanking and battery
  inactivity sleep timers set to one hour. Early idle dimming is disabled.
- A clone of `https://github.com/holly-the-dude/Library-Creator_x86.git` at
  `/root/Library-Creator_x86`. Existing directories are preserved, not updated.

The clone runs inside the installed system using `in-target git clone`, which
is equivalent to cloning after `cd /root`. It downloads the repository but
**does not run its scripts**. A network/GitHub failure is logged under
`library-clone` and does not block completion of the Debian installation.

## 5. Set up the Library after reboot

Open a terminal on the root desktop. If the automatic clone failed, retry:

```sh
cd /root
git clone https://github.com/holly-the-dude/Library-Creator_x86.git
```

Then check the host and open the Library setup menu:

```sh
cd /root/Library-Creator_x86
./bootstrap --check
./bootstrap --storage mounted
```

Choose **Fresh Install** and your Office preference. The preseed layouts use
an existing mount at `/Library`; mounted mode requires it to be mounted:

```sh
findmnt /Library
```

If you intentionally use a normal directory on the OS filesystem instead of
an existing `/Library` mount, use `./bootstrap --storage directory`. An existing
mount is also detected automatically by a plain `./bootstrap` fresh install.
From the `library` user, prefix installation commands with `sudo`.

Preserve the `/Library` partition created by Debian. Library setup formats a
partition only when you explicitly select that operation and confirm erasure;
normal setup preserves existing content. Empty storage, including storage with
only `lost+found`, receives the bundled starter content before services start.

The Library bootstrap stages its checkout under `/opt/library-creator`, builds
native containers, and installs the host services. Firefox shows progress at
`file:///root/progress.html`; full output is in
`/var/log/library-installer/install.log`. Keep internet and power connected.
Successful setup schedules a reboot within one minute; failed setup does not.
After reboot, Firefox shows startup progress and opens `http://localhost/`
when the services are ready. The **Library** desktop shortcut opens it too.

Office is optional. To enable it during setup:

```sh
./bootstrap --storage mounted --office yes
```

Office and routing imports require substantial extra disk space, and routing
memory requirements depend on the chosen region. Office clients need a
keyboard and pointing device. To change Office later without rebuilding:

```sh
cd /root/Library-Creator_x86
./bootstrap --configure-office yes
# or: ./bootstrap --configure-office no
```

## 6. Connect and use your Library

| Connection | Open in the browser |
| --- | --- |
| On the Library machine | `http://localhost/` |
| Another device on the same LAN | `http://<machine-IP>/` (find the address with `hostname -I`) |
| Connected to the Library hotspot | `http://10.1.1.1/` |

Ethernet and existing Debian network connections are retained. For a hotspot,
use **Library Wi-Fi** on the root desktop or in the applications menu. Choose
an AP-capable adapter and hotspot mode. It broadcasts the open **`library`**
network with no password. Visitors connect and open `http://10.1.1.1/`.
Switch back to internet Wi-Fi using the same shortcut when downloading content.
The same adapter cannot act as hotspot and internet client simultaneously;
Ethernet is unchanged. Keep initial downloads on Ethernet or internet Wi-Fi.

The homepage links to Wikipedia/Kiwix, music and audiobooks, e-books, maps,
StreetZim, Meshtastic, Downloads and optional Office. Typical ports:

| Service | Port |
| --- | --- |
| Library homepage | 80 |
| Downloads and uploads | 4826 |
| Wikipedia/Kiwix | 6902 |
| E-books | 8083 |
| Maps | 8080 |
| Music player | 2001 |
| Meshtastic | 8086 |
| StreetZim | 8093 |
| Optional Office | 3001 (HTTPS) |

Use **Downloads** to fetch maps, ZIM collections and other offline assets.
Saved content works offline; downloading new collections needs internet access.
Upload or copy your own content to:

- Music: `/Library/music`
- Public files: `/Library/library`
- E-books: `/Library/calibre/put_new_books_here`

Offline directions need a routing extract in addition to the map. A USB radio
or GPS connects to the Library host. Content-dependent services may show
**Not running** until their content is present.

## Maintenance and troubleshooting

Run Library commands from `/root/Library-Creator_x86`. Its menu offers status,
retry, reinstall/upgrade, container rebuilds, Office configuration and USB Clone
repair. Reinstall/Upgrade pulls source changes; Rebuild uses current source.

```sh
./bootstrap --status
systemctl status start_library
journalctl -u start_library -b
podman ps -a
systemctl restart start_library
```

In the Debian installer, inspect `/var/log/syslog` for a failure. Git clone
messages use tag `library-clone`; optional GNOME settings use `library-desktop`.
If an old installer loops at **Finish installation** with an unterminated
quoted string in `preseed/late_command`, rebuild and reflash with the corrected
preseed. To finish that old session instead, the installer shell can skip its
late command with `debconf-set preseed/late_command true`, then `exit` and retry
**Finish installation**. This also skips other setup performed by that command.

If another OS boots after a supposedly successful replacement, check the
actual installed disk layout and firmware boot order. Boot the USB in UEFI
mode, select the intended internal disk and wait for installation to complete.

## Firmware and implementation notes

The builder downloads trixie's architecture-specific `mini.iso` and firmware
collection, checks their HTTPS-served SHA256 manifests, and embeds firmware,
preseed and installer helpers in the initrd. It rebuilds the ISO with xorriso
boot-record replay. This includes Intel `firmware-iwlwifi`; no laptop-model
selection is needed. Firmware increases image size and RAM requirements, and
newer hardware may need firmware beyond the trixie collection. Debian checksum
signatures are not independently verified by this builder.

Settings are shared by both builders in `preseed/partition.cfg` and
`preseed/usb.cfg`; helper scripts are in `installer/`. Root SSH uses
`00-library-root.conf`; GDM root login/autologin changes preserve originals as
`.library-original`. GNOME defaults are compiled near installation completion;
errors in optional desktop settings log a warning rather than block completion.

Python and PowerShell helper checks run on Linux. PowerShell image-building
has also been checked with cached Debian inputs and Linux xorriso. MSYS2 setup,
UAC, native macOS/Windows USB flashing and hardware boot/install behavior still
need testing on their respective platforms.

## Further reading

- [Library project README](../Library-Creator_x86/README.md)
- [Library installation guide](../Library-Creator_x86/docs/INSTALL.md)
- [Library usage guide](../Library-Creator_x86/docs/USAGE.md)
- [Library bootstrap reference](../Library-Creator_x86/bootstrap.md)
- [Library remaining validation](../Library-Creator_x86/TODO.md)
- [Debian preseed documentation](https://www.debian.org/releases/trixie/amd64/apbs04.en.html)
- [Official preseed example](https://www.debian.org/releases/trixie/example-preseed.txt)
- [Trixie AMD64 installer](https://deb.debian.org/debian/dists/trixie/main/installer-amd64/current/images/netboot/)
- [Trixie ARM64 installer](https://deb.debian.org/debian/dists/trixie/main/installer-arm64/current/images/netboot/)
- [Debian firmware collection](https://cdimage.debian.org/cdimage/firmware/trixie/current/)
