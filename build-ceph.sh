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
#   ./build-ceph.sh [options]
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
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_HOST=${REMOTE_HOST:-43.163.78.103}
REMOTE_USER=${REMOTE_USER:-root}
REMOTE_PASS=${REMOTE_PASS:-}
PROXY_PORT=${PROXY_PORT:-1080}
BUILD_DIR=${BUILD_DIR:-${SCRIPT_DIR}/build}
RPM_TOP=${RPM_TOP:-${SCRIPT_DIR}/build-rpms}
RPM_VERSION=${RPM_VERSION:-21.3.0}
BUILD_TYPE=${BUILD_TYPE:-RelWithDebInfo}
JOBS=${JOBS:-$(nproc)}
WITH_TESTS=${WITH_TESTS:-OFF}
WITH_PARQUET=${WITH_PARQUET:-OFF}
SYNC_SUBMODULES=${SYNC_SUBMODULES:-1}
SUBMODULE_JOBS=${SUBMODULE_JOBS:-8}
LOG_DIR=${LOG_DIR:-${SCRIPT_DIR}/build-logs}
BUILD_MODE=binary
SKIP_DEPS=0
CLEAN=0
PROXY_PID=""

# Local overrides (contains credentials, not committed).
if [ -f "${SCRIPT_DIR}/.build-ceph.local" ]; then
    # shellcheck disable=SC1091
    . "${SCRIPT_DIR}/.build-ceph.local"
fi

usage() {
    cat <<'EOF'
Usage: ./build-ceph.sh [options]

Modes:
  (default)              Compile native binaries with cmake/ninja
  --rpm                  Build source tarball and RPM packages with rpmbuild
  --both                 Compile native binaries, then build RPM packages

Options:
  --rpm-version VERSION  Version used by the RPM spec (default: 21.3.0)
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

Outputs:
  binaries : build/bin
  rpm      : build-rpms/RPMS/<arch> and build-rpms/SRPMS
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

while [ $# -gt 0 ]; do
    case "$1" in
        --rpm) BUILD_MODE=rpm ;;
        --both) BUILD_MODE=both ;;
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

mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/build-$(date '+%Y%m%d-%H%M%S').log"
SCRIPT_START=$(date +%s)
DEPS_SECONDS=0
SUBMODULE_SECONDS=0
CONFIGURE_SECONDS=0
BUILD_SECONDS=0
RPM_SECONDS=0
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
        || die "REMOTE_PASS is not set: export it or create ${SCRIPT_DIR}/.build-ceph.local"
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

sync_submodules() {
    # Git submodules (rocksdb, zstd, arrow, isa-l, ...) are cloned by the
    # remote host's network: git is pointed at the SOCKS5 tunnel, so the
    # objects are fetched through REMOTE_HOST and delivered here.
    [ "$SYNC_SUBMODULES" -eq 1 ] || { log "Skipping submodule sync"; return; }
    [ -d "${SCRIPT_DIR}/.git" ] || { log "Not a git checkout, skipping submodules"; return; }

    local status
    status=$(git -C "$SCRIPT_DIR" submodule status --recursive 2>/dev/null || true)
    if [ -z "$status" ]; then
        log "No git submodules defined"
        return
    fi
    if ! grep -q '^-' <<< "$status"; then
        log "Git submodules already initialized"
        return
    fi

    log "Fetching git submodules via ${REMOTE_HOST} (SOCKS5 127.0.0.1:${PROXY_PORT}), delivering to this host"
    git -C "$SCRIPT_DIR" submodule sync --recursive >/dev/null

    # Only touch missing submodules; initialized (possibly modified) ones
    # are left alone.
    local path
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        log "  -> ${path}"
        GIT_TERMINAL_PROMPT=0 \
            git -C "$SCRIPT_DIR" -c "submodule.fetchJobs=${SUBMODULE_JOBS}" \
            submodule update --init --recursive --progress -- "$path" \
            || die "git submodule update failed for ${path} (check proxy ${REMOTE_HOST})"
    done < <(printf '%s\n' "$status" \
             | sed -n 's/^-[0-9a-f]* //p' \
             | sed 's/ (.*)$//')

    status=$(git -C "$SCRIPT_DIR" submodule status --recursive 2>/dev/null || true)
    if grep -q '^-' <<< "$status"; then
        die "some submodules are still missing"
    fi
    log "Git submodules are ready"
}

install_deps() {
    # openEuler sets %{openEuler} in rpm macros; other rpm distros fall back
    # to the upstream install-deps.sh.
    if [ "$(rpm --eval '%{?openEuler}')" = "2" ]; then
        log "Installing build dependencies for openEuler via proxy"
        local spec="${LOG_DIR}/ceph-builddeps.spec"
        sed -e 's/@//g' "${SCRIPT_DIR}/ceph.spec.in" \
            | sed -e 's/^%bcond_without crimson/%bcond_with crimson/' \
                  -e 's/^BuildRequires:\tgcc-c++ >= 13.3/BuildRequires:\tgcc-c++/' \
            > "$spec"
        dnf_proxy -y install python3-devel dnf-plugins-core grpc-plugins \
            python3-unversioned-command python3-pysocks
        ensure_libnbd
        dnf_proxy -y builddep "$spec"
    else
        log "Non-openEuler distro detected, delegating to install-deps.sh"
        ( cd "$SCRIPT_DIR" \
            && export http_proxy="socks5h://127.0.0.1:${PROXY_PORT}" \
            && export https_proxy="$http_proxy" \
            && export all_proxy="$http_proxy" \
            && ./install-deps.sh )
    fi
}

