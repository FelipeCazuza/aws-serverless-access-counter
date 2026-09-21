#requires -Version 7.3
. "$PSScriptRoot/common.ps1"
Assert-Tools @('go')
$buildEnvironment = @{}
foreach ($name in @('GOOS', 'GOARCH', 'CGO_ENABLED')) {
    $buildEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
Push-Location (Join-Path $PSScriptRoot '../lambda')
try {
    $env:GOOS = 'linux'
    $env:GOARCH = 'arm64'
    $env:CGO_ENABLED = '0'
    Invoke-Native go @('build', '-mod=readonly', '-trimpath', '-ldflags=-s -w', '-o', 'bootstrap', '.')
    Write-Host 'Build concluido: lambda/bootstrap (Linux ARM64)'
} finally {
    foreach ($name in $buildEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $buildEnvironment[$name], 'Process')
    }
    Pop-Location
}
