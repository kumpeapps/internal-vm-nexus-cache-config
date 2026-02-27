#!/usr/bin/env bash
set -euo pipefail

# Client-only configuration script.
# This script does NOT create/update Nexus repositories.

NEXUS_HOST="artifacts.vm.kumpeapps.com"
PYPI_REPO="pypi"
DOCKER_HUB_PROXY="artifacts.vm.kumpeapps.com/docker"
DOCKER_GHCR_PROXY="artifacts.vm.kumpeapps.com/ghcr"
RUN_UPDATE="false"
BLOCK_DIRECT_REGISTRIES="false"
UNBLOCK_DIRECT_REGISTRIES="false"
INSTALL_DOCKER_WRAPPER="false"
REMOVE_DOCKER_WRAPPER="false"

usage() {
  cat <<'EOF'
Usage:
  configure-nexus-clients.sh [options]

Options:
  --nexus-host <host>            Nexus public host (default: artifacts.vm.kumpeapps.com)
  --pypi-repo <name>             Nexus PyPI proxy repo name (default: pypi)
  --docker-hub-proxy <endpoint>  Docker Hub proxy endpoint URL or host:port
                                 (default: artifacts.vm.kumpeapps.com/repository/docker)
  --docker-ghcr-proxy <endpoint> GHCR proxy endpoint URL or host:port
                                 (default: artifacts.vm.kumpeapps.com/repository/ghcr)
  --block-direct-registries      Add /etc/hosts blocks for direct docker.io/ghcr.io registry hosts
  --unblock-direct-registries    Remove /etc/hosts blocks added by this script
  --install-docker-wrapper       Install /usr/local/bin/docker wrapper to rewrite pull refs to Nexus
  --remove-docker-wrapper        Remove wrapper installed by this script
  --update                       Run pip and apt metadata refresh checks
  -h, --help                     Show this help

What it configures (system-wide):
  - /etc/pip.conf
  - /etc/docker/daemon.json
  - /etc/profile.d/nexus-python.sh

Notes:
  - Docker endpoints can be full URLs (https://.../repository/docker) or host:port (http assumed).
  - Docker registry mirrors only work with registry-root endpoints (no path component).
  - Docker CLI cannot pull through Nexus path endpoints; use a dedicated Nexus Docker connector/vhost (host[:port]).
  - Wrapper mode rewrites only `docker pull`; all other docker commands are passed through unchanged.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nexus-host)
      shift
      NEXUS_HOST="${1:-}"
      ;;
    --pypi-repo)
      shift
      PYPI_REPO="${1:-}"
      ;;
    --docker-hub-proxy)
      shift
      DOCKER_HUB_PROXY="${1:-}"
      ;;
    --docker-ghcr-proxy)
      shift
      DOCKER_GHCR_PROXY="${1:-}"
      ;;
    --update)
      RUN_UPDATE="true"
      ;;
    --block-direct-registries)
      BLOCK_DIRECT_REGISTRIES="true"
      ;;
    --unblock-direct-registries)
      UNBLOCK_DIRECT_REGISTRIES="true"
      ;;
    --install-docker-wrapper)
      INSTALL_DOCKER_WRAPPER="true"
      ;;
    --remove-docker-wrapper)
      REMOVE_DOCKER_WRAPPER="true"
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

if [[ -z "$NEXUS_HOST" || -z "$PYPI_REPO" || -z "$DOCKER_HUB_PROXY" || -z "$DOCKER_GHCR_PROXY" ]]; then
  echo "Error: one or more required option values are empty" >&2
  exit 1
fi

if [[ "$BLOCK_DIRECT_REGISTRIES" == "true" && "$UNBLOCK_DIRECT_REGISTRIES" == "true" ]]; then
  echo "Error: --block-direct-registries and --unblock-direct-registries are mutually exclusive" >&2
  exit 1
fi

if [[ "$INSTALL_DOCKER_WRAPPER" == "true" && "$REMOVE_DOCKER_WRAPPER" == "true" ]]; then
  echo "Error: --install-docker-wrapper and --remove-docker-wrapper are mutually exclusive" >&2
  exit 1
