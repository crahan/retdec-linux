#!/usr/bin/env bash
#
# build-retdec.sh — reproducible, from-scratch RetDec build in a container.
#
# Reproduces the official Linux release toolchain (Ubuntu 22.04 / GCC 11)
# inside a container, so the build is isolated from whatever compiler/Python
# the host happens to have. Works on aarch64 and x86_64 hosts alike — the
# base image is multi-arch and is pulled for the host's native architecture,
# so there is no emulation and the resulting binaries are native.
#
# Output: RetDec-<version>-Linux-<arch>-Release.tar.xz (+ .sha256), with the
# same bin/include/lib/share + LICENSE*/CHANGELOG/README/SECURITY layout as
# the artifacts on https://github.com/avast/retdec/releases.
#
# Usage:
#   ./build-retdec.sh                 # latest master, native arch
#   REF=v5.0 ./build-retdec.sh        # build a specific tag/branch/commit
#   JOBS=4 ./build-retdec.sh          # limit parallelism (lower if low on RAM)
#   OUTPUT_DIR=/tmp/out ./build-retdec.sh
#   STOP_AFTER=image ./build-retdec.sh   # checkpoint: fetch|image|build|package
#
# Env overrides (all optional):
#   REPO_URL   git URL to build from         (default: avast/retdec on GitHub)
#   REF        branch / tag / commit          (default: master)
#   WORKDIR    scratch + source checkout dir  (default: ./build next to script)
#   OUTPUT_DIR where artifacts are written    (default: $WORKDIR/dist)
#   JOBS       parallel compile jobs          (default: nproc)
#   RUNTIME    podman | docker                (default: autodetect)
#   IMAGE      toolchain image tag            (default: retdec-build:ubuntu22.04)
#   BASE_IMAGE base image                     (default: ubuntu:22.04)
#   STOP_AFTER stop after a checkpoint for testing: fetch|image|build|package
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_URL="${REPO_URL:-https://github.com/avast/retdec.git}"
REF="${REF:-master}"
WORKDIR="${WORKDIR:-$SCRIPT_DIR/build}"
OUTPUT_DIR="${OUTPUT_DIR:-$WORKDIR/dist}"
JOBS="${JOBS:-$(nproc)}"
IMAGE="${IMAGE:-retdec-build:ubuntu22.04}"
BASE_IMAGE="${BASE_IMAGE:-docker.io/library/ubuntu:22.04}"
STOP_AFTER="${STOP_AFTER:-}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --- Container runtime --------------------------------------------------------
RUNTIME="${RUNTIME:-}"
if [ -z "$RUNTIME" ]; then
	if command -v podman >/dev/null 2>&1; then RUNTIME=podman
	elif command -v docker >/dev/null 2>&1; then RUNTIME=docker
	else die "need podman or docker installed"; fi
fi
# podman wants :Z for SELinux relabeling of bind mounts; harmless elsewhere.
VOPT=":Z"

# --- Host architecture --------------------------------------------------------
case "$(uname -m)" in
	aarch64|arm64) ARCH_LABEL=aarch64 ;;
	x86_64|amd64)  ARCH_LABEL=x86_64 ;;
	*)             ARCH_LABEL="$(uname -m)" ;;
esac

mkdir -p "$WORKDIR" "$OUTPUT_DIR"
SRC="$WORKDIR/src"

# --- 1. Fetch the latest source ----------------------------------------------
log "Fetching source: $REPO_URL @ $REF"
if [ -d "$SRC/.git" ]; then
	git -C "$SRC" remote set-url origin "$REPO_URL"
	git -C "$SRC" fetch --tags --force --prune origin
else
	git clone "$REPO_URL" "$SRC"
fi
if git -C "$SRC" show-ref --verify --quiet "refs/remotes/origin/$REF"; then
	# REF is a branch -> track the latest remote tip.
	git -C "$SRC" checkout -B "$REF" "origin/$REF"
else
	# REF is a tag or commit.
	git -C "$SRC" checkout --force "$REF"
