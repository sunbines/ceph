#!/usr/bin/env bash
# Build Ceph from this source tree on openEuler.
#
# Modes:
#   (default)   compile native binaries with cmake/ninja
#   --rpm       build source tarball and RPM packages with rpmbuild
#   --both      compile native binaries, then build RPM packages
#
# All dependency downloads go through the remote host below, used as an
# SSH SOCKS5 proxy. Git submodules are fetched the same way: the remote
# host resolves and downloads them, and they are delivered back to this
# build host over the SSH tunnel (no direct internet access needed).
# If the remote host lacks a package that openEuler does not ship
# (libnbd-devel), it is downloaded on the remote and copied back.
#
# Usage:
#   ./script/build-ceph.sh [options]
#
# Options:
#   --rpm                 Build RPM packages instead of native binaries
#   --both                Build native binaries and RPM packages
#   --rpm-version VERSION Version used by the RPM spec (default: 21.3.0)
#   --clean               Remove build/ and build-rpms/ before starting
#   --skip-deps           Do not install build dependencies
#   --skip-submodules     Do not fetch git submodules
#   --jobs N              Parallel build jobs (default: nproc)
#   --build-type TYPE     CMake build type (default: RelWithDebInfo)
#   --with-tests          Build unit tests (default: off)
#   --with-parquet        Build RGW S3 Select parquet support (default: off)
#   -h, --help            Show this help
#
# Environment overrides:
#   REMOTE_HOST REMOTE_USER REMOTE_PASS PROXY_PORT
#   BUILD_DIR LOG_DIR RPM_TOP RPM_VERSION JOBS BUILD_TYPE
#   WITH_TESTS WITH_PARQUET SYNC_SUBMODULES SUBMODULE_JOBS
#   CONFIG_FILE
#
# Configuration file (TOML, optional):
#   conf/build-ceph.toml under the repo root. Environment variables take
#   precedence over it; command-line options take precedence over both.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REMOTE_HOST=${REMOTE_HOST:-43.163.78.103}
REMOTE_USER=${REMOTE_USER:-root}
REMOTE_PASS=${REMOTE_PASS:-}
PROXY_PORT=${PROXY_PORT:-1080}
BUILD_DIR=${BUILD_DIR:-${REPO_ROOT}/build}
RPM_TOP=${RPM_TOP:-${REPO_ROOT}/build-rpms}
RPM_VERSION=${RPM_VERSION:-21.3.0}
BUILD_TYPE=${BUILD_TYPE:-RelWithDebInfo}
JOBS=${JOBS:-$(nproc)}
WITH_TESTS=${WITH_TESTS:-OFF}
WITH_PARQUET=${WITH_PARQUET:-OFF}
SYNC_SUBMODULES=${SYNC_SUBMODULES:-1}
SUBMODULE_JOBS=${SUBMODULE_JOBS:-8}
LOG_DIR=${LOG_DIR:-${REPO_ROOT}/build-logs}
CONFIG_FILE=${CONFIG_FILE:-${REPO_ROOT}/conf/build-ceph.toml}
INSTALL_PREFIX=${INSTALL_PREFIX:-/usr/local}
BUILD_MODE=binary
SKIP_DEPS=0
CLEAN=0
INSTALL_RPMS=0
INSTALL_BINARIES=0
PROXY_PID=""

# Runtime dependencies of the built RPMs that openEuler does not pull in
# automatically. python3-asyncssh is not packaged on openEuler and is
# installed with pip instead (see install_asyncssh).
RUNTIME_DEPS=(
    luarocks python3-cherrypy python3-natsort python3-pyOpenSSL
    python3-routes python3-numpy python3-scikit-learn python3-scipy
    python3-kubernetes python3-jsonpatch resource-agents
)

