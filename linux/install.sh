#!/bin/bash
# Install keyd-capslock (Caps Lock tap = Hangul, hold = Caps Lock).
#
#   sudo ./install.sh            install or upgrade, enable at boot, start now
#   sudo ./install.sh --check    preflight only, change nothing
#
# Touches only:
#   /usr/local/bin/keyd-capslock
#   /etc/keyd-capslock/default.conf      (kept if you edited it)
#   /etc/systemd/system/keyd-capslock.service
#   /var/lib/keyd-capslock/              (install manifest and backups)
#
# Staging without root (see dev/test-installer.sh). Never touches the host:
#   KEYD_CAPSLOCK_ROOT=<stage dir>  existing directory that does not resolve to /
#   KEYD_CAPSLOCK_SYSTEMCTL, KEYD_CAPSLOCK_PGREP   required stand-in commands
#                                   (the host's systemctl/pgrep are refused)
#   KEYD_CAPSLOCK_SETTLE            seconds to wait before checking the service
set -Eeuo pipefail

NAME=keyd-capslock
UNIT=$NAME.service
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PAYLOAD=$HERE/payload
SETTLE=${KEYD_CAPSLOCK_SETTLE:-2}

BIN=/usr/local/bin/$NAME
CONF_DIR=/etc/$NAME
CONF=$CONF_DIR/default.conf
CONF_DIST=$CONF_DIR/default.conf.dist
UNIT_FILE=/etc/systemd/system/$UNIT
STATE=/var/lib/$NAME
MANIFEST=$STATE/manifest

CHECK_ONLY=0
case "${1:-}" in
	"") ;;
	--check) CHECK_ONLY=1 ;;
	*) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

