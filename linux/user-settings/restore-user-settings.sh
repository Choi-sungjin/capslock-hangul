#!/bin/bash
# Put back the user settings saved by apply-user-settings.sh before its first change.
#
#   ./restore-user-settings.sh --dry-run   show what would be restored
#   ./restore-user-settings.sh             restore (run as your normal user, not sudo)
#
# Restores the four whole values (xkb-options, switch-keys, on-keys, off-keys)
# exactly as they were before the first apply. Any later change you made to
# those four settings is replaced too; other settings are not touched.
# The backup file is kept, so apply/restore can be repeated.
# Testing: KEYD_CAPSLOCK_GSETTINGS=<stand-in gsettings>, KEYD_CAPSLOCK_USER_BACKUP=<file>
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GSETTINGS=${KEYD_CAPSLOCK_GSETTINGS:-gsettings}
BACKUP=${KEYD_CAPSLOCK_USER_BACKUP:-$HERE/backup/original-user-settings.tsv}

log() { echo "[keyd-capslock user] $*"; }
die() { echo "[keyd-capslock user] ERROR: $*" >&2; exit 1; }

DRY=0
case "${1:-}" in
	"") ;;
	--dry-run) DRY=1 ;;
	*) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

[ "$(id -u)" -ne 0 ] || die "run as your normal user (not root/sudo); these are per-user settings"
[ -z "${SUDO_USER:-}" ] || die "do not run through sudo; these are per-user settings"
[ -f "$BACKUP" ] || die "no backup at $BACKUP; nothing to restore (apply-user-settings.sh was never applied)"

entries=()
declare -A ORIG CUR
while IFS=$'\t' read -r s k v; do
	case "$s" in ""|"#"*) continue ;; esac
	case "$s/$k" in
		org.gnome.desktop.input-sources/xkb-options|org.freedesktop.ibus.engine.hangul/switch-keys|\
		org.freedesktop.ibus.engine.hangul/on-keys|org.freedesktop.ibus.engine.hangul/off-keys) ;;
		*) die "unexpected entry in $BACKUP: $s $k" ;;
	esac
	[ -n "$v" ] || die "empty value for $s $k in $BACKUP"
	e="$s	$k"
	entries+=("$e")
	ORIG[$e]=$v
	CUR[$e]=$("$GSETTINGS" get "$s" "$k")
done < "$BACKUP"
[ ${#entries[@]} -gt 0 ] || die "$BACKUP has no entries"

changed=0
for e in "${entries[@]}"; do
	if [ "${CUR[$e]}" != "${ORIG[$e]}" ]; then
		log "${e/	/ }: ${CUR[$e]} -> ${ORIG[$e]}"
		changed=1
	fi
done
[ "$changed" -eq 1 ] || { log "settings already equal the saved originals"; exit 0; }
[ "$DRY" -eq 0 ] || { log "dry run: nothing written"; exit 0; }

done_keys=()
rollback() {
	trap - ERR
	echo "[keyd-capslock user] failed; putting back the values from before this run" >&2
	for e in "${done_keys[@]}"; do
		"$GSETTINGS" set "${e%%	*}" "${e#*	}" "${CUR[$e]}" || true
	done
	exit 1
}
trap rollback ERR

for e in "${entries[@]}"; do
	[ "${CUR[$e]}" != "${ORIG[$e]}" ] || continue
	done_keys+=("$e")
	"$GSETTINGS" set "${e%%	*}" "${e#*	}" "${ORIG[$e]}"
	got=$("$GSETTINGS" get "${e%%	*}" "${e#*	}")
	[ "$got" = "${ORIG[$e]}" ] || { echo "[keyd-capslock user] ${e/	/ } reads back as $got" >&2; false; }
done
trap - ERR

log "restored original settings from $BACKUP. Log out and back in once to be sure every app picks it up."
