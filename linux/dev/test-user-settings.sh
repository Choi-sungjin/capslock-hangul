#!/bin/bash
# Test user-settings/apply-user-settings.sh and restore-user-settings.sh with real
# gsettings on an isolated keyfile backend (dev/gsettings-isolated). The user's
# real dconf values are snapshotted before and after and must not change.
set -uo pipefail

OUT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$OUT/.work}
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
T=$WORK/user-settings-test
rm -rf "$T"; mkdir -p "$T"

APPLY=$OUT/user-settings/apply-user-settings.sh
RESTORE=$OUT/user-settings/restore-user-settings.sh
export KEYD_CAPSLOCK_GSETTINGS=$OUT/dev/gsettings-isolated
X=org.gnome.desktop.input-sources
H=org.freedesktop.ibus.engine.hangul

pass=0 fail=0
ok()  { echo "PASS  $*"; pass=$((pass+1)); }
bad() { echo "FAIL  $*"; fail=$((fail+1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

real_snapshot() {
	for k in "$X xkb-options" "$H switch-keys" "$H on-keys" "$H off-keys"; do
		/usr/bin/gsettings get $k
	done
	dconf dump /org/gnome/desktop/input-sources/ 2>/dev/null
	dconf dump /org/freedesktop/ibus/engine/hangul/ 2>/dev/null
}
REAL_BEFORE=$(real_snapshot)

# store <name> <xkb-options> <switch-keys> [on-keys] [off-keys]: fresh isolated store.
store() {
	export ISOLATED_GSETTINGS_DIR=$T/$1
	export KEYD_CAPSLOCK_USER_BACKUP=$T/$1/backup/original-user-settings.tsv
	mkdir -p "$ISOLATED_GSETTINGS_DIR"
	gs set $X xkb-options "$2"
	gs set $H switch-keys "$3"
	gs set $H on-keys "${4:-''}"
	gs set $H off-keys "${5:-'Escape'}"
}
gs() { "$KEYD_CAPSLOCK_GSETTINGS" "$@"; }
get() { gs get "$@"; }

echo "== 1. fixed original-settings fixture in an isolated store"
store real "['korean:ralt_hangul']" "'Hangul,Alt_R,Shift+space'" "''" "'Escape'"
for k in "$X xkb-options" "$H switch-keys" "$H on-keys" "$H off-keys"; do
    read -r schema key <<< "$k"
    printf '%s\t%s\t%s\n' "$schema" "$key" "$(get "$schema" "$key")"
done > "$T/original-fixture.tsv"
before=$(get $X xkb-options; get $H switch-keys)
"$APPLY" --dry-run > "$T/1-dry.log" 2>&1; rc=$?
check "dry run exits 0" [ $rc -eq 0 ]
check "dry run writes nothing (values, no backup)" bash -c "[ \"\$1\" = \"\$2\" ] && [ ! -e '$KEYD_CAPSLOCK_USER_BACKUP' ]" _ "$before" "$(get $X xkb-options; get $H switch-keys)"
"$APPLY" > "$T/1.log" 2>&1; rc=$?
check "apply exits 0" [ $rc -eq 0 ]
check "xkb-options = ['lv3:ralt_alt']" [ "$(get $X xkb-options)" = "['lv3:ralt_alt']" ]
check "switch-keys = 'Hangul,Shift+space'" [ "$(get $H switch-keys)" = "'Hangul,Shift+space'" ]
check "off-keys unchanged" [ "$(get $H off-keys)" = "'Escape'" ]
check "backup holds the original values" diff <(grep -v '^#' "$KEYD_CAPSLOCK_USER_BACKUP") "$T/original-fixture.tsv"
bsum=$(sha256sum < "$KEYD_CAPSLOCK_USER_BACKUP")

echo "== 2. repeat apply is a no-op and keeps the first backup"
"$APPLY" > "$T/2.log" 2>&1; rc=$?
check "second apply exits 0, nothing to change" bash -c "[ $rc -eq 0 ] && grep -q 'already applied' '$T/2.log'"
check "backup unchanged" [ "$bsum" = "$(sha256sum < "$KEYD_CAPSLOCK_USER_BACKUP")" ]

echo "== 3. settings changed later, apply again: new entries kept, backup still original"
gs set $X xkb-options "['lv3:ralt_alt', 'grp:alt_shift_toggle', 'korean:ralt_hangul']"
"$APPLY" > "$T/3.log" 2>&1; rc=$?
check "apply exits 0" [ $rc -eq 0 ]
check "unrelated option kept, ralt_hangul removed" [ "$(get $X xkb-options)" = "['grp:alt_shift_toggle', 'lv3:ralt_alt']" ]
check "backup still the first original" [ "$bsum" = "$(sha256sum < "$KEYD_CAPSLOCK_USER_BACKUP")" ]

echo "== 4. restore puts back the exact originals"
"$RESTORE" --dry-run > "$T/4-dry.log" 2>&1
check "restore --dry-run writes nothing" [ "$(get $X xkb-options)" = "['grp:alt_shift_toggle', 'lv3:ralt_alt']" ]
"$RESTORE" > "$T/4.log" 2>&1; rc=$?
check "restore exits 0" [ $rc -eq 0 ]
check "values equal the fixture originals" bash -c "[ \"\$1\" = \"\$2\" ]" _ "$before" "$(get $X xkb-options; get $H switch-keys)"
"$RESTORE" > "$T/4b.log" 2>&1; rc=$?
check "second restore is a no-op" bash -c "[ $rc -eq 0 ] && grep -q 'already equal' '$T/4b.log'"
check "backup kept after restore" [ -f "$KEYD_CAPSLOCK_USER_BACKUP" ]
"$APPLY" > "$T/4c.log" 2>&1; rc=$?
check "apply again after restore works" bash -c "[ $rc -eq 0 ] && [ \"\$(\"$KEYD_CAPSLOCK_GSETTINGS\" get $H switch-keys)\" = \"'Hangul,Shift+space'\" ]"

echo "== 5. other user options are preserved in order"
store keep "['terminate:ctrl_alt_bksp', 'korean:ralt_hangul', 'compose:rwin']" "'Hangul,Alt_R,Shift+space'"
"$APPLY" > "$T/5.log" 2>&1
check "xkb-options keeps others in order" [ "$(get $X xkb-options)" = "['terminate:ctrl_alt_bksp', 'compose:rwin', 'lv3:ralt_alt']" ]

echo "== 6. edge values"
store edge "@as []" "'Alt_R'" "'Alt_R'" "'Escape,Shift+Alt_R'"
"$APPLY" > "$T/6.log" 2>&1; rc=$?
check "empty xkb-options -> ['lv3:ralt_alt']" bash -c "[ $rc -eq 0 ] && [ \"\$(\"$KEYD_CAPSLOCK_GSETTINGS\" get $X xkb-options)\" = \"['lv3:ralt_alt']\" ]"
check "switch-keys 'Alt_R' -> 'Hangul'" [ "$(get $H switch-keys)" = "'Hangul'" ]
check "on-keys 'Alt_R' -> ''" [ "$(get $H on-keys)" = "''" ]
check "off-keys drops Shift+Alt_R" [ "$(get $H off-keys)" = "'Escape'" ]
store conflict "['lv3:ralt_switch', 'compose:ralt', 'korean:ralt_hanja']" "'Hangul,Shift+space'"
"$APPLY" > "$T/6b.log" 2>&1
check "other Right-Alt takeovers removed" [ "$(get $X xkb-options)" = "['lv3:ralt_alt']" ]
store capsnote "['caps:escape', 'korean:ralt_hangul']" "'Hangul,Alt_R'"
"$APPLY" > "$T/6c.log" 2>&1
check "caps:* option kept with a warning" bash -c "[ \"\$(\"$KEYD_CAPSLOCK_GSETTINGS\" get $X xkb-options)\" = \"['caps:escape', 'lv3:ralt_alt']\" ] && grep -q 'kept xkb option caps:escape' '$T/6c.log'"

echo "== 7. a failed write rolls back this run"
store failing "['korean:ralt_hangul']" "'Hangul,Alt_R,Shift+space'"
FAIL_SET_KEY=switch-keys "$APPLY" > "$T/7.log" 2>&1; rc=$?
check "apply exits != 0" [ $rc -ne 0 ]
check "xkb-options rolled back" [ "$(get $X xkb-options)" = "['korean:ralt_hangul']" ]
check "switch-keys unchanged" [ "$(get $H switch-keys)" = "'Hangul,Alt_R,Shift+space'" ]

echo "== 8. refusals"
store refuse "['korean:ralt_hangul']" "'Hangul,Alt_R,Shift+space'"
snap=$(get $X xkb-options; get $H switch-keys)
for s in "$APPLY" "$RESTORE"; do
	out=$(unshare -r "$s" 2>&1); rc=$?
	check "$(basename "$s") refuses uid 0" bash -c "[ $rc -ne 0 ] && echo \"\$1\" | grep -q 'normal user'" _ "$out"
	out=$(SUDO_USER=someone "$s" 2>&1); rc=$?
	check "$(basename "$s") refuses sudo" [ $rc -ne 0 ]
done
out=$("$RESTORE" 2>&1); rc=$?
check "restore without backup refuses" bash -c "[ $rc -ne 0 ] && echo \"\$1\" | grep -q 'no backup'" _ "$out"
mkdir -p "$(dirname "$KEYD_CAPSLOCK_USER_BACKUP")"
printf 'org.gnome.desktop.interface\tgtk-theme\t%s\n' "'x'" > "$KEYD_CAPSLOCK_USER_BACKUP"
out=$("$RESTORE" 2>&1); rc=$?
check "restore refuses unexpected backup entries" [ $rc -ne 0 ]
check "refused runs changed nothing" [ "$snap" = "$(get $X xkb-options; get $H switch-keys)" ]

echo "== 10. options that would still redefine Right Alt are refused before any write"
CONFLICTS=$(sed -n 's/^RALT_CONFLICTS="\(.*\)"$/\1/p' "$APPLY")
check "conflict list found in apply script (11 options)" [ "$(wc -w <<< "$CONFLICTS")" -eq 11 ]
for o in $CONFLICTS; do
	store "conflict-$o" "['terminate:ctrl_alt_bksp', 'korean:ralt_hangul', '$o']" "'Hangul,Alt_R,Shift+space'"
	snap=$(get $X xkb-options; get $H switch-keys)
	out=$("$APPLY" 2>&1); rc=$?
	check "$o: refused, nothing written, no backup" bash -c "[ $rc -ne 0 ] && echo \"\$1\" | grep -q 'contain $o' && [ \"\$2\" = \"\$3\" ] && [ ! -e '$KEYD_CAPSLOCK_USER_BACKUP' ]" \
		_ "$out" "$snap" "$(get $X xkb-options; get $H switch-keys)"
done
store keep-grp "['grp:alt_shift_toggle', 'korean:ralt_hangul']" "'Hangul,Alt_R,Shift+space'"
"$APPLY" > "$T/10.log" 2>&1; rc=$?
check "grp:alt_shift_toggle (keeps Alt_R) is allowed and kept" bash -c "[ $rc -eq 0 ] && [ \"\$(\"$KEYD_CAPSLOCK_GSETTINGS\" get $X xkb-options)\" = \"['grp:alt_shift_toggle', 'lv3:ralt_alt']\" ]"

echo "== 9. the user's real settings were never touched"
check "real dconf values unchanged" [ "$REAL_BEFORE" = "$(real_snapshot)" ]

echo
echo "user-settings tests: $pass passed, $fail failed"
[ $fail -eq 0 ]