log() { echo "[$NAME] $*"; }
die() { echo "[$NAME] ERROR: $*" >&2; exit 1; }
r() { echo "$ROOT$1"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

# Hash recorded in the manifest for a path, empty if not owned.
owned_sha() {
	[ -f "$(r "$MANIFEST")" ] || return 0
	awk -v p="$1" '$2 == p { print $1 }' "$(r "$MANIFEST")"
}

# stand_in <env var> <host command>: resolved stand-in path; refuses the host command.
stand_in() {
	local v=${!1:-} p real
	[ -n "$v" ] || die "staging requires $1 (a stand-in for $2); the host's $2 is never used"
	p=$(command -v -- "$v") || die "$1=$v not found"
	p=$(realpath -e -- "$p")
	for real in "$(command -v "$2" 2>/dev/null || true)" /usr/bin/$2 /bin/$2 /usr/sbin/$2 /sbin/$2; do
		if [ -n "$real" ] && [ -e "$real" ] && [ "$p" = "$(realpath -e -- "$real")" ]; then
			die "$1 resolves to the host's $2; staging must use a stand-in"
		fi
	done
	echo "$p"
}

# ---------------------------------------------------------------- preflight

if [ -z "${KEYD_CAPSLOCK_ROOT+x}" ]; then
	[ -z "${KEYD_CAPSLOCK_SYSTEMCTL:-}${KEYD_CAPSLOCK_PGREP:-}" ] ||
		die "KEYD_CAPSLOCK_SYSTEMCTL/KEYD_CAPSLOCK_PGREP are only valid with KEYD_CAPSLOCK_ROOT"
	[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0"
	ROOT=
	SYSTEMCTL=systemctl
	PGREP=pgrep
else
	ROOT=$(realpath -m -- "${KEYD_CAPSLOCK_ROOT:-.}")
	case "$KEYD_CAPSLOCK_ROOT" in /*) ;; *) die "KEYD_CAPSLOCK_ROOT must be an absolute path" ;; esac
	[ "$ROOT" != / ] || die "KEYD_CAPSLOCK_ROOT=$KEYD_CAPSLOCK_ROOT resolves to /; refusing"
	[ -d "$ROOT" ] || die "KEYD_CAPSLOCK_ROOT=$KEYD_CAPSLOCK_ROOT is not an existing directory"
	SYSTEMCTL=$(stand_in KEYD_CAPSLOCK_SYSTEMCTL systemctl)
	PGREP=$(stand_in KEYD_CAPSLOCK_PGREP pgrep)
	log "staging into $ROOT (no host files or services are touched)"
fi

log "checking payload integrity"
(cd "$PAYLOAD" && sha256sum --quiet -c SHA256SUMS) || die "payload does not match payload/SHA256SUMS"

log "checking payload config with the payload binary"
"$PAYLOAD$BIN" check "$PAYLOAD$CONF" || die "payload config is invalid"

log "checking for conflicting key remappers"
conflicts=()
for p in /usr/bin/keyd /usr/local/bin/keyd /usr/sbin/keyd; do
	[ -e "$(r "$p")" ] && conflicts+=("keyd binary $p")
done
for u in keyd.service kanata.service kmonad.service xremap.service evremap.service \
	 keymapperd.service input-remapper.service udevmon.service interception-tools.service; do
	for d in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system /usr/local/lib/systemd/system; do
		[ -e "$(r "$d/$u")" ] && conflicts+=("unit file $d/$u")
	done
	if "$SYSTEMCTL" is-active --quiet "$u" 2>/dev/null; then
		conflicts+=("active service $u")
	fi
done
for p in keyd kanata kmonad xremap evremap keymapperd udevmon; do
	if "$PGREP" -x "$p" >/dev/null 2>&1; then
		conflicts+=("running process $p")
	fi
done
# Names longer than 15 chars (and python scripts) need a command-line match.
if "$PGREP" -f 'input-remapper-(service|reader-service)' >/dev/null 2>&1; then
	conflicts+=("running process input-remapper")
fi
if [ ${#conflicts[@]} -gt 0 ]; then
	printf '[%s] conflict: %s\n' "$NAME" "${conflicts[@]}" >&2
	die "another key remapper is installed or running; stop/remove it first. Nothing was changed."
fi
[ -e "$(r /etc/keyd)" ] && log "note: /etc/keyd exists; it is not used or modified by $NAME"

# Every target must be absent or recorded in our manifest.
for p in "$BIN" "$CONF" "$CONF_DIST" "$UNIT_FILE"; do
	if [ -e "$(r "$p")" ] && [ -z "$(owned_sha "$p")" ]; then
		die "$p exists but was not installed by $NAME; refusing to overwrite. Nothing was changed."
	fi
done
if [ -e "$(r "$CONF_DIR")" ] && [ ! -d "$(r "$CONF_DIR")" ]; then
	die "$CONF_DIR exists and is not a directory. Nothing was changed."
fi

# Keep a config the user edited after a previous install.
KEEP_CONF=0
if [ -f "$(r "$CONF")" ] && [ "$(owned_sha "$CONF")" != "$(sha "$(r "$CONF")")" ]; then
	KEEP_CONF=1
	log "keeping edited $CONF; new default goes to $CONF_DIST"
	"$PAYLOAD$BIN" check "$(r "$CONF")" || die "existing $CONF is invalid with the new binary. Nothing was changed."
fi
# Other *.conf files in the config dir are loaded by the daemon too.
for f in "$(r "$CONF_DIR")"/*.conf; do
	[ -e "$f" ] || continue
	[ "$f" = "$(r "$CONF")" ] && continue
	"$PAYLOAD$BIN" check "$f" || die "$f is invalid. Nothing was changed."
done

if [ "$CHECK_ONLY" -eq 1 ]; then
	log "preflight OK (--check: nothing changed)"
	exit 0
fi

# ------------------------------------------------------------------ install

WAS_ENABLED=0
WAS_ACTIVE=0
"$SYSTEMCTL" is-enabled --quiet "$UNIT" 2>/dev/null && WAS_ENABLED=1
"$SYSTEMCTL" is-active --quiet "$UNIT" 2>/dev/null && WAS_ACTIVE=1

TS=$(date +%Y%m%d-%H%M%S)
BACKUP=$STATE/backup.$TS.$$
CREATED=()     # paths that did not exist before this run
TEMPS=()       # temporary files written next to targets (removed on rollback)
BACKED_UP=()   # paths saved under $BACKUP
STATE_CREATED=0
CONF_DIR_CREATED=0
DONE=0

rollback() {
	local rc=$?
	trap - ERR INT TERM
	[ "$DONE" -eq 1 ] && return
	echo "[$NAME] install failed (exit $rc), rolling back" >&2
	set +e
	"$SYSTEMCTL" stop "$UNIT" >/dev/null 2>&1
	# Disable while the unit file still exists so no enable symlink is left behind.
	[ "$WAS_ENABLED" -eq 0 ] && "$SYSTEMCTL" disable "$UNIT" >/dev/null 2>&1
	for t in "${TEMPS[@]}"; do rm -f "$t"; done
	for p in "${CREATED[@]}"; do rm -f "$(r "$p")"; done
	for p in "${BACKED_UP[@]}"; do
		t="$(r "$p").rollback.$$"
		cp -a "$(r "$BACKUP")$p" "$t" && mv -f "$t" "$(r "$p")"
		rm -f "$t"
	done
	[ -f "$(r "$BACKUP")/manifest" ] && cp -a "$(r "$BACKUP")/manifest" "$(r "$MANIFEST")"
	[ -f "$(r "$BACKUP")/manifest" ] || rm -f "$(r "$MANIFEST")"
	rm -f "$(r "$MANIFEST").new"
	[ "$CONF_DIR_CREATED" -eq 1 ] && rmdir "$(r "$CONF_DIR")" 2>/dev/null
	"$SYSTEMCTL" daemon-reload >/dev/null 2>&1
	[ "$WAS_ENABLED" -eq 1 ] && "$SYSTEMCTL" enable "$UNIT" >/dev/null 2>&1
	[ "$WAS_ACTIVE" -eq 1 ] && "$SYSTEMCTL" start "$UNIT" >/dev/null 2>&1
	"$SYSTEMCTL" reset-failed "$UNIT" >/dev/null 2>&1
	if [ "${#BACKED_UP[@]}" -eq 0 ]; then
		rm -rf "$(r "$BACKUP")"
		[ "$STATE_CREATED" -eq 1 ] && rmdir "$(r "$STATE")" 2>/dev/null
	else
		echo "[$NAME] previous files restored; copies kept in $BACKUP" >&2
	fi
	echo "[$NAME] rollback finished. Logs: journalctl -u $UNIT -b" >&2
	exit 1
}
trap rollback ERR INT TERM

[ -d "$(r "$STATE")" ] || { mkdir -p -m 0755 "$(r "$STATE")"; STATE_CREATED=1; }
mkdir -m 0700 "$(r "$BACKUP")"
[ -f "$(r "$MANIFEST")" ] && cp -a "$(r "$MANIFEST")" "$(r "$BACKUP")/manifest"
[ -d "$(r "$CONF_DIR")" ] || { mkdir -p -m 0755 "$(r "$CONF_DIR")"; CONF_DIR_CREATED=1; }

# put <payload path> <target path> <mode>: atomic replace, backing up the old file.
put() {
	local src=$PAYLOAD$1 dst=$2 mode=$3 tmp
	tmp="$(r "$dst").$NAME-new.$$"
	if [ -f "$(r "$dst")" ] && [ "$(sha "$(r "$dst")")" = "$(sha "$src")" ]; then
		chmod "$mode" "$(r "$dst")"
		return 0
	fi
	if [ -e "$(r "$dst")" ]; then
		mkdir -p "$(r "$BACKUP")$(dirname "$dst")"
		cp -a "$(r "$dst")" "$(r "$BACKUP")$dst"
		BACKED_UP+=("$dst")
	else
		CREATED+=("$dst")
	fi
	TEMPS+=("$tmp")
	if [ -z "$ROOT" ]; then
		install -D -m "$mode" -o root -g root "$src" "$tmp"
	else
		install -D -m "$mode" "$src" "$tmp"
	fi
	mv -f "$tmp" "$(r "$dst")"
}

log "installing files"
put "$BIN" "$BIN" 0755
if [ "$KEEP_CONF" -eq 1 ]; then
	put "$CONF" "$CONF_DIST" 0644
else
	put "$CONF" "$CONF" 0644
	if [ -e "$(r "$CONF_DIST")" ]; then
		mkdir -p "$(r "$BACKUP")$CONF_DIR"
		cp -a "$(r "$CONF_DIST")" "$(r "$BACKUP")$CONF_DIST"
		BACKED_UP+=("$CONF_DIST")
		rm -f "$(r "$CONF_DIST")"
	fi
fi
put "$UNIT_FILE" "$UNIT_FILE" 0644

# Manifest: hashes as installed now (an edited config keeps its old recorded hash
# so it is still recognised as edited next time).
{
	for p in "$BIN" "$UNIT_FILE"; do echo "$(sha "$(r "$p")")  $p"; done
	if [ "$KEEP_CONF" -eq 1 ]; then
		echo "$(owned_sha "$CONF")  $CONF"
		echo "$(sha "$(r "$CONF_DIST")")  $CONF_DIST"
	else
		echo "$(sha "$(r "$CONF")")  $CONF"
	fi
} > "$(r "$MANIFEST").new"
mv -f "$(r "$MANIFEST").new" "$(r "$MANIFEST")"

log "enabling $UNIT at boot and (re)starting it"
"$SYSTEMCTL" daemon-reload
"$SYSTEMCTL" enable "$UNIT"
"$SYSTEMCTL" reset-failed "$UNIT" >/dev/null 2>&1 || true
"$SYSTEMCTL" restart "$UNIT"
sleep "$SETTLE"
"$SYSTEMCTL" is-active --quiet "$UNIT" || { echo "[$NAME] $UNIT is not active" >&2; false; }
"$SYSTEMCTL" is-enabled --quiet "$UNIT" || { echo "[$NAME] $UNIT is not enabled" >&2; false; }

DONE=1
trap - ERR INT TERM
if [ "${#BACKED_UP[@]}" -eq 0 ]; then
	rm -rf "$(r "$BACKUP")"
fi
log "installed. Status: systemctl status $UNIT   Logs: journalctl -u $UNIT -b"
log "emergency exit while running: press Backspace+Escape+Enter together"
