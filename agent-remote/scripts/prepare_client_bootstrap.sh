#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INVENTORY_FILE="${INVENTORY_FILE:-${REPO_ROOT}/inventory/clients.tsv}"
CHISEL_BIN="${CHISEL_BIN:-/usr/local/bin/chisel}"
CHISEL_USERS_FILE="${CHISEL_USERS_FILE:-/etc/chisel/users.json}"
CHISEL_KEYFILE="${CHISEL_KEYFILE:-/etc/chisel/server_key.pem}"
CHISEL_SERVICE_FILE="${CHISEL_SERVICE_FILE:-/etc/systemd/system/chisel-server.service}"
DEFAULT_AI_PUBKEY="${DEFAULT_AI_PUBKEY:-/root/.ssh/ai_chisel_ed25519.pub}"
PORT_START="${PORT_START:-2200}"
PORT_END="${PORT_END:-2299}"

CLIENT_OS="linux"
CLIENT_NAME=""
SSH_USER=""
SERVER_HOST=""
SERVER_PORT=""
AUTH=""
FINGERPRINT=""
TAGS=""
DESCRIPTION=""
CLIENT_SCRIPT_URL=""
SSH_PUBLIC_KEY_FILE=""

usage() {
  cat <<EOF
Usage:
  $0 --client-name <name> --ssh-user <user> --server-host <host> [options]

Options:
  --os <linux|windows>
  --server-port <port>
  --auth <user:pass>
  --fingerprint <fp>
  --tags <tags>
  --description <description>
  --port-start <port>
  --port-end <port>
  --ssh-public-key-file <path>
  --client-script-url <url>

Examples:
  $0 --client-name client-1 --ssh-user ubuntu --server-host ai.example.com
  $0 --client-name client-2 --ssh-user root --server-host 203.0.113.10 --tags prod --description "Second lab node"
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --os)
        CLIENT_OS="$2"
        shift 2
        ;;
      --client-name)
        CLIENT_NAME="$2"
        shift 2
        ;;
      --ssh-user)
        SSH_USER="$2"
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
      --tags)
        TAGS="$2"
        shift 2
        ;;
      --description)
        DESCRIPTION="$2"
        shift 2
        ;;
      --port-start)
        PORT_START="$2"
        shift 2
        ;;
      --port-end)
        PORT_END="$2"
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

  if [[ -z "$CLIENT_NAME" || -z "$SSH_USER" || -z "$SERVER_HOST" ]]; then
    usage
    exit 1
  fi
}

ensure_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1"
    exit 1
  fi
}

infer_server_port() {
  if [[ -n "$SERVER_PORT" ]]; then
    return
  fi
  if [[ -f "$CHISEL_SERVICE_FILE" ]]; then
    SERVER_PORT="$(sed -n 's/.*--port \([0-9][0-9]*\).*/\1/p' "$CHISEL_SERVICE_FILE" | head -n 1)"
  fi
  if [[ -z "$SERVER_PORT" ]]; then
    echo "Unable to determine server port. Pass --server-port explicitly."
    exit 1
  fi
}

infer_auth() {
  if [[ -n "$AUTH" ]]; then
    return
  fi
  if [[ -f "$CHISEL_USERS_FILE" ]]; then
    AUTH="$(sed -n 's/^[[:space:]]*"\([^"]\+\)":[[:space:]]*\[.*/\1/p' "$CHISEL_USERS_FILE" | head -n 1)"
  fi
  if [[ -z "$AUTH" ]]; then
    echo "Unable to determine chisel auth. Pass --auth explicitly."
    exit 1
  fi
}

infer_fingerprint() {
  if [[ -n "$FINGERPRINT" ]]; then
    return
  fi
  if [[ ! -x "$CHISEL_BIN" || ! -f "$CHISEL_KEYFILE" ]]; then
    echo "Unable to determine fingerprint. Pass --fingerprint explicitly."
    exit 1
  fi
  FINGERPRINT="$(
    timeout 3s "$CHISEL_BIN" server --host 127.0.0.1 --port 0 --keyfile "$CHISEL_KEYFILE" 2>&1 || true
  )"
  FINGERPRINT="$(sed -n 's/.*Fingerprint \(.*\)$/\1/p' <<<"$FINGERPRINT" | tail -n 1)"
  if [[ -z "$FINGERPRINT" ]]; then
    echo "Unable to determine fingerprint. Pass --fingerprint explicitly."
    exit 1
  fi
}

port_in_inventory() {
  local port="$1"
  [[ -f "$INVENTORY_FILE" ]] || return 1
  awk -F '\t' -v p="$port" '
    $0 !~ /^#/ && NF >= 2 && $2 == p { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$INVENTORY_FILE"
}

port_in_use_locally() {
  local port="$1"
  ss -ltnH | awk '{print $4}' | sed 's/.*://' | grep -qx "$port"
}

pick_port() {
  local port
  for ((port=PORT_START; port<=PORT_END; port++)); do
    if port_in_inventory "$port"; then
      continue
    fi
    if port_in_use_locally "$port"; then
      continue
    fi
    echo "$port"
    return
  done
  echo "No free reverse port found in range ${PORT_START}-${PORT_END}" >&2
  exit 1
}

main() {
  parse_args "$@"
  ensure_cmd sed
  ensure_cmd head
  ensure_cmd tail
  ensure_cmd timeout
  ensure_cmd ss

  infer_server_port
  infer_auth
  infer_fingerprint

  local reverse_port
  reverse_port="$(pick_port)"

  local generator_cmd
  generator_cmd=(
    "${REPO_ROOT}/scripts/generate_client_install_command.sh"
    --server-host "$SERVER_HOST"
    --server-port "$SERVER_PORT"
    --auth "$AUTH"
    --fingerprint "$FINGERPRINT"
    --reverse-port "$reverse_port"
    --ssh-user "$SSH_USER"
    --os "$CLIENT_OS"
  )

  if [[ -n "$SSH_PUBLIC_KEY_FILE" ]]; then
    generator_cmd+=(--ssh-public-key-file "$SSH_PUBLIC_KEY_FILE")
  fi
  if [[ -n "$CLIENT_SCRIPT_URL" ]]; then
    generator_cmd+=(--client-script-url "$CLIENT_SCRIPT_URL")
  fi

  echo "Client name: ${CLIENT_NAME}"
  echo "Chosen reverse port: ${reverse_port}"
  echo "Inventory add command:"
  printf '%q ' "${REPO_ROOT}/scripts/ai_client.sh" add "$CLIENT_NAME" "$reverse_port" "$SSH_USER" "$TAGS" "$DESCRIPTION" "$CLIENT_OS"
  printf '\n\n'

  "${generator_cmd[@]}"
}

main "$@"
