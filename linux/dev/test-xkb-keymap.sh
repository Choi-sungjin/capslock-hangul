#!/bin/bash
# Compile XKB keymaps offline with xkbcomp (file in, file out; nothing is loaded
# into any X server) and check what Right Alt (<RALT>, keycode 108), the Hangul
# key (<HNGL>, 130) and Caps Lock (<CAPS>, 66) produce, before and after
# apply-user-settings.sh. Symbol strings are what the evdev rules give for each
# layout/option set; the rules lines used are checked below.
# If an X display is available, the "current" compile is first compared with a
# read-only dump of the live keymap to show the method reproduces it.
set -uo pipefail

OUT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$OUT/.work}
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
T=$WORK/xkb-test
rm -rf "$T"; mkdir -p "$T"
RULES=/usr/share/X11/xkb/rules/evdev

pass=0 fail=0
ok()  { echo "PASS  $*"; pass=$((pass+1)); }
bad() { echo "FAIL  $*"; fail=$((fail+1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

compile() {  # compile <name> <symbols>
	printf 'xkb_keymap {\n xkb_keycodes { include "evdev+aliases(qwerty)" };\n xkb_types { include "complete" };\n xkb_compat { include "complete" };\n xkb_symbols { include "%s" };\n xkb_geometry { include "pc(pc104)" };\n};\n' "$2" > "$T/$1.src"
	xkbcomp -w0 -xkb "$T/$1.src" "$T/$1.xkb"
}
keysyms() {  # keysyms <name> <KEY>: symbols of group 1
	awk -v k="key <$2>" 'index($0,k){f=1} f{b=b $0} f&&/;/&&/}/{print b; exit}' "$T/$1.xkb" |
		sed -E 's/.*\[ *([^]]*)\].*/\1/; s/ +//g'
}
in_mod1() { grep -q "modifier_map Mod1 { <$2> };" "$T/$1.xkb"; }

echo "== rules used for the option strings"
check "rules: korean:ralt_hangul = +kr(ralt_hangul)" grep -qP '^\s+korean:ralt_hangul\s+=\s+\+kr\(ralt_hangul\)$' "$RULES"
check "rules: lv3:ralt_alt = +level3(ralt_alt) (single layout)" grep -qP '^\s+\*\s+lv3:ralt_alt\s+=\s+\+level3\(ralt_alt\)$' "$RULES"
check "rules: lv3:ralt_alt = +level3(ralt_alt):1 / :2 (two layouts)" bash -c "grep -qP '^\s+\*\s+lv3:ralt_alt\s+=\s+\+level3\(ralt_alt\):1$' '$RULES' && grep -qP '^\s+\*\s+lv3:ralt_alt\s+=\s+\+level3\(ralt_alt\):2$' '$RULES'"
check "kr(kr104) itself includes kr(ralt_hangul)" bash -c "awk '/xkb_symbols \"kr104\"/,/^};/' /usr/share/X11/xkb/symbols/kr | grep -q 'include \"kr(ralt_hangul)\"'"

CUR="pc+kr+us:2+inet(evdev)+kr(ralt_hangul)"
compile current "$CUR"

echo "== method check against the live keymap (read-only dump)"
if [ -n "${DISPLAY:-}" ] && xkbcomp -w0 -xkb "$DISPLAY" "$T/live.xkb" 2>/dev/null; then
	live_sym=$(sed -n 's/^xkb_symbols "\(.*\)" {/\1/p' "$T/live.xkb")
	echo "live symbols: $live_sym"
	if [ "$live_sym" = "$CUR" ]; then
		check "offline compile of the live components equals the live keymap" \
			diff <(sed -n '/^xkb_symbols/,$p' "$T/live.xkb" | tail -n +2) <(sed -n '/^xkb_symbols/,$p' "$T/current.xkb" | tail -n +2)
	else
		echo "NOTE  live components differ from '$CUR' (settings changed?); comparison skipped"
	fi
else
	echo "SKIP  no X display; live comparison skipped"
fi

echo "== current settings (kr,us + korean:ralt_hangul): the problem"
check "current: Right Alt (108) = Hangul" [ "$(keysyms current RALT)" = "Hangul" ]

echo "== after apply-user-settings.sh, for each layout GNOME may use"
#        name          symbols (layout + options as resolved by the evdev rules)
cases=(
	"kr-us-after   pc+kr+us:2+inet(evdev)+level3(ralt_alt):1+level3(ralt_alt):2"
	"kr104-after   pc+kr(kr104)+inet(evdev)+level3(ralt_alt)"
	"kr104-us-after pc+kr(kr104)+us:2+inet(evdev)+level3(ralt_alt):1+level3(ralt_alt):2"
)
for c in "${cases[@]}"; do
	read -r n s <<< "$c"
	compile "$n" "$s" || { bad "$n: compile failed"; continue; }
	check "$n: Right Alt (108) = Alt_R,Meta_R" [ "$(keysyms "$n" RALT)" = "Alt_R,Meta_R" ]
	check "$n: Right Alt is in Mod1 (Alt+key works)" in_mod1 "$n" RALT
	check "$n: Hangul key (130) = Hangul" [ "$(keysyms "$n" HNGL)" = "Hangul" ]
	check "$n: Caps Lock (66) = Caps_Lock" [ "$(keysyms "$n" CAPS)" = "Caps_Lock" ]
	check "$n: Left Alt = Alt_L,Meta_L" [ "$(keysyms "$n" LALT)" = "Alt_L,Meta_L" ]
done

echo "== why lv3:ralt_alt is added instead of only removing korean:ralt_hangul"
compile kr104-no-option "pc+kr(kr104)+inet(evdev)"
check "kr(kr104) without options: Right Alt is still Hangul" [ "$(keysyms kr104-no-option RALT)" = "Hangul" ]

echo "== apply-user-settings.sh RALT_CONFLICTS: each one really breaks Right Alt after lv3:ralt_alt"
optsym() {  # symbols the evdev rules give for one option (single layout)
	awk -v o="$1" '/^!/{f=($0 ~ /^! (layout[[:space:]]+)?option[[:space:]]+=[[:space:]]+symbols/); next}
		f && $1=="*" && $2==o {print $4; exit} f && $1==o {print $3; exit}' "$RULES"
}
ralt_ok() {  # Right Alt level 1 is Alt_R and it is in Mod1
	[ "$(keysyms "$1" RALT | cut -d, -f1)" = Alt_R ] && in_mod1 "$1" RALT
}
not_ralt_ok() { ! ralt_ok "$1"; }
CONFLICTS=$(sed -n 's/^RALT_CONFLICTS="\(.*\)"$/\1/p' "$OUT/user-settings/apply-user-settings.sh")
for o in $CONFLICTS; do
	sym=$(optsym "$o"); n=c-${o//:/_}
	[ -n "$sym" ] || { bad "$o: not in rules"; continue; }
	if compile "$n" "pc+kr(kr104)+inet(evdev)+level3(ralt_alt)$sym"; then
		check "$o ($sym): Right Alt is no longer Alt_R -> refusing it is right" not_ralt_ok "$n"
	else
		bad "$o: compile failed"
	fi
done
for o in grp:alt_shift_toggle grp:alts_toggle compose:menu-altgr altwin:meta_alt; do
	n=k-${o//:/_}
	if compile "$n" "pc+kr(kr104)+inet(evdev)+level3(ralt_alt)$(optsym "$o")"; then
		check "$o: Right Alt stays Alt_R -> allowed" ralt_ok "$n"
	else
		bad "$o: compile failed"
	fi
done

echo
echo "xkb tests: $pass passed, $fail failed"
[ $fail -eq 0 ]
