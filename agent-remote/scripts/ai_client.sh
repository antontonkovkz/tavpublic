#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INVENTORY_FILE="${INVENTORY_FILE:-${REPO_ROOT}/inventory/clients.tsv}"
KNOWN_HOSTS_FILE="${KNOWN_HOSTS_FILE:-${REPO_ROOT}/inventory/known_hosts}"
AI_SSH_KEY="${AI_SSH_KEY:-/root/.ssh/ai_chisel_ed25519}"
SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o ServerAliveInterval=15
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}"
  -i "${AI_SSH_KEY}"
)

usage() {
  cat <<EOF
Usage:
  $0 add <name> <port> <ssh_user> [tags] [description] [linux|windows]
  $0 list
  $0 show <name>
  $0 check [name]
  $0 run <name> -- <command...>
  $0 ps <name> <PowerShell script>
  $0 ssh <name>

Examples:
  $0 add client-1 2201 ubuntu demo "Ubuntu test box"
  $0 list
  $0 check client-1
  $0 run client-1 -- bash -lc 'hostname && uname -a'
  $0 ssh client-1
EOF
}

ensure_inventory() {
  mkdir -p "$(dirname "$INVENTORY_FILE")"
  touch "$INVENTORY_FILE"
  touch "$KNOWN_HOSTS_FILE"
}

record_exists() {
  local name="$1"
  awk -F '\t' -v target="$name" '
    $0 !~ /^#/ && NF >= 3 && $1 == target { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$INVENTORY_FILE"
}

get_record() {
  local name="$1"
  awk -F '\t' -v target="$name" '
    $0 !~ /^#/ && NF >= 3 && $1 == target { print; exit }
  ' "$INVENTORY_FILE"
}

add_client() {
  local name="$1"
  local port="$2"
  local ssh_user="$3"
  local tags="${4:-}"
  local description="${5:-}"
  local os="${6:-linux}"
  [[ "$os" == linux || "$os" == windows ]] || { echo "Invalid OS" >&2; exit 1; }

  ensure_inventory

  if record_exists "$name"; then
    echo "Client already exists: $name"
    exit 1
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$port" "$ssh_user" "$tags" "$description" "$os" >> "$INVENTORY_FILE"
  echo "Added client: $name"
}

list_clients() {
  ensure_inventory
  awk -F '\t' '
    BEGIN {
      printf "%-20s %-8s %-16s %-20s %s\n", "NAME", "PORT", "SSH_USER", "TAGS", "DESCRIPTION"
    }
    $0 !~ /^#/ && NF >= 3 {
      printf "%-20s %-8s %-16s %-20s %s\n", $1, $2, $3, $4, $5
    }
  ' "$INVENTORY_FILE"
}

show_client() {
  local record
  record="$(get_record "$1")"
  if [[ -z "$record" ]]; then
    echo "Client not found: $1"
    exit 1
  fi
  IFS=$'\t' read -r name port ssh_user tags description <<<"$record"
  cat <<EOF
name=${name}
port=${port}
ssh_user=${ssh_user}
tags=${tags}
description=$(awk -F '\t' '{print $5}' <<<"$record")
os=$(awk -F '\t' '{print ($6 == "" ? "linux" : $6)}' <<<"$record")
ssh_command=ssh -i ${AI_SSH_KEY} -p ${port} ${ssh_user}@127.0.0.1
EOF
}

check_one() {
  local name="$1"
  local record port ssh_user
  record="$(get_record "$name")"
  if [[ -z "$record" ]]; then
    echo "Client not found: $name"
    return 1
  fi
  IFS=$'\t' read -r _ port ssh_user _ _ <<<"$record"

  local os probe
  os="$(awk -F '\t' '{print $6}' <<<"$record")"
  probe=true
  [[ "$os" != windows ]] || probe='powershell.exe -NoProfile -NonInteractive -Command "exit 0"'
  if ssh "${SSH_OPTS[@]}" -p "$port" "${ssh_user}@127.0.0.1" "$probe" >/dev/null 2>&1; then
    echo "${name}: ok"
  else
    echo "${name}: unreachable"
    return 1
  fi
}

check_clients() {
  local target="${1:-}"
  local failed=0
  ensure_inventory

  if [[ -n "$target" ]]; then
    check_one "$target"
    return
  fi

  while IFS=$'\t' read -r name _; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    if ! check_one "$name"; then
      failed=1
    fi
  done < "$INVENTORY_FILE"

  return "$failed"
}

run_client() {
  local name="$1"
  shift

  local record port ssh_user
  record="$(get_record "$name")"
  if [[ -z "$record" ]]; then
    echo "Client not found: $name"
    exit 1
  fi
  IFS=$'\t' read -r _ port ssh_user _ _ <<<"$record"

  ssh "${SSH_OPTS[@]}" -p "$port" "${ssh_user}@127.0.0.1" "$@"
}

ssh_client() {
  local name="$1"
  local record port ssh_user
  record="$(get_record "$name")"
  if [[ -z "$record" ]]; then
    echo "Client not found: $name"
    exit 1
  fi
  IFS=$'\t' read -r _ port ssh_user _ _ <<<"$record"
  ssh "${SSH_OPTS[@]}" -p "$port" "${ssh_user}@127.0.0.1"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    add)
      [[ $# -ge 4 ]] || { usage; exit 1; }
      add_client "$2" "$3" "$4" "${5:-}" "${6:-}" "${7:-linux}"
      ;;
    list)
      list_clients
      ;;
    show)
      [[ $# -eq 2 ]] || { usage; exit 1; }
      show_client "$2"
      ;;
    check)
      check_clients "${2:-}"
      ;;
    run)
      [[ $# -ge 4 && "$3" == "--" ]] || { usage; exit 1; }
      run_client "$2" "${@:4}"
      ;;
    ps)
      [[ $# -eq 3 ]] || { usage; exit 1; }
      encoded="$(printf '%s' "$3" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
      run_client "$2" powershell.exe -NoProfile -NonInteractive -EncodedCommand "$encoded"
      ;;
    ssh)
      [[ $# -eq 2 ]] || { usage; exit 1; }
      ssh_client "$2"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
