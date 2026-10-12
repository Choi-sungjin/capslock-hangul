#!/bin/bash
# Exercise install.sh / uninstall.sh against a staged root with fake
# systemctl/pgrep. No root, no real systemd, nothing outside $WORK is touched.
# This checks the scripts' file and state logic only, not a real install.
set -uo pipefail

OUT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$OUT/.work}
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
T=$WORK/installer-test
rm -rf "$T"
mkdir -p "$T"

# Any call to a host systemctl/pgrep found via PATH is recorded here and fails.
mkdir -p "$T/shim"
for c in systemctl pgrep; do
	printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' "$c" "$T/host-calls.log" > "$T/shim/$c"
	chmod +x "$T/shim/$c"
done
# mv stand-in: fails when an argument matches $FAIL_MV_MATCH (extended regex), else real mv.
printf '#!/bin/sh\nif [ -n "$FAIL_MV_MATCH" ]; then for a in "$@"; do echo "$a" | grep -Eq "$FAIL_MV_MATCH" && { echo "mv: injected failure for $a" >&2; exit 1; }; done; fi\nexec /usr/bin/mv "$@"\n' > "$T/shim/mv"
chmod +x "$T/shim/mv"
export PATH=$T/shim:$PATH

export KEYD_CAPSLOCK_SYSTEMCTL=$OUT/dev/fake-systemctl
export KEYD_CAPSLOCK_PGREP=$OUT/dev/fake-pgrep
export KEYD_CAPSLOCK_SETTLE=0
unset FAKE_FAIL FAKE_ACTIVE FAKE_PROCS

