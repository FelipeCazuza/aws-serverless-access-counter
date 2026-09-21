#requires -Version 7.3
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Tools([string[]] $Names) {
    foreach ($name in $Names) {
        if (-not (Get-Command $name -CommandType Application -ErrorAction SilentlyContinue)) {
            throw "Instale '$name' e adicione-o ao PATH."
        }
    }
}

function Invoke-Native([string] $Command, [string[]] $Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command falhou (exit code $LASTEXITCODE)." }
}

function Assert-AwsAccount([string] $Expected) {
    $identity = Invoke-Native aws @('sts', 'get-caller-identity', '--output', 'json', '--no-cli-pager')
    $account = ($identity | ConvertFrom-Json).Account
    if ($account -cne $Expected) { throw 'Conta autenticada diferente de AWS_ACCOUNT_ID. Operacao abortada.' }
    Write-Host "AWS Account: $account"
}

function Invoke-CounterOperation([ValidateSet('deploy', 'destroy')] [string] $Operation) {
    $root = Split-Path $PSScriptRoot -Parent
    $sensitive = @('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN', 'AWS_SECURITY_TOKEN')
    $saved = @{}
    $plain = $null
    $secrets = $null
    $plan = Join-Path $root 'terraform/tfplan'
    $locationPushed = $false
    try {
        # Isola configuracoes herdadas que poderiam alterar o destino ou registrar secrets.
        $names = @((Get-ChildItem Env: | Where-Object {
            $_.Name -match '^(AWS_|TF_VAR_|TF_CLI_ARGS|TF_LOG|TF_WORKSPACE$|TF_DATA_DIR$)'
        } | ForEach-Object { $_.Name })) + @('AWS_REGION', 'AWS_DEFAULT_REGION', 'AWS_CONFIG_FILE', 'AWS_SHARED_CREDENTIALS_FILE',
            'AWS_EC2_METADATA_DISABLED', 'AWS_PAGER', 'TF_VAR_aws_region', 'TF_VAR_allowed_account_ids')
        foreach ($name in ($names | Select-Object -Unique)) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
        $required = @('sops', 'age', 'terraform', 'aws')
        if ($Operation -eq 'deploy') { $required += 'go' }
        Assert-Tools $required
        $file = Join-Path $root 'config/aws.secrets.enc.json'
        if (-not (Test-Path $file)) { throw 'Crie config/aws.secrets.enc.json conforme o README.' }
        # Nao propaga mensagens de parsing que possam conter trechos do JSON secreto.
        $plain = & sops --decrypt --output-type json $file 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Falha ao descriptografar secrets. Confira SOPS_AGE_KEY_FILE e o destinatario age.' }
        try { $secrets = ($plain -join "`n") | ConvertFrom-Json -AsHashtable }
        catch { throw 'O secrets descriptografado nao e um JSON valido.' }
        $plain = $null
        if ($secrets -isnot [System.Collections.IDictionary]) {
            $secrets = $null
            throw 'O secrets deve ser um objeto JSON.'
        }
        foreach ($key in @('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_REGION', 'AWS_ACCOUNT_ID')) {
            if ($secrets[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($secrets[$key])) {
                throw "Campo obrigatorio ausente ou invalido: $key."
            }
        }
        if ($secrets.AWS_ACCOUNT_ID -notmatch '^\d{12}$') { throw 'AWS_ACCOUNT_ID deve conter 12 digitos.' }
        if ($secrets.AWS_REGION -notmatch '^[a-z]{2}(-[a-z]+)+-\d+$') { throw 'AWS_REGION invalida.' }
        $env:AWS_ACCESS_KEY_ID = $secrets.AWS_ACCESS_KEY_ID
        $env:AWS_SECRET_ACCESS_KEY = $secrets.AWS_SECRET_ACCESS_KEY
        if ($secrets.ContainsKey('AWS_SESSION_TOKEN') -and $secrets.AWS_SESSION_TOKEN) {
            if ($secrets.AWS_SESSION_TOKEN -isnot [string]) { throw 'AWS_SESSION_TOKEN invalido.' }
            $env:AWS_SESSION_TOKEN = $secrets.AWS_SESSION_TOKEN
        }
        $account = $secrets.AWS_ACCOUNT_ID
        $region = $secrets.AWS_REGION
        $secrets.Clear()
        $env:AWS_REGION = $region
        $env:AWS_DEFAULT_REGION = $region
        $env:AWS_CONFIG_FILE = if ($IsWindows) { 'NUL' } else { '/dev/null' }
        $env:AWS_SHARED_CREDENTIALS_FILE = $env:AWS_CONFIG_FILE
        $env:AWS_EC2_METADATA_DISABLED = 'true'
        $env:AWS_PAGER = ''
        $env:TF_VAR_aws_region = $region
        $env:TF_VAR_allowed_account_ids = ConvertTo-Json -InputObject @($account) -Compress
        Assert-AwsAccount $account
        Write-Host "AWS Region: $region"
        Write-Host 'Environment: lab'
        Push-Location (Join-Path $root 'terraform')
        $locationPushed = $true
        if ($Operation -eq 'deploy') { & (Join-Path $PSScriptRoot 'build.ps1') }
        Invoke-Native terraform @('init', '-input=false')
        Invoke-Native terraform @('fmt', '-check', '-recursive')
        Invoke-Native terraform @('validate')
        $workspace = Invoke-Native terraform @('workspace', 'show')
        if ($workspace -ne 'default') { throw 'Use o workspace default deste laboratorio.' }
        # A conta e a regiao validadas tem precedencia sobre configuracoes locais.
        $vars = @('-var', "aws_region=$region", '-var', "allowed_account_ids=$env:TF_VAR_allowed_account_ids")
        $outputs = (Invoke-Native terraform @('output', '-json') | ConvertFrom-Json -AsHashtable)
        foreach ($check in @(@('aws_account_id', $account), @('aws_region', $region))) {
            if ($outputs.ContainsKey($check[0]) -and $outputs[$check[0]].value -ne $check[1]) {
                throw "O state pertence a outro $($check[0]). Use os secrets originais."
            }
        }
        if ($Operation -eq 'deploy') {
            Invoke-Native terraform (@('plan', '-input=false', '-out=tfplan') + $vars)
            if ((Read-Host 'Aplicar este plano? Digite sim') -cne 'sim') { throw 'Apply cancelado.' }
            Assert-AwsAccount $account
            Invoke-Native terraform @('apply', '-input=false', 'tfplan')
            foreach ($item in @(@('URL da API (POST)', 'hit_url'), @('Lambda', 'lambda_function_name'), @('Tabela DynamoDB', 'dynamodb_table_name'))) {
                $value = Invoke-Native terraform @('output', '-raw', $item[1])
                Write-Host "$($item[0]): $value"
            }
            Write-Host "AWS Region: $region"
            Write-Host "AWS Account: $account"
        } else {
            Assert-AwsAccount $account
            # O destroy exibe seu plano e pede a confirmacao padrao do Terraform.
            Invoke-Native terraform (@('destroy') + $vars)
        }
    } finally {
        $plain = $null
        if ($null -ne $secrets) { $secrets.Clear() }
        foreach ($name in $sensitive) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
        foreach ($name in $saved.Keys) {
            if ($name -notin $sensitive) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        }
        $saved.Clear()
        if ($locationPushed) { Pop-Location }
        if (Test-Path $plan) { Remove-Item $plan -Force }
    }
}
