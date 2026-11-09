#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('amd64','arm64')][string]$Arch,
    [ValidateSet('partition','usb')][string]$Layout,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'output'),
    [string]$Image,
    [switch]$NoWrite
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$script:Root = $PSScriptRoot
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

try {
    if ($env:OS -ne 'Windows_NT') { throw 'This script runs on Windows. Use bootstrap_debian on Linux or macOS.' }
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
            'Save image only', 'Open portable balenaEtcher GUI') 2
        if ($method -eq 1) { Start-Etcher $Image; exit 0 }
    }
    Say 'Image saved. Run again with -Image to open it in Etcher when you are ready to create the USB.' Green
    exit 0
} catch {
    Say ("Error: " + $_.Exception.Message) Red
    exit 1
}