pass=0 fail=0
ok()  { echo "PASS  $*"; pass=$((pass+1)); }
bad() { echo "FAIL  $*"; fail=$((fail+1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

# Copy of the package so payload variants can be built.
pkg() {
	local p=$T/pkg-$1
	rm -rf "$p"; mkdir -p "$p"
	cp -a "$OUT/install.sh" "$OUT/uninstall.sh" "$OUT/payload" "$p/"
	echo "$p"
}
resum() { (cd "$1/payload" && sha256sum usr/local/bin/keyd-capslock etc/keyd-capslock/default.conf etc/systemd/system/keyd-capslock.service > SHA256SUMS); }
newroot() { local r=$T/root-$1; rm -rf "$r"; mkdir -p "$r/.fake-systemd"; echo "$r"; }
# Snapshot of a root (excluding the fake systemd call log).
snap() { (cd "$1" && find . -path ./.fake-systemd/calls.log -prune -o -printf '%p %y %m %l\n' | sort; \
	find . -type f ! -path ./.fake-systemd/calls.log -exec sha256sum {} + | sort); }
inst()   { KEYD_CAPSLOCK_ROOT=$1 "$2/install.sh" "${@:3}"; }
uninst() { KEYD_CAPSLOCK_ROOT=$1 "$2/uninstall.sh"; }
active()  { [ -e "$1/.fake-systemd/active.keyd-capslock.service" ]; }
enabled() { [ -L "$1/etc/systemd/system/multi-user.target.wants/keyd-capslock.service" ]; }
clean_after_fail() {  # nothing of ours left, no dangling enable link
	[ ! -e "$1/usr/local/bin/keyd-capslock" ] && [ ! -e "$1/etc/keyd-capslock" ] &&
	[ ! -e "$1/etc/systemd/system/keyd-capslock.service" ] && [ ! -e "$1/var/lib/keyd-capslock" ] &&
	[ ! -e "$1/etc/systemd/system/multi-user.target.wants/keyd-capslock.service" ] && ! active "$1"
}

P=$(pkg main)

echo "== 1. preflight --check changes nothing"
R=$(newroot check)
before=$(snap "$R")
inst "$R" "$P" --check >"$T/1.log" 2>&1; rc=$?
check "--check exits 0" [ $rc -eq 0 ]
check "--check leaves root unchanged" [ "$before" = "$(snap "$R")" ]

echo "== 2. fresh install"
R=$(newroot fresh)
inst "$R" "$P" >"$T/2.log" 2>&1; rc=$?
check "install exits 0" [ $rc -eq 0 ]
check "binary installed 0755" [ "$(stat -c %a "$R/usr/local/bin/keyd-capslock")" = 755 ]
check "config installed 0644" [ "$(stat -c %a "$R/etc/keyd-capslock/default.conf")" = 644 ]
check "unit installed 0644" [ "$(stat -c %a "$R/etc/systemd/system/keyd-capslock.service")" = 644 ]
check "files equal payload" cmp -s "$R/etc/systemd/system/keyd-capslock.service" "$P/payload/etc/systemd/system/keyd-capslock.service"
check "manifest has 3 entries" [ "$(wc -l < "$R/var/lib/keyd-capslock/manifest")" -eq 3 ]
check "enabled at boot (multi-user.target.wants)" enabled "$R"
check "active" active "$R"
check "no backup left on fresh install" [ -z "$(ls -d "$R"/var/lib/keyd-capslock/backup.* 2>/dev/null)" ]
check "only task-owned paths created" [ "$(cd "$R" && find . -mindepth 1 \( -path ./.fake-systemd -o -path ./.fake-systemd/\* \) -prune -o -print | sort | tr '\n' ' ')" = \
	"./etc ./etc/keyd-capslock ./etc/keyd-capslock/default.conf ./etc/systemd ./etc/systemd/system ./etc/systemd/system/keyd-capslock.service ./etc/systemd/system/multi-user.target.wants ./etc/systemd/system/multi-user.target.wants/keyd-capslock.service ./usr ./usr/local ./usr/local/bin ./usr/local/bin/keyd-capslock ./var ./var/lib ./var/lib/keyd-capslock ./var/lib/keyd-capslock/manifest " ]

echo "== 3. repeat install is idempotent"
before=$(snap "$R")
inst "$R" "$P" >"$T/3.log" 2>&1; rc=$?
check "repeat install exits 0" [ $rc -eq 0 ]
check "repeat install leaves files identical" [ "$before" = "$(snap "$R")" ]
check "still enabled and active" bash -c "[ -L '$R/etc/systemd/system/multi-user.target.wants/keyd-capslock.service' ] && [ -e '$R/.fake-systemd/active.keyd-capslock.service' ]"

echo "== 4. edited config is kept on reinstall"
sed -i 's/300/250/' "$R/etc/keyd-capslock/default.conf"
inst "$R" "$P" >"$T/4.log" 2>&1; rc=$?
check "reinstall exits 0" [ $rc -eq 0 ]
check "edited config kept" grep -q 'timeout(hangeul, 250, capslock)' "$R/etc/keyd-capslock/default.conf"
check "new default written to default.conf.dist" cmp -s "$R/etc/keyd-capslock/default.conf.dist" "$P/payload/etc/keyd-capslock/default.conf"
inst "$R" "$P" >"$T/4b.log" 2>&1; rc=$?
check "second reinstall still keeps edit" bash -c "[ $rc -eq 0 ] && grep -q 'hangeul, 250' '$R/etc/keyd-capslock/default.conf'"

echo "== 5. invalid edited config is rejected before any change"
sed -i 's/capslock = timeout(hangeul, 250, capslock)/capslock = timeout(hangeul, 250/' "$R/etc/keyd-capslock/default.conf"
before=$(snap "$R")
inst "$R" "$P" >"$T/5.log" 2>&1; rc=$?
check "install refuses (exit != 0)" [ $rc -ne 0 ]
check "root unchanged" [ "$before" = "$(snap "$R")" ]
grep -q "is invalid" "$T/5.log" && ok "reports invalid config" || bad "reports invalid config"

echo "== 6. invalid payload config is rejected before any change"
P6=$(pkg badconf)
sed -i 's/^capslock = .*/capslock = timeout(hangeul, 300/' "$P6/payload/etc/keyd-capslock/default.conf"; resum "$P6"
R=$(newroot badconf); before=$(snap "$R")
inst "$R" "$P6" >"$T/6.log" 2>&1; rc=$?
check "install refuses" [ $rc -ne 0 ]
check "root unchanged" [ "$before" = "$(snap "$R")" ]

echo "== 7. tampered payload (checksum mismatch) is rejected"
P7=$(pkg tampered)
echo "# x" >> "$P7/payload/etc/systemd/system/keyd-capslock.service"
R=$(newroot tampered); before=$(snap "$R")
inst "$R" "$P7" >"$T/7.log" 2>&1; rc=$?
check "install refuses" [ $rc -ne 0 ]
check "root unchanged" [ "$before" = "$(snap "$R")" ]

echo "== 8. conflicts abort before any change"
for c in binary unitfile active process inputremapper; do
	R=$(newroot "conflict-$c")
	case $c in
		binary) mkdir -p "$R/usr/bin"; echo x > "$R/usr/bin/keyd" ;;
		unitfile) mkdir -p "$R/usr/lib/systemd/system"; echo x > "$R/usr/lib/systemd/system/kanata.service" ;;
	esac
	before=$(snap "$R")
	case $c in
		active) FAKE_ACTIVE=keyd.service inst "$R" "$P" >"$T/8-$c.log" 2>&1; rc=$? ;;
		process) FAKE_PROCS=kmonad inst "$R" "$P" >"$T/8-$c.log" 2>&1; rc=$? ;;
		inputremapper) FAKE_PROCS=/usr/bin/input-remapper-service inst "$R" "$P" >"$T/8-$c.log" 2>&1; rc=$? ;;
		*) inst "$R" "$P" >"$T/8-$c.log" 2>&1; rc=$? ;;
	esac
	check "conflict ($c): refuses and root unchanged" bash -c "[ $rc -ne 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$before" "$(snap "$R")"
