#!/usr/bin/env bash
set -euo pipefail

# Uso:
#   ./bootstrap_repo_deploykey.sh "HFT2" "git@github.com:JohnHeberty/HFT2.git"
#   ./bootstrap_repo_deploykey.sh "HFT2" "https://github.com/JohnHeberty/HFT2"

PROJECT_NAME="${1:-}"
REPO_INPUT="${2:-}"

if [[ -z "$PROJECT_NAME" || -z "$REPO_INPUT" ]]; then
  echo "Uso: $0 <nome_projeto> <repo_url_ssh_ou_https>"
  exit 1
fi

# Normaliza URL (aceita SSH ou HTTPS GitHub)
REPO_SSH="$REPO_INPUT"
if [[ "$REPO_INPUT" =~ ^https?://github\.com/([^/]+)/([^/]+)(\.git)?/?$ ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
  REPO="${REPO%.git}"
  REPO_SSH="git@github.com:${OWNER}/${REPO}.git"
fi

if [[ ! "$REPO_SSH" =~ ^git@github\.com:.+/.+\.git$ ]]; then
  echo "Repo inválido. Use SSH (git@github.com:owner/repo.git) ou HTTPS (https://github.com/owner/repo)."
  echo "Recebido: $REPO_INPUT"
  exit 1
fi

command -v git >/dev/null || { echo "git não encontrado"; exit 1; }
command -v ssh-keygen >/dev/null || { echo "ssh-keygen não encontrado"; exit 1; }

# Pasta do projeto
if [[ -e "$PROJECT_NAME" ]]; then
  echo "❌ Pasta '$PROJECT_NAME' já existe. Escolha outro nome ou remova a pasta."
  exit 1
fi

mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

git init -q
git remote add origin "$REPO_SSH"

SSH_DIR="${HOME}/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

TS="$(date +%Y%m%d_%H%M%S)" # timestamp com segundos
SAFE_PROJECT="$(echo "$PROJECT_NAME" | tr -cs 'a-zA-Z0-9._-' '_' | tr '[:upper:]' '[:lower:]')"

BASE_KEY_PATH="${SSH_DIR}/deploy_${SAFE_PROJECT}_${TS}"
KEY_PATH="$BASE_KEY_PATH"
i=2
while [[ -e "$KEY_PATH" || -e "${KEY_PATH}.pub" ]]; do
  KEY_PATH="${BASE_KEY_PATH}_${i}"
  i=$((i+1))
done

KEY_COMMENT="$(basename "$KEY_PATH")"

umask 077
ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "$KEY_COMMENT" >/dev/null

chmod 600 "$KEY_PATH"
chmod 644 "${KEY_PATH}.pub"

git config core.sshCommand "ssh -i ${KEY_PATH} -o IdentitiesOnly=yes -F /dev/null"

echo "$KEY_PATH" > .deploy_key_path
chmod 600 .deploy_key_path

echo
echo "✅ Deploy key criada:"
echo "   Privada: ${KEY_PATH}"
echo "   Pública: ${KEY_PATH}.pub"
echo
echo "👉 Cole a chave pública abaixo no GitHub:"
echo "   Repo → Settings → Deploy keys → Add deploy key"
echo "   (marque 'Allow write access' se precisar fazer push)"
echo
echo "----- BEGIN PUBLIC KEY -----"
cat "${KEY_PATH}.pub"
echo "----- END PUBLIC KEY -----"
echo

read -r -p "Quando adicionar a deploy key no GitHub, aperte ENTER para continuar... "

echo
echo "🔎 Testando SSH com a deploy key..."
ssh -i "${KEY_PATH}" -o IdentitiesOnly=yes -T git@github.com || true
echo

echo "⬇️  Fazendo fetch do origin..."
git fetch --prune origin

DEFAULT_BRANCH="$(git ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/ {print $2}' | sed 's@refs/heads/@@' || true)"

if [[ -z "${DEFAULT_BRANCH:-}" ]]; then
  if git show-ref --verify --quiet "refs/remotes/origin/main"; then
    DEFAULT_BRANCH="main"
  elif git show-ref --verify --quiet "refs/remotes/origin/master"; then
    DEFAULT_BRANCH="master"
  else
    echo "⚠️  Não encontrei 'main' nem 'master' em origin. O repositório pode estar vazio."
    echo "   Rode: git branch -r"
    exit 0
  fi
fi

echo "✅ Branch detectada: ${DEFAULT_BRANCH}"

git checkout -B "${DEFAULT_BRANCH}" --track "origin/${DEFAULT_BRANCH}" 2>/dev/null \
  || git checkout -B "${DEFAULT_BRANCH}"

echo "⬇️  Pull (ff-only) da branch ${DEFAULT_BRANCH}..."
git pull --ff-only origin "${DEFAULT_BRANCH}"

echo
echo "✅ Pronto!"
echo "📁 Projeto em: $(pwd)"
echo "🔑 Key path salvo em: $(pwd)/.deploy_key_path"