usage() {
    cat <<'EOF'
Usage: ./script/build-ceph.sh [options]

Modes:
  (default)              Compile native binaries with cmake/ninja
  --rpm                  Build source tarball and RPM packages with rpmbuild
  --both                 Compile native binaries, then build RPM packages
  --install              Install the already-built RPMs (no compilation)

Options:
  --rpm-version VERSION  Version used by the RPM spec (default: 21.3.0)
  --install-rpms         After building RPMs, install them and their runtime deps
  --install-binaries     Compile (if needed), then cmake --install to INSTALL_PREFIX
                         (alias: --install-bin)
  --clean                Remove build/ and build-rpms/ before starting
  --skip-deps            Do not install build dependencies
  --skip-submodules      Do not fetch git submodules
  --jobs N               Parallel build jobs (default: nproc)
  --build-type TYPE      CMake build type (default: RelWithDebInfo)
  --with-tests           Build unit tests (default: off)
  --with-parquet         Build RGW S3 Select parquet support (default: off)
  -h, --help             Show this help

Environment overrides:
  REMOTE_HOST REMOTE_USER REMOTE_PASS PROXY_PORT
  BUILD_DIR LOG_DIR RPM_TOP RPM_VERSION JOBS BUILD_TYPE
  WITH_TESTS WITH_PARQUET SYNC_SUBMODULES SUBMODULE_JOBS
  CONFIG_FILE (default: conf/build-ceph.toml)
  INSTALL_PREFIX (default: /usr/local)

Precedence: command line > environment > conf/build-ceph.toml > defaults

Outputs:
  binaries : build/bin (install with --install-binaries)
  rpm      : build-rpms/RPMS/<arch> and build-rpms/SRPMS (install with --install)
  logs     : build-logs/build-<timestamp>.log
EOF
    exit 0
}

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

format_duration() {
    local s=$1
    if [ "$s" -ge 3600 ]; then
        printf '%dh%02dm%02ds' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
    elif [ "$s" -ge 60 ]; then
        printf '%dm%02ds' $((s / 60)) $((s % 60))
    else
        printf '%ds' "$s"
    fi
}

format_percent() {
    local part=$1 whole=$2 tenth
    if [ "$whole" -gt 0 ]; then
        tenth=$(( part * 1000 / whole ))
    else
        tenth=0
    fi
    printf '(%3d.%d%%)' $((tenth / 10)) $((tenth % 10))
}

die() {
    log "ERROR: $*"
    exit 1
}

load_config() {
    local cfg=${CONFIG_FILE:-${REPO_ROOT}/conf/build-ceph.toml} assignments
    [ -f "$cfg" ] || return 0

    assignments=$(python3 - "$cfg" <<'PY'
import os
import shlex
import sys

try:
    import tomllib
except ModuleNotFoundError:
    sys.exit("python3 >= 3.11 (tomllib) is required for TOML config")

with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)

entries = [
    (("remote", "host"), "REMOTE_HOST", str),
    (("remote", "user"), "REMOTE_USER", str),
    (("remote", "password"), "REMOTE_PASS", str),
    (("remote", "port"), "PROXY_PORT", str),
    (("build", "jobs"), "JOBS", str),
    (("build", "build_type"), "BUILD_TYPE", str),
    (("build", "tests"), "WITH_TESTS", lambda v: "ON" if v else "OFF"),
    (("build", "parquet"), "WITH_PARQUET", lambda v: "ON" if v else "OFF"),
    (("build", "sync_submodules"), "SYNC_SUBMODULES", lambda v: "1" if v else "0"),
    (("build", "submodule_jobs"), "SUBMODULE_JOBS", str),
    (("rpm", "version"), "RPM_VERSION", str),
]

for (section, key), env, conv in entries:
    value = data.get(section, {}).get(key)
    # Environment variables take precedence over the config file.
    if value is None or env in os.environ:
        continue
    if isinstance(value, str) and value == "":
        continue
    print(f"{env}={shlex.quote(conv(value))}")
PY
) || die "failed to parse ${cfg}"

    # Values are shlex-quoted by the parser above.
    eval "$assignments"
    log "Loaded config from ${cfg}"
}

load_config

while [ $# -gt 0 ]; do
    case "$1" in
        --rpm) BUILD_MODE=rpm ;;
        --both) BUILD_MODE=both ;;
        --install) INSTALL_RPMS=1 ;;
        --install-rpms) INSTALL_RPMS=1 ;;
        --install-binaries|--install-bin) INSTALL_BINARIES=1 ;;
        --rpm-version) RPM_VERSION=$2; shift ;;
        --clean) CLEAN=1 ;;
        --skip-deps) SKIP_DEPS=1 ;;
        --skip-submodules) SYNC_SUBMODULES=0 ;;
        --jobs) JOBS=$2; shift ;;
        --build-type) BUILD_TYPE=$2; shift ;;
        --with-tests) WITH_TESTS=ON ;;
        --with-parquet) WITH_PARQUET=ON ;;
        -h|--help) usage ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

