#!/bin/bash
# Make Right Alt a real Right Alt in this user's GNOME/IBus settings, so that
# only the Hangul key (sent by Caps Lock via keyd-capslock) switches Korean/English.
#
#   ./apply-user-settings.sh --dry-run   show the change, write nothing
#   ./apply-user-settings.sh             apply (run as your normal user, not sudo)
#
# Changes (other entries are kept in order):
#   org.gnome.desktop.input-sources xkb-options:
#       remove options that take over Right Alt (korean:ralt_hangul, korean:ralt_hanja,
#       lv3:ralt_switch, lv3:ralt_switch_multikey, compose:ralt), add lv3:ralt_alt
#       (Right Alt = Alt_R even with the kr(kr104) layout, which includes ralt_hangul)
#   org.freedesktop.ibus.engine.hangul switch-keys / on-keys / off-keys:
#       remove Alt_R / Meta_R entries; switch-keys keeps (or gains) Hangul
#
# Refuses, before writing anything, if xkb-options contain an option that would
# still redefine Right Alt after lv3:ralt_alt (RALT_CONFLICTS below, checked with
# dev/test-xkb-keymap.sh); change or remove those in Settings first.
#
# The original values are saved once, before the first change, to
#   backup/original-user-settings.tsv (next to this script)
# and restore-user-settings.sh puts them back. gsettings stores to dconf, so the
# change survives logout and reboot.
#
# Testing: KEYD_CAPSLOCK_GSETTINGS=<stand-in gsettings>, KEYD_CAPSLOCK_USER_BACKUP=<file>
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GSETTINGS=${KEYD_CAPSLOCK_GSETTINGS:-gsettings}
BACKUP=${KEYD_CAPSLOCK_USER_BACKUP:-$HERE/backup/original-user-settings.tsv}

XKB_SCHEMA=org.gnome.desktop.input-sources
HANGUL_SCHEMA=org.freedesktop.ibus.engine.hangul
# schema<TAB>key pairs handled by this script, in backup order.
KEYS=(
	"$XKB_SCHEMA	xkb-options"
	"$HANGUL_SCHEMA	switch-keys"
	"$HANGUL_SCHEMA	on-keys"
	"$HANGUL_SCHEMA	off-keys"
)

# Options that make Right Alt something other than Alt_R even after lv3:ralt_alt.
RALT_CONFLICTS="altwin:ctrl_alt_win altwin:swap_alt_win ctrl:ralt_rctrl ctrl:swap_ralt_rctl grp:alt_altgr_toggle grp:switch grp:toggle lv3:alt_switch lv5:ralt_switch lv5:ralt_switch_lock lv5:ralt_switch_lock_cancel"

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

# Only keys present in the installed schemas are handled.
present=()
for e in "${KEYS[@]}"; do
	s=${e%%	*} k=${e#*	}
	if "$GSETTINGS" list-keys "$s" 2>/dev/null | grep -qx -- "$k"; then
		present+=("$e")
	elif [ "$k" = xkb-options ] || [ "$k" = switch-keys ]; then
		die "$s $k not found (GNOME input-sources / ibus-hangul schema missing)"
	fi
done

declare -A CUR NEW
for e in "${present[@]}"; do
	s=${e%%	*} k=${e#*	}
	CUR[$e]=$("$GSETTINGS" get "$s" "$k")
done

bad=$(python3 - "${CUR[$XKB_SCHEMA	xkb-options]}" $RALT_CONFLICTS <<'EOF2'
import ast, sys
t = sys.argv[1].strip()
t = t[len("@as "):] if t.startswith("@as ") else t
print(" ".join(o for o in ast.literal_eval(t) if o in sys.argv[2:]))
EOF2
)
if [ -n "$bad" ]; then
	die "xkb-options contain $bad, which would keep Right Alt from being Alt_R. Nothing was changed. Remove or change it (Settings > Keyboard, or gsettings) and run again."
fi

# New value for one key, computed from its current GVariant text.
compute() {
	python3 - "$1" "$2" <<'EOF'
import ast, sys
key, cur = sys.argv[1], sys.argv[2].strip()
if key == "xkb-options":
    text = cur[len("@as "):] if cur.startswith("@as ") else cur
    opts = ast.literal_eval(text)
    takes_ralt = {"korean:ralt_hangul", "korean:ralt_hanja", "lv3:ralt_switch",
                  "lv3:ralt_switch_multikey", "lv3:ralt_alt", "compose:ralt"}
    new = [o for o in opts if o not in takes_ralt] + ["lv3:ralt_alt"]
    print("[" + ", ".join(repr(o) for o in new) + "]")
else:
    val = ast.literal_eval(cur)
    toks = [t.strip() for t in val.split(",") if t.strip()]
    toks = [t for t in toks if t.split("+")[-1] not in ("Alt_R", "Meta_R")]
    if key == "switch-keys" and "Hangul" not in toks:
        toks.insert(0, "Hangul")
    print(repr(",".join(toks)))
EOF
}

changed=0
for e in "${present[@]}"; do
	k=${e#*	}
	NEW[$e]=$(compute "$k" "${CUR[$e]}")
	if [ "${NEW[$e]}" != "${CUR[$e]}" ]; then
		log "${e/	/ }: ${CUR[$e]} -> ${NEW[$e]}"
		changed=1
	fi
done
for o in $(python3 -c 'import ast,sys; t=sys.argv[1]; t=t[4:] if t.startswith("@as ") else t; print(" ".join(x for x in ast.literal_eval(t) if x.startswith("caps:") or x.startswith("ctrl:nocaps") or x.startswith("ctrl:swapcaps")))' "${CUR[$XKB_SCHEMA	xkb-options]}"); do
	log "note: kept xkb option $o, which changes Caps Lock; hold-for-Caps-Lock may not work with it"
done

if [ "$changed" -eq 0 ]; then
	log "already applied; nothing to change"
	exit 0
fi
if [ "$DRY" -eq 1 ]; then
	log "dry run: nothing written"
	exit 0
fi

# Back up the original values once, before the very first change.
if [ -e "$BACKUP" ]; then
	log "keeping existing original backup $BACKUP"
else
	mkdir -p "$(dirname "$BACKUP")"
	tmp=$BACKUP.tmp.$$
	{
		echo "# keyd-capslock original user settings, saved $(date -Iseconds) for $(id -un)"
		for e in "${present[@]}"; do printf '%s\t%s\n' "$e" "${CUR[$e]}"; done
	} > "$tmp"
	mv -n "$tmp" "$BACKUP"
	rm -f "$tmp"
	log "saved original values to $BACKUP"
fi

done_keys=()
rollback() {
	trap - ERR
	echo "[keyd-capslock user] failed; restoring the values from before this run" >&2
	for e in "${done_keys[@]}"; do
		"$GSETTINGS" set "${e%%	*}" "${e#*	}" "${CUR[$e]}" || true
	done
	exit 1
}
trap rollback ERR

for e in "${present[@]}"; do
	[ "${NEW[$e]}" != "${CUR[$e]}" ] || continue
	done_keys+=("$e")
	"$GSETTINGS" set "${e%%	*}" "${e#*	}" "${NEW[$e]}"
	got=$("$GSETTINGS" get "${e%%	*}" "${e#*	}")
	[ "$got" = "${NEW[$e]}" ] || { echo "[keyd-capslock user] ${e/	/ } reads back as $got" >&2; false; }
done
trap - ERR

log "applied. Right Alt is now Alt_R; Hangul key (Caps Lock tap) switches Korean/English."
log "to be sure every app picks it up, log out and back in once. Undo: $HERE/restore-user-settings.sh"