done

echo "== 9. foreign file at a target path is never overwritten"
R=$(newroot foreign)
mkdir -p "$R/etc/systemd/system"; echo "mine" > "$R/etc/systemd/system/keyd-capslock.service"
before=$(snap "$R")
inst "$R" "$P" >"$T/9.log" 2>&1; rc=$?
check "install refuses, foreign file untouched" bash -c "[ $rc -ne 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$before" "$(snap "$R")"

echo "== 10. existing /etc/keyd is left alone"
R=$(newroot etckeyd); mkdir -p "$R/etc/keyd"; echo keep > "$R/etc/keyd/default.conf"
inst "$R" "$P" >"$T/10.log" 2>&1; rc=$?
check "install ok and /etc/keyd untouched" bash -c "[ $rc -eq 0 ] && [ \"\$(cat '$R/etc/keyd/default.conf')\" = keep ]"
uninst "$R" "$P" >>"$T/10.log" 2>&1
check "/etc/keyd still there after uninstall" [ -f "$R/etc/keyd/default.conf" ]

echo "== 11. service start failure on fresh install rolls back fully"
R=$(newroot startfail)
FAKE_FAIL=restart inst "$R" "$P" >"$T/11.log" 2>&1; rc=$?
check "install exits != 0" [ $rc -ne 0 ]
check "nothing left behind (files, state, enable link)" clean_after_fail "$R"

echo "== 12. partial failure while copying rolls back"
R=$(newroot partial)
mkdir -p "$R/etc/systemd"; echo "not a dir" > "$R/etc/systemd/system"
inst "$R" "$P" >"$T/12.log" 2>&1; rc=$?
check "install exits != 0" [ $rc -ne 0 ]
check "binary/config/state removed again" bash -c "[ ! -e '$R/usr/local/bin/keyd-capslock' ] && [ ! -e '$R/etc/keyd-capslock' ] && [ ! -e '$R/var/lib/keyd-capslock' ]"
check "blocking file untouched" [ "$(cat "$R/etc/systemd/system")" = "not a dir" ]

