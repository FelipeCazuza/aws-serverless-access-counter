#requires -Version 7.3
. "$PSScriptRoot/common.ps1"
Assert-Tools @('sops', 'age')
Push-Location (Split-Path $PSScriptRoot -Parent)
$values = @{}
$json = $null
try {
    if (-not (Test-Path '.sops.yaml')) { throw 'Copie .sops.yaml.example e configure sua chave publica age.' }
    $values.AWS_ACCESS_KEY_ID = Read-Host 'AWS Access Key ID' -MaskInput
    $values.AWS_SECRET_ACCESS_KEY = Read-Host 'AWS Secret Access Key' -MaskInput
    $values.AWS_SESSION_TOKEN = Read-Host 'AWS Session Token (Enter se nao houver)' -MaskInput
    $values.AWS_REGION = Read-Host 'AWS Region (ex.: us-east-1)'
    $values.AWS_ACCOUNT_ID = Read-Host 'AWS Account ID (12 digitos)'
    if ([string]::IsNullOrWhiteSpace($values.AWS_ACCESS_KEY_ID) -or [string]::IsNullOrWhiteSpace($values.AWS_SECRET_ACCESS_KEY)) {
        throw 'Access Key e Secret Key sao obrigatorias.'
    }
    if ($values.AWS_ACCOUNT_ID -notmatch '^\d{12}$' -or $values.AWS_REGION -notmatch '^[a-z]{2}(-[a-z]+)+-\d+$') {
        throw 'Conta ou regiao invalida.'
    }
    $json = $values | ConvertTo-Json -Compress
    # stdin evita arquivos em texto claro e argumentos com secrets no historico.
    $encrypted = $json | & sops --config .sops.yaml encrypt --filename-override config/aws.secrets.enc.json --input-type json --output-type json 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao criptografar. Confira a versao do SOPS e a chave publica.' }
    $document = ($encrypted -join "`n") | ConvertFrom-Json -AsHashtable
    if (-not $document.ContainsKey('sops') -or -not $document.AWS_SECRET_ACCESS_KEY.StartsWith('ENC[')) {
        throw 'SOPS nao produziu um documento criptografado valido.'
    }
    $encrypted | Set-Content 'config/aws.secrets.enc.json' -Encoding utf8
    Write-Host 'Criado config/aws.secrets.enc.json. Somente o documento criptografado foi salvo.'
} finally {
    $json = $null
    $values.Clear()
    Pop-Location
}
