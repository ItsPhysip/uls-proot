# uls-proot

Static [termux/proot](https://github.com/termux/proot) builds for
[ULS](https://github.com/Jaseunda/uls). ULS runs a Linux rootfs on an
Android phone over ADB, with proot as the sandbox.

Every binary is built by CI in this repository from a pinned upstream
commit, plus the patches in [`patches/`](patches/). Release assets carry
SHA-256 sums, and ULS's catalog pins those sums.

## Why termux/proot

Until now ULS used stock proot-me v5.3.0. On Android kernels ≥ 5.8 several
path-taking syscalls reach the kernel with the *guest* path untranslated,
and one crashes proot outright. Measured on a Samsung SM-S948B
(kernel 6.12, Android 16), with no ULS compatibility shims loaded:

| Problem | proot-me 5.3.0 | proot-me 5.4.1 | termux/proot |
|---|---|---|---|
| `faccessat2`: pacman, `bash [ -r ]`, glibc `realpath("dir/")` | broken | broken on arm64 (support is x86_64-only) | **fixed** |
| `openat2`: resolves against the host (`/system` opens) | leaks | leaks | **fixed** |
| `readlinkat(fd, "")`: assertion kills the sandbox (systemd-tmpfiles) | crashes | **fixed** | **fixed** |
| `fchmodat2` | broken | broken | broken |

`fchmodat2`, plus the Android SELinux and uid issues that aren't proot's
(socket files, D-Bus peer credentials), are handled by ULS's libc shims.

## Build

```sh
INSTALL_DEPS=1 ./build.sh     # Debian/Ubuntu; output in dist/
```

The script builds static talloc from the Samba tarball (sha256-checked),
fetches termux/proot at the pinned commit, applies `patches/`, and links a
static binary with clang. It then runs a `proot -r / /bin/true` self-test
and writes `dist/BUILDINFO-<arch>`.

| Arch | Built on | Tested on a device |
|---|---|---|
| aarch64 | native arm64 runner | yes (SM-S948B) |
| x86_64 | native x86_64 runner | no |
| armv7 | armhf container under qemu-user | no |

## Releasing

Push a tag named `termux-<short upstream commit>-r<n>` (for example
`termux-d4d2a19-r1`). CI builds all three architectures and publishes a
release whose title is the tag.

## Licence

proot is free software under the GNU General Public License, version 2.
See [`COPYING`](COPYING), which comes from upstream unchanged. The patches
and build files in this repository are distributed under the same licence.
Each patched upstream file carries a notice of what was changed and when.