echo "== 13. failed upgrade restores the previous version and keeps it running"
R=$(newroot upgrade)
inst "$R" "$P" >"$T/13a.log" 2>&1
old=$(snap "$R")
P13=$(pkg upgrade)
sed -i 's/^RestartSec=2/RestartSec=3/' "$P13/payload/etc/systemd/system/keyd-capslock.service"; resum "$P13"
FAKE_FAIL=restart inst "$R" "$P13" >"$T/13.log" 2>&1; rc=$?
check "upgrade exits != 0" [ $rc -ne 0 ]
check "old unit restored" grep -q '^RestartSec=2' "$R/etc/systemd/system/keyd-capslock.service"
check "still enabled" enabled "$R"
check "restarted (active)" active "$R"
check "files and manifest as before upgrade (plus backup copy)" [ "$(echo "$old" | grep -v backup)" = "$(snap "$R" | grep -v backup)" ]
inst "$R" "$P13" >"$T/13b.log" 2>&1; rc=$?
check "successful upgrade afterwards" bash -c "[ $rc -eq 0 ] && grep -q '^RestartSec=3' '$R/etc/systemd/system/keyd-capslock.service'"

echo "== 14. uninstall removes only our unchanged files"
R=$(newroot uninstall)
inst "$R" "$P" >"$T/14a.log" 2>&1
mkdir -p "$R/etc/systemd/system/other.d"; echo x > "$R/etc/systemd/system/other.service"
uninst "$R" "$P" >"$T/14.log" 2>&1; rc=$?
check "uninstall exits 0" [ $rc -eq 0 ]
check "our files, state and enable link gone, service stopped" clean_after_fail "$R"
check "unrelated files kept" [ -f "$R/etc/systemd/system/other.service" ]

echo "== 15. uninstall keeps an edited config and foreign files in /etc/keyd-capslock"
R=$(newroot uninstall-edited)
inst "$R" "$P" >"$T/15a.log" 2>&1
sed -i 's/300/400/' "$R/etc/keyd-capslock/default.conf"; echo note > "$R/etc/keyd-capslock/notes.txt"
uninst "$R" "$P" >"$T/15.log" 2>&1; rc=$?
check "uninstall exits 0" [ $rc -eq 0 ]
check "binary and unit removed" bash -c "[ ! -e '$R/usr/local/bin/keyd-capslock' ] && [ ! -e '$R/etc/systemd/system/keyd-capslock.service' ]"
check "edited config and notes.txt kept" bash -c "grep -q 400 '$R/etc/keyd-capslock/default.conf' && [ -f '$R/etc/keyd-capslock/notes.txt' ]"
check "manifest keeps only the kept config" [ "$(awk '{print $2}' "$R/var/lib/keyd-capslock/manifest")" = /etc/keyd-capslock/default.conf ]
inst "$R" "$P" >"$T/15b.log" 2>&1; rc=$?
check "reinstall after that keeps the edit" bash -c "[ $rc -eq 0 ] && grep -q 'hangeul, 400' '$R/etc/keyd-capslock/default.conf'"

echo "== 16. uninstall without manifest touches nothing"
R=$(newroot nomanifest)
mkdir -p "$R/usr/local/bin"; echo x > "$R/usr/local/bin/keyd-capslock"
before=$(snap "$R")
uninst "$R" "$P" >"$T/16.log" 2>&1; rc=$?
check "uninstall refuses, root unchanged" bash -c "[ $rc -ne 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$before" "$(snap "$R")"

echo "== 17. installer refuses to run without root when no stage root is given"
out=$(env -u KEYD_CAPSLOCK_ROOT -u KEYD_CAPSLOCK_SYSTEMCTL -u KEYD_CAPSLOCK_PGREP "$P/install.sh" --check 2>&1); rc=$?
if [ "$(id -u)" -ne 0 ]; then
	check "non-root real install refused" bash -c "[ $rc -ne 0 ] && echo \"\$1\" | grep -q 'run as root'" _ "$out"
fi

echo "== 18. stage roots that resolve to / are refused before any command runs"
mkdir -p "$T/rec"
for c in systemctl pgrep; do
	printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 0\n' "$c" "$T/rec/stand-in-calls.log" > "$T/rec/$c-rec"
	chmod +x "$T/rec/$c-rec"