fi

normalize_endpoint_url() {
  local value="$1"
  if [[ "$value" =~ ^https?:// ]]; then
    echo "${value%/}"
  else
    echo "http://${value}"
  fi
}

strip_scheme() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  echo "${value%/}"
}

is_host_port() {
  local value="$1"
  [[ "$value" =~ ^[a-zA-Z0-9._-]+(:[0-9]+)?$ ]]
}

docker_mirror_supported() {
  local endpoint="$1"
  endpoint="${endpoint#http://}"
  endpoint="${endpoint#https://}"
  [[ "$endpoint" != */* ]]
}

install_docker_wrapper() {
  local docker_prefix="$1"
  local ghcr_prefix="$2"

  sudo env \
    NEXUS_DOCKER_PREFIX="$docker_prefix" \
    NEXUS_GHCR_PREFIX="$ghcr_prefix" \
    python3 - <<'PY'
import os
from pathlib import Path

wrapper_path = Path('/usr/local/bin/docker')
backup_path = Path('/usr/local/bin/docker.original-pre-nexus-wrapper')
marker_text = '# nexus-docker-pull-wrapper'
marker = marker_text.encode('utf-8')
template = """#!/usr/bin/env bash
set -euo pipefail

{marker}

NEXUS_DOCKER_PREFIX=\"{docker_prefix}\"
NEXUS_GHCR_PREFIX=\"{ghcr_prefix}\"

REAL_DOCKER_BIN=\"/usr/bin/docker\"
if [[ ! -x \"$REAL_DOCKER_BIN\" ]]; then
  REAL_DOCKER_BIN=\"$(command -v docker)\"
fi

if [[ -z \"${{REAL_DOCKER_BIN:-}}\" ]]; then
  echo \"Error: unable to find real docker binary\" >&2
  exit 1
fi

SELF=\"$(readlink -f \"$0\")\"
REAL_RESOLVED=\"$(readlink -f \"$REAL_DOCKER_BIN\" || true)\"
if [[ \"$REAL_RESOLVED\" == \"$SELF\" ]]; then
  if [[ -x \"/usr/bin/docker\" ]]; then
    REAL_DOCKER_BIN=\"/usr/bin/docker\"
  elif [[ -x \"/usr/bin/docker.io\" ]]; then
    REAL_DOCKER_BIN=\"/usr/bin/docker.io\"
  else
    echo \"Error: docker wrapper recursion detected and fallback docker binary not found\" >&2
    exit 1
  fi
fi

is_explicit_registry() {{
  local first_segment=\"$1\"
  [[ \"$first_segment\" == *.* || \"$first_segment\" == *:* || \"$first_segment\" == \"localhost\" ]]
}}

rewrite_image_ref() {{
  local image=\"$1\"
  local remainder
  local first

  case \"$image\" in
    \"${{NEXUS_DOCKER_PREFIX}}\"/*|\"${{NEXUS_GHCR_PREFIX}}\"/*)
      echo \"$image\"
      return
      ;;
    ghcr.io/*)
      remainder=\"${{image#ghcr.io/}}\"
      echo \"${{NEXUS_GHCR_PREFIX}}/$remainder\"
      return
      ;;
    docker.io/*)
      remainder=\"${{image#docker.io/}}\"
      echo \"${{NEXUS_DOCKER_PREFIX}}/$remainder\"
      return
      ;;
  esac

  if [[ \"$image\" != */* ]]; then
    echo \"${{NEXUS_DOCKER_PREFIX}}/library/$image\"
    return
  fi

  first=\"${{image%%/*}}\"
  if is_explicit_registry \"$first\"; then
    echo \"$image\"
    return
  fi

  echo \"${{NEXUS_DOCKER_PREFIX}}/$image\"
}}

