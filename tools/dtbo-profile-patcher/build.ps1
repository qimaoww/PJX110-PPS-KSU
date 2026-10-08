#requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$output = Join-Path $repo 'bin\dtbo-profile-patcher'

Push-Location $PSScriptRoot
try {
    Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.go' | ForEach-Object {
        & gofmt -w $_.FullName
        if ($LASTEXITCODE -ne 0) { throw "gofmt failed: $($_.Name)" }
    }
    & go mod verify
    if ($LASTEXITCODE -ne 0) { throw 'go mod verify failed' }
    & go vet ./...
    if ($LASTEXITCODE -ne 0) { throw 'go vet failed' }

    $oldGoos = $env:GOOS
    $oldGoarch = $env:GOARCH
    $oldCgo = $env:CGO_ENABLED
    try {
        $env:GOOS = 'linux'
        $env:GOARCH = 'arm64'
        $env:CGO_ENABLED = '0'
        & go build -buildvcs=false -trimpath -ldflags '-s -w -buildid=' -o $output .
        if ($LASTEXITCODE -ne 0) { throw 'arm64 build failed' }
    }
    finally {
        $env:GOOS = $oldGoos
        $env:GOARCH = $oldGoarch
        $env:CGO_ENABLED = $oldCgo
    }
}
finally {
    Pop-Location
}

$item = Get-Item -LiteralPath $output
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $output).Hash.ToLowerInvariant()
[pscustomobject]@{
    PowerShell = $PSVersionTable.PSVersion.ToString()
    Output = $item.FullName
    Bytes = $item.Length
    SHA256 = $hash
}