done
ln -sfn / "$T/link-to-root"
for bad in /. // /tmp/.. /usr/.. "$T/link-to-root" "$T/link-to-root/."; do
	for cmd in "install.sh --check" "install.sh" "uninstall.sh"; do
		rm -f "$T/rec/stand-in-calls.log"
		out=$(KEYD_CAPSLOCK_ROOT=$bad KEYD_CAPSLOCK_SYSTEMCTL=$T/rec/systemctl-rec KEYD_CAPSLOCK_PGREP=$T/rec/pgrep-rec \
			$P/$cmd 2>&1); rc=$?
		check "root '$bad' ($cmd): refused, no command run" bash -c \
			"[ $rc -ne 0 ] && echo \"\$1\" | grep -q 'resolves to /' && [ ! -s '$T/rec/stand-in-calls.log' ]" _ "$out"
	done
done
for bad in relative/dir "$T/does-not-exist"; do
	out=$(KEYD_CAPSLOCK_ROOT=$bad "$P/install.sh" --check 2>&1); rc=$?
	check "root '$bad': refused" [ $rc -ne 0 ]
done

echo "== 19. staging without stand-ins, or with the host's commands, is refused"
R=$(newroot nostandin)
before=$(snap "$R")
out=$(env -u KEYD_CAPSLOCK_SYSTEMCTL KEYD_CAPSLOCK_ROOT=$R "$P/install.sh" 2>&1); rc=$?
check "install without KEYD_CAPSLOCK_SYSTEMCTL refused" bash -c "[ $rc -ne 0 ] && echo \"\$1\" | grep -q 'requires KEYD_CAPSLOCK_SYSTEMCTL'" _ "$out"
out=$(env -u KEYD_CAPSLOCK_PGREP KEYD_CAPSLOCK_ROOT=$R "$P/install.sh" 2>&1); rc=$?
check "install without KEYD_CAPSLOCK_PGREP refused" bash -c "[ $rc -ne 0 ] && echo \"\$1\" | grep -q 'requires KEYD_CAPSLOCK_PGREP'" _ "$out"
out=$(env -u KEYD_CAPSLOCK_SYSTEMCTL KEYD_CAPSLOCK_ROOT=$R "$P/uninstall.sh" 2>&1); rc=$?
check "uninstall without KEYD_CAPSLOCK_SYSTEMCTL refused" [ $rc -ne 0 ]
for host in /usr/bin/systemctl systemctl; do
	out=$(KEYD_CAPSLOCK_ROOT=$R KEYD_CAPSLOCK_SYSTEMCTL=$host "$P/install.sh" --check 2>&1); rc=$?
	check "KEYD_CAPSLOCK_SYSTEMCTL=$host refused" bash -c "[ $rc -ne 0 ] && echo \"\$1\" | grep -q \"host's systemctl\"" _ "$out"
done
out=$(KEYD_CAPSLOCK_ROOT=$R KEYD_CAPSLOCK_PGREP=/usr/bin/pgrep "$P/install.sh" --check 2>&1); rc=$?
check "KEYD_CAPSLOCK_PGREP=/usr/bin/pgrep refused" [ $rc -ne 0 ]
out=$(env -u KEYD_CAPSLOCK_ROOT "$P/install.sh" --check 2>&1); rc=$?
check "stand-ins without KEYD_CAPSLOCK_ROOT refused" bash -c "[ $rc -ne 0 ] && echo \"\$1\" | grep -q 'only valid with KEYD_CAPSLOCK_ROOT'" _ "$out"
check "stage root unchanged by refused runs" [ "$before" = "$(snap "$R")" ]

echo "== 20. uninstall ignores manifest entries outside its own paths"
R=$(newroot manifest-foreign)
inst "$R" "$P" >"$T/20a.log" 2>&1
mkdir -p "$R/etc"; echo important > "$R/etc/important.conf"
echo "$(sha256sum "$R/etc/important.conf" | cut -d' ' -f1)  /etc/important.conf" >> "$R/var/lib/keyd-capslock/manifest"
uninst "$R" "$P" >"$T/20.log" 2>&1; rc=$?
check "foreign manifest entry not deleted" bash -c "[ $rc -eq 0 ] && [ -f '$R/etc/important.conf' ] && [ ! -e '$R/usr/local/bin/keyd-capslock' ]"

