#!/usr/bin/env bash
set -euo pipefail

PKG_NAME="kumpe-server-nexusclient"
PKG_VERSION="${1:-1.0.0}"
PKG_ARCH="all"
MAINTAINER="KumpeApps <helpdesk@kumpeapps.com>"
DESCRIPTION="Configure host to use KumpeApps Nexus APT/Docker/PyPI proxies"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
PKG_ROOT="${DIST_DIR}/${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}"
OUTPUT_DEB="${DIST_DIR}/${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}.deb"

if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "Error: dpkg-deb is required to build the package." >&2
  exit 1
fi

rm -rf "${PKG_ROOT}"
mkdir -p "${PKG_ROOT}/DEBIAN"
mkdir -p "${PKG_ROOT}/usr/lib/${PKG_NAME}"

install -m 0755 "${SCRIPT_DIR}/set-nexus-apt-sources.sh" "${PKG_ROOT}/usr/lib/${PKG_NAME}/set-nexus-apt-sources.sh"
install -m 0755 "${SCRIPT_DIR}/configure-nexus-clients.sh" "${PKG_ROOT}/usr/lib/${PKG_NAME}/configure-nexus-clients.sh"
install -m 0644 "${SCRIPT_DIR}/public.key.asc" "${PKG_ROOT}/usr/lib/${PKG_NAME}/public.key.asc"

cat > "${PKG_ROOT}/DEBIAN/control" <<EOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Section: admin
Priority: optional
Architecture: ${PKG_ARCH}
Maintainer: ${MAINTAINER}
Depends: bash, python3, curl, ca-certificates, apt
Description: ${DESCRIPTION}
 This package installs KumpeApps Nexus client configuration scripts.
 On install/upgrade, it configures APT sources and Nexus client policies.
EOF

cat > "${PKG_ROOT}/DEBIAN/postinst" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "configure" ]]; then
  BASE_DIR="/usr/lib/kumpe-server-nexusclient"

  "${BASE_DIR}/set-nexus-apt-sources.sh"
  "${BASE_DIR}/configure-nexus-clients.sh" --block-direct-registries --install-docker-wrapper
fi
EOF

cat > "${PKG_ROOT}/DEBIAN/postrm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "remove" || "${1:-}" == "purge" ]]; then
  python3 - <<'PY' || true
from pathlib import Path

wrapper_path = Path('/usr/local/bin/docker')
backup_path = Path('/usr/local/bin/docker.original-pre-nexus-wrapper')
marker = b'# nexus-docker-pull-wrapper'
system_docker_path = Path('/usr/bin/docker')
system_backup_path = Path('/usr/bin/docker.original-pre-nexus-wrapper')
system_shim_marker = b'# nexus-docker-shim'

if wrapper_path.exists() and not wrapper_path.is_symlink():
  existing = wrapper_path.read_bytes()
  if marker in existing:
    if backup_path.exists():
      wrapper_path.write_bytes(backup_path.read_bytes())
      backup_path.unlink()
      wrapper_path.chmod(0o755)
    else:
      wrapper_path.unlink()

if system_backup_path.exists():
  if not system_docker_path.exists() or system_docker_path.is_symlink():
    system_docker_path.write_bytes(system_backup_path.read_bytes())
    system_backup_path.unlink()
    system_docker_path.chmod(0o755)
  else:
    existing_system = system_docker_path.read_bytes()
    if system_shim_marker in existing_system:
      system_docker_path.write_bytes(system_backup_path.read_bytes())
      system_backup_path.unlink()
      system_docker_path.chmod(0o755)

hosts_path = Path('/etc/hosts')
if hosts_path.exists():
  start = '# BEGIN nexus-client-registry-blocks'
  end = '# END nexus-client-registry-blocks'
  content = hosts_path.read_text(encoding='utf-8')
  if start in content and end in content:
    pre = content.split(start)[0].rstrip('\n')
    post = content.split(end, 1)[1].lstrip('\n')
    merged = '\n'.join([x for x in [pre, post] if x]).rstrip('\n')
    hosts_path.write_text((merged + '\n') if merged else '', encoding='utf-8')
PY
fi
EOF

chmod 0755 "${PKG_ROOT}/DEBIAN/postinst"
chmod 0755 "${PKG_ROOT}/DEBIAN/postrm"

mkdir -p "${DIST_DIR}"
rm -f "${OUTPUT_DEB}"

if dpkg-deb --help 2>/dev/null | grep -q -- '--root-owner-group'; then
  dpkg-deb --root-owner-group --build "${PKG_ROOT}" "${OUTPUT_DEB}" >/dev/null
else
  dpkg-deb --build "${PKG_ROOT}" "${OUTPUT_DEB}" >/dev/null
fi

echo "Built package: ${OUTPUT_DEB}"