if [[ \"${{1:-}}\" != \"pull\" ]]; then
  exec \"$REAL_DOCKER_BIN\" \"$@\"
fi

shift
pull_opts=()
image_ref=\"\"
extra=()

for arg in \"$@\"; do
  if [[ -z \"$image_ref\" && \"$arg\" == -* ]]; then
    pull_opts+=(\"$arg\")
    continue
  fi

  if [[ -z \"$image_ref\" ]]; then
    image_ref=\"$arg\"
    continue
  fi

  extra+=(\"$arg\")
done

if [[ -z \"$image_ref\" ]]; then
  exec \"$REAL_DOCKER_BIN\" pull \"${{pull_opts[@]}}\"
fi

rewritten=\"$(rewrite_image_ref \"$image_ref\")\"
if [[ \"${{NEXUS_DOCKER_WRAPPER_DEBUG:-0}}\" == \"1\" && \"$rewritten\" != \"$image_ref\" ]]; then
  echo \"docker wrapper rewrite: $image_ref -> $rewritten\" >&2
fi

exec \"$REAL_DOCKER_BIN\" pull \"${{pull_opts[@]}}\" \"$rewritten\" \"${{extra[@]}}\"
"""

content = template.format(
  marker=marker_text,
    docker_prefix=os.environ['NEXUS_DOCKER_PREFIX'],
    ghcr_prefix=os.environ['NEXUS_GHCR_PREFIX'],
).encode('utf-8')

if wrapper_path.is_symlink():
  wrapper_path.unlink()

if wrapper_path.exists():
  existing = wrapper_path.read_bytes()
  if marker not in existing and not backup_path.exists():
    backup_path.write_bytes(existing)

wrapper_path.write_bytes(content)
wrapper_path.chmod(0o755)
PY
}

remove_docker_wrapper() {
  sudo python3 - <<'PY'
from pathlib import Path

wrapper_path = Path('/usr/local/bin/docker')
backup_path = Path('/usr/local/bin/docker.original-pre-nexus-wrapper')
marker = b'# nexus-docker-pull-wrapper'

if not wrapper_path.exists():
    raise SystemExit(0)

if wrapper_path.is_symlink():
  wrapper_path.unlink()
  raise SystemExit(0)

existing = wrapper_path.read_bytes()
if marker in existing:
    if backup_path.exists():
    wrapper_path.write_bytes(backup_path.read_bytes())
        backup_path.unlink()
        wrapper_path.chmod(0o755)
    else:
        wrapper_path.unlink()
PY
}

apply_hosts_blocks() {
  sudo python3 - <<'PY'
from pathlib import Path

hosts_path = Path('/etc/hosts')
start = '# BEGIN nexus-client-registry-blocks'
end = '# END nexus-client-registry-blocks'
block = '\n'.join([
    start,
  '0.0.0.0 registry-1.docker.io',
  ':: registry-1.docker.io',
  '0.0.0.0 auth.docker.io',
  ':: auth.docker.io',
  '0.0.0.0 index.docker.io',
  ':: index.docker.io',
  '0.0.0.0 production.cloudflare.docker.com',
  ':: production.cloudflare.docker.com',
  '0.0.0.0 ghcr.io',
  ':: ghcr.io',
  '0.0.0.0 pkg-containers.githubusercontent.com',
  ':: pkg-containers.githubusercontent.com',
    end,
])

content = hosts_path.read_text(encoding='utf-8') if hosts_path.exists() else ''
if start in content and end in content:
    pre = content.split(start)[0].rstrip('\n')
    post = content.split(end, 1)[1].lstrip('\n')
    content = (pre + '\n' + block + ('\n' + post if post else '\n')).lstrip('\n')
else:
    if content and not content.endswith('\n'):
        content += '\n'
    content += block + '\n'

hosts_path.write_text(content, encoding='utf-8')
PY
}

remove_hosts_blocks() {
  sudo python3 - <<'PY'
from pathlib import Path

hosts_path = Path('/etc/hosts')
if not hosts_path.exists():
    raise SystemExit(0)

start = '# BEGIN nexus-client-registry-blocks'
end = '# END nexus-client-registry-blocks'
content = hosts_path.read_text(encoding='utf-8')
if start in content and end in content:
    pre = content.split(start)[0].rstrip('\n')
    post = content.split(end, 1)[1].lstrip('\n')
    merged = '\n'.join([x for x in [pre, post] if x]).rstrip('\n')
    hosts_path.write_text((merged + '\n') if merged else '', encoding='utf-8')
PY
}

PYPI_SIMPLE_URL="https://${NEXUS_HOST}/repository/${PYPI_REPO}/simple"
DOCKER_HUB_ENDPOINT_URL="$(normalize_endpoint_url "$DOCKER_HUB_PROXY")"
DOCKER_GHCR_ENDPOINT_URL="$(normalize_endpoint_url "$DOCKER_GHCR_PROXY")"
DOCKER_HUB_PREFIX="$(strip_scheme "$DOCKER_HUB_ENDPOINT_URL")"
DOCKER_GHCR_PREFIX="$(strip_scheme "$DOCKER_GHCR_ENDPOINT_URL")"
DOCKER_HUB_MIRROR_SUPPORTED="false"
DOCKER_GHCR_PULL_SUPPORTED="false"

if docker_mirror_supported "$DOCKER_HUB_ENDPOINT_URL"; then
  DOCKER_HUB_MIRROR_SUPPORTED="true"
fi

if docker_mirror_supported "$DOCKER_GHCR_ENDPOINT_URL"; then
  DOCKER_GHCR_PULL_SUPPORTED="true"
fi

if [[ "$INSTALL_DOCKER_WRAPPER" == "true" ]]; then
  if [[ "$DOCKER_HUB_MIRROR_SUPPORTED" != "true" || "$DOCKER_GHCR_PULL_SUPPORTED" != "true" ]]; then
    cat <<EOF >&2
Warning: wrapper install is using path-based Docker endpoints.
This is non-standard and may fail unless your reverse proxy maps these paths to Docker registry roots:
  --docker-hub-proxy=${DOCKER_HUB_PROXY}
  --docker-ghcr-proxy=${DOCKER_GHCR_PROXY}

Preferred dedicated Nexus Docker connector/vhost endpoints are:
  --docker-hub-proxy=nexus-docker.example.com:5000
  --docker-ghcr-proxy=nexus-ghcr.example.com:5001
EOF
  fi
fi

DOCKER_HUB_INSECURE=""
DOCKER_GHCR_INSECURE=""

if is_host_port "$DOCKER_HUB_PROXY"; then
  DOCKER_HUB_INSECURE="$DOCKER_HUB_PROXY"
fi

if is_host_port "$DOCKER_GHCR_PROXY"; then
  DOCKER_GHCR_INSECURE="$DOCKER_GHCR_PROXY"
fi

echo "Applying system-wide pip configuration..."
sudo tee /etc/pip.conf >/dev/null <<EOF
[global]
index-url = ${PYPI_SIMPLE_URL}
trusted-host = ${NEXUS_HOST}
timeout = 60
EOF

echo "Applying global Python env defaults..."
sudo tee /etc/profile.d/nexus-python.sh >/dev/null <<EOF
export PIP_INDEX_URL="${PYPI_SIMPLE_URL}"
export PIP_TRUSTED_HOST="${NEXUS_HOST}"
EOF
sudo chmod 0644 /etc/profile.d/nexus-python.sh

echo "Applying system-wide Docker daemon configuration..."
sudo env \
  DOCKER_HUB_ENDPOINT_URL="$DOCKER_HUB_ENDPOINT_URL" \
  DOCKER_HUB_INSECURE="$DOCKER_HUB_INSECURE" \
  DOCKER_HUB_MIRROR_SUPPORTED="$DOCKER_HUB_MIRROR_SUPPORTED" \
  DOCKER_GHCR_INSECURE="$DOCKER_GHCR_INSECURE" \
  python3 - <<'PY'
import json
import os
from pathlib import Path

config = {}

if os.environ["DOCKER_HUB_MIRROR_SUPPORTED"] == "true":
    config["registry-mirrors"] = [os.environ["DOCKER_HUB_ENDPOINT_URL"]]

insecure = [value for value in [os.environ["DOCKER_HUB_INSECURE"], os.environ["DOCKER_GHCR_INSECURE"]] if value]
if insecure:
    config["insecure-registries"] = insecure

Path("/etc/docker").mkdir(parents=True, exist_ok=True)
Path("/etc/docker/daemon.json").write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
PY

if [[ "$DOCKER_HUB_MIRROR_SUPPORTED" != "true" ]]; then
  cat <<EOF
Warning: ${DOCKER_HUB_ENDPOINT_URL} contains a path, so Docker cannot use it as a registry mirror.
Mirror for docker.io was not configured. To mirror transparently, use a dedicated Nexus Docker connector/vhost on host[:port].
EOF
fi

if [[ "$DOCKER_GHCR_PULL_SUPPORTED" != "true" ]]; then
  cat <<EOF
Warning: ${DOCKER_GHCR_ENDPOINT_URL} contains a path, so Docker CLI cannot pull images through it directly.
Use a dedicated Nexus Docker connector/vhost for GHCR proxying (for example: nexus-ghcr.example.com[:port]).
EOF
fi

if [[ "$UNBLOCK_DIRECT_REGISTRIES" == "true" ]]; then
  echo "Removing direct registry hostname blocks from /etc/hosts..."
  remove_hosts_blocks
fi

if [[ "$BLOCK_DIRECT_REGISTRIES" == "true" ]]; then
  echo "Adding direct registry hostname blocks to /etc/hosts..."
  apply_hosts_blocks
fi

if [[ "$REMOVE_DOCKER_WRAPPER" == "true" ]]; then
  echo "Removing docker pull wrapper from /usr/local/bin/docker..."
  remove_docker_wrapper
fi

if [[ "$INSTALL_DOCKER_WRAPPER" == "true" ]]; then
  echo "Installing docker pull wrapper to /usr/local/bin/docker..."
  install_docker_wrapper "$DOCKER_HUB_PREFIX" "$DOCKER_GHCR_PREFIX"
fi

if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^docker\.service'; then
  echo "Restarting docker service..."
  sudo systemctl restart docker
fi

echo "Validating configured endpoints..."
curl -sS -I "${PYPI_SIMPLE_URL}/" | sed -n '1,8p'
curl -sS -I "${DOCKER_HUB_ENDPOINT_URL}/v2/" | sed -n '1,8p'
curl -sS -I "${DOCKER_GHCR_ENDPOINT_URL}/v2/" | sed -n '1,8p'

if [[ "$RUN_UPDATE" == "true" ]]; then
  echo "Running metadata refresh checks..."
  python3 -m pip index versions pip >/dev/null || true
  sudo apt-get update >/dev/null || true
fi

cat <<EOF

Done.

All-user configuration set:
  - /etc/pip.conf -> ${PYPI_SIMPLE_URL}
  - /etc/docker/daemon.json -> docker hub mirror ${DOCKER_HUB_ENDPOINT_URL} (supported: ${DOCKER_HUB_MIRROR_SUPPORTED})
  - ghcr pull-through endpoint support -> ${DOCKER_GHCR_PULL_SUPPORTED}

Direct registry block mode:
  - enabled now: ${BLOCK_DIRECT_REGISTRIES}
  - removed now: ${UNBLOCK_DIRECT_REGISTRIES}

Docker wrapper mode:
  - installed now: ${INSTALL_DOCKER_WRAPPER}
  - removed now: ${REMOVE_DOCKER_WRAPPER}

Usage examples:
  pip install requests
  docker pull alpine:latest
  docker pull <nexus-ghcr-host[:port]>/OWNER/IMAGE:TAG
  NEXUS_DOCKER_WRAPPER_DEBUG=1 docker pull ghcr.io/OWNER/IMAGE:TAG

Enforcement notes:
  - For hard enforcement across hosts, block egress to docker.io/ghcr.io at network firewall and allow Nexus only.
EOF