# --install alone means "install the RPMs built by an earlier run".
if [ "$INSTALL_RPMS" -eq 1 ] && [ "$BUILD_MODE" = "binary" ]; then
    BUILD_MODE=install
fi

mkdir -p "$LOG_DIR"
# Concurrent runs share build/ and the proxy port; serialize them.
exec 9>"${LOG_DIR}/build.lock"
flock -n 9 || die "another build-ceph.sh run is already in progress"
LOG_FILE="${LOG_DIR}/build-$(date '+%Y%m%d-%H%M%S').log"
SCRIPT_START=$(date +%s)
DEPS_SECONDS=0
SUBMODULE_SECONDS=0
CONFIGURE_SECONDS=0
BUILD_SECONDS=0
RPM_SECONDS=0
INSTALL_SECONDS=0
INSTALL_BIN_SECONDS=0
exec > >(tee -a "$LOG_FILE") 2>&1

SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=3
    -o ExitOnForwardFailure=yes
)

cleanup() {
    if [ -n "$PROXY_PID" ] && kill -0 "$PROXY_PID" 2>/dev/null; then
        log "Stopping SOCKS5 proxy (pid $PROXY_PID)"
        kill "$PROXY_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

proxy_works() {
    curl -s -m 10 -x "socks5h://127.0.0.1:${PROXY_PORT}" -o /dev/null \
        https://mirrors.tuna.tsinghua.edu.cn/ 2>/dev/null
}

start_proxy() {
    command -v sshpass >/dev/null || die "sshpass is required"
    if proxy_works; then
        log "Reusing SOCKS5 proxy on 127.0.0.1:${PROXY_PORT}"
        return
    fi
    if ss -lnt 2>/dev/null | grep -q "127.0.0.1:${PROXY_PORT} "; then
        die "port ${PROXY_PORT} is in use but is not a working SOCKS5 proxy"
    fi
    [ -n "$REMOTE_PASS" ] \
        || die "REMOTE_PASS is not set: export it or set [remote] password in ${CONFIG_FILE}"
    log "Starting SOCKS5 proxy 127.0.0.1:${PROXY_PORT} via ${REMOTE_USER}@${REMOTE_HOST}"
    sshpass -p "$REMOTE_PASS" ssh -D "127.0.0.1:${PROXY_PORT}" -N \
        "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" </dev/null \
        >"${LOG_DIR}/ssh-proxy.log" 2>&1 &
    PROXY_PID=$!
    for _ in $(seq 1 40); do
        kill -0 "$PROXY_PID" 2>/dev/null || die "SSH tunnel exited, see ${LOG_DIR}/ssh-proxy.log"
        if proxy_works; then
            log "SOCKS5 proxy is up"
            return
        fi
        sleep 0.5
    done
    die "SOCKS5 proxy did not become ready"
}

dnf_proxy() {
    dnf --setopt="proxy=socks5h://127.0.0.1:${PROXY_PORT}" \
        --setopt=timeout=60 --setopt=retries=3 \
        --setopt=max_parallel_downloads=10 "$@"
}

ensure_libnbd() {
    rpm -q libnbd-devel >/dev/null 2>&1 && return
    log "libnbd-devel is missing on openEuler; fetching it from ${REMOTE_HOST}"
    local remote_dir local_dir
    remote_dir=$(sshpass -p "$REMOTE_PASS" ssh "${SSH_OPTS[@]}" \
        "${REMOTE_USER}@${REMOTE_HOST}" 'mktemp -d /tmp/libnbd.XXXXXX')
    sshpass -p "$REMOTE_PASS" ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" \
        "dnf download --resolve --destdir '${remote_dir}' libnbd-devel" >/dev/null
    local_dir=$(mktemp -d /tmp/libnbd-rpms.XXXXXX)
    sshpass -p "$REMOTE_PASS" scp "${SSH_OPTS[@]}" \
        "${REMOTE_USER}@${REMOTE_HOST}:${remote_dir}/*x86_64.rpm" "$local_dir"/
    dnf -y install "$local_dir"/*x86_64.rpm
    sshpass -p "$REMOTE_PASS" ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" \
        "rm -rf '${remote_dir}'"
    rm -rf "$local_dir"
}

repair_submodules() {
    # A submodule can look initialized yet have an empty worktree (e.g. an
    # interrupted checkout). Restore only missing tracked files from HEAD.
    local path
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        [ -n "$(git -C "${REPO_ROOT}/${path}" ls-files -d 2>/dev/null)" ] || continue
        log "  repairing ${path}: restoring missing tracked files"
        git -C "${REPO_ROOT}/${path}" ls-files -d -z \
            | xargs -0 -r git -C "${REPO_ROOT}/${path}" checkout --
    done < <(git -C "$REPO_ROOT" submodule status --recursive 2>/dev/null \
             | sed -n 's/^[ +][0-9a-f]* //p' | sed 's/ (.*)$//')
}

sync_submodules() {
    # Git submodules (rocksdb, zstd, arrow, isa-l, ...) are cloned by the
    # remote host's network: git is pointed at the SOCKS5 tunnel, so the
    # objects are fetched through REMOTE_HOST and delivered here.
    [ "$SYNC_SUBMODULES" -eq 1 ] || { log "Skipping submodule sync"; return; }
    [ -d "${REPO_ROOT}/.git" ] || { log "Not a git checkout, skipping submodules"; return; }

    local status
    status=$(git -C "$REPO_ROOT" submodule status --recursive 2>/dev/null || true)
    if [ -z "$status" ]; then
        log "No git submodules defined"
        return
    fi
    if ! grep -q '^-' <<< "$status"; then
        log "Git submodules already initialized"
        repair_submodules
        return
    fi

    log "Fetching git submodules via ${REMOTE_HOST} (SOCKS5 127.0.0.1:${PROXY_PORT}), delivering to this host"
    git -C "$REPO_ROOT" submodule sync --recursive >/dev/null

    # Only touch missing submodules; initialized (possibly modified) ones
    # are left alone.
    local path
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        log "  -> ${path}"
        GIT_TERMINAL_PROMPT=0 \
            git -C "$REPO_ROOT" -c "submodule.fetchJobs=${SUBMODULE_JOBS}" \
            submodule update --init --recursive --progress -- "$path" \
            || die "git submodule update failed for ${path} (check proxy ${REMOTE_HOST})"
    done < <(printf '%s\n' "$status" \
             | sed -n 's/^-[0-9a-f]* //p' \
             | sed 's/ (.*)$//')

    status=$(git -C "$REPO_ROOT" submodule status --recursive 2>/dev/null || true)
    if grep -q '^-' <<< "$status"; then
        die "some submodules are still missing"
    fi
    repair_submodules
    log "Git submodules are ready"
}

install_deps() {
    # openEuler sets %{openEuler} in rpm macros; other rpm distros fall back
    # to the upstream install-deps.sh.
    if [ "$(rpm --eval '%{?openEuler}')" = "2" ]; then
        log "Installing build dependencies for openEuler via proxy"
        local spec="${LOG_DIR}/ceph-builddeps.spec"
        sed -e 's/@//g' "${REPO_ROOT}/ceph.spec.in" \
            | sed -e 's/^%bcond_without crimson/%bcond_with crimson/' \
                  -e 's/^BuildRequires:\tgcc-c++ >= 13.3/BuildRequires:\tgcc-c++/' \
            > "$spec"
        dnf_proxy -y install python3-devel dnf-plugins-core grpc-plugins \
            python3-unversioned-command python3-pysocks
        ensure_libnbd
        dnf_proxy -y builddep "$spec"
    else
        log "Non-openEuler distro detected, delegating to install-deps.sh"
        ( cd "$REPO_ROOT" \
            && export http_proxy="socks5h://127.0.0.1:${PROXY_PORT}" \
            && export https_proxy="$http_proxy" \
            && export all_proxy="$http_proxy" \
            && ./install-deps.sh )
    fi
}

install_binaries() {
    [ -f "${BUILD_DIR}/build.ninja" ] \
        || die "no build tree in ${BUILD_DIR}; run a binary build first"
    log "Installing binaries to ${INSTALL_PREFIX} (cmake --install)"
    cmake --install "$BUILD_DIR"
}

install_asyncssh() {
    python3 -c 'import asyncssh' 2>/dev/null && return
    log "python3-asyncssh is not packaged on openEuler; installing it with pip"
    if python3 -m pip install -q asyncssh; then
        return
    fi
    log "pip through SOCKS failed; downloading asyncssh on ${REMOTE_HOST}"
    local remote_dir local_dir
    remote_dir=$(sshpass -p "$REMOTE_PASS" ssh "${SSH_OPTS[@]}" \
        "${REMOTE_USER}@${REMOTE_HOST}" 'mktemp -d /tmp/asyncssh.XXXXXX')
    sshpass -p "$REMOTE_PASS" ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" \
        "python3 -m pip download -q --dest '${remote_dir}' asyncssh"
    local_dir=$(mktemp -d /tmp/asyncssh-wheels.XXXXXX)
    sshpass -p "$REMOTE_PASS" scp "${SSH_OPTS[@]}" \
        "${REMOTE_USER}@${REMOTE_HOST}:${remote_dir}/"* "$local_dir"/
    python3 -m pip install -q --no-index --find-links "$local_dir" asyncssh
    sshpass -p "$REMOTE_PASS" ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" \
        "rm -rf '${remote_dir}'"
    rm -rf "$local_dir"
}

install_rpms() {
    local rpms=() found f nevra
    local -A newest=()

    # Interrupted rebuilds can leave two copies of the same NEVRA under
    # different arch dirs (e.g. RPMS/x86_64 vs RPMS/noarch). dnf aborts with
    # "cannot install both X from @commandline and X from @commandline"
    # when that happens, so keep only the newest file per package.
    found=$(find "${RPM_TOP}/RPMS" -name '*.rpm' 2>/dev/null | wc -l)
    while IFS= read -r f; do
        nevra=$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$f" 2>/dev/null) \
            || { log "WARNING: skipping unreadable RPM ${f}"; continue; }
        [ -n "$nevra" ] \
            || { log "WARNING: skipping unreadable RPM ${f}"; continue; }
        if [ -z "${newest[$nevra]:-}" ] || [ "$f" -nt "${newest[$nevra]}" ]; then
            newest[$nevra]="$f"
        fi
    done < <(find "${RPM_TOP}/RPMS" -name '*.rpm' -print 2>/dev/null | sort)
    mapfile -t rpms < <(printf '%s\n' "${newest[@]}" | sort)

    [ "${#rpms[@]}" -gt 0 ] \
        || die "no RPMs under ${RPM_TOP}/RPMS; build them with --rpm first"
    if [ "$found" -gt "${#rpms[@]}" ]; then
        log "Ignoring $((found - ${#rpms[@]})) duplicate RPM files (same name-version-release.arch)"
    fi

    log "Installing runtime dependencies of the Ceph RPMs"
    dnf_proxy -y install "${RUNTIME_DEPS[@]}"
    install_asyncssh

    log "Installing ${#rpms[@]} Ceph RPMs from ${RPM_TOP}/RPMS"
    dnf -y install "${rpms[@]}"
    log "Ceph RPMs installed"
}

prepare_cephadm_wheelhouse() {
    # cephadm bundles Jinja2/MarkupSafe/PyYAML with pip, but pip in its
    # temporary venv cannot use a SOCKS proxy. Pre-download the packages
    # through the proxy and let the build install them offline.
    local wh="${REPO_ROOT}/.cache/cephadm-wheelhouse" pat missing=0
    mkdir -p "$wh"
    for pat in 'pip-*.whl' 'jinja2-*.tar.gz' 'MarkupSafe-2.1*.tar.gz' \
               'pyyaml-*cp311*.whl' 'setuptools-*.tar.gz' 'wheel-*.tar.gz' \
               'flit_core-3*.tar.gz'; do
        compgen -G "${wh}/${pat}" >/dev/null || missing=1
    done
    if [ "$missing" -eq 1 ]; then
        log "Preparing offline wheelhouse for cephadm pip dependencies"
        local pipdl=(env -u PIP_NO_INDEX -u PIP_FIND_LINKS pip download -q --dest "$wh")
        "${pipdl[@]}" pip
        "${pipdl[@]}" --no-binary ':all:' 'MarkupSafe>=2.1.3,<2.2'
        "${pipdl[@]}" --no-binary ':all:' 'Jinja2>=3.1.2,<3.2'
        "${pipdl[@]}" 'PyYAML>=6.0,<6.1'
        "${pipdl[@]}" --no-binary ':all:' setuptools wheel packaging
        "${pipdl[@]}" --no-binary ':all:' 'flit_core<4'
    fi
    export PIP_NO_INDEX=1
    export PIP_FIND_LINKS="file://${wh}"
}

configure() {
    local pyver cc cxx catch2=OFF
    pyver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    cc=${CC:-$(command -v gcc)}
    cxx=${CXX:-$(command -v g++)}
    [ "$WITH_TESTS" = "ON" ] && catch2=ON
    log "Configuring Ceph: build type=${BUILD_TYPE}, jobs=${JOBS}, python=${pyver}"
    cmake -S "$REPO_ROOT" -B "$BUILD_DIR" -GNinja \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
        -DCMAKE_C_COMPILER="$cc" \
        -DCMAKE_CXX_COMPILER="$cxx" \
        -DWITH_PYTHON3="$pyver" \
        -DWITH_TESTS="$WITH_TESTS" \
        -DWITH_CATCH2="$catch2" \
        -DWITH_MGR_DASHBOARD_FRONTEND=OFF \
        -DWITH_JAEGER=OFF \
        -DWITH_CRIMSON=OFF \
        -DWITH_RADOSGW=ON \
        -DWITH_RADOSGW_SELECT_PARQUET="$WITH_PARQUET" \
        -DWITH_CEPHFS=ON \
        -DWITH_RBD=ON \
        -DWITH_BLUESTORE=ON
}

build() {
    log "Building with ninja -j${JOBS}"
    ninja -C "$BUILD_DIR" -j "$JOBS"
}

build_rpms() {
    command -v rpmbuild >/dev/null || die "rpmbuild is required (dnf install rpm-build)"

    local rpm_version=$RPM_VERSION rpm_release=0 tarball_name
    if [[ "$RPM_VERSION" == *-* ]]; then
        rpm_version=${RPM_VERSION%%-*}
        rpm_release=${RPM_VERSION#*-}
        rpm_release=${rpm_release//-/.}
    fi
    tarball_name="ceph-${RPM_VERSION}.tar.bz2"

    mkdir -p "$RPM_TOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

    if [ ! -f "${RPM_TOP}/SOURCES/${tarball_name}" ]; then
        log "Generating source tarball ${tarball_name} (dashboard frontend skipped)"
        local shim="${RPM_TOP}/bin" make_dist="${RPM_TOP}/make-dist"
        mkdir -p "$shim"
        cat > "${shim}/wget" <<'WGET_EOF'
#!/bin/sh
# wget stand-in so make-dist downloads through the SOCKS5 proxy via curl.
out=""
url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -O) out=$2; shift 2 ;;
        --no-verbose|-q|--quiet) shift ;;
        *) url=$1; shift ;;
    esac
done
[ -n "$out" ] && [ -n "$url" ] || { echo "wget shim: missing -O or URL" >&2; exit 1; }
exec curl -fsSL --retry 3 -o "$out" "$url"
WGET_EOF
        chmod +x "${shim}/wget"

        # make-dist builds the dashboard frontend with npm. The RPM spec
        # builds with WITH_MGR_DASHBOARD_FRONTEND=OFF, so skip that step.
        sed -e 's/^build_dashboard_frontend$/:/' \
            -e '/^[[:space:]]*dashboard_frontend \\$/d' \
            "${REPO_ROOT}/make-dist" > "$make_dist"
        chmod +x "$make_dist"

        ( cd "$REPO_ROOT" && PATH="${shim}:$PATH" "$make_dist" "$RPM_VERSION" )
        mv "${REPO_ROOT}/${tarball_name}" "${RPM_TOP}/SOURCES/"
    else
        log "Reusing ${RPM_TOP}/SOURCES/${tarball_name}"
    fi

    local spec="${RPM_TOP}/SPECS/ceph.spec"
    sed -e "s/@PROJECT_VERSION@/${rpm_version}/g" \
        -e "s/@RPM_RELEASE@/${rpm_release}/g" \
        -e "s/@TARBALL_BASENAME@/ceph-${RPM_VERSION}/g" \
        "${REPO_ROOT}/ceph.spec.in" > "$spec"
    # openEuler ships GCC 12; the 13.3 floor only matters for LTO builds.
    sed -i 's/^BuildRequires:\tgcc-c++ >= 13.3/BuildRequires:\tgcc-c++/' "$spec"
    # Avoid building the bundled Arrow copy; parquet S3 Select is optional,
    # and skip the Catch2 fetch since tests are disabled.
    sed -i '/^    \$CEPH_EXTRA_CMAKE_ARGS \\$/i\    -DWITH_CATCH2:BOOL=OFF \\\n    -DWITH_RADOSGW_SELECT_PARQUET:BOOL=OFF \\' "$spec"
    grep -q "WITH_RADOSGW_SELECT_PARQUET:BOOL=OFF" "$spec" \
        || die "failed to patch RPM spec"
    grep -q "WITH_CATCH2:BOOL=OFF" "$spec" \
        || die "failed to patch WITH_CATCH2"
    # openEuler's python rpm macros lack py3_shebang_fix; installed
    # scripts already use the system python3 shebang, so make it a no-op.
    sed -i 's|^%{py3_shebang_fix} .*|:|' "$spec"
    if grep -q '^%{py3_shebang_fix}' "$spec"; then
        die "failed to patch py3_shebang_fix"
    fi
    # openEuler does not package python3-asyncssh. It is installed with pip
    # by install_rpms(), so a hard requirement would make dnf refuse to
    # install ceph-mgr-cephadm.
    sed -i 's/^Requires:\([[:space:]]*\)python%{python3_pkgversion}-asyncssh/Recommends:\1python%{python3_pkgversion}-asyncssh/' "$spec"
    grep -q '^Recommends:.*python%{python3_pkgversion}-asyncssh' "$spec" \
        || die "failed to patch asyncssh requirement"
    # openEuler's rpm runs brp-python-bytecompile over the whole buildroot
    # (Fedora does not). The spec already byte-compiles sitelib itself, so
    # the extra pass only leaves stray __pycache__ dirs unpackaged.
    printf '\n%%undefine py_auto_byte_compile\n' >> "$spec"
    # ceph_ec_consistency_checker is installed unconditionally but is only
    # packaged by the ceph-test subpackage, which we disable.
    sed -i '/^%files$/a\%if 0%{without ceph_test_package}\n%exclude %{_bindir}/ceph_ec_consistency_checker\n%endif' "$spec"
    grep -q '%exclude %{_bindir}/ceph_ec_consistency_checker' "$spec" \
        || die "failed to patch ceph-test exclusion"

    log "Running rpmbuild -j${JOBS} (rpmbuild compiles the tree from the tarball)"
    rpmbuild -ba "$spec" \
        --define "_topdir ${RPM_TOP}" \
        --define "_smp_mflags -j${JOBS}" \
        --define "_smp_build_ncpus ${JOBS}" \
        --without crimson \
        --without ceph_test_package \
        --without dwz \
        --without cephadm_bundling

    log "RPM packages:"
    find "${RPM_TOP}/RPMS" "${RPM_TOP}/SRPMS" -name '*.rpm' -print | sort
}

summary() {
    local total
    total=$(( $(date +%s) - SCRIPT_START ))
    if [ "$BUILD_MODE" != "rpm" ] && [ "$BUILD_MODE" != "install" ] \
        && [ -d "${BUILD_DIR}/bin" ]; then
        log "Binaries in ${BUILD_DIR}/bin:"
        ls "${BUILD_DIR}/bin" | tr '\n' ' '
        echo
        if [ -x "${BUILD_DIR}/bin/ceph" ]; then
            "${BUILD_DIR}/bin/ceph" --version || true
        fi
    fi
    if [ "$BUILD_MODE" != "binary" ] && [ -d "${RPM_TOP}/RPMS" ]; then
        log "RPM output: $(find "${RPM_TOP}/RPMS" -name '*.rpm' | wc -l) RPM files in ${RPM_TOP}/RPMS"
    fi
    log "构建完成，耗时统计"
    if [ "$SUBMODULE_SECONDS" -gt 0 ]; then
        printf '  子模块   : %-9s %s\n' "$(format_duration "$SUBMODULE_SECONDS")" "$(format_percent "$SUBMODULE_SECONDS" "$total")"
    fi
    printf '  依赖安装 : %-9s %s\n' "$(format_duration "$DEPS_SECONDS")" "$(format_percent "$DEPS_SECONDS" "$total")"
    if [ "$BUILD_MODE" != "rpm" ] && [ "$BUILD_MODE" != "install" ]; then
        printf '  配置     : %-9s %s\n' "$(format_duration "$CONFIGURE_SECONDS")" "$(format_percent "$CONFIGURE_SECONDS" "$total")"
        printf '  编译     : %-9s %s\n' "$(format_duration "$BUILD_SECONDS")" "$(format_percent "$BUILD_SECONDS" "$total")"
    fi
    if [ "$BUILD_MODE" != "binary" ] && [ "$BUILD_MODE" != "install" ]; then
        printf '  打包     : %-9s %s\n' "$(format_duration "$RPM_SECONDS")" "$(format_percent "$RPM_SECONDS" "$total")"
    fi
    if [ "$INSTALL_BIN_SECONDS" -gt 0 ]; then
        printf '  二进制安装 : %-9s %s\n' "$(format_duration "$INSTALL_BIN_SECONDS")" "$(format_percent "$INSTALL_BIN_SECONDS" "$total")"
    fi
    if [ "$INSTALL_SECONDS" -gt 0 ]; then
        printf '  安装     : %-9s %s\n' "$(format_duration "$INSTALL_SECONDS")" "$(format_percent "$INSTALL_SECONDS" "$total")"
    fi
    printf '  %s\n' "----------------------------------"
    printf '  总计     : %-9s %s\n' "$(format_duration "$total")" "(100.0%)"
    log "Full log: ${LOG_FILE}"
}

log "Ceph build started from ${REPO_ROOT} (mode: ${BUILD_MODE})"
log "Dependencies will be downloaded through ${REMOTE_USER}@${REMOTE_HOST}"

start_proxy
export http_proxy="socks5h://127.0.0.1:${PROXY_PORT}"
export https_proxy="$http_proxy"
export all_proxy="$http_proxy"

if [ "$BUILD_MODE" != "install" ] && [ "$SYNC_SUBMODULES" -eq 1 ]; then
    phase_start=$(date +%s)
    sync_submodules
    SUBMODULE_SECONDS=$(( $(date +%s) - phase_start ))
    log "Submodule sync took $(format_duration "$SUBMODULE_SECONDS")"
else
    log "Skipping submodule sync"
fi

if [ "$BUILD_MODE" != "install" ] && [ "$SKIP_DEPS" -eq 0 ]; then
    phase_start=$(date +%s)
    install_deps
    DEPS_SECONDS=$(( $(date +%s) - phase_start ))
    log "Dependency installation took $(format_duration "$DEPS_SECONDS")"
else
    log "Skipping dependency installation"
fi

if [ "$CLEAN" -eq 1 ]; then
    log "Removing ${BUILD_DIR}"
    rm -rf "$BUILD_DIR"
    if [ "$BUILD_MODE" != "binary" ] && [ "$BUILD_MODE" != "install" ]; then
        log "Removing ${RPM_TOP}"
        rm -rf "$RPM_TOP"
    fi
fi

if [ "$BUILD_MODE" != "rpm" ] && [ "$BUILD_MODE" != "install" ]; then
    prepare_cephadm_wheelhouse

    phase_start=$(date +%s)
    configure
    CONFIGURE_SECONDS=$(( $(date +%s) - phase_start ))
    log "Configuration took $(format_duration "$CONFIGURE_SECONDS")"

    phase_start=$(date +%s)
    build
    BUILD_SECONDS=$(( $(date +%s) - phase_start ))
    log "Compilation took $(format_duration "$BUILD_SECONDS")"
fi

if [ "$INSTALL_BINARIES" -eq 1 ]; then
    phase_start=$(date +%s)
    install_binaries
    INSTALL_BIN_SECONDS=$(( $(date +%s) - phase_start ))
    log "Binary installation took $(format_duration "$INSTALL_BIN_SECONDS")"
fi

if [ "$BUILD_MODE" != "binary" ] && [ "$BUILD_MODE" != "install" ]; then
    phase_start=$(date +%s)
    build_rpms
    RPM_SECONDS=$(( $(date +%s) - phase_start ))
    log "RPM packaging took $(format_duration "$RPM_SECONDS")"
fi

if [ "$INSTALL_RPMS" -eq 1 ]; then
    phase_start=$(date +%s)
    install_rpms
    INSTALL_SECONDS=$(( $(date +%s) - phase_start ))
    log "RPM installation took $(format_duration "$INSTALL_SECONDS")"
fi

summary
