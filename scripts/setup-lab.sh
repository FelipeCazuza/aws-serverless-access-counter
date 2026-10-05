#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# aws-serverless-access-counter
# Setup completo para Ubuntu / WSL
# ============================================================

GO_SERIES="1.26"
SOPS_VERSION="3.13.3"
POWERSHELL_VERSION="7.6.6"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AGE_DIR="$HOME/.config/sops/age"
AGE_KEY_FILE="$AGE_DIR/keys.txt"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info() {
    echo -e "\n${CYAN}==>${NC} $1"
}

ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
}

fail() {
    echo -e "${RED}[ERRO]${NC} $1"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ============================================================
# Validar Ubuntu
# ============================================================

info "Validando sistema"

source /etc/os-release

if [[ "$ID" != "ubuntu" ]]; then
    fail "Este script suporta Ubuntu/WSL."
fi

ok "Ubuntu $VERSION_ID"

ARCH="$(uname -m)"

case "$ARCH" in
    x86_64)
        GO_ARCH="amd64"
        AWS_ARCH="x86_64"
        SOPS_ARCH="amd64"
        PWSH_ARCH="x64"
        ;;
    aarch64|arm64)
        GO_ARCH="arm64"
        AWS_ARCH="aarch64"
        SOPS_ARCH="arm64"
        PWSH_ARCH="arm64"
        ;;
    *)
        fail "Arquitetura não suportada: $ARCH"
        ;;
esac

# ============================================================
# Dependências básicas
# ============================================================

info "Instalando pacotes básicos"

sudo apt update

sudo apt install -y \
    curl \
    wget \
    unzip \
    tar \
    git \
    jq \
    gnupg \
    ca-certificates \
    lsb-release \
    libicu-dev \
    libunwind8 \
    zlib1g \
    age

ok "Pacotes básicos instalados"

# ============================================================
# Go
# ============================================================

info "Configurando Go"

INSTALL_GO=true

if command_exists go; then
    GO_CURRENT="$(go version | sed -E 's/.*go([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')"

    if [[ "$GO_CURRENT" == "$GO_SERIES"* ]]; then
        ok "Go $GO_CURRENT já instalado"
        INSTALL_GO=false
    fi
fi

if [[ "$INSTALL_GO" == true ]]; then

    GO_JSON="$(curl -fsSL 'https://go.dev/dl/?mode=json')"

    GO_VERSION="$(
        echo "$GO_JSON" |
        jq -r \
        --arg prefix "go${GO_SERIES}." \
        '[.[] | select(.stable == true) | select(.version | startswith($prefix))][0].version'
    )"

    [[ -n "$GO_VERSION" && "$GO_VERSION" != "null" ]] ||
        fail "Não encontrei Go ${GO_SERIES}.x."

    GO_FILE="${GO_VERSION}.linux-${GO_ARCH}.tar.gz"

    info "Instalando $GO_VERSION"

    cd /tmp

    curl -fsSLO \
        "https://go.dev/dl/${GO_FILE}"

    sudo rm -rf /usr/local/go

    sudo tar \
        -C /usr/local \
        -xzf "$GO_FILE"

    rm -f "$GO_FILE"

    if ! grep -q '/usr/local/go/bin' "$HOME/.bashrc"; then
        echo 'export PATH="/usr/local/go/bin:$PATH"' >> "$HOME/.bashrc"
    fi

    export PATH="/usr/local/go/bin:$PATH"

    ok "$(go version)"
fi

# ============================================================
# Terraform
# ============================================================

info "Configurando Terraform"

if ! command_exists terraform; then

    curl -fsSL \
        https://apt.releases.hashicorp.com/gpg |
        sudo gpg \
            --dearmor \
            --yes \
            -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

    echo \
        "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" |
        sudo tee \
        /etc/apt/sources.list.d/hashicorp.list \
        >/dev/null

    sudo apt update
    sudo apt install -y terraform
fi

ok "$(terraform version | head -1)"

# ============================================================
# AWS CLI v2
# ============================================================

info "Configurando AWS CLI v2"

if ! command_exists aws ||
   ! aws --version 2>&1 | grep -q 'aws-cli/2'; then

    TMP_AWS="$(mktemp -d)"

    curl -fsSL \
        "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" \
        -o "$TMP_AWS/awscliv2.zip"

    unzip -q \
        "$TMP_AWS/awscliv2.zip" \
        -d "$TMP_AWS"

    if command_exists aws; then
        sudo "$TMP_AWS/aws/install" --update
    else
        sudo "$TMP_AWS/aws/install"
    fi

    rm -rf "$TMP_AWS"
fi

ok "$(aws --version 2>&1)"

# ============================================================
# PowerShell
# ============================================================

info "Configurando PowerShell"