fi
VER="$(git -C "$SRC" describe --tags 2>/dev/null || git -C "$SRC" rev-parse --short HEAD)"
log "Source ready — version=$VER  arch=$ARCH_LABEL  jobs=$JOBS  runtime=$RUNTIME"
[ "$STOP_AFTER" = fetch ] && { log "STOP_AFTER=fetch — done."; exit 0; }

# --- 2. Build the toolchain image --------------------------------------------
log "Building toolchain image: $IMAGE"
CTX="$(mktemp -d)"
trap 'rm -rf "$CTX"' EXIT
"$RUNTIME" build -t "$IMAGE" -f - "$CTX" <<DOCKERFILE
FROM $BASE_IMAGE
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git ca-certificates \
        openssl libssl-dev python3 python3-dev python3-venv python-is-python3 \
        autoconf automake libtool pkg-config m4 zlib1g-dev \
        upx-ucl xz-utils file \
    && rm -rf /var/lib/apt/lists/*
RUN git config --global --add safe.directory /src
DOCKERFILE
[ "$STOP_AFTER" = image ] && { log "STOP_AFTER=image — done."; exit 0; }

# --- 3. Inner build + smoke-test script (runs inside the container) -----------
INNER="$WORKDIR/.container-build.sh"
cat > "$INNER" <<'INNEREOF'
#!/usr/bin/env bash
set -euxo pipefail
JOBS="${JOBS:-4}"
SRC=/src
BUILD=/src/build
INSTALL=/src/install

# Always build from scratch.
rm -rf "$BUILD" "$INSTALL"
mkdir -p "$BUILD"
cd "$BUILD"
cmake "$SRC" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$INSTALL"
make -j"$JOBS" install

# --- smoke test: decompile a tiny native binary ---
printf 'int add(int a,int b){return a+b;}\nint main(){return add(2,3);}\n' > /tmp/t.c
gcc -O0 /tmp/t.c -o /tmp/t
"$INSTALL/bin/retdec-decompiler" --version || true
"$INSTALL/bin/retdec-decompiler" --cleanup -o /tmp/out.c /tmp/t > /tmp/dec.log 2>&1 \
	|| { echo "SMOKE_TEST_FAILED"; tail -30 /tmp/dec.log; exit 1; }
grep -q 'Retargetable Decompiler' /tmp/out.c \
	&& echo "SMOKE_TEST_OK" \
	|| { echo "SMOKE_TEST_FAILED: unexpected output"; exit 1; }
INNEREOF
chmod +x "$INNER"

# --- 4. Build RetDec ----------------------------------------------------------
log "Building RetDec (long step; ~tens of minutes the first time)"
"$RUNTIME" run --rm \
	-e JOBS="$JOBS" \
	-v "$SRC":/src"$VOPT" \
	-v "$INNER":/build.sh:ro${VOPT:+,${VOPT#:}} \
	"$IMAGE" bash /build.sh
[ "$STOP_AFTER" = build ] && { log "STOP_AFTER=build — done (artifacts in $SRC/install)."; exit 0; }

# --- 5. Package ---------------------------------------------------------------
log "Packaging release tarball"
NAME="RetDec-${VER}-Linux-${ARCH_LABEL}-Release"
"$RUNTIME" run --rm \
	-e NAME="$NAME" \
	-v "$SRC":/src"$VOPT" \
	"$IMAGE" bash -c '
		set -eux
		cd /src
		cp LICENSE* SECURITY.md CHANGELOG.md README.md install/
		cd install
		tar -cJf "/src/${NAME}.tar.xz" *
	'
mv -f "$SRC/${NAME}.tar.xz" "$OUTPUT_DIR/"
( cd "$OUTPUT_DIR" && sha256sum "${NAME}.tar.xz" > "${NAME}.sha256" )

log "DONE"
echo "Artifact: $OUTPUT_DIR/${NAME}.tar.xz"
echo "Checksum: $OUTPUT_DIR/${NAME}.sha256"
cat "$OUTPUT_DIR/${NAME}.sha256"
