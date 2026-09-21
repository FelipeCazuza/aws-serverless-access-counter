#requires -Version 7.3
. "$PSScriptRoot/common.ps1"
Assert-Tools @('terraform')
$terraformDir = Join-Path $PSScriptRoot '../terraform'
$url = Invoke-Native terraform @("-chdir=$terraformDir", 'output', '-raw', 'hit_url')
Invoke-RestMethod -Method POST -Uri $url
