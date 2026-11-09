# Run: powershell -NoProfile -File tests/windows_helpers.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$source = Join-Path $script:Root 'bootstrap_debian.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path $source), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($function in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]}, $false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}
$csharp = $ast.FindAll({param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('public static class BootstrapUsbWriter')
}, $true)
Add-Type -TypeDefinition $csharp[0].Value
$work = Join-Path ([IO.Path]::GetTempPath()) ('bootstrap-ps-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
try {
    $config = Join-Path $work 'preseed.cfg'
    [IO.File]::WriteAllText($config, 'test preseed', (New-Object Text.UTF8Encoding($false)))
    $archive = Join-Path $work 'preseed.cpio.gz'
    New-PreseedArchive $config $archive
    $inputFile = [IO.File]::OpenRead($archive)
    $zip = New-Object IO.Compression.GZipStream($inputFile, [IO.Compression.CompressionMode]::Decompress)
    $memory = New-Object IO.MemoryStream
    try { $zip.CopyTo($memory) } finally { $zip.Dispose(); $inputFile.Dispose() }
    $data = $memory.ToArray()
    $text = [Text.Encoding]::ASCII.GetString($data)
    if (!$text.StartsWith('070701') -or !$text.Contains('preseed.cfg') -or !$text.Contains('test preseed') -or !$text.Contains('TRAILER!!!')) { throw 'Invalid preseed archive' }
    $nameSize = [Convert]::ToInt32($text.Substring(94,8),16)
    $dataSize = [Convert]::ToInt32($text.Substring(54,8),16)
    $start = [int]([Math]::Ceiling((110+$nameSize)/4.0)*4)
    if ([Text.Encoding]::ASCII.GetString($data,$start,$dataSize) -ne 'test preseed') { throw 'Invalid cpio alignment' }
    $manifest = Join-Path $work 'SHA256SUMS'
    [IO.File]::WriteAllText($manifest, (Get-FileHash $config).Hash + '  ./netboot/mini.iso')
    Assert-Checksum $config $manifest 'netboot/mini.iso'
    [IO.File]::WriteAllText($config, 'corrupt')
    $rejected = $false
    try { Assert-Checksum $config $manifest 'netboot/mini.iso' } catch { $rejected = $true }
    if (!$rejected) { throw 'Corrupt download accepted' }
    if ($env:OS -eq 'Windows_NT' -and (Convert-MsysPath 'C:\Folder With Spaces\mini.iso') -ne '/c/Folder With Spaces/mini.iso') { throw 'Incorrect MSYS path conversion' }
    function Read-Host { return '' }
    if ((Select-Option 'Test default' @('Cancel','Erase') 1) -ne 0) { throw 'Unsafe confirmation default' }
    function Test-Administrator { return $true }
    function Get-Disk { return [pscustomobject]@{BusType='NVMe'; IsBoot=$true; IsSystem=$true; IsReadOnly=$false} }
    $rejected = $false
    try { Write-Usb $config 0 'fake' 'fake' } catch { $rejected = $true }
    if (!$rejected) { throw 'System disk accepted' }
    $staged = Join-Path $work 'staged.iso'
    $destination = Join-Path $work 'installer.iso'
    [IO.File]::WriteAllText($staged, 'first image')
    Publish-Image $staged $destination
    [IO.File]::WriteAllText($staged, 'rebuilt image')
    Publish-Image $staged $destination
    if ([IO.File]::ReadAllText($destination) -ne 'rebuilt image') { throw 'Existing image not replaced' }
    $rejected = $false
    try { Publish-Image $staged $destination } catch { $rejected = $true }
    if (!$rejected -or [IO.File]::ReadAllText($destination) -ne 'rebuilt image') { throw 'Failed publication lost previous image' }

    # Exercise real ZIP extraction, partial-cache recovery and reuse without network access.
    $script:Tmp = Join-Path $work 'tmp'
    $fixture = Join-Path $work 'etcher-fixture'
    New-Item -ItemType Directory -Path $fixture | Out-Null
    Set-Content -LiteralPath (Join-Path $fixture 'balenaEtcher.exe') -Value 'test executable'
    Set-Content -LiteralPath (Join-Path $fixture 'resources.pak') -Value 'test resource'
    $script:EtcherZip = Join-Path $work 'etcher.zip'
    Compress-Archive -Path (Join-Path $fixture '*') -DestinationPath $script:EtcherZip
    $script:EtcherHash = (Get-FileHash $script:EtcherZip -Algorithm SHA256).Hash.ToLowerInvariant()
    $script:EtcherDownloads = 0
    function Invoke-RestMethod {
        return @{assets=@(@{name='balenaEtcher-win32-x64-2.1.9.zip'; digest=('sha256:' + $script:EtcherHash); browser_download_url='https://example.test/etcher.zip'})}
    }
    function Get-File {
        param($Url, $Destination)
        $script:EtcherDownloads++
        Copy-Item -LiteralPath $script:EtcherZip -Destination $Destination
    }
    $cache = Join-Path $script:Tmp ('tools/etcher-windows-x64-' + $script:EtcherHash)
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $cache 'balenaEtcher.exe') -Value 'partial download'
    $etcher = Get-Etcher
    if (!(Test-Path -LiteralPath $etcher) -or !(Test-Path -LiteralPath (Join-Path $cache 'resources.pak'))) { throw 'Portable Etcher extraction failed' }
    if ((Get-Etcher) -ne $etcher -or $script:EtcherDownloads -ne 1) { throw 'Complete Etcher cache not reused' }
    $script:EtcherHash = '0' * 64
    $rejected = $false
    try { Get-Etcher | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw 'Corrupt Etcher download accepted' }
    Write-Host 'PowerShell syntax, C# compilation, cpio, checksums, menu default, system-disk rejection, image replacement/rollback, and Etcher cache recovery passed.'
} finally { Remove-Item $work -Recurse -Force }
