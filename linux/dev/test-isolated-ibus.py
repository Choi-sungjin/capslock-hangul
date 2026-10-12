# Isolated real-IBus check (from the requester's work/test-isolated-ibus.py): a private
# ibus-daemon + ibus-engine-hangul on an abstract socket, memory GSettings backend and
# XDG dirs under $IBUS_TEST_DIR. Sends the keyd output key (Hangul keysym, evdev 122)
# to an input context and checks Latin -> Hangul -> Latin. Run inside dbus-run-session.
# No desktop input is injected and no user input-method settings are touched.
import os, time, subprocess, uuid
from pathlib import Path
root=Path(os.environ['IBUS_TEST_DIR'])
root.mkdir(parents=True,exist_ok=True)
os.environ.update(IBUS_ADDRESS='unix:abstract=capslock-test-'+uuid.uuid4().hex,GIO_USE_VFS='local',GSETTINGS_BACKEND='memory',XDG_CACHE_HOME=str(root/'cache'),XDG_CONFIG_HOME=str(root/'config'))
os.environ.pop('IBUS_USE_PORTAL',None)
import gi
gi.require_version('IBus','1.0')
from gi.repository import IBus,GLib
IBus.init()
log=(root/'daemon.log').open('w')
daemon=subprocess.Popen(['ibus-daemon','--address='+os.environ['IBUS_ADDRESS'],'--panel=disable','--emoji-extension=disable'],stdout=log,stderr=log)
bus=None
engine_proc=None
try:
 for _ in range(50):
  bus=IBus.Bus.new()
  if bus.is_connected():break
  while GLib.MainContext.default().pending():GLib.MainContext.default().iteration(False)
  time.sleep(.1)
 assert bus.is_connected(),'isolated IBus not connected'
 engine_proc=subprocess.Popen(['/usr/libexec/ibus-engine-hangul','--ibus'],stdout=log,stderr=log)
 time.sleep(.5)
 ctx=bus.create_input_context('capslock-isolated-verification')
 ctx.set_capabilities(int(IBus.Capabilite.PREEDIT_TEXT|IBus.Capabilite.FOCUS))
 ctx.focus_in();assert bus.set_global_engine('hangul'), 'set global engine failed';ctx.set_engine('hangul')
 out=[]
 ctx.connect('commit-text',lambda c,t:out.append(t.get_text()))
 def drain():
  for _ in range(10):
   while GLib.MainContext.default().pending():GLib.MainContext.default().iteration(False)
   time.sleep(.01)
 drain()
 for _ in range(50):
  engine=ctx.get_engine()
  if engine and engine.get_name()=='hangul':break
  drain()
 assert engine and engine.get_name()=='hangul', 'Hangul engine not activated'
 def key(v):
  code={ord('a'):30,ord('r'):19,ord('k'):37,ord(' '):57,IBus.KEY_Hangul:122}.get(v,0)
  handled=ctx.process_key_event(v,code,0)
  ctx.process_key_event(v,code,int(IBus.ModifierType.RELEASE_MASK))
  drain()
  if not handled and v<128:out.append(chr(v))
 def text():return ''.join(out)
 key(ord('a'))
 assert text()=='a',repr(out)
 key(IBus.KEY_Hangul)
 key(ord('r'));key(ord('k'));key(ord(' '))
 assert '가' in text(),repr(out)
 key(IBus.KEY_Hangul);key(ord('a'))
 assert text().endswith('a'),repr(out)
 print('PASS isolated real IBus hangul: Latin a -> Hangul key -> 가 -> Hangul key -> Latin a')
 print('Observed text:',repr(text()))
 print('No live desktop input injected; physical keyboard and keyd daemon path not tested.')
 ctx.focus_out();ctx.destroy()
finally:
 if bus and bus.is_connected():bus.exit(False)
 try:daemon.wait(timeout=5)
 except subprocess.TimeoutExpired:daemon.terminate();daemon.wait(timeout=5)
 if engine_proc:
  try:engine_proc.wait(timeout=3)
  except subprocess.TimeoutExpired:engine_proc.terminate();engine_proc.wait(timeout=3)
 log.close()
