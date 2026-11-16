#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root or via sudo."
  exit 1
fi

CHISEL_VERSION="${CHISEL_VERSION:-1.11.3}"
CHISEL_PORT="${CHISEL_PORT:-9312}"
CHISEL_USER="${CHISEL_USER:-ai}"
CHISEL_PASS="${CHISEL_PASS:-}"
CHISEL_BIND_HOST="${CHISEL_BIND_HOST:-0.0.0.0}"
CHISEL_CONFIG_DIR="${CHISEL_CONFIG_DIR:-/etc/chisel}"
CHISEL_INSTALL_DIR="${CHISEL_INSTALL_DIR:-/opt/chisel}"
CHISEL_BIN="${CHISEL_BIN:-/usr/local/bin/chisel}"
CHISEL_SERVICE_NAME="${CHISEL_SERVICE_NAME:-chisel-server}"
CHISEL_ALLOWED_REVERSE_REGEX="${CHISEL_ALLOWED_REVERSE_REGEX:-^R:127[.]0[.]0[.]1:[0-9]+$}"
AI_SSH_KEY_DIR="${AI_SSH_KEY_DIR:-/root/.ssh}"
AI_SSH_KEY_NAME="${AI_SSH_KEY_NAME:-ai_chisel_ed25519}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1"
    exit 1
  fi
}

open_firewall_port() {
  if command -v ufw >/dev/null 2>&1; then
    local ufw_status
    ufw_status="$(ufw status 2>/dev/null || true)"
    if grep -q "^Status: active" <<<"$ufw_status"; then
      if ! grep -Eq "(^|[[:space:]])${CHISEL_PORT}/tcp([[:space:]]|$)" <<<"$ufw_status"; then
        echo "Opening TCP ${CHISEL_PORT} in ufw..."
        ufw allow "${CHISEL_PORT}/tcp" >/dev/null
      fi
      return
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    if firewall-cmd --state >/dev/null 2>&1; then
      local runtime_open permanent_open
      runtime_open="no"
      permanent_open="no"
      if firewall-cmd --query-port="${CHISEL_PORT}/tcp" >/dev/null 2>&1; then
        runtime_open="yes"
      fi
      if firewall-cmd --permanent --query-port="${CHISEL_PORT}/tcp" >/dev/null 2>&1; then
        permanent_open="yes"
      fi
      if [[ "$runtime_open" != "yes" ]]; then
        echo "Opening TCP ${CHISEL_PORT} in firewalld runtime config..."
        firewall-cmd --add-port="${CHISEL_PORT}/tcp" >/dev/null
      fi
      if [[ "$permanent_open" != "yes" ]]; then
        echo "Opening TCP ${CHISEL_PORT} in firewalld permanent config..."
        firewall-cmd --permanent --add-port="${CHISEL_PORT}/tcp" >/dev/null
      fi
      return
    fi
  fi

  echo "No supported active local firewall manager detected. If needed, open TCP ${CHISEL_PORT} manually."
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

  mkdir -p "$CHISEL_INSTALL_DIR"
  echo "Downloading chisel v${CHISEL_VERSION} for ${arch}..."
  curl -fsSL "$url" -o "${tmp_dir}/chisel.gz"
  gunzip -c "${tmp_dir}/chisel.gz" > "$CHISEL_BIN"
  chmod 0755 "$CHISEL_BIN"
}

gen_password() {
  if [[ -n "$CHISEL_PASS" ]]; then
    return
  fi

  if command -v openssl >/dev/null 2>&1; then
    CHISEL_PASS="$(openssl rand -base64 24 | tr -d '\n' | tr '/+' '_-')"
  else
    CHISEL_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
  fi
}

