#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root or via sudo."
  exit 1
fi

SERVER_HOST=""
SERVER_PORT=""
CHISEL_AUTH=""
CHISEL_FINGERPRINT=""
REVERSE_SSH_PORT=""
SSH_USER="${SSH_USER:-}"
SSH_PUBLIC_KEY=""
SSH_PUBLIC_KEY_FILE=""
CHISEL_VERSION="${CHISEL_VERSION:-1.11.3}"
CHISEL_BIN="${CHISEL_BIN:-/usr/local/bin/chisel}"
CHISEL_CONFIG_DIR="${CHISEL_CONFIG_DIR:-/etc/chisel}"
CHISEL_SERVICE_NAME="${CHISEL_SERVICE_NAME:-chisel-client}"
LOCAL_SSH_HOST="${LOCAL_SSH_HOST:-127.0.0.1}"
LOCAL_SSH_PORT="${LOCAL_SSH_PORT:-22}"

usage() {
  cat <<EOF
Usage:
  $0 --server-host <host> --server-port <port> --auth <user:pass> --fingerprint <fp> --reverse-port <port> [--ssh-user <user>] [--ssh-public-key '<key>'] [--ssh-public-key-file <path>]

Example:
  sudo $0 --server-host ai.example.com --server-port 9312 --auth 'ai:secret' --fingerprint '<fp>' --reverse-port 2201 --ssh-user ubuntu --ssh-public-key 'ssh-ed25519 AAAA...'
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1"
    exit 1
  fi
}

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "armv7" ;;
    *)
      echo "Unsupported architecture: $arch"
      exit 1
      ;;
  esac
}

download_chisel() {
  local arch url tmp_dir
  arch="$(detect_arch)"
  url="https://github.com/jpillora/chisel/releases/download/v${CHISEL_VERSION}/chisel_${CHISEL_VERSION}_linux_${arch}.gz"
  tmp_dir="$(mktemp -d)"
  trap "rm -rf '$tmp_dir'" EXIT

  curl -fsSL "$url" -o "${tmp_dir}/chisel.gz"
  gunzip -c "${tmp_dir}/chisel.gz" > "$CHISEL_BIN"
  chmod 0755 "$CHISEL_BIN"
}

install_dependencies() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y openssh-server curl gzip ca-certificates
  systemctl enable --now ssh
}

read_public_key() {
  if [[ -n "$SSH_PUBLIC_KEY_FILE" ]]; then
    if [[ ! -f "$SSH_PUBLIC_KEY_FILE" ]]; then
      echo "Public key file not found: $SSH_PUBLIC_KEY_FILE"
      exit 1
    fi
    SSH_PUBLIC_KEY="$(tr -d '\n' < "$SSH_PUBLIC_KEY_FILE")"
  fi
}

install_ssh_key() {
  if [[ -z "$SSH_PUBLIC_KEY" ]]; then
    return
  fi

  if [[ -z "$SSH_USER" ]]; then
    echo "--ssh-user is required when --ssh-public-key or --ssh-public-key-file is used."
    exit 1
  fi

  local home_dir ssh_dir auth_file
  home_dir="$(getent passwd "$SSH_USER" | cut -d: -f6)"
  if [[ -z "$home_dir" ]]; then
    echo "SSH user not found: $SSH_USER"
    exit 1
  fi

  ssh_dir="${home_dir}/.ssh"
  auth_file="${ssh_dir}/authorized_keys"

  install -d -m 0700 -o "$SSH_USER" -g "$SSH_USER" "$ssh_dir"
  touch "$auth_file"
  chown "$SSH_USER:$SSH_USER" "$auth_file"
  chmod 0600 "$auth_file"

  if ! grep -qxF "$SSH_PUBLIC_KEY" "$auth_file"; then
    printf '%s\n' "$SSH_PUBLIC_KEY" >> "$auth_file"
  fi
}

write_env() {
  mkdir -p "$CHISEL_CONFIG_DIR"
  chmod 0700 "$CHISEL_CONFIG_DIR"

  cat > "${CHISEL_CONFIG_DIR}/client.env" <<EOF
SERVER_HOST=${SERVER_HOST}
SERVER_PORT=${SERVER_PORT}
CHISEL_AUTH=${CHISEL_AUTH}
CHISEL_FINGERPRINT=${CHISEL_FINGERPRINT}
REVERSE_SSH_PORT=${REVERSE_SSH_PORT}
LOCAL_SSH_HOST=${LOCAL_SSH_HOST}
LOCAL_SSH_PORT=${LOCAL_SSH_PORT}
EOF
  chmod 0600 "${CHISEL_CONFIG_DIR}/client.env"
}

write_service() {
  cat > "/etc/systemd/system/${CHISEL_SERVICE_NAME}.service" <<EOF
[Unit]
Description=Chisel reverse tunnel client
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${CHISEL_CONFIG_DIR}/client.env
ExecStart=${CHISEL_BIN} client --fingerprint \${CHISEL_FINGERPRINT} --auth \${CHISEL_AUTH} \${SERVER_HOST}:\${SERVER_PORT} R:127.0.0.1:\${REVERSE_SSH_PORT}:\${LOCAL_SSH_HOST}:\${LOCAL_SSH_PORT}
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${CHISEL_CONFIG_DIR}

[Install]
WantedBy=multi-user.target
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server-host)
        SERVER_HOST="$2"
        shift 2
        ;;
      --server-port)
        SERVER_PORT="$2"
        shift 2
        ;;
      --auth)
        CHISEL_AUTH="$2"
        shift 2
        ;;
      --fingerprint)
        CHISEL_FINGERPRINT="$2"
        shift 2
        ;;
      --reverse-port)
        REVERSE_SSH_PORT="$2"
        shift 2
        ;;
      --ssh-user)
        SSH_USER="$2"
        shift 2
        ;;
      --ssh-public-key)
        SSH_PUBLIC_KEY="$2"
        shift 2
        ;;
      --ssh-public-key-file)
        SSH_PUBLIC_KEY_FILE="$2"
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

  if [[ -z "$SERVER_HOST" || -z "$SERVER_PORT" || -z "$CHISEL_AUTH" || -z "$CHISEL_FINGERPRINT" || -z "$REVERSE_SSH_PORT" ]]; then
    usage
    exit 1
  fi
}

main() {
  parse_args "$@"
  require_cmd apt-get
  require_cmd systemctl
  require_cmd getent
  require_cmd cut
  read_public_key
  install_dependencies
  download_chisel
  install_ssh_key
  write_env
  write_service

  systemctl daemon-reload
  systemctl enable --now "${CHISEL_SERVICE_NAME}.service"

  echo
  echo "Client install complete."
  echo "This host should now be reachable from the AI server via:"
  if [[ -n "$SSH_USER" ]]; then
    echo "  ssh -p ${REVERSE_SSH_PORT} ${SSH_USER}@127.0.0.1"
  else
    echo "  ssh -p ${REVERSE_SSH_PORT} <ubuntu-user>@127.0.0.1"
  fi
}

main "$@"
