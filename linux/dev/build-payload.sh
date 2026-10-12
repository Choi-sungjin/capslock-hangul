#!/bin/bash
# Build payload/usr/local/bin/keyd-capslock and test binaries from a clean
# export of keyd v2.6.0 + keyd-capslock.patch. No root needed; writes only
# under work/build and linux/payload.
set -euo pipefail

OUT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$OUT/.work}
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
KEYD_GIT=${KEYD_GIT:-$WORK/keyd}
TAG=v2.6.0
TAG_COMMIT=7c0aecb8bfd34dc8642bf4eefd2e59c89e61cec3
BUILD=$WORK/build
SRC=$BUILD/keyd-src
ORIG=$BUILD/keyd-orig

if [ ! -e "$KEYD_GIT" ]; then
    git clone --depth 1 --branch "$TAG" https://github.com/rvaiya/keyd.git "$KEYD_GIT"
fi
actual=$(git -C "$KEYD_GIT" rev-parse "$TAG^{commit}")
[ "$actual" = "$TAG_COMMIT" ] || { echo "keyd source revision does not match pinned commit" >&2; exit 1; }

rm -rf "$SRC" "$ORIG"
mkdir -p "$SRC/bin" "$ORIG/bin"
git -C "$KEYD_GIT" archive "$TAG" | tar -x -C "$SRC"
git -C "$KEYD_GIT" archive "$TAG" | tar -x -C "$ORIG"
(cd "$SRC" && patch -p1 --no-backup-if-mismatch < "$OUT/keyd-capslock.patch")

# Same flags as the upstream Makefile "all" target, with isolated paths.
CFLAGS=(
	-DVERSION="\"v2.6.0 (7c0aecb+keyd-capslock)\""
	-Wall -Wextra -Wstrict-prototypes -Wno-unused -std=c11
	-DSOCKET_PATH="\"/run/keyd-capslock/keyd.socket\""
	-DCONFIG_DIR="\"/etc/keyd-capslock\""
	-DDATA_DIR="\"/usr/local/share/keyd-capslock\""
	-D_FORTIFY_SOURCE=2 -D_DEFAULT_SOURCE -Werror=format-security -O3
)
(cd "$SRC" && cc "${CFLAGS[@]}" src/*.c src/vkbd/uinput.c -lpthread -o bin/keyd-capslock)

# Test binaries: upstream test-io (patched and original) and the evdev path test.
TEST_SRCS="src/keyboard.c src/string.c src/macro.c src/config.c src/log.c src/ini.c src/keys.c src/unicode.c"
(cd "$SRC" && cc -DDATA_DIR=\"\" -o bin/test-io t/test-io.c $TEST_SRCS)
(cd "$ORIG" && cc -DDATA_DIR=\"\" -o bin/test-io t/test-io.c $TEST_SRCS)
(cd "$SRC" && cc -std=c11 -D_DEFAULT_SOURCE -DDATA_DIR=\"\" -iquote "$SRC/src" \
	-o bin/evdev-repeat-test "$OUT/dev/evdev-repeat-test.c" src/device.c src/dbg.c src/util.c $TEST_SRCS -lpthread)

install -D -m 0755 "$SRC/bin/keyd-capslock" "$OUT/payload/usr/local/bin/keyd-capslock"
(cd "$OUT/payload" && sha256sum usr/local/bin/keyd-capslock etc/keyd-capslock/default.conf \
	etc/systemd/system/keyd-capslock.service > SHA256SUMS)

echo "built: $OUT/payload/usr/local/bin/keyd-capslock"
"$OUT/payload/usr/local/bin/keyd-capslock" -v
