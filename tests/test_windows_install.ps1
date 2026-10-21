param([Parameter(Mandatory = $true)][string]$BinaryPath)
$ErrorActionPreference = 'Stop'
$repo_root = Split-Path $PSScriptRoot -Parent
$temp_dir = Join-Path ([IO.Path]::GetTempPath()) ('vibeguard-installer-test-' + [guid]::NewGuid())
$archive_name = 'vibeguard-x86_64-pc-windows-msvc.tar.gz'
$checksum_mode = 'valid'
$requests = [Collections.Generic.List[string]]::new()

# Keep network responses local while exercising download, extraction and setup.
function Invoke-RestMethod {
    param([string]$Uri)
    if ($Uri -ne 'https://api.github.com/repos/majiayu000/vibeguard/releases/latest') {
        throw 'Unexpected release endpoint.'
    }
    return @{ tag_name = 'v2.1.0' }
}
function Invoke-WebRequest {
    param([switch]$UseBasicParsing, [Parameter(Position = 0)][string]$Uri, [string]$OutFile)
    $requests.Add($Uri)
    if ($Uri -eq "https://github.com/majiayu000/vibeguard/releases/download/v2.1.0/$archive_name") {
        Copy-Item -LiteralPath (Join-Path $temp_dir $archive_name) -Destination $OutFile
    } elseif ($Uri -eq 'https://github.com/majiayu000/vibeguard/releases/download/v2.1.0/SHA256SUMS') {
        $hash = (Get-FileHash -LiteralPath (Join-Path $temp_dir $archive_name) -Algorithm SHA256).Hash
        if ($checksum_mode -eq 'mismatch') { $hash = '0' * 64 }
        $line = "$hash  $archive_name"
        if ($checksum_mode -eq 'missing') { $line = "$hash  other.tar.gz" }
        if ($checksum_mode -eq 'duplicate') { $line += "`n$line" }
        [IO.File]::WriteAllText($OutFile, $line)
    } else {
        throw 'Unexpected download endpoint.'
    }
}

try {
    $package_dir = Join-Path $temp_dir 'package'
    New-Item -ItemType Directory -Path $package_dir | Out-Null
    Copy-Item -LiteralPath $BinaryPath -Destination (Join-Path $package_dir 'vibeguard-runtime.exe')
    Copy-Item -LiteralPath (Join-Path $repo_root 'install.ps1') -Destination $package_dir
    & tar.exe -czf (Join-Path $temp_dir $archive_name) -C $package_dir .
    if ($LASTEXITCODE -ne 0) { throw 'Fixture archive creation failed.' }
    $home_path = Join-Path $temp_dir ('home space ' + [char]0x7528 + [char]0x6237)
    & "$repo_root/install.ps1" -HomeDirectory $home_path -DryRun
    if (Test-Path -LiteralPath $home_path) { throw 'Download preview wrote installation files.' }
    & "$repo_root/install.ps1" -HomeDirectory $home_path
    $installed_binary = Join-Path $home_path '.vibeguard/bin/vibeguard-runtime.exe'
    & $installed_binary status claude --home $home_path
    if ($LASTEXITCODE -ne 0) { throw 'Downloaded installation is incomplete.' }
    if ($requests.Count -ne 4) { throw 'Download path was not exercised.' }
    # The extracted archive's adjacent executable supports offline installation.
    $request_count = $requests.Count
    & "$package_dir/install.ps1" -HomeDirectory $home_path
    if ($requests.Count -ne $request_count) { throw 'Offline installer used the network.' }
    & $installed_binary uninstall claude --home $home_path
    if ($LASTEXITCODE -ne 0) { throw 'Uninstall failed.' }

    foreach ($checksum_mode in @('mismatch', 'missing', 'duplicate')) {
        $rejected_home = Join-Path $temp_dir $checksum_mode
        $failed = $false
        try { & "$repo_root/install.ps1" -HomeDirectory $rejected_home } catch { $failed = $true }
        if (!$failed -or (Test-Path -LiteralPath $rejected_home)) {
            throw "Invalid checksum ($checksum_mode) did not fail before installation."
        }
    }
    $bad_home = Join-Path $temp_dir 'invalid config'
    New-Item -ItemType Directory -Path (Join-Path $bad_home '.claude') | Out-Null
    [IO.File]::WriteAllText((Join-Path $bad_home '.claude/settings.json'), 'invalid JSON')
    $failed = $false
    try { & "$package_dir/install.ps1" -HomeDirectory $bad_home } catch { $failed = $true }
    if (!$failed -or (Test-Path -LiteralPath (Join-Path $bad_home '.vibeguard'))) {
        throw 'Runtime failure was swallowed by the installer.'
    }
    Write-Host 'OK: download, checksum failures, preview, offline reinstall and runtime errors'
} finally {
    Remove-Item -LiteralPath $temp_dir -Recurse -Force
}
exit 0
