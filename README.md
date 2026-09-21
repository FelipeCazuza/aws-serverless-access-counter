# AWS Serverless Access Counter

Laboratório AWS provisionado inteiramente por Terraform. Cada `POST /hit` incrementa um contador global no DynamoDB e retorna `{"hits": N}`.

```text
Internet -> API Gateway HTTP API (POST /hit)
         -> Lambda (Go / ARM64 / provided.al2023)
         -> DynamoDB (PAY_PER_REQUEST)

Lambda -> CloudWatch Logs
```

A Lambda usa 128 MB, timeout de 5 segundos e uma role restrita a `dynamodb:UpdateItem` na tabela do projeto e `logs:CreateLogStream`/`logs:PutLogEvents` no Log Group. O Terraform cria esse grupo com retenção de 1 dia e o remove no destroy.

O incremento é atômico: `ADD hits :increment`, com `UPDATED_NEW`. Não há leitura prévia. O item `id = hits` é criado na primeira chamada; repetir a requisição incrementa novamente. A API é pública e o uso dos serviços pode gerar custos. Destrua o laboratório após a apresentação.

## Pré-requisitos

Abra um terminal **PowerShell 7** (`pwsh`) na raiz do projeto. Instale e coloque no PATH:

- [Go](https://go.dev/doc/install) **1.26+**, usando o patch mais recente da versão suportada.
- [PowerShell](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) **7.3+** tecnicamente; para instalação use uma versão com suporte, como 7.4 LTS ou superior.
- [Terraform](https://developer.hashicorp.com/terraform/install) **1.5+**.
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html).
- [SOPS](https://getsops.io/docs/installation/) **3.13.3+**: baixe o binário oficial para seu sistema/arquitetura e verifique o checksum publicado.
- [age](https://github.com/FiloSottile/age#installation), incluindo `age-keygen`. No Windows: `winget install --id FiloSottile.age --exact`.

Confira:

```powershell
Get-Command sops, age, age-keygen, go, terraform, aws
```

A identidade AWS usada precisa poder criar/remover os recursos descritos em `terraform/` e passar a role à Lambda (`iam:PassRole`). Não use credenciais de root.

**Por que essas versões?** `aws-lambda-go v1.55.0` declara Go 1.26; os módulos fixados do AWS SDK v2 declaram Go 1.24. O código do contador não usa um recurso exclusivo de Go 1.26, mas sua dependência exige essa versão. Mantemos a dependência atual: versões Go anteriores a 1.26 estão fora do suporte em setembro de 2026. Veja o [go.mod da biblioteca](https://github.com/aws/aws-lambda-go/blob/v1.55.0/go.mod) e a [política de suporte Go](https://go.dev/doc/devel/release).

PowerShell 7.3 é o mínimo para o [tratamento de aspas em argumentos de programas nativos](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_parsing#passing-arguments-to-native-commands), usado para passar a lista JSON de contas ao Terraform no Windows. `Read-Host -MaskInput` exige 7.1. Nenhum recurso usado exige especificamente 7.4, mas 7.3 já encerrou suporte: consulte o [ciclo de vida](https://learn.microsoft.com/lifecycle/products/powershell). Windows PowerShell 5.1 não é suportado.

## Primeira configuração: age e SOPS

Gere a chave privada **fora do repositório**, uma única vez:

```powershell
$keyDir = Join-Path $HOME '.config/sops/age'
New-Item -ItemType Directory -Force $keyDir | Out-Null
$keyFile = Join-Path $keyDir 'keys.txt'
age-keygen -o $keyFile
if ($LASTEXITCODE -ne 0) { throw 'Falha ao gerar chave. Nao sobrescreva uma chave existente.' }
$env:SOPS_AGE_KEY_FILE = $keyFile
age-keygen -y $keyFile
Copy-Item .sops.yaml.example .sops.yaml
```

Substitua o marcador de `.sops.yaml` pela **chave pública** mostrada por `age-keygen -y`. Não coloque a linha privada `AGE-SECRET-KEY-...` nesse arquivo. Mantenha `keys.txt` acessível apenas ao seu usuário e faça backup protegido. Em Linux/macOS, use `chmod 600` no arquivo; no Windows, restrinja o acesso nas propriedades de Segurança.

Em cada novo terminal, indique a chave:

```powershell
$env:SOPS_AGE_KEY_FILE = Join-Path $HOME '.config/sops/age/keys.txt'
```

Você pode adicionar essa linha à configuração pessoal do seu terminal. Apenas o caminho é configuração; não copie a chave privada para scripts.

## Criar os secrets

```powershell
.\scripts\secrets.ps1
```

Informe Access Key, Secret Key, token de sessão (Enter se não houver), região e Account ID. O formato está em `config/aws.secrets.example.json`; não edite o exemplo com credenciais reais.

`secrets.ps1` tem uma única responsabilidade: coletar os valores com credenciais mascaradas, criptografar por stdin e salvar `config/aws.secrets.enc.json`. Não cria arquivo em texto claro. Execute-o novamente para renovar credenciais temporárias, mantendo conta e região até destruir o laboratório.

Não fornecemos `.sops.yaml` real nem arquivo criptografado inicial, pois dependem da chave pública do integrante.

```text
SOPS encrypted secrets
        |
        v
deploy.ps1 / destroy.ps1
        |
        v
AWS credentials em memória
        |
        v
Terraform -> AWS
```

## Deploy → teste → destroy

Depois da configuração inicial:

```powershell
.\scripts\deploy.ps1
.\scripts\test.ps1
.\scripts\destroy.ps1
```

**Deploy:** verifica ferramentas, descriptografa em memória e compara STS com `AWS_ACCOUNT_ID`. Configura as credenciais no ambiente e as variáveis Terraform de conta/região. Compila `bootstrap` Linux ARM64; o provider `archive` gera o único ZIP, com permissão executável. Executa `init`, `fmt -check`, `validate` e `plan`. Confira o plano e digite `sim`; STS é verificado novamente antes do apply. No final, mostra URL `/hit`, Lambda, tabela, conta e região.

**Teste:** lê `hit_url` do state local, faz um `POST /hit` e mostra a resposta. Cada execução incrementa o contador. Não pede secrets nem URL manualmente.

**Destroy:** mostra conta, região e ambiente `lab`, valida STS e executa Terraform com confirmação. Confira o plano e digite `yes`. Remove também a tabela e seus dados, Log Group, API e IAM. Não precisa recompilar nem ter Go instalado.

Os scripts abortam em caso de conta divergente, falhas dos comandos ou conta/região diferente da registrada no state. Credenciais são removidas do processo e o plano temporário é apagado em `finally`. Use uma sessão dedicada; credenciais anteriormente presentes não são restauradas. Encerramento forçado não garante execução de `finally`, nem apagar referências garante apagamento físico da memória.

**Guarde o state local até destruir os recursos.** Use um operador por vez e mantenha o workspace `default`. Para continuar um deploy existente em outra máquina, transfira o state por canal protegido. Clonar apenas o código não recupera o controle dos recursos já criados. Para trocar de conta, primeiro destrua usando os secrets originais.

## Segurança e reprodução

- **Arquivo criptografado + chave privada no mesmo GitHub = inseguro.** Se uma credencial vazar, revogue-a; apagar o último arquivo não elimina o histórico.
- Versione o arquivo criptografado, `.sops.yaml` contendo somente chave pública, os exemplos sem secrets, `go.mod`, `go.sum` e `.terraform.lock.hcl`.
- Não versione chave privada, secrets descriptografados, state, planos ou binários. `.gitignore` protege os caminhos usuais, mas não reconhece credenciais coladas em qualquer arquivo nem remove arquivos já rastreados. Revise o diff.
- Não redirecione `sops decrypt` para disco nem registre dumps de ambiente ou transcrições com secrets. As credenciais chegam ao provider apenas pelo ambiente; não entram no state nem na configuração da Lambda.
- Outro integrante pode gerar sua própria chave e criar seu arquivo criptografado para reproduzir o laboratório. Não compartilhe chaves privadas pelo Git.

## Validação para manutenção

Estes comandos são locais e não criam recursos AWS:

```powershell
.\tests\scripts.tests.ps1
Push-Location lambda
try { go test ./... } finally { Pop-Location }
.\scripts\build.ps1
terraform -chdir=terraform init -backend=false -input=false
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
```

Os testes Go substituem apenas `UpdateItem`. Os testes PowerShell simulam SOPS, STS, Terraform e HTTP para cobrir falhas, validação de secrets, conta/região, token de sessão e limpeza do ambiente. `scripts/test.ps1` é o teste da API implantada; não o confunda com essa suíte local.