echo "== 22. mv failure while installing: temp files removed, nothing left behind"
leftovers() { find "$1" \( -name '*.keyd-capslock-new.*' -o -name '*.rollback.*' \) | head -n 5; }
R=$(newroot mvfail-fresh)
FAIL_MV_MATCH='keyd-capslock\.service\.keyd-capslock-new\.' inst "$R" "$P" >"$T/22.log" 2>&1; rc=$?
check "fresh install with failing mv exits != 0" [ $rc -ne 0 ]
check "unit temp file was written before the failure" grep -q 'injected failure for .*keyd-capslock.service.keyd-capslock-new' "$T/22.log"
check "no .keyd-capslock-new / .rollback temp files left" [ -z "$(leftovers "$R")" ]
check "nothing of ours left (files, state, enable link)" clean_after_fail "$R"

echo "== 23. mv failure during an upgrade: old files and service state restored, no temp files"
R=$(newroot mvfail-upgrade)
inst "$R" "$P" >"$T/23a.log" 2>&1
old=$(snap "$R")
P23=$(pkg mvfail)
sed -i 's/^RestartSec=2/RestartSec=4/' "$P23/payload/etc/systemd/system/keyd-capslock.service"; resum "$P23"
cp "$OUT/dev/fake-systemctl" "$T/rec-fake-systemctl"
FAIL_MV_MATCH='keyd-capslock\.service\.keyd-capslock-new\.' inst "$R" "$P23" >"$T/23.log" 2>&1; rc=$?
check "upgrade with failing mv exits != 0" [ $rc -ne 0 ]
check "no temp files left" [ -z "$(leftovers "$R")" ]
check "old unit restored byte-identical" cmp -s "$R/etc/systemd/system/keyd-capslock.service" "$P/payload/etc/systemd/system/keyd-capslock.service"
check "still enabled and active" bash -c "[ -L '$R/etc/systemd/system/multi-user.target.wants/keyd-capslock.service' ] && [ -e '$R/.fake-systemd/active.keyd-capslock.service' ]"
check "files and manifest as before (ignoring backup copies)" [ "$(echo "$old" | grep -v backup)" = "$(snap "$R" | grep -v backup)" ]
inst "$R" "$P23" >"$T/23b.log" 2>&1; rc=$?
check "retry without the failure succeeds" bash -c "[ $rc -eq 0 ] && grep -q '^RestartSec=4' '$R/etc/systemd/system/keyd-capslock.service' && [ -z \"\$(find '$R' -name '*.keyd-capslock-new.*' -o -name '*.rollback.*')\" ]"

echo "== 24. rollback's own copy also fails: its temp file is removed, backup copy kept"
R=$(newroot mvfail-rollback)
inst "$R" "$P" >"$T/24a.log" 2>&1
FAIL_MV_MATCH='\.keyd-capslock-new\.|\.rollback\.' inst "$R" "$P23" >"$T/24.log" 2>&1; rc=$?
check "exits != 0" [ $rc -ne 0 ]
check "no temp files left" [ -z "$(leftovers "$R")" ]
check "previous unit kept in a backup directory" bash -c "ls '$R'/var/lib/keyd-capslock/backup.*/etc/systemd/system/keyd-capslock.service >/dev/null 2>&1 || cmp -s '$R/etc/systemd/system/keyd-capslock.service' '$P/payload/etc/systemd/system/keyd-capslock.service'"
check "reports where the copies are" grep -q 'copies kept in' "$T/24.log"

echo "== 21. no host systemctl/pgrep was ever called during this run"
check "host command log is empty" [ ! -s "$T/host-calls.log" ]

echo
echo "installer tests: $pass passed, $fail failed"
[ $fail -eq 0 ]
