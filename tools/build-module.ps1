#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dist = Join-Path $repo 'dist'
$versionLine = Get-Content -LiteralPath (Join-Path $repo 'module.prop') | Where-Object { $_ -match '^version=' }
$version = $versionLine -replace '^version=', ''
if ($version -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Invalid module version' }
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$output = Join-Path $dist "PJX110-PPS-KSU-$version.zip"
$temporary = Join-Path $dist ('.build-' + [guid]::NewGuid().ToString('N') + '.zip')
$files = @('module.prop','customize.sh','common.sh','uninstall.sh','skip_mount','README.md','RECOVERY.md','FIRMWARES.md','FIRMWARES.json','LICENSE','THIRD_PARTY_NOTICES.md')
foreach ($directory in @('bin','templates','webroot','rescue','LICENSES')) {
    $files += Get-ChildItem -LiteralPath (Join-Path $repo $directory) -File -Recurse |
        ForEach-Object { [IO.Path]::GetRelativePath($repo, $_.FullName).Replace('\','/') }
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$catalog = Get-Content -LiteralPath (Join-Path $repo 'FIRMWARES.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$setsDirectory = Join-Path $dist 'image-sets'
New-Item -ItemType Directory -Path $setsDirectory -Force | Out-Null
$packedSets = @{}
foreach ($firmware in $catalog) {
    if ($firmware.family -notmatch '^\d+(?:_\d+)?$') { throw 'Invalid image family' }
    $packedPath = Join-Path $setsDirectory ('dtbo_' + $firmware.family + '.zip')
    $packedTemp = Join-Path $setsDirectory ('.set-' + [guid]::NewGuid().ToString('N') + '.zip')
    $set = [IO.Compression.ZipFile]::Open($packedTemp, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($profile in @('stock','pps33','pps55')) {
            $image = Join-Path $repo ('images/dtbo_' + $firmware.family + '_' + $profile + '.img')
            $expected = $firmware."${profile}_sha"
            if ((Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw "Image hash mismatch: $image" }
            $entry = $set.CreateEntry("$profile.img", [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::new(1980,1,1,0,0,0,[TimeSpan]::Zero)
            $inputStream = [IO.File]::OpenRead($image)
            $outputStream = $entry.Open()
            try { $inputStream.CopyTo($outputStream) }
            finally { $outputStream.Dispose(); $inputStream.Dispose() }
        }
    } finally { $set.Dispose() }
    # Reopen each compressed triplet and hash its decompressed members. This
    # also catches source changes between the pre-pack hash and stream copy.
    $checkSet = [IO.Compression.ZipFile]::OpenRead($packedTemp)
    try {
        if ($checkSet.Entries.Count -ne 3) { throw "Invalid triplet count: $packedTemp" }
        foreach ($profile in @('stock','pps33','pps55')) {
            $entry = $checkSet.GetEntry("$profile.img")
            if ($null -eq $entry) { throw "Missing compressed profile: $profile" }
            $stream = $entry.Open()
            try { $actual = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
            finally { $stream.Dispose() }
            if ($actual -ne $firmware."${profile}_sha") { throw "Compressed image hash mismatch: $profile" }
        }
    } finally { $checkSet.Dispose() }
    Move-Item -LiteralPath $packedTemp -Destination $packedPath -Force
    $packedSets['image_sets/dtbo_' + $firmware.family + '.zip'] = $packedPath
}
$zip = [IO.Compression.ZipFile]::Open($temporary, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($name in ($files | Sort-Object -Unique)) {
        if ($name -match '(^|/)(AGENTS\.md|dist|investigation|tools|patch-mode)(/|$)') { throw "Forbidden archive path: $name" }
        $source = Join-Path $repo $name
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $source, $name, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
    foreach ($name in ($packedSets.Keys | Sort-Object)) {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $packedSets[$name], $name, [IO.Compression.CompressionLevel]::NoCompression) | Out-Null
    }
} finally { $zip.Dispose() }
# Validate every archive entry before replacing the prior local ZIP.
$zip = [IO.Compression.ZipFile]::OpenRead($temporary)
try {
    foreach ($entry in $zip.Entries) {
        $stream = $entry.Open()
        try { $actual = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) }
        finally { $stream.Dispose() }
        $source = if ($packedSets.ContainsKey($entry.FullName)) { $packedSets[$entry.FullName] } else { Join-Path $repo $entry.FullName }
        $expected = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        if ($actual -ne $expected) { throw "Archive hash mismatch: $($entry.FullName)" }
    }
    $entryCount = $zip.Entries.Count
} finally { $zip.Dispose() }
Move-Item -LiteralPath $temporary -Destination $output -Force
[pscustomobject]@{Path=$output;Entries=$entryCount;Bytes=(Get-Item -LiteralPath $output).Length;SHA256=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()}
