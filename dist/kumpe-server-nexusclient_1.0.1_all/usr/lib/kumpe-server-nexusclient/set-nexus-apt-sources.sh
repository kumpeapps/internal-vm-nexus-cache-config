#!/usr/bin/env bash
set -euo pipefail

if ! command -v sudo >/dev/null 2>&1; then
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    sudo() { "$@"; }
  else
    echo "Error: sudo is required when not running as root" >&2
    exit 1
  fi
fi

NEXUS_BASE="https://artifacts.vm.kumpeapps.com/repository"
TARGET_FILE="/etc/apt/sources.list"
BACKUP_DIR="/etc/apt/backups"
HOSTED_REPO="kumpeapps"
HOSTED_DIST="kumpeapps"
HOSTED_COMPONENT="main"
KEYRING_DIR="/etc/apt/keyrings"
KEYRING_FILE="${KEYRING_DIR}/kumpeapps-nexus.asc"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLIC_KEY_SOURCE="${SCRIPT_DIR}/public.key.asc"

usage() {
  cat <<'EOF'
Usage:
  set-nexus-apt-sources.sh [--suite bookworm|bullseye|trixie] [--update]
  set-nexus-apt-sources.sh --restore [--file /etc/apt/backups/sources.list.TIMESTAMP.bak] [--update]

Options:
  --suite <name>   Override detected Debian codename.
  --restore        Restore sources.list from backup (latest by default).
  --file <path>    Backup file path to restore (used with --restore).
  --update         Run apt-get update after writing sources.
  -h, --help       Show this help.
EOF
}

suite_override=""
restore_mode="false"
restore_file=""
run_update="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite)
      shift
      suite_override="${1:-}"
      if [[ -z "$suite_override" ]]; then
        echo "Error: --suite requires a value" >&2
        exit 1
      fi
      ;;
    --restore)
      restore_mode="true"
      ;;
    --file)
      shift
      restore_file="${1:-}"
      if [[ -z "$restore_file" ]]; then
        echo "Error: --file requires a value" >&2
        exit 1
      fi
      ;;
    --update)
      run_update="true"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ "$restore_mode" == "true" ]]; then
  if [[ -n "$suite_override" ]]; then
    echo "Error: --suite cannot be used with --restore" >&2
    exit 1
  fi

  if [[ -n "$restore_file" ]]; then
    backup_file="$restore_file"
  else
    if ! ls -1 "$BACKUP_DIR"/sources.list.*.bak >/dev/null 2>&1; then
      echo "No backups found in $BACKUP_DIR" >&2
      exit 1
    fi
    backup_file=$(ls -1t "$BACKUP_DIR"/sources.list.*.bak | head -n 1)
  fi

  if [[ ! -f "$backup_file" ]]; then
    echo "Backup file not found: $backup_file" >&2
    exit 1
  fi

  echo "Restoring from: $backup_file"
  sudo cp "$backup_file" "$TARGET_FILE"
  echo "Restored $TARGET_FILE"

  if [[ "$run_update" == "true" ]]; then
    echo "Running apt-get update..."
    sudo apt-get update
  fi

  echo "Done."
  exit 0
fi

if [[ -n "$restore_file" ]]; then
  echo "Error: --file can only be used with --restore" >&2
  exit 1
fi

if [[ -n "$suite_override" ]]; then
  suite="$suite_override"
else
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    suite="${VERSION_CODENAME:-}"
  else
    echo "Error: /etc/os-release not found" >&2
    exit 1
  fi
fi

case "$suite" in
  bookworm|bullseye|trixie)
    ;;
  *)
    echo "Unsupported suite: $suite" >&2
    echo "Supported suites: bookworm, bullseye, trixie" >&2
    exit 1
    ;;
esac

main_repo="debian-${suite}-proxy"
security_repo="debian-${suite}-security-proxy"
updates_repo="debian-${suite}-updates-proxy"

new_sources=$(cat <<EOF
# Managed by set-nexus-apt-sources.sh
# Suite: ${suite}

deb ${NEXUS_BASE}/${main_repo}/ ${suite} main non-free-firmware
deb-src ${NEXUS_BASE}/${main_repo}/ ${suite} main non-free-firmware

deb ${NEXUS_BASE}/${security_repo}/ ${suite}-security main non-free-firmware
deb-src ${NEXUS_BASE}/${security_repo}/ ${suite}-security main non-free-firmware

deb ${NEXUS_BASE}/${updates_repo}/ ${suite}-updates main non-free-firmware
deb-src ${NEXUS_BASE}/${updates_repo}/ ${suite}-updates main non-free-firmware

deb [signed-by=${KEYRING_FILE}] ${NEXUS_BASE}/${HOSTED_REPO}/ ${HOSTED_DIST} ${HOSTED_COMPONENT}
EOF
)

echo "Detected/selected suite: ${suite}"

if [[ ! -f "$PUBLIC_KEY_SOURCE" ]]; then
  echo "Error: public key file not found: $PUBLIC_KEY_SOURCE" >&2
  exit 1
fi

sudo mkdir -p "$KEYRING_DIR"
sudo install -m 0644 "$PUBLIC_KEY_SOURCE" "$KEYRING_FILE"
echo "Installed KumpeApps APT signing key: $KEYRING_FILE"

ts=$(date +%Y%m%d-%H%M%S)
sudo mkdir -p "$BACKUP_DIR"
if [[ -f "$TARGET_FILE" ]]; then
  sudo cp "$TARGET_FILE" "$BACKUP_DIR/sources.list.${ts}.bak"
  echo "Backup created: $BACKUP_DIR/sources.list.${ts}.bak"
fi

printf '%s\n' "$new_sources" | sudo tee "$TARGET_FILE" >/dev/null
echo "Updated $TARGET_FILE to use Nexus APT proxies."

if [[ "$run_update" == "true" ]]; then
  echo "Running apt-get update..."
  sudo apt-get update
fi

echo "Done."
