#!/usr/bin/env bash
# Build a static proot (the ULS fork of termux/proot) for this machine's
# architecture.
#
#   ./build.sh                  build into ./dist
#   INSTALL_DEPS=1 ./build.sh   also apt-get install the build dependencies
#   SKIP_SELFTEST=1 ./build.sh  skip the `proot -r / true` check (use under
#                               qemu-user, which can't run ptrace)
#
# Output: dist/proot-<arch> and dist/BUILDINFO-<arch>
set -euo pipefail

# ULS fork of termux/proot: its `uls` branch, pinned.  Changes and their
# upstream PRs are listed in ULS-CHANGES.md in that repository.
PROOT_REPO=https://github.com/ItsPhysip/proot.git
PROOT_COMMIT=a7d996b0d7a3bcaffa51008f348977956d137e30
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
# waf builds talloc.c and libreplace's replace.c twice each (library +
# compat variant) with the same exports; archive the first of each so there
# are no duplicate symbols.  libreplace supplies rep_* fallbacks for libc
# functions older glibc lacks (e.g. memset_explicit before glibc 2.40).
obj=$(ls bin/default/talloc.c.*.o | sort -V | head -n1)
rep=$(ls bin/default/lib/replace/replace.c.*.o | sort -V | head -n1)
ar rcs "$work/talloc/lib/libtalloc.a" "$obj" "$rep"
cp talloc.h "$work/talloc/include/"

# --- proot ------------------------------------------------------------------
cd "$work"
git init -q proot
cd proot
git fetch -q --depth 1 "$PROOT_REPO" "$PROOT_COMMIT"
git checkout -q FETCH_HEAD
# Local patches on top of the pinned commit, if any.
for p in "$here"/patches/*.patch; do
    [ -e "$p" ] || continue
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
    echo "patches:       $(cd "$here/patches" 2>/dev/null && ls *.patch 2>/dev/null | tr '\n' ' ')"
    echo "talloc:        $TALLOC_VERSION (sha256 $TALLOC_SHA256)"
    echo "compiler:      $(clang --version | head -n1)"
    echo "libc (static): $(ldd --version | head -n1)"
    echo "sha256:        $(sha256sum "$dist/proot-$arch" | cut -d' ' -f1)"
} > "$dist/BUILDINFO-$arch"
cat "$dist/BUILDINFO-$arch"
