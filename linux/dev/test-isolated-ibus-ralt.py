# Isolated real-IBus check of Right Alt vs Hangul with a given ibus-hangul
# switch-keys value. Same isolation as test-isolated-ibus.py (private ibus-daemon
# on an abstract socket, XDG dirs under $IBUS_TEST_DIR), but GSettings uses a
# keyfile backend there so ibus-engine-hangul reads the switch-keys under test.
# Run inside dbus-run-session. No desktop input is injected; no user settings change.
#
#   python3 test-isolated-ibus-ralt.py after    switch-keys 'Hangul,Shift+space'
#        Alt_R does not switch, Alt_R+a is passed through, Hangul switches
#   python3 test-isolated-ibus-ralt.py before   switch-keys 'Hangul,Alt_R,Shift+space'
#        control: Alt_R does switch (why the user setting must change)
import os, sys, time, subprocess, uuid
from pathlib import Path

mode = sys.argv[1]
switch_keys = {'after': 'Hangul,Shift+space', 'before': 'Hangul,Alt_R,Shift+space'}[mode]
root = Path(os.environ['IBUS_TEST_DIR']) / mode
root.mkdir(parents=True, exist_ok=True)
os.environ.update(IBUS_ADDRESS='unix:abstract=capslock-ralt-' + uuid.uuid4().hex, GIO_USE_VFS='local',
                  GSETTINGS_BACKEND='keyfile', XDG_CACHE_HOME=str(root / 'cache'),
                  XDG_CONFIG_HOME=str(root / 'config'))
os.environ.pop('IBUS_USE_PORTAL', None)
subprocess.run(['gsettings', 'set', 'org.freedesktop.ibus.engine.hangul', 'switch-keys', switch_keys], check=True)
got = subprocess.run(['gsettings', 'get', 'org.freedesktop.ibus.engine.hangul', 'switch-keys'],
                     check=True, capture_output=True, text=True).stdout.strip()
assert got == repr(switch_keys), got

import gi
gi.require_version('IBus', '1.0')
from gi.repository import IBus, GLib
IBus.init()
log = (root / 'daemon.log').open('w')
daemon = subprocess.Popen(['ibus-daemon', '--address=' + os.environ['IBUS_ADDRESS'], '--panel=disable',
                           '--emoji-extension=disable'], stdout=log, stderr=log)
bus = None
engine_proc = None
MOD1 = int(IBus.ModifierType.MOD1_MASK)
RELEASE = int(IBus.ModifierType.RELEASE_MASK)
# evdev keycodes as delivered by X (keycode - 8): a, r, k, space, Right Alt, Hangul
CODE = {ord('a'): 30, ord('r'): 19, ord('k'): 37, ord(' '): 57, IBus.KEY_Alt_R: 100, IBus.KEY_Hangul: 122}
try:
    for _ in range(50):
        bus = IBus.Bus.new()
        if bus.is_connected():
            break
        while GLib.MainContext.default().pending():
            GLib.MainContext.default().iteration(False)
        time.sleep(.1)
    assert bus.is_connected(), 'isolated IBus not connected'
    engine_proc = subprocess.Popen(['/usr/libexec/ibus-engine-hangul', '--ibus'], stdout=log, stderr=log)
    time.sleep(.5)
    ctx = bus.create_input_context('capslock-ralt-verification')
    ctx.set_capabilities(int(IBus.Capabilite.PREEDIT_TEXT | IBus.Capabilite.FOCUS))
    ctx.focus_in()
    assert bus.set_global_engine('hangul'), 'set global engine failed'
    ctx.set_engine('hangul')
    out = []
    passed_through = []
    ctx.connect('commit-text', lambda c, t: out.append(t.get_text()))

    def drain():
        for _ in range(10):
            while GLib.MainContext.default().pending():
                GLib.MainContext.default().iteration(False)
            time.sleep(.01)

    drain()
    engine = None
    for _ in range(50):
        engine = ctx.get_engine()
        if engine and engine.get_name() == 'hangul':
            break
        drain()
    assert engine and engine.get_name() == 'hangul', 'Hangul engine not activated'

    def key(v, state=0):
        code = CODE.get(v, 0)
        handled = ctx.process_key_event(v, code, state)
        ctx.process_key_event(v, code, state | RELEASE)
        drain()
        if not handled:
            if state & MOD1:
                passed_through.append('Alt+' + chr(v))
            elif v < 128:
                out.append(chr(v))
        return handled

    def right_alt_tap():
        h1 = ctx.process_key_event(IBus.KEY_Alt_R, 100, 0)
        h2 = ctx.process_key_event(IBus.KEY_Alt_R, 100, MOD1 | RELEASE)
        drain()
        return h1 or h2

    def text():
        return ''.join(out)

    key(ord('a'))
    assert text() == 'a', repr(out)
    right_alt_tap()
    key(ord('a'))
    if mode == 'after':
        assert text() == 'aa', 'Right Alt switched the input mode: %r' % out
        # Alt held + a: passed to the application as a shortcut, no text.
        ctx.process_key_event(IBus.KEY_Alt_R, 100, 0)
        alt_a = key(ord('a'), MOD1)
        ctx.process_key_event(IBus.KEY_Alt_R, 100, MOD1 | RELEASE)
        drain()
        assert not alt_a and passed_through == ['Alt+a'] and text() == 'aa', (alt_a, passed_through, out)
        key(IBus.KEY_Hangul)
        key(ord('r')); key(ord('k')); key(ord(' '))
        assert text().startswith('aa') and '가' in text(), repr(out)
        # Alt+a in Hangul mode is also passed through.
        ctx.process_key_event(IBus.KEY_Alt_R, 100, 0)
        alt_a2 = key(ord('a'), MOD1)
        ctx.process_key_event(IBus.KEY_Alt_R, 100, MOD1 | RELEASE)
        drain()
        assert not alt_a2 and passed_through == ['Alt+a', 'Alt+a'], (alt_a2, passed_through)
        key(IBus.KEY_Hangul); key(ord('a'))
        assert text() == 'aa가 a', repr(out)
        print("PASS isolated IBus, switch-keys %r: Right Alt does not switch, Alt_R+a passed through,"
              " Hangul switches" % switch_keys)
    else:
        assert text() != 'aa', 'expected Right Alt to switch with Alt_R in switch-keys: %r' % out
        print("PASS control, switch-keys %r: Right Alt switches the input mode (this is what the user"
              " setting removes)" % switch_keys)
    print('Observed text:', repr(text()), 'passed-through shortcuts:', passed_through)
    print('No live desktop input injected; physical keyboard and keyd daemon path not tested.')
    ctx.focus_out(); ctx.destroy()
finally:
    if bus and bus.is_connected():
        bus.exit(False)
    try:
        daemon.wait(timeout=5)
    except subprocess.TimeoutExpired:
        daemon.terminate(); daemon.wait(timeout=5)
    if engine_proc:
        try:
            engine_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            engine_proc.terminate(); engine_proc.wait(timeout=3)
    log.close()