if ! command_exists pwsh; then

    TMP_PWSH="$(mktemp -d)"

    PWSH_FILE="powershell-${POWERSHELL_VERSION}-linux-${PWSH_ARCH}.tar.gz"

    curl -fsSL \
        "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/${PWSH_FILE}" \
        -o "$TMP_PWSH/$PWSH_FILE"

    sudo mkdir -p \
        "/opt/microsoft/powershell/${POWERSHELL_VERSION}"

    sudo tar \
        -xzf "$TMP_PWSH/$PWSH_FILE" \
        -C "/opt/microsoft/powershell/${POWERSHELL_VERSION}"

    sudo chmod +x \
        "/opt/microsoft/powershell/${POWERSHELL_VERSION}/pwsh"

    sudo ln -sf \
        "/opt/microsoft/powershell/${POWERSHELL_VERSION}/pwsh" \
        /usr/local/bin/pwsh

    rm -rf "$TMP_PWSH"
fi

ok "$(pwsh --version)"

# ============================================================
# SOPS
# ============================================================

info "Configurando SOPS"

if ! command_exists sops; then

    TMP_SOPS="$(mktemp -d)"

    SOPS_FILE="sops-v${SOPS_VERSION}.linux.${SOPS_ARCH}"
    SOPS_URL="https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}"

    curl -fsSL \
        "$SOPS_URL/$SOPS_FILE" \
        -o "$TMP_SOPS/$SOPS_FILE"

    curl -fsSL \
        "$SOPS_URL/sops-v${SOPS_VERSION}.checksums.txt" \
        -o "$TMP_SOPS/checksums.txt"

    info "Validando checksum do SOPS"

    EXPECTED="$(
        grep " ${SOPS_FILE}$" "$TMP_SOPS/checksums.txt" |
        awk '{print $1}'
    )"

    [[ -n "$EXPECTED" ]] ||
        fail "Checksum oficial do SOPS não encontrado."

    ACTUAL="$(
        sha256sum "$TMP_SOPS/$SOPS_FILE" |
        awk '{print $1}'
    )"

    if [[ "$EXPECTED" != "$ACTUAL" ]]; then
        fail "Checksum do SOPS inválido."
    fi

    ok "Checksum do SOPS válido"

    sudo install \
        -m 0755 \
        "$TMP_SOPS/$SOPS_FILE" \
        /usr/local/bin/sops

    rm -rf "$TMP_SOPS"
fi

ok "$(sops --version | head -1)"

# ============================================================
# age / age-keygen
# ============================================================

info "Validando age"

command_exists age ||
    fail "age não foi encontrado."

command_exists age-keygen ||
    fail "age-keygen não foi encontrado."

ok "$(age --version)"

# ============================================================
# Criar chave age
# ============================================================

info "Configurando chave age"

mkdir -p "$AGE_DIR"

if [[ ! -f "$AGE_KEY_FILE" ]]; then

    age-keygen \
        -o "$AGE_KEY_FILE"

    chmod 600 "$AGE_KEY_FILE"

    ok "Nova chave age criada"

else

    warn "Chave age já existe. Ela será preservada."

fi

# Validar a chave
if ! AGE_PUBLIC_KEY="$(age-keygen -y "$AGE_KEY_FILE" 2>/dev/null)"; then
    fail "A chave existente em $AGE_KEY_FILE é inválida."
fi

# ============================================================
# SOPS_AGE_KEY_FILE
# ============================================================

export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"

if ! grep -q 'SOPS_AGE_KEY_FILE=' "$HOME/.bashrc"; then

    echo \
        'export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"' \
        >> "$HOME/.bashrc"

fi

ok "SOPS_AGE_KEY_FILE configurado"

# ============================================================
# .sops.yaml
# ============================================================

info "Configurando .sops.yaml"

cd "$PROJECT_ROOT"

if [[ ! -f .sops.yaml ]]; then

    if [[ -f .sops.yaml.example ]]; then
        cp .sops.yaml.example .sops.yaml
    else
        fail ".sops.yaml.example não encontrado."
    fi

fi

# Substitui marcador esperado
if grep -q \
    'COLE_AQUI_SOMENTE_A_CHAVE_PUBLICA_AGE' \
    .sops.yaml; then

    sed -i \
        "s|COLE_AQUI_SOMENTE_A_CHAVE_PUBLICA_AGE|$AGE_PUBLIC_KEY|" \
        .sops.yaml

    ok ".sops.yaml configurado"

elif grep -qF "$AGE_PUBLIC_KEY" .sops.yaml; then

    ok ".sops.yaml já está usando esta chave"

else

    warn ".sops.yaml já possui outra configuração."
    warn "Não alterei o arquivo automaticamente."

fi

# ============================================================
# Resultado
# ============================================================

echo
echo "============================================================"
echo " AMBIENTE CONFIGURADO"
echo "============================================================"
echo

echo "Go:"
go version

echo
echo "PowerShell:"
pwsh --version

echo
echo "Terraform:"
terraform version | head -1

echo
echo "AWS CLI:"
aws --version

echo
echo "SOPS:"
sops --version | head -1

echo
echo "age:"
age --version

echo
echo "Chave pública age:"
echo "$AGE_PUBLIC_KEY"

echo
echo "Chave privada armazenada em:"
echo "$AGE_KEY_FILE"

echo
echo "============================================================"
echo " Próximo passo:"
echo
echo " pwsh ./scripts/secrets.ps1"
echo
echo " Depois:"
echo
echo " pwsh ./scripts/deploy.ps1"
echo "============================================================"
