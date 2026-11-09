#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('amd64','arm64')][string]$Arch,
    [ValidateSet('partition','usb')][string]$Layout,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'output'),
    [string]$Image,
    [switch]$NoWrite,
    [switch]$WriteOnly,
    [int]$DiskNumber = -1,
    [string]$ExpectedDiskId,
    [string]$ExpectedImageHash
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$script:Root = $PSScriptRoot
$script:EntryScript = $PSCommandPath
$script:Tmp = Join-Path $script:Root 'tmp'

function Say([string]$Text, [ConsoleColor]$Color = 'Cyan') {
    if (Test-Path Env:NO_COLOR) { Write-Host $Text } else { Write-Host $Text -ForegroundColor $Color }
}
function Select-Option([string]$Title, [string[]]$Options, [int]$Default = 0) {
    Say "`n$Title"
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $suffix = if ($i + 1 -eq $Default) { ' (default)' } else { '' }
        Say ('  {0}. {1}{2}' -f ($i + 1), $Options[$i], $suffix)
    }
    while ($true) {
        $hint = if ($Default) { " [$Default]" } else { '' }
        $answer = Read-Host "Choose a number$hint"
        if (!$answer -and $Default) { return $Default - 1 }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Options.Count) {
            return $number - 1
        }
        Say "Enter a number from 1 to $($Options.Count)." Yellow
    }
}
function Get-File([string]$Url, [string]$Destination) {
    Say "Downloading $Url"
    $client = New-Object Net.WebClient
    try {
        $client.Headers['User-Agent'] = 'bootstrap_debian'
        $client.DownloadFile($Url, $Destination)
    } finally { $client.Dispose() }
}
function Assert-Checksum([string]$File, [string]$Manifest, [string]$Entry) {
    $matches = @(Get-Content -LiteralPath $Manifest | Where-Object {
        $_ -match '^([a-fA-F0-9]{64})\s+\*?(.+)$' -and ($Matches[2] -replace '^\./','') -eq $Entry
    })
    if ($matches.Count -ne 1) { throw "No unique SHA256 checksum for $Entry" }
    $expected = ($matches[0] -split '\s+')[0]
    if ((Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash -ne $expected) {
        throw "Checksum verification failed: $Entry"
    }
}
function Invoke-Tool([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE" }
}
function Convert-MsysPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^([A-Za-z]):\\') { throw 'Build files must be on a local drive, not a UNC network path.' }
    return '/' + $full.Substring(0,1).ToLowerInvariant() + '/' + $full.Substring(3).Replace('\','/')
}
function Get-Xorriso {
    $root = Join-Path $script:Tmp 'tools'
    if ($root -match '\s') { throw 'Portable ISO tools need a folder path without spaces. Move this folder to e.g. C:\debian_bootstrap and run again.' }
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $msys = Join-Path $root 'msys64'
    $exe = Join-Path $msys 'usr\bin\xorriso.exe'
    if (Test-Path -LiteralPath $exe) {
        try { Invoke-Tool $exe @('-version'); return $exe }
        catch { Say 'Cached ISO tools are incomplete; preparing a fresh copy.' Yellow }
    }
    # Leave interrupted caches aside rather than extracting over existing files.
    if (Test-Path -LiteralPath $msys) {
        Move-Item -LiteralPath $msys -Destination (Join-Path $root ('msys64-incomplete-' + [guid]::NewGuid().ToString('N')))
    }
    $work = Join-Path $root ('msys-setup-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        Say 'Preparing portable ISO tools. No WSL or Python installation is needed.'
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/msys2/msys2-installer/releases/latest' -Headers @{'User-Agent'='bootstrap_debian'}
        $assets = @($release.assets | Where-Object { $_.name -match '^msys2-base-x86_64-.*\.sfx\.exe$' })
        if ($assets.Count -ne 1) { throw 'Unable to locate the official portable MSYS2 tools.' }
        $asset = $assets[0]
        if ($asset.digest -notmatch '^sha256:([a-f0-9]{64})$') { throw 'Portable tools download has no SHA256 digest.' }
        $expected = $Matches[1]
        $archive = Join-Path $work 'msys2-base.sfx.exe'
        Get-File $asset.browser_download_url $archive
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expected) { throw 'Portable tools checksum failed.' }
        Invoke-Tool $archive @('-y', "-o$work")
        $prepared = Join-Path $work 'msys64'
        $oldSystem = $env:MSYSTEM
        $oldHere = $env:CHERE_INVOKING
        try {
            $env:MSYSTEM = 'MSYS'
            $env:CHERE_INVOKING = '1'
            # The portable runtime initializes its keyring; pacman verifies package signatures.
            Invoke-Tool (Join-Path $prepared 'usr\bin\bash.exe') @('--login','-c','pacman -Sy --needed --noconfirm xorriso')
        } finally {
            $env:MSYSTEM = $oldSystem
            $env:CHERE_INVOKING = $oldHere
        }
        Invoke-Tool (Join-Path $prepared 'usr\bin\xorriso.exe') @('-version')
        [IO.Directory]::Move($prepared, $msys)
        return $exe
    } finally { Remove-Item -LiteralPath $work -Recurse -Force }
}
function Publish-Image([string]$Staged, [string]$Destination) {
    # Same-directory renames also work on filesystems without File.Replace support.
    $backup = $Destination + '.previous-' + [guid]::NewGuid().ToString('N')
    $hadPrevious = [IO.File]::Exists($Destination)
    if ($hadPrevious) { [IO.File]::Move($Destination, $backup) }
    try { [IO.File]::Move($Staged, $Destination) }
    catch {
        if ($hadPrevious) { [IO.File]::Move($backup, $Destination) }
        throw
    }
    if ($hadPrevious) { Remove-Item -LiteralPath $backup -Force }
}
function Write-CpioEntry([IO.Stream]$Stream, [string]$Name, [byte[]]$Data, [int]$Mode) {
    $nameBytes = [Text.Encoding]::ASCII.GetBytes($Name + [char]0)
    $fields = @(1, $Mode, 0, 0, 1, 0, $Data.Length, 0, 0, 0, 0, $nameBytes.Length, 0)
    $header = '070701' + (($fields | ForEach-Object { '{0:x8}' -f $_ }) -join '')
    $bytes = [Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Write($nameBytes, 0, $nameBytes.Length)
    for ($i = 0; $i -lt ((4 - ((110 + $nameBytes.Length) % 4)) % 4); $i++) { $Stream.WriteByte(0) }
    $Stream.Write($Data, 0, $Data.Length)
    for ($i = 0; $i -lt ((4 - ($Data.Length % 4)) % 4); $i++) { $Stream.WriteByte(0) }
}
function New-PreseedArchive([string]$Config, [string]$Destination) {
    $file = [IO.File]::Create($Destination)
    $zip = New-Object IO.Compression.GZipStream($file, [IO.Compression.CompressionMode]::Compress)
    try {
        Write-CpioEntry $zip 'preseed.cfg' ([IO.File]::ReadAllBytes($Config)) 33152
        Write-CpioEntry $zip 'library-select-target.sh' ([IO.File]::ReadAllBytes((Join-Path $script:Root 'installer\select-target.sh'))) 33152
        Write-CpioEntry $zip 'library-target.templates' ([IO.File]::ReadAllBytes((Join-Path $script:Root 'installer\target.templates'))) 33152
        Write-CpioEntry $zip 'library-root-access.sh' ([IO.File]::ReadAllBytes((Join-Path $script:Root 'installer\root-access.sh'))) 33152
        Write-CpioEntry $zip 'library-clone-library.sh' ([IO.File]::ReadAllBytes((Join-Path $script:Root 'installer\clone-library.sh'))) 33152
        Write-CpioEntry $zip 'TRAILER!!!' ([byte[]]@()) 0
    } finally { $zip.Dispose(); $file.Dispose() }
}
function Build-Image([string]$Architecture, [string]$StorageLayout) {
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $output = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) "debian-trixie-$Architecture-library.iso"
    if (Test-Path -LiteralPath $output) {
        $action = Select-Option 'An installer image already exists. What would you like to do?' @(
            'Rebuild using the settings just selected', 'Use the existing image (keep its previous settings)', 'Cancel') 1
        if ($action -eq 1) { return $output }
        if ($action -eq 2) { throw 'Build cancelled. Existing image kept.' }
    }
    $tool = Get-Xorriso
    $work = Join-Path $script:Tmp ('build-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $config = Join-Path $work 'preseed.cfg'
        Copy-Item -LiteralPath (Join-Path $script:Root "preseed\$StorageLayout.cfg") -Destination $config
        $base = "https://deb.debian.org/debian/dists/trixie/main/installer-$Architecture/current/images/"
        $mini = Join-Path $work 'mini.iso'
        $sums = Join-Path $work 'SHA256SUMS'
        Get-File ($base + 'netboot/mini.iso') $mini
        Get-File ($base + 'SHA256SUMS') $sums
        Assert-Checksum $mini $sums 'netboot/mini.iso'
        $firmware = Join-Path $work 'firmware.cpio.gz'
        $firmwareBase = 'https://cdimage.debian.org/cdimage/firmware/trixie/current/'
        Get-File ($firmwareBase + 'firmware.cpio.gz') $firmware
        Get-File ($firmwareBase + 'SHA256SUMS') $sums
        Assert-Checksum $firmware $sums 'firmware.cpio.gz'
        $initrd = Join-Path $work 'initrd.gz'
        Invoke-Tool $tool @('-osirrox','on','-indev',(Convert-MsysPath $mini),'-extract','/initrd.gz',(Convert-MsysPath $initrd))
        $preseedArchive = Join-Path $work 'preseed.cpio.gz'
        New-PreseedArchive $config $preseedArchive
        $combined = Join-Path $work 'combined-initrd.gz'
        $stream = [IO.File]::Create($combined)
        try {
            foreach ($part in @($initrd, $firmware, $preseedArchive)) {
                $source = [IO.File]::OpenRead($part)
                try { $source.CopyTo($stream) } finally { $source.Dispose() }
            }
        } finally { $stream.Dispose() }
        $built = Join-Path $work 'installer.iso'
        Invoke-Tool $tool @('-indev',(Convert-MsysPath $mini),'-outdev',(Convert-MsysPath $built),
            '-boot_image','any','replay','-map',(Convert-MsysPath $combined),'/initrd.gz',
            '-map',(Convert-MsysPath $config),'/preseed.cfg')
        # Verify that ISO reconstruction preserved the combined initrd byte-for-byte.
        $check = Join-Path $work 'verify-initrd.gz'
        Invoke-Tool $tool @('-osirrox','on','-indev',(Convert-MsysPath $built),'-extract','/initrd.gz',(Convert-MsysPath $check))
        if ((Get-FileHash $combined).Hash -ne (Get-FileHash $check).Hash) { throw 'ISO initrd verification failed.' }
        $staged = Join-Path ([IO.Path]::GetDirectoryName($output)) ('.build-' + [guid]::NewGuid().ToString('N'))
        try {
            [IO.File]::Copy($built, $staged)
            Publish-Image $staged $output
        } finally { if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged } }
        Copy-Item -LiteralPath $config -Destination (Join-Path $OutputDirectory 'preseed.cfg') -Force
        Say "Installer image ready: $output" Green
        return $output
    } finally { Remove-Item -LiteralPath $work -Recurse -Force }
}
function Get-Etcher {
    $tools = Join-Path $script:Tmp 'tools'
    New-Item -ItemType Directory -Force -Path $tools | Out-Null
    Say 'Checking the official portable balenaEtcher release.'
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/balena-io/etcher/releases/latest' -Headers @{'User-Agent'='bootstrap_debian'}
    $assets = @($release.assets | Where-Object { $_.name -match '^balenaEtcher-win32-x64-.*\.zip$' })
    if ($assets.Count -ne 1) { throw 'Cannot locate the official Windows x64 portable Etcher ZIP.' }
    $asset = $assets[0]
    if ($asset.digest -notmatch '^sha256:([a-f0-9]{64})$') { throw 'Etcher release has no SHA256 digest; refusing unverified setup.' }
    $expected = $Matches[1]
    $cache = Join-Path $tools ('etcher-windows-x64-' + $expected)
    $marker = Join-Path $cache '.bootstrap-complete'
    $exe = Join-Path $cache 'balenaEtcher.exe'
    if ((Test-Path -LiteralPath $marker) -and (Test-Path -LiteralPath $exe)) { return $exe }
    # A failed extraction must never be mistaken for a complete cached application.
    if (Test-Path -LiteralPath $cache) {
        Move-Item -LiteralPath $cache -Destination ($cache + '-incomplete-' + [guid]::NewGuid().ToString('N'))
    }
    $work = Join-Path $tools ('etcher-setup-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $package = Join-Path $work 'etcher.zip'
        Say 'Downloading portable balenaEtcher. No installation is needed.'
        Get-File $asset.browser_download_url $package
        if ((Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash -ne $expected) { throw 'Etcher download checksum verification failed.' }
        $extracted = Join-Path $work 'extracted'
        Expand-Archive -LiteralPath $package -DestinationPath $extracted
        $launchers = @(Get-ChildItem -LiteralPath $extracted -Filter 'balenaEtcher.exe' -Recurse -File)
        if ($launchers.Count -ne 1) { throw 'Etcher ZIP does not contain its expected application.' }
        $app = $launchers[0].DirectoryName
        Set-Content -LiteralPath (Join-Path $app '.bootstrap-complete') -Value $expected
        [IO.Directory]::Move($app, $cache)
        return $exe
    } finally { Remove-Item -LiteralPath $work -Recurse -Force }
}
function Start-Etcher([string]$ImagePath) {
    $exe = Get-Etcher
    Say "Opening Etcher with installer image: $ImagePath" Yellow
    Say 'Choose Select target, check the USB name and capacity, then Flash. Wait for validation to finish.' Yellow
    # Etcher accepts the image path as its final positional argument.
    Start-Process -FilePath $exe -Verb RunAs -ArgumentList ('"' + $ImagePath + '"') | Out-Null
    Say 'Etcher is open. Complete USB flashing in its window; closing this script does not stop Etcher.' Green
}
function Get-UsbDisks {
    return @(Get-Disk | Where-Object {
        $_.BusType -eq 'USB' -and !$_.IsBoot -and !$_.IsSystem -and !$_.IsReadOnly -and $_.Size -gt 0
    } | Sort-Object Number)
}
function Describe-Disk($Disk) {
    return '{0} - {1:N1} GiB (Disk {2})' -f $Disk.FriendlyName, ($Disk.Size / 1GB), $Disk.Number
}
function Test-Administrator {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Write-Usb([string]$ImagePath, [int]$Number, [string]$Identity, [string]$ImageHash) {
    if (!(Test-Administrator)) { throw 'USB writing requires Administrator access.' }
    $disk = Get-Disk -Number $Number
    if ($disk.BusType -ne 'USB' -or $disk.IsBoot -or $disk.IsSystem -or $disk.IsReadOnly) {
        throw 'Refusing a non-USB, system, boot, or read-only disk.'
    }
    if (!$Identity -or [string]$disk.UniqueId -ne $Identity) { throw 'USB identity changed. Select the drive again.' }
    $file = Get-Item -LiteralPath $ImagePath
    if (!$ImageHash -or (Get-FileHash -LiteralPath $ImagePath -Algorithm SHA256).Hash -ne $ImageHash) {
        throw 'Installer image changed. Select the image again.'
    }
    $sector = [int]$disk.LogicalSectorSize
    if ($sector -le 0) { throw 'Cannot determine USB sector size.' }
    $paddedSize = [long]([Math]::Ceiling($file.Length / [double]$sector) * $sector)
    if ($disk.Size -lt $paddedSize) { throw 'The USB drive is smaller than the installer image.' }
    Say ("`nSelected USB drive: " + (Describe-Disk $disk))
    Say 'Creating the installer USB will erase all files on this drive.' Yellow
    if ((Select-Option 'Erase this USB drive and create the installer?' @('Cancel - keep the USB unchanged','Erase this USB and create the installer') 1) -eq 0) {
        Say 'Cancelled. USB unchanged.' Yellow
        return
    }
    $currentDisk = Get-Disk -Number $Number
    if ([string]$currentDisk.UniqueId -ne $Identity -or $currentDisk.IsBoot -or $currentDisk.IsSystem -or $currentDisk.BusType -ne 'USB') {
        throw 'USB identity or system-disk status changed. Select the drive again.'
    }
    # Resolve all volumes belonging to this disk, including those without a drive letter.
    $volumes = @(Get-Partition -DiskNumber $Number | Get-Volume -ErrorAction SilentlyContinue |
        ForEach-Object { if ($_.Path) { $_.Path.TrimEnd('\') } } | Select-Object -Unique)
    if (!('BootstrapUsbWriter' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.ComponentModel;
using Microsoft.Win32.SafeHandles;
public static class BootstrapUsbWriter {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool DeviceIoControl(SafeFileHandle handle, uint code, IntPtr input, uint inputSize, IntPtr output, uint outputSize, out uint returned, IntPtr overlapped);
    static SafeFileHandle Open(string path) {
        SafeFileHandle handle = CreateFile(path, 0xC0000000u, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (handle.IsInvalid) { handle.Dispose(); throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot open " + path); }
        return handle;
    }
    public static void Write(string image, int disk, string[] volumes, int sector) {
        var locked = new List<SafeFileHandle>();
        try {
            foreach (string volume in volumes) {
                SafeFileHandle handle = Open(volume);
                locked.Add(handle);
                uint returned;
                if (!DeviceIoControl(handle, 0x00090018, IntPtr.Zero, 0, IntPtr.Zero, 0, out returned, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot lock USB volume " + volume);
                if (!DeviceIoControl(handle, 0x00090020, IntPtr.Zero, 0, IntPtr.Zero, 0, out returned, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot dismount USB volume " + volume);
            }
            using (SafeFileHandle handle = Open(@"\\.\PhysicalDrive" + disk))
            using (var target = new FileStream(handle, FileAccess.ReadWrite, 1024*1024, false))
            using (var source = File.OpenRead(image)) {
                byte[] buffer = new byte[1024*1024];
                int count;
                while ((count = source.Read(buffer, 0, buffer.Length)) > 0) {
                    int padded = ((count + sector - 1) / sector) * sector;
                    if (padded != count) Array.Clear(buffer, count, padded - count);
                    target.Write(buffer, 0, padded);
                }
                target.Flush(true);
                target.Position = 0;
                source.Position = 0;
                byte[] readback = new byte[buffer.Length];
                while ((count = source.Read(buffer, 0, buffer.Length)) > 0) {
                    int total = 0;
                    while (total < count) {
                        int got = target.Read(readback, total, count-total);
                        if (got == 0) throw new IOException("USB read-back ended early.");
                        total += got;
                    }
                    for (int i=0; i<count; i++) if (buffer[i] != readback[i]) throw new IOException("USB read-back verification failed.");
                }
            }
        } finally { foreach (SafeFileHandle handle in locked) handle.Dispose(); }
    }
}
'@
    }
    Say 'Writing installer and checking the written bytes. Please wait...'
    [BootstrapUsbWriter]::Write($ImagePath, $Number, [string[]]$volumes, $sector)
    Say 'USB written and read-back verified. Safely remove it before booting the target.' Green
}
function Start-UsbWrite([string]$ImagePath, $Disk) {
    $identity = [string]$Disk.UniqueId
    if (!$identity) { throw 'Cannot establish USB identity; refusing to write.' }
    $hash = (Get-FileHash -LiteralPath $ImagePath -Algorithm SHA256).Hash
    if (Test-Administrator) { Write-Usb $ImagePath $Disk.Number $identity $hash; return }
    # EncodedCommand transports paths and device identity without command-line quoting ambiguities.
    $scriptLiteral = $script:EntryScript.Replace("'", "''")
    $imageLiteral = $ImagePath.Replace("'", "''")
    $idLiteral = $identity.Replace("'", "''")
    $command = "& '$scriptLiteral' -WriteOnly -Image '$imageLiteral' -DiskNumber $($Disk.Number) -ExpectedDiskId '$idLiteral' -ExpectedImageHash '$hash'; if (`$LASTEXITCODE -ne 0) { Read-Host 'Press Enter to close' }; exit `$LASTEXITCODE"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Say 'Windows will request Administrator access to write the USB.' Yellow
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
    if ($process.ExitCode -ne 0) { throw 'USB writing did not complete. Check the Administrator window.' }
}

try {
    if ($env:OS -ne 'Windows_NT') { throw 'This script runs on Windows. Use bootstrap_debian on Linux or macOS.' }
    if ($WriteOnly) {
        if (!$Image -or $DiskNumber -lt 0) { throw 'USB write parameters are missing.' }
        Write-Usb ([IO.Path]::GetFullPath($Image)) $DiskNumber $ExpectedDiskId $ExpectedImageHash
        exit 0
    }
    New-Item -ItemType Directory -Force -Path $script:Tmp | Out-Null
    if (!$Image) {
        if (!$Arch) {
            $choice = Select-Option 'What hardware will run Debian?' @('x86-64 - Intel or AMD 64-bit PC','ARM64 - AArch64 hardware with UEFI')
            $Arch = @('amd64','arm64')[$choice]
        }
        if (!$Layout) {
            $choice = Select-Option 'Where should /Library be stored?' @(
                'Same disk - 32 GB for Debian, remaining space for /Library',
                'Separate USB drive for /Library (configure during installation)')
            $Layout = @('partition','usb')[$choice]
        }
        $Image = Build-Image $Arch $Layout
    }
    $Image = (Resolve-Path -LiteralPath $Image).ProviderPath
    Say "Installer image saved: $Image" Green
    if (!$NoWrite) {
        $method = Select-Option 'How would you like to create the USB?' @(
            'Save image only', 'Open portable balenaEtcher GUI', 'Use the built-in Windows USB writer') 2
        if ($method -eq 1) { Start-Etcher $Image; exit 0 }
        if ($method -eq 2) {
            $disks = @(Get-UsbDisks)
            $options = @('Save image only (do not write a USB drive)')
            foreach ($disk in $disks) { $options += 'Create bootable USB on ' + (Describe-Disk $disk) }
            if (!$disks.Count) { Say 'No writable USB drives found by the built-in writer. Use portable balenaEtcher from the USB menu instead.' Yellow }
            $choice = Select-Option 'Create a bootable USB drive, or save the installer image for later.' $options 1
            if ($choice -gt 0) { Start-UsbWrite $Image $disks[$choice - 1] }
        }
    }
    Say 'Boot the USB and choose Install. Remove the installer USB when installation reboots.' Green
    exit 0
} catch {
    Say ("Error: " + $_.Exception.Message) Red
    exit 1
}
