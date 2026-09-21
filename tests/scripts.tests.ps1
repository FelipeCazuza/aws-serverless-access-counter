#requires -Version 7.3
$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('counter-test-' + [guid]::NewGuid())
New-Item -ItemType Directory "$fixture/scripts", "$fixture/config", "$fixture/terraform" | Out-Null
Copy-Item "$PSScriptRoot/../scripts/common.ps1" "$fixture/scripts/common.ps1"
Set-Content "$fixture/config/aws.secrets.enc.json" 'mock ciphertext'
Set-Content "$fixture/scripts/build.ps1" 'if ($scenario -eq "build-failure") { throw "Build failed" }'
$originalRegion = $env:AWS_REGION
$originalToken = $env:AWS_SESSION_TOKEN
$originalKey = $env:AWS_ACCESS_KEY_ID
$originalSecret = $env:AWS_SECRET_ACCESS_KEY
try {
    . "$fixture/scripts/common.ps1"
    $toolsFailed = $false
    try { Assert-Tools @('counter-nonexistent-command-93817') } catch { $toolsFailed = $true }
    if (-not $toolsFailed) { throw 'Missing tool was accepted' }
    Write-Host 'PASS: missing tool detection'
    function Assert-Tools { param($Names) if ($script:scenario -eq 'missing-tools') { throw 'Missing tool' } }
    function sops {
        $global:LASTEXITCODE = 0
        if ($script:scenario -eq 'decrypt-failure') { $global:LASTEXITCODE = 1; return }
        if ($script:scenario -eq 'invalid-json') { return 'invalid-json' }
        if ($script:scenario -eq 'invalid-shape') { return '"invalid-shape"' }
        $secrets = @{
            AWS_ACCESS_KEY_ID = 'test-only'
            AWS_SECRET_ACCESS_KEY = 'test-only'
            AWS_REGION = 'us-east-1'
            AWS_ACCOUNT_ID = '123456789012'
        }
        switch ($script:scenario) {
            'missing-secret' { $secrets.Remove('AWS_SECRET_ACCESS_KEY') }
            'invalid-region' { $secrets.AWS_REGION = 'invalid' }
            'invalid-account' { $secrets.AWS_ACCOUNT_ID = '123' }
            'session-token' { $secrets.AWS_SESSION_TOKEN = 'session-test-only' }
        }
        return ($secrets | ConvertTo-Json)
    }
    function Read-Host { param($Prompt) if ($script:scenario -eq 'cancel') { return 'nao' }; return 'sim' }
    function Invoke-Native {
        param($Command, $Arguments)
        $script:calls.Add("$Command $($Arguments -join ' ')")
        if ($Command -eq 'aws') {
            if ($script:scenario -eq 'session-token') {
                if ($env:AWS_SESSION_TOKEN -ne 'session-test-only') { throw 'Missing session token' }
            } elseif ($env:AWS_SESSION_TOKEN) { throw 'Stale session token leaked' }
            if ($env:AWS_REGION -ne 'us-east-1' -or $env:AWS_DEFAULT_REGION -ne 'us-east-1') { throw 'Incorrect region' }
            if ($env:TF_VAR_aws_region -ne 'us-east-1' -or $env:TF_VAR_allowed_account_ids -ne '["123456789012"]') { throw 'Incorrect Terraform variables' }
            $script:stsCount++
            if ($script:scenario -eq 'sts-failure') { throw 'STS failed' }
            if ($script:scenario -eq 'wrong-account' -or ($script:scenario -eq 'changed-account' -and $script:stsCount -eq 2)) {
                return '{"Account":"999999999999"}'
            }
            return '{"Account":"123456789012"}'
        }
        if ($Arguments[0] -in @('plan', 'destroy') -and ($Arguments -join ' ') -notmatch 'allowed_account_ids=\["123456789012"\]') {
            throw 'Missing account guard in Terraform arguments'
        }
        switch ($Arguments[0]) {
            'plan' {
                Set-Content "$fixture/terraform/tfplan" 'mock plan'
                if ($script:scenario -eq 'plan-failure') { throw 'Plan failed' }
            }
            'apply' { if ($script:scenario -eq 'apply-failure') { throw 'Apply failed' } }
            'workspace' { return 'default' }
            'output' {
                if ($Arguments[1] -eq '-json') {
                    if ($script:scenario -eq 'state-mismatch') { return '{"aws_region":{"value":"eu-west-1"}}' }
                    return '{}'
                }
                return 'mock output'
            }
        }
    }
    foreach ($operation in @('deploy', 'destroy')) {
        $cases = @('success', 'session-token', 'missing-tools', 'missing-secret', 'invalid-region', 'invalid-account', 'wrong-account', 'sts-failure', 'decrypt-failure', 'invalid-json', 'invalid-shape', 'state-mismatch', 'changed-account')
        if ($operation -eq 'deploy') { $cases += @('build-failure', 'plan-failure', 'apply-failure', 'cancel') }
        foreach ($scenario in $cases) {
            $script:scenario = $scenario
            $script:calls = [Collections.Generic.List[string]]::new()
            $script:stsCount = 0
            $env:AWS_SESSION_TOKEN = 'stale-test-token'
            $env:AWS_REGION = 'original-region'
            $failed = $false
            try { Invoke-CounterOperation $operation } catch { $failed = $true; if ($scenario -in @('success', 'session-token')) { throw } }
            if ($failed -ne ($scenario -notin @('success', 'session-token'))) { throw "Unexpected outcome: $operation / $scenario" }
            if ($env:AWS_ACCESS_KEY_ID -or $env:AWS_SECRET_ACCESS_KEY -or $env:AWS_SESSION_TOKEN) { throw 'Credentials not cleared' }
            if ($env:AWS_REGION -ne 'original-region') { throw 'Region not restored' }
            if (Test-Path "$fixture/terraform/tfplan") { throw 'Plan not removed' }
            $mutations = @($script:calls | Where-Object { $_ -match '^terraform (apply|destroy)' })
            if ($scenario -notin @('success', 'session-token', 'apply-failure') -and $mutations.Count -gt 0) { throw "Unsafe mutation: $scenario" }
            if ($scenario -in @('success', 'session-token') -and $mutations.Count -ne 1) { throw 'Missing mutation' }
            if ($scenario -eq 'wrong-account' -and @($script:calls | Where-Object { $_ -like 'terraform *' }).Count) { throw 'Terraform ran on wrong account' }
            Write-Host "PASS: $operation / $scenario"
        }
    }
    Copy-Item "$PSScriptRoot/../scripts/test.ps1" "$fixture/scripts/test.ps1"
    Set-Content "$fixture/scripts/common.ps1" @'
function Assert-Tools { param($Names) }
function Invoke-Native { param($Command, $Arguments) return 'https://example.invalid/hit' }
'@
    function Invoke-RestMethod {
        param($Method, $Uri)
        if ($Method -ne 'POST' -or $Uri -ne 'https://example.invalid/hit') { throw 'Incorrect API request' }
        return @{ hits = 1 }
    }
    $response = & "$fixture/scripts/test.ps1"
    if ($response.hits -ne 1) { throw 'Missing API response' }
    Write-Host 'PASS: test.ps1 with simulated HTTP'
} finally {
    $env:AWS_REGION = $originalRegion
    $env:AWS_SESSION_TOKEN = $originalToken
    $env:AWS_ACCESS_KEY_ID = $originalKey
    $env:AWS_SECRET_ACCESS_KEY = $originalSecret
    Remove-Item $fixture -Recurse -Force
}
