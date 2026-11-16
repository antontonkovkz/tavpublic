#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_AI_PUBKEY="${DEFAULT_AI_PUBKEY:-/root/.ssh/ai_chisel_ed25519.pub}"
CLIENT_SCRIPT_URL="${CLIENT_SCRIPT_URL:-https://raw.githubusercontent.com/REPLACE_ME/agent-remote/main/scripts/install_ubuntu_client.sh}"

CLIENT_OS="linux"
SERVER_HOST=""
SERVER_PORT=""
AUTH=""
FINGERPRINT=""
REVERSE_PORT=""
SSH_USER=""
SSH_PUBLIC_KEY=""
SSH_PUBLIC_KEY_FILE=""
LOCAL_SCRIPT_PATH="${REPO_ROOT}/scripts/install_ubuntu_client.sh"

usage() {
  cat <<EOF
Usage:
  $0 --server-host <host> --server-port <port> --auth <user:pass> --fingerprint <fp> --reverse-port <port> --ssh-user <user> [--ssh-public-key-file <path>] [--client-script-url <url>]

Examples:
  $0 --server-host ai.example.com --server-port 9312 --auth 'ai:secret' --fingerprint 'fp' --reverse-port 2201 --ssh-user ubuntu
  $0 --server-host 203.0.113.10 --server-port 9312 --auth 'ai:secret' --fingerprint 'fp' --reverse-port 2202 --ssh-user root --client-script-url 'https://example.com/install_ubuntu_client.sh'
EOF
}

shell_escape() {
  printf "%q" "$1"
}

read_public_key() {
  local path
  if [[ -n "$SSH_PUBLIC_KEY_FILE" ]]; then
    path="$SSH_PUBLIC_KEY_FILE"
  else
    path="$DEFAULT_AI_PUBKEY"
  fi

  if [[ ! -f "$path" ]]; then
    echo "Public key file not found: $path"
    exit 1
  fi
  SSH_PUBLIC_KEY="$(tr -d '\n' < "$path")"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --os)
        CLIENT_OS="$2"
        shift 2
        ;;
      --server-host)
        SERVER_HOST="$2"
        shift 2
        ;;
      --server-port)
        SERVER_PORT="$2"
        shift 2
        ;;
      --auth)
        AUTH="$2"
        shift 2
        ;;
      --fingerprint)
        FINGERPRINT="$2"
        shift 2
        ;;
      --reverse-port)
        REVERSE_PORT="$2"
        shift 2
        ;;
      --ssh-user)
        SSH_USER="$2"
        shift 2
        ;;
      --ssh-public-key-file)
        SSH_PUBLIC_KEY_FILE="$2"
        shift 2
        ;;
      --client-script-url)
        CLIENT_SCRIPT_URL="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ -z "$SERVER_HOST" || -z "$SERVER_PORT" || -z "$AUTH" || -z "$FINGERPRINT" || -z "$REVERSE_PORT" || -z "$SSH_USER" ]]; then
    usage
    exit 1
  fi
}

main() {
  parse_args "$@"
  read_public_key

  [[ "$CLIENT_OS" == linux || "$CLIENT_OS" == windows ]] || { echo "Invalid OS" >&2; exit 1; }
  if [[ "$CLIENT_OS" == windows ]]; then
    ps_quote() { local value="${1//\'/\'\'}"; printf "'%s'" "$value"; }
    printf 'Run in elevated PowerShell from the repository root:\n& .\\scripts\\install_windows_client.ps1'
    local pair
    local args=(ServerHost "$SERVER_HOST" ServerPort "$SERVER_PORT" Auth "$AUTH" Fingerprint "$FINGERPRINT" ReversePort "$REVERSE_PORT" SshUser "$SSH_USER" SshPublicKey "$SSH_PUBLIC_KEY")
    for ((pair=0; pair<${#args[@]}; pair+=2)); do
      printf ' -%s ' "${args[pair]}"; ps_quote "${args[pair+1]}"
    done
    printf '\n'
    return
  fi

  local curl_cmd local_cmd
  curl_cmd="curl -fsSL $(shell_escape "$CLIENT_SCRIPT_URL") | sudo bash -s -- --server-host $(shell_escape "$SERVER_HOST") --server-port $(shell_escape "$SERVER_PORT") --auth $(shell_escape "$AUTH") --fingerprint $(shell_escape "$FINGERPRINT") --reverse-port $(shell_escape "$REVERSE_PORT") --ssh-user $(shell_escape "$SSH_USER") --ssh-public-key $(shell_escape "$SSH_PUBLIC_KEY")"
  local_cmd="sudo bash $(shell_escape "$LOCAL_SCRIPT_PATH") --server-host $(shell_escape "$SERVER_HOST") --server-port $(shell_escape "$SERVER_PORT") --auth $(shell_escape "$AUTH") --fingerprint $(shell_escape "$FINGERPRINT") --reverse-port $(shell_escape "$REVERSE_PORT") --ssh-user $(shell_escape "$SSH_USER") --ssh-public-key $(shell_escape "$SSH_PUBLIC_KEY")"

  cat <<EOF
Public key source: ${SSH_PUBLIC_KEY_FILE:-$DEFAULT_AI_PUBKEY}

Local command:
${local_cmd}

Remote one-liner:
${curl_cmd}
EOF
}

main "$@"