prepare_cephadm_wheelhouse() {
    # cephadm bundles Jinja2/MarkupSafe/PyYAML with pip, but pip in its
    # temporary venv cannot use a SOCKS proxy. Pre-download the packages
    # through the proxy and let the build install them offline.
    local wh="${SCRIPT_DIR}/.cache/cephadm-wheelhouse" pat missing=0
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
    cmake -S "$SCRIPT_DIR" -B "$BUILD_DIR" -GNinja \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
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
            "${SCRIPT_DIR}/make-dist" > "$make_dist"
        chmod +x "$make_dist"

        ( cd "$SCRIPT_DIR" && PATH="${shim}:$PATH" "$make_dist" "$RPM_VERSION" )
        mv "${SCRIPT_DIR}/${tarball_name}" "${RPM_TOP}/SOURCES/"
    else
        log "Reusing ${RPM_TOP}/SOURCES/${tarball_name}"
    fi

    local spec="${RPM_TOP}/SPECS/ceph.spec"
    sed -e "s/@PROJECT_VERSION@/${rpm_version}/g" \
        -e "s/@RPM_RELEASE@/${rpm_release}/g" \
        -e "s/@TARBALL_BASENAME@/ceph-${RPM_VERSION}/g" \
        "${SCRIPT_DIR}/ceph.spec.in" > "$spec"
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
    if [ "$BUILD_MODE" != "rpm" ] && [ -d "${BUILD_DIR}/bin" ]; then
        log "Binaries in ${BUILD_DIR}/bin:"
        ls "${BUILD_DIR}/bin" | tr '\n' ' '
        echo
        if [ -x "${BUILD_DIR}/bin/ceph" ]; then
            "${BUILD_DIR}/bin/ceph" --version || true
        fi
    fi
    if [ "$BUILD_MODE" != "binary" ] && [ -d "${RPM_TOP}/RPMS" ]; then
        log "RPM output: $(find "${RPM_TOP}/RPMS" -name '*.rpm' | wc -l) packages in ${RPM_TOP}/RPMS"
    fi
    log "构建完成，耗时统计"
    if [ "$SUBMODULE_SECONDS" -gt 0 ]; then
        printf '  子模块   : %-9s %s\n' "$(format_duration "$SUBMODULE_SECONDS")" "$(format_percent "$SUBMODULE_SECONDS" "$total")"
    fi
    printf '  依赖安装 : %-9s %s\n' "$(format_duration "$DEPS_SECONDS")" "$(format_percent "$DEPS_SECONDS" "$total")"
    if [ "$BUILD_MODE" != "rpm" ]; then
        printf '  配置     : %-9s %s\n' "$(format_duration "$CONFIGURE_SECONDS")" "$(format_percent "$CONFIGURE_SECONDS" "$total")"
        printf '  编译     : %-9s %s\n' "$(format_duration "$BUILD_SECONDS")" "$(format_percent "$BUILD_SECONDS" "$total")"
    fi
    if [ "$BUILD_MODE" != "binary" ]; then
        printf '  打包     : %-9s %s\n' "$(format_duration "$RPM_SECONDS")" "$(format_percent "$RPM_SECONDS" "$total")"
    fi
    printf '  %s\n' "----------------------------------"
    printf '  总计     : %-9s %s\n' "$(format_duration "$total")" "(100.0%)"
    log "Full log: ${LOG_FILE}"
}

log "Ceph build started from ${SCRIPT_DIR} (mode: ${BUILD_MODE})"
log "Dependencies will be downloaded through ${REMOTE_USER}@${REMOTE_HOST}"

start_proxy
export http_proxy="socks5h://127.0.0.1:${PROXY_PORT}"
export https_proxy="$http_proxy"
export all_proxy="$http_proxy"

if [ "$SYNC_SUBMODULES" -eq 1 ]; then
    phase_start=$(date +%s)
    sync_submodules
    SUBMODULE_SECONDS=$(( $(date +%s) - phase_start ))
    log "Submodule sync took $(format_duration "$SUBMODULE_SECONDS")"
else
    log "Skipping submodule sync"
fi

if [ "$SKIP_DEPS" -eq 0 ]; then
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
    if [ "$BUILD_MODE" != "binary" ]; then
        log "Removing ${RPM_TOP}"
        rm -rf "$RPM_TOP"
    fi
fi

if [ "$BUILD_MODE" != "rpm" ]; then
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

if [ "$BUILD_MODE" != "binary" ]; then
    phase_start=$(date +%s)
    build_rpms
    RPM_SECONDS=$(( $(date +%s) - phase_start ))
    log "RPM packaging took $(format_duration "$RPM_SECONDS")"
fi

summary
