# Windows x64 bootstrap. From a release archive, installs the adjacent executable.
[CmdletBinding()]
param(
    [string]$Version = 'latest',
    [string]$HomeDirectory,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$download_dir = $null
$native_encoding = [Console]::OutputEncoding
try {
    if ($env:OS -ne 'Windows_NT') { throw 'This installer requires Windows.' }
    $architecture = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $architecture = $env:PROCESSOR_ARCHITEW6432 }
    if ($architecture -ne 'AMD64') { throw 'This release supports Windows x64 only.' }
    $binary_path = Join-Path $PSScriptRoot 'vibeguard-runtime.exe'
    if (!(Test-Path -LiteralPath $binary_path -PathType Leaf) -or $Version -ne 'latest') {
        if ($Version -eq 'latest') {
            $release = Invoke-RestMethod 'https://api.github.com/repos/majiayu000/vibeguard/releases/latest'
            $Version = $release.tag_name
        }
        if ($Version -notmatch '^v\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$') {
            throw 'Version must be a release tag such as v2.1.0.'
        }
        $download_dir = Join-Path ([IO.Path]::GetTempPath()) ('vibeguard-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $download_dir | Out-Null
        $archive_name = 'vibeguard-x86_64-pc-windows-msvc.tar.gz'
        $release_url = "https://github.com/majiayu000/vibeguard/releases/download/$Version"
        $archive_path = Join-Path $download_dir $archive_name
        $checksum_path = Join-Path $download_dir 'SHA256SUMS'
        Invoke-WebRequest -UseBasicParsing "$release_url/$archive_name" -OutFile $archive_path
        Invoke-WebRequest -UseBasicParsing "$release_url/SHA256SUMS" -OutFile $checksum_path
        $checksum_lines = @(Get-Content -LiteralPath $checksum_path | Where-Object {
            $_ -match ('^[0-9a-fA-F]{64}\s+\*?' + [regex]::Escape($archive_name) + '$')
        })
        if ($checksum_lines.Count -ne 1) { throw 'Release checksum is missing or ambiguous.' }
        $expected_hash = ($checksum_lines[0] -split '\s+')[0]
        if ((Get-FileHash -LiteralPath $archive_path -Algorithm SHA256).Hash -ne $expected_hash) {
            throw 'Release archive checksum mismatch.'
        }
        & tar.exe -xzf $archive_path -C $download_dir
        if ($LASTEXITCODE -ne 0) { throw "Archive extraction failed (exit $LASTEXITCODE)." }
        $binary_path = Join-Path $download_dir 'vibeguard-runtime.exe'
    }
    $install_args = @('install', 'claude')
    if ($HomeDirectory) { $install_args += @('--home', $HomeDirectory) }
    if ($DryRun) { $install_args += '--dry-run' }
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    & $binary_path @install_args
    if ($LASTEXITCODE -ne 0) { throw "VibeGuard installation failed (exit $LASTEXITCODE)." }
} finally {
    [Console]::OutputEncoding = $native_encoding
    if ($download_dir) { Remove-Item -LiteralPath $download_dir -Recurse -Force }
}
