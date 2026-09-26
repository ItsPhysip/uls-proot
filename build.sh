#!/usr/bin/env bash
# Build a static termux/proot for the current machine's architecture.
#
#   ./build.sh                  build into ./dist
#   INSTALL_DEPS=1 ./build.sh   also apt-get install the build dependencies
#   SKIP_SELFTEST=1 ./build.sh  skip the `proot -r / true` check (use under
#                               qemu-user, which can't run ptrace)
#
# Output: dist/proot-<arch> and dist/BUILDINFO-<arch>
set -euo pipefail

PROOT_REPO=https://github.com/termux/proot.git
PROOT_COMMIT=d4d2a19081c3c07f75250e4ce2980b9fa2f5720f
TALLOC_VERSION=2.5.0
TALLOC_SHA256=912afa237510ae542a7733998eb18a12bcda35ab6729c8e2ddb43e8d0ebab007

here=$(cd "$(dirname "$0")" && pwd)
work=${WORK:-$here/work}
dist=${DIST:-$here/dist}

case "$(uname -m)" in
    aarch64|arm64) arch=aarch64 ;;
    armv7l|armv8l) arch=armv7 ;;
    x86_64)        arch=x86_64 ;;
    *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

if [ "${INSTALL_DEPS:-0}" = 1 ]; then
    sudo=; [ "$(id -u)" = 0 ] || sudo=sudo
    pkgs="build-essential clang curl file git python3 ca-certificates"
    # x86_64 proot also builds a 32-bit loader for i386 guests.
    [ "$arch" = x86_64 ] && pkgs="$pkgs gcc-multilib"
    $sudo apt-get update -qq
    DEBIAN_FRONTEND=noninteractive $sudo apt-get install -qq -y --no-install-recommends $pkgs
fi

rm -rf "$work"
mkdir -p "$work" "$dist"

# --- talloc, static ---------------------------------------------------------
# Ubuntu ships no libtalloc.a, so build it from the Samba release tarball.
cd "$work"
curl -sfLO "https://www.samba.org/ftp/talloc/talloc-$TALLOC_VERSION.tar.gz"
echo "$TALLOC_SHA256  talloc-$TALLOC_VERSION.tar.gz" | sha256sum -c -
tar -xzf "talloc-$TALLOC_VERSION.tar.gz"
cd "talloc-$TALLOC_VERSION"
./configure --disable-python --prefix="$work/talloc-inst" >/dev/null
make >/dev/null
mkdir -p "$work/talloc/lib" "$work/talloc/include"
# waf builds talloc.c twice (library + compat variant). Both export the same
# API; archive the first so there are no duplicate symbols.
obj=$(ls bin/default/talloc.c.*.o | sort -V | head -n1)
ar rcs "$work/talloc/lib/libtalloc.a" "$obj"
cp talloc.h "$work/talloc/include/"

# --- proot ------------------------------------------------------------------
cd "$work"
git init -q proot
cd proot
git fetch -q --depth 1 "$PROOT_REPO" "$PROOT_COMMIT"
git checkout -q FETCH_HEAD
for p in "$here"/patches/*.patch; do
    git apply "$p"
done

LDFLAGS="-static -L$work/talloc/lib" \
CFLAGS="-I$work/talloc/include" \
    make -C src CC=clang proot >"$work/proot-build.log" 2>&1 \
    || { tail -40 "$work/proot-build.log"; exit 1; }

file src/proot | grep -q "statically linked" \
    || { echo "proot is not statically linked" >&2; exit 1; }

if [ "${SKIP_SELFTEST:-0}" != 1 ]; then
    ./src/proot -r / /bin/true
    echo "self-test ok: proot -r / /bin/true"
fi

cp src/proot "$dist/proot-$arch"
{
    echo "arch:          $arch"
    echo "proot:         $PROOT_REPO @ $PROOT_COMMIT"
    echo "patches:       $(cd "$here/patches" && ls *.patch | tr '\n' ' ')"
    echo "talloc:        $TALLOC_VERSION (sha256 $TALLOC_SHA256)"
    echo "compiler:      $(clang --version | head -n1)"
    echo "libc (static): $(ldd --version | head -n1)"
    echo "sha256:        $(sha256sum "$dist/proot-$arch" | cut -d' ' -f1)"
} > "$dist/BUILDINFO-$arch"
cat "$dist/BUILDINFO-$arch"