write_config() {
  mkdir -p "$CHISEL_CONFIG_DIR"
  chmod 0700 "$CHISEL_CONFIG_DIR"

  if [[ ! -f "${CHISEL_CONFIG_DIR}/server_key.pem" ]]; then
    "$CHISEL_BIN" server --keygen "${CHISEL_CONFIG_DIR}/server_key.pem" >/dev/null
    chmod 0600 "${CHISEL_CONFIG_DIR}/server_key.pem"
  fi

  cat > "${CHISEL_CONFIG_DIR}/users.json" <<EOF
{
  "${CHISEL_USER}:${CHISEL_PASS}": [
    "${CHISEL_ALLOWED_REVERSE_REGEX}"
  ]
}
EOF
  chmod 0600 "${CHISEL_CONFIG_DIR}/users.json"
}

validate_server_config() {
  local output
  output="$(timeout 3s "$CHISEL_BIN" server --host 127.0.0.1 --port 0 --keyfile "${CHISEL_CONFIG_DIR}/server_key.pem" --authfile "${CHISEL_CONFIG_DIR}/users.json" 2>&1 || true)"
  if grep -q "Invalid JSON" <<<"$output"; then
    echo "Generated ${CHISEL_CONFIG_DIR}/users.json is invalid:"
    echo "$output"
    exit 1
  fi
}

write_service() {
  cat > "/etc/systemd/system/${CHISEL_SERVICE_NAME}.service" <<EOF
[Unit]
Description=Chisel reverse tunnel server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CHISEL_BIN} server --host ${CHISEL_BIND_HOST} --port ${CHISEL_PORT} --reverse --keyfile ${CHISEL_CONFIG_DIR}/server_key.pem --authfile ${CHISEL_CONFIG_DIR}/users.json
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

ensure_ai_ssh_key() {
  local key_path
  key_path="${AI_SSH_KEY_DIR}/${AI_SSH_KEY_NAME}"
  mkdir -p "$AI_SSH_KEY_DIR"
  chmod 0700 "$AI_SSH_KEY_DIR"

  if [[ ! -f "$key_path" ]]; then
    ssh-keygen -t ed25519 -N "" -f "$key_path" -C "ai-chisel-access" >/dev/null
    chmod 0600 "$key_path"
    chmod 0644 "${key_path}.pub"
  fi
}

extract_fingerprint() {
  local output
  output="$(timeout 3s "$CHISEL_BIN" server --host 127.0.0.1 --port 0 --keyfile "${CHISEL_CONFIG_DIR}/server_key.pem" 2>&1 || true)"
  sed -n 's/.*Fingerprint \(.*\)$/\1/p' <<<"$output" | tail -n 1
}

main() {
  require_cmd curl
  require_cmd gunzip
  require_cmd sed
  require_cmd systemctl
  require_cmd ssh-keygen
  download_chisel
  gen_password
  write_config
  validate_server_config
  write_service
  ensure_ai_ssh_key

  systemctl daemon-reload
  systemctl enable --now "${CHISEL_SERVICE_NAME}.service"
  open_firewall_port

  local fingerprint
  local key_path
  fingerprint="$(extract_fingerprint)"
  key_path="${AI_SSH_KEY_DIR}/${AI_SSH_KEY_NAME}"

  echo
  echo "Server install complete."
  echo "Chisel binary: ${CHISEL_BIN}"
  echo "Listen address: ${CHISEL_BIND_HOST}:${CHISEL_PORT}"
  echo "Auth: ${CHISEL_USER}:${CHISEL_PASS}"
  if [[ -n "$fingerprint" ]]; then
    echo "Fingerprint: ${fingerprint}"
  else
    echo "Fingerprint: unable to auto-detect, inspect: journalctl -u ${CHISEL_SERVICE_NAME} -n 20 --no-pager"
  fi
  echo "AI SSH private key: ${key_path}"
  echo "AI SSH public key: ${key_path}.pub"
  echo
  echo "Ensure inbound TCP ${CHISEL_PORT} is allowed on any external firewall or cloud security group."
  echo "Generate a client install command with:"
  echo "  scripts/generate_client_install_command.sh --server-host <host-or-ip> --server-port ${CHISEL_PORT} --auth '${CHISEL_USER}:${CHISEL_PASS}' --fingerprint '${fingerprint:-<fingerprint>}' --reverse-port <port> --ssh-user <user>"
}

main "$@"
