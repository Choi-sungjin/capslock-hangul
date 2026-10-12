#!/bin/bash
# Remove keyd-capslock: stop and disable the service, then delete only files
# listed in /var/lib/keyd-capslock/manifest that are unchanged since install.
# Files you edited (e.g. default.conf) are kept and reported.
#
#   sudo ./uninstall.sh
#
# Staging: same KEYD_CAPSLOCK_ROOT / KEYD_CAPSLOCK_SYSTEMCTL rules as install.sh
# (root must not resolve to /, a stand-in systemctl is required).
set -Eeuo pipefail

NAME=keyd-capslock
UNIT=$NAME.service

CONF_DIR=/etc/$NAME
UNIT_FILE=/etc/systemd/system/$UNIT
STATE=/var/lib/$NAME
MANIFEST=$STATE/manifest

log() { echo "[$NAME] $*"; }
die() { echo "[$NAME] ERROR: $*" >&2; exit 1; }
r() { echo "$ROOT$1"; }

# Only these paths are ever removed, whatever the manifest says.
OWNED="/usr/local/bin/$NAME $CONF_DIR/default.conf $CONF_DIR/default.conf.dist $UNIT_FILE"

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

if [ -z "${KEYD_CAPSLOCK_ROOT+x}" ]; then
	[ -z "${KEYD_CAPSLOCK_SYSTEMCTL:-}" ] || die "KEYD_CAPSLOCK_SYSTEMCTL is only valid with KEYD_CAPSLOCK_ROOT"
	[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0"
	ROOT=
	SYSTEMCTL=systemctl
else
	ROOT=$(realpath -m -- "${KEYD_CAPSLOCK_ROOT:-.}")
	case "$KEYD_CAPSLOCK_ROOT" in /*) ;; *) die "KEYD_CAPSLOCK_ROOT must be an absolute path" ;; esac
	[ "$ROOT" != / ] || die "KEYD_CAPSLOCK_ROOT=$KEYD_CAPSLOCK_ROOT resolves to /; refusing"
	[ -d "$ROOT" ] || die "KEYD_CAPSLOCK_ROOT=$KEYD_CAPSLOCK_ROOT is not an existing directory"
	SYSTEMCTL=$(stand_in KEYD_CAPSLOCK_SYSTEMCTL systemctl)
	log "staging in $ROOT (no host files or services are touched)"
fi

[ -f "$(r "$MANIFEST")" ] || die "$MANIFEST not found: nothing installed by $NAME (no files touched)"

if awk '{ print $2 }' "$(r "$MANIFEST")" | grep -qx "$UNIT_FILE" && [ -e "$(r "$UNIT_FILE")" ]; then
	log "stopping and disabling $UNIT"
	"$SYSTEMCTL" disable --now "$UNIT" || die "could not stop/disable $UNIT; no files removed"
fi

kept=()
while read -r hash path; do
	[ -n "$path" ] || continue
	case " $OWNED " in *" $path "*) ;; *) log "ignoring unexpected manifest entry $path"; continue ;; esac
	f=$(r "$path")
	if [ ! -e "$f" ]; then
		continue
	elif [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$hash" ]; then
		rm -f "$f"
		log "removed $path"
	else
		kept+=("$hash  $path")
		log "kept $path (changed since install)"
	fi
done < "$(r "$MANIFEST")"

rmdir "$(r "$CONF_DIR")" 2>/dev/null || true
"$SYSTEMCTL" daemon-reload
"$SYSTEMCTL" reset-failed "$UNIT" >/dev/null 2>&1 || true

rm -rf "$(r "$STATE")"/backup.*
if [ ${#kept[@]} -gt 0 ]; then
	# Keep ownership records so a later install/uninstall still recognises them.
	printf '%s\n' "${kept[@]}" > "$(r "$MANIFEST")"
	log "done; kept files are listed in $MANIFEST"
else
	rm -f "$(r "$MANIFEST")"
	rmdir "$(r "$STATE")" 2>/dev/null || true
	log "done"
fi
