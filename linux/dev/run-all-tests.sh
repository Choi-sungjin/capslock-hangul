#!/bin/bash
# Build the payload and run every non-root verification. Logs go to
# linux/logs/, a one-line-per-step summary to logs/SUMMARY.txt.
set -uo pipefail

OUT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$OUT/.work}
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
export WORK
LOGS=$OUT/logs
SRC=$WORK/build/keyd-src
ORIG=$WORK/build/keyd-orig
TESTS=$OUT/dev/tests
CONF=$OUT/payload/etc/keyd-capslock/default.conf
UNIT=$OUT/payload/etc/systemd/system/keyd-capslock.service

rm -rf "$LOGS"; mkdir -p "$LOGS"
: > "$LOGS/SUMMARY.txt"
nfail=0

strip() { sed 's/\x1b\[[0-9;]*m//g'; }
# step <name> <expect: pass|fail> <command...>
step() {
	local name=$1 expect=$2; shift 2
	local log=$LOGS/$name.log rc res
	{ echo "\$ $*"; "$@"; } 2>&1 | strip > "$log"
	rc=${PIPESTATUS[0]}
	if { [ "$expect" = pass ] && [ "$rc" -eq 0 ]; } || { [ "$expect" = fail ] && [ "$rc" -ne 0 ]; }; then
		res=OK
	else
		res=NG; nfail=$((nfail+1))
	fi
	printf '%-4s %-40s expected=%-4s exit=%s\n' "$res" "$name" "$expect" "$rc" | tee -a "$LOGS/SUMMARY.txt"
}
each() {  # run test-io once per file (fresh engine state each time)
	local bin=$1 conf=$2 rc=0; shift 2
	for f in "$@"; do "$bin" "$conf" "$f" > "$WORK/build/each.out" 2>&1 || rc=1; grep -E 'PASSED|FAILED|^\S+ +\S+ ' "$WORK/build/each.out"; done
	return $rc
}
no_option() { grep -v '^timeout_instant_tap' "$CONF" > "$WORK/build/default-no-option.conf"; echo "$WORK/build/default-no-option.conf"; }
upstream_without() {  # upstream t/*.t minus the given basenames
	local f skip
	for f in "$SRC"/t/*.t; do
		for skip in "$@"; do [ "$(basename "$f")" = "$skip" ] && continue 2; done
		echo "$f"
	done
}

step 00-build-payload pass "$OUT/dev/build-payload.sh"
step 01-binary-info pass bash -c "file '$OUT/payload/usr/local/bin/keyd-capslock'; ldd '$OUT/payload/usr/local/bin/keyd-capslock'; '$OUT/payload/usr/local/bin/keyd-capslock' -v; strings '$OUT/payload/usr/local/bin/keyd-capslock' | grep -E '^/(etc|run|usr)/' ; ! strings '$OUT/payload/usr/local/bin/keyd-capslock' | grep -q /home/"

# Reproduction: the required behaviour fails on unmodified keyd v2.6.0.
NOOPT=$(no_option)
step 10-repro-unpatched-same-ms fail "$ORIG/bin/test-io" "$NOOPT" "$TESTS/capslock/same-ms-then-idle.t"
step 11-unpatched-rejects-option fail "$ORIG/bin/test-io" "$CONF" "$TESTS/capslock/tap.t"
step 12-patched-option-off-unchanged fail "$SRC/bin/test-io" "$NOOPT" "$TESTS/capslock/same-ms-then-idle.t"

# Upstream suite: unmodified and patched builds, default config.
step 20-upstream-94-unpatched pass bash -c "cd '$ORIG' && ./bin/test-io t/test.conf t/*.t"
step 21-upstream-94-patched pass bash -c "cd '$SRC' && ./bin/test-io t/test.conf t/*.t"
step 22-upstream-count pass bash -c "n=\$(ls '$SRC'/t/*.t | wc -l); echo \"\$n test files\"; [ \"\$n\" -eq 94 ]"

# Option on: every upstream test except timeout3.t (its zero-duration press is
# exactly the case the option changes), plus new timeout regression tests.
RCONF=$WORK/build/test-instant.conf
sed 's/^overload_tap_timeout = 5$/overload_tap_timeout = 5\ntimeout_instant_tap = 1/' "$SRC/t/test.conf" > "$RCONF"
step 30-upstream-93-option-on pass each "$SRC/bin/test-io" "$RCONF" $(upstream_without timeout3.t)
step 31-timeout3-differs-option-on fail "$SRC/bin/test-io" "$RCONF" "$SRC/t/timeout3.t"
step 32-timeout-regression-option-on pass each "$SRC/bin/test-io" "$RCONF" "$TESTS"/timeout-regression/*.t

# Caps Lock behaviour with the shipped config.
step 40-config-check pass "$OUT/payload/usr/local/bin/keyd-capslock" check "$CONF"
step 41-capslock-isolated pass each "$SRC/bin/test-io" "$CONF" "$TESTS"/capslock/*.t
step 42-capslock-sequential pass "$SRC/bin/test-io" "$CONF" "$TESTS"/capslock/*.t
step 43-evdev-repeat-path pass "$SRC/bin/evdev-repeat-test" "$CONF"
step 43-evdev-without-option-fails fail "$SRC/bin/evdev-repeat-test" "$NOOPT"

# Invalid configs are rejected by the binary used for preflight.
BAD=$WORK/build/bad; rm -rf "$BAD"; mkdir -p "$BAD"
printf '[ids]\n*\n[main]\ncapslock = timeout(hangeul, 300\n' > "$BAD/syntax.conf"
printf '[ids]\n*\n[main]\ncapslok = timeout(hangeul, 300, capslock)\n' > "$BAD/key.conf"
printf '[ids]\n*\n[global]\ntimeout_instant_tapp = 1\n[main]\n' > "$BAD/option.conf"
for b in syntax key option; do
	step "44-bad-config-$b" fail "$OUT/payload/usr/local/bin/keyd-capslock" check "$BAD/$b.conf"
done

# Unit file: systemd-analyze verify in a staged root (installed by install.sh
# with fake systemctl) that also contains this machine's system units.
VR=$WORK/verify-root
rm -rf "$VR"; mkdir -p "$VR/.fake-systemd" "$VR/usr/lib/systemd"
cp -a /usr/lib/systemd/system "$VR/usr/lib/systemd/"
KEYD_CAPSLOCK_ROOT=$VR KEYD_CAPSLOCK_SYSTEMCTL=$OUT/dev/fake-systemctl KEYD_CAPSLOCK_PGREP=$OUT/dev/fake-pgrep \
	KEYD_CAPSLOCK_SETTLE=0 "$OUT/install.sh" > "$LOGS/50-stage-install-for-verify.log" 2>&1
step 50-systemd-analyze-verify pass systemd-analyze verify --root="$VR" /etc/systemd/system/keyd-capslock.service
step 51-unit-enabled-for-boot pass bash -c "readlink '$VR/etc/systemd/system/multi-user.target.wants/keyd-capslock.service'; grep -E '^(WantedBy|Restart|ExecStartPre|ExecStart|Before)=' '$VR/etc/systemd/system/keyd-capslock.service'"
sed 's|^ExecStart=/usr/local/bin/keyd-capslock$|ExecStart=/usr/local/bin/keyd-capslock-missing|' "$UNIT" > "$VR/etc/systemd/system/keyd-capslock.service"
step 52-verify-catches-bad-unit fail systemd-analyze verify --root="$VR" /etc/systemd/system/keyd-capslock.service
cp "$UNIT" "$VR/etc/systemd/system/keyd-capslock.service"

# Installer / uninstaller logic (staged root, fake systemctl/pgrep).
step 60-installer-staged pass "$OUT/dev/test-installer.sh"
step 61-shell-syntax pass bash -c "for f in '$OUT'/install.sh '$OUT'/uninstall.sh '$OUT'/user-settings/*.sh '$OUT'/dev/*.sh; do bash -n \"\$f\" || exit 1; done"

# User settings (Right Alt = Alt_R): scripts against real gsettings on an isolated
# keyfile store, and offline XKB keymap compiles. The user's dconf is not written.
step 62-user-settings-isolated pass "$OUT/dev/test-user-settings.sh"
step 63-xkb-keymap-offline pass "$OUT/dev/test-xkb-keymap.sh"

# Read-only look at this machine (what install.sh --check would see).
step 70-host-readonly pass bash -c "
	for p in /usr/bin/keyd /usr/local/bin/keyd /etc/keyd /usr/local/bin/keyd-capslock /etc/keyd-capslock /etc/systemd/system/keyd-capslock.service /var/lib/keyd-capslock; do
		[ -e \$p ] && echo \"exists: \$p\" || echo \"absent: \$p\"; done
	systemctl list-unit-files --no-legend 2>/dev/null | grep -iE 'keyd|kanata|kmonad|xremap|evremap|keymapper|input-remapper|udevmon' || echo 'no remapper unit files'
	pgrep -a -x 'keyd|kanata|kmonad|xremap|evremap|keymapperd|udevmon' || echo 'no remapper processes'
	pgrep -af 'input-remapper-(service|reader-service)' || echo 'no input-remapper process'
	ls -l /dev/uinput; grep -E 'CONFIG_INPUT_(UINPUT|EVDEV)=' /boot/config-\$(uname -r)
	systemctl get-default; systemctl is-enabled display-manager.service 2>&1 || true
	xmodmap -pke 2>/dev/null | grep -E '^keycode +(66|130) ' || echo 'no X display'
	gsettings get org.freedesktop.ibus.general.hotkey triggers 2>/dev/null || true
	gsettings get org.freedesktop.ibus.engine.hangul switch-keys 2>/dev/null || true
	gsettings get org.gnome.desktop.input-sources xkb-options 2>/dev/null || true
	xmodmap -pke 2>/dev/null | grep -E '^keycode +108 ' || true"

# Optional: private IBus + Hangul engine receives the Hangul key keyd emits.
if command -v dbus-run-session >/dev/null && command -v ibus-daemon >/dev/null &&
   [ -x /usr/libexec/ibus-engine-hangul ] &&
   python3 -c "import gi; gi.require_version('IBus','1.0')" 2>/dev/null; then
	rm -rf "$WORK/build/isolated-ibus"
	step 80-isolated-ibus-hangul pass env IBUS_TEST_DIR="$WORK/build/isolated-ibus" \
		timeout 60 dbus-run-session -- python3 "$OUT/dev/test-isolated-ibus.py"
	rm -rf "$WORK/build/isolated-ibus-ralt"
	step 81-isolated-ibus-ralt-after pass env IBUS_TEST_DIR="$WORK/build/isolated-ibus-ralt" \
		timeout 60 dbus-run-session -- python3 "$OUT/dev/test-isolated-ibus-ralt.py" after
	step 82-isolated-ibus-ralt-before-control pass env IBUS_TEST_DIR="$WORK/build/isolated-ibus-ralt" \
		timeout 60 dbus-run-session -- python3 "$OUT/dev/test-isolated-ibus-ralt.py" before
else
	printf '%-4s %-40s (ibus-daemon/ibus-engine-hangul/python3-gi missing)\n' SKIP 80-isolated-ibus-hangul | tee -a "$LOGS/SUMMARY.txt"
fi

echo
echo "steps not as expected: $nfail" | tee -a "$LOGS/SUMMARY.txt"
[ "$nfail" -eq 0 ]
