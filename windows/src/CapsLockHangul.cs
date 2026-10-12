// CapsLockHangul: Caps Lock tap = Hangul (Korean IME toggle), hold = Caps Lock,
// physical Right Alt / Korean key position = real Right Alt (VK_RMENU).
//
// Build (.NET Framework 4.x csc, C# 5):
//   csc /nologo /target:winexe /out:CapsLockHangul.exe /r:System.Windows.Forms.dll /r:System.Drawing.dll CapsLockHangul.cs
//
// Command line:
//   (no args)                     run (tray app, single instance per user/session)
//   --stop [--timeout <ms>]       signal the running instance to exit; 0 = stopped or absent, 1 = still running
//   --status                      0 = ready, 3 = absent, 4 = starting/stopping
//   --self-test [--report <path>] deterministic state machine tests; 0 = pass, 1 = failure
//
// Layout: Engine is the pure state machine (no Win32, no clock reads). HookApp feeds it
// low-level hook events on the UI thread and performs SendInput. SelfTest drives Engine only.
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("CapsLockHangul")]
[assembly: System.Reflection.AssemblyProduct("CapsLockHangul")]
[assembly: System.Reflection.AssemblyVersion("1.0.0.0")]

namespace CapsLockHangul
{
    // ------------------------------------------------------------------ state machine

    internal struct KeyIn
    {
        public ushort Vk;
        public ushort Scan;
        public bool Up;
        public bool Extended;
        public bool Injected;   // LLKHF_INJECTED (any injector, including us)
        public bool Own;        // dwExtraInfo carries our tag
        public uint Time;       // GetTickCount-based milliseconds (monotonic, wraps)
    }

    internal struct KeyOut
    {
        public ushort Vk;
        public ushort Scan;
        public bool Up;
        public bool Extended;

        public KeyOut(ushort vk, ushort scan, bool up, bool extended)
        {
            Vk = vk; Scan = scan; Up = up; Extended = extended;
        }
    }

    internal sealed class Decision
    {
        // Suppress: drop the original event and inject Out (in order, one SendInput batch).
        // Not suppressed: the original passes through unchanged and Out is empty.
        public bool Suppress;
        public readonly List<KeyOut> Out = new List<KeyOut>();
        // Out ends with a copy of the suppressed original (overlap commit). If injection
        // fails, the caller lets the original through instead of losing the key.
        public bool ReinjectsOriginal;
    }

    internal enum CapsState
    {
        Idle,       // Caps Lock not held
        Pending,    // held < 300ms, nothing decided yet
        Done        // decided (tap committed or hold toggled); swallow until release
    }

    internal sealed class Engine
    {
        public const uint HoldMs = 300;
        // Windows typematic repeat: delay <= 1000ms, interval <= ~400ms. A Caps down
        // after a longer silence while not Idle means the release was never seen
        // (secure desktop, UAC, hook gap); treat it as a new press.
        public const uint StaleRepeatGapMs = 1500;
        // Dedicated LANG1 keys that do send a break may also autorepeat.
        public const uint DedicatedRepeatGapMs = 600;

        public const ushort VK_CAPITAL = 0x14;
        public const ushort VK_HANGUL = 0x15;
        public const ushort VK_RMENU = 0xA5;
        public const ushort SC_CAPITAL = 0x3A;
        public const ushort SC_ALT = 0x38;      // extended = Right Alt position
        public const ushort SC_LANG1 = 0x72;    // dedicated Hangul key
        public const ushort SC_LANG1_ALT = 0xF2; // make-only variant reported by many Korean keyboards
        public const ushort SC_HANGUL_OUT = 0xF2; // informational only (no KEYEVENTF_SCANCODE)

        // After Reset a Caps down may be autorepeat of a key held across the reset. A second
        // down this soon (shorter than the minimum typematic delay of 250ms) is autorepeat.
        public const uint PostResetRepeatMs = 250;

        // Physical sources holding Right Alt. Windows keeps one VK_RMENU state, so only the
        // first source down and the last source up reach the system.
        const int AltGenuine = 1, AltMapped = 2, AltDedicated = 4;

        readonly bool dedicatedHold;
        CapsState state = CapsState.Idle;
        uint pressTime;
        uint lastCapsDown;
        bool postReset;
        int altMask;
        bool dedicatedDown;
        uint lastDedicatedDown;

        public int Taps, Holds, OverlapCommits, MissedReleases, Resets, DedicatedPulses;

        public Engine() : this(false) { }

        // dedicatedHold: the dedicated Hangul key (scan 0x72/0xF2) sends a reliable break and
        // acts as a held Right Alt. Default false: make-only hardware gets a safe pulse.
        public Engine(bool dedicatedHold)
        {
            this.dedicatedHold = dedicatedHold;
        }

        public CapsState State { get { return state; } }
        public bool HasDeadline { get { return state == CapsState.Pending; } }
        public uint Deadline { get { return unchecked(pressTime + HoldMs); } }
        // True while any physical source holds Right Alt (system VK_RMENU should be down).
        public bool RightAltDown { get { return altMask != 0; } }
        public bool DedicatedHold { get { return dedicatedHold; } }

        // Wrap-safe "now - since >= ms"; a negative difference never counts as reached.
        public static bool Reached(uint now, uint since, uint ms)
        {
            int d = unchecked((int)(now - since));
            return d >= (int)ms;
        }

        static void Pulse(List<KeyOut> o, ushort vk, ushort scan, bool ext)
        {
            o.Add(new KeyOut(vk, scan, false, ext));
            o.Add(new KeyOut(vk, scan, true, ext));
        }

        static void HangulPulse(List<KeyOut> o) { Pulse(o, VK_HANGUL, SC_HANGUL_OUT, false); }
        static void CapsPulse(List<KeyOut> o) { Pulse(o, VK_CAPITAL, SC_CAPITAL, false); }

        public Decision OnKey(KeyIn k)
        {
            Decision d = new Decision();
            // Our own output and other injectors' events pass untouched and never change state.
            if (k.Own || k.Injected)
                return d;

            if (k.Vk == VK_CAPITAL)
            {
                OnCaps(k, d);
                return d;
            }

            bool commit = !k.Up && state == CapsState.Pending;
            if (commit)
            {
                d.Suppress = true;
                if (Reached(k.Time, pressTime, HoldMs))
                {
                    // Timer was late: the hold already happened before this key.
                    CapsPulse(d.Out);
                    Holds++;
                }
                else
                {
                    HangulPulse(d.Out);
                    Taps++;
                    OverlapCommits++;
                }
                state = CapsState.Done;
            }

            if (MapOther(k, d))
            {
                d.Suppress = true;
            }
            else if (commit)
            {
                d.Out.Add(new KeyOut(k.Vk, k.Scan, k.Up, k.Extended));
                d.ReinjectsOriginal = true;
            }
            return d;
        }

        void OnCaps(KeyIn k, Decision d)
        {
            d.Suppress = true;
            if (!k.Up)
            {
                if (state == CapsState.Idle)
                {
                    state = CapsState.Pending;
                    pressTime = k.Time;
                }
                else if (postReset && state == CapsState.Pending)
                {
                    // Only the first repeat identifies whether the first post-reset down
                    // was a fresh press. Later 33ms repeats are normal for a fresh hold.
                    if (!Reached(k.Time, lastCapsDown, PostResetRepeatMs))
                        state = CapsState.Done;
                    postReset = false;
                }
                else if (Reached(k.Time, lastCapsDown, StaleRepeatGapMs))
                {
                    MissedReleases++;
                    state = CapsState.Pending;
                    pressTime = k.Time;
                }
                // otherwise autorepeat: deadline is not restarted
                lastCapsDown = k.Time;
                return;
            }

            if (state == CapsState.Pending)
            {
                if (Reached(k.Time, pressTime, HoldMs))
                {
                    CapsPulse(d.Out);
                    Holds++;
                }
                else
                {
                    HangulPulse(d.Out);
                    Taps++;
                }
            }
            state = CapsState.Idle;
            postReset = false;
        }

        // Aggregate Right Alt: emit (or pass) only the system-level transition.
        bool AltSource(int bit, KeyIn k, Decision d, bool passOriginal)
        {
            bool others = (altMask & ~bit) != 0;
            if (k.Up) altMask &= ~bit; else altMask |= bit;
            if (others)
                return true; // another source keeps Alt down; drop this edge
            if (passOriginal)
                return false;
            d.Out.Add(new KeyOut(VK_RMENU, SC_ALT, k.Up, true));
            return true;
        }

        // Right Alt position and dedicated Hangul key. Returns true if the event is
        // replaced by d.Out (possibly nothing).
        bool MapOther(KeyIn k, Decision d)
        {
            if (k.Vk == VK_RMENU)
                return AltSource(AltGenuine, k, d, true); // real Right Alt: passes unless redundant

            if (k.Scan == SC_ALT && k.Extended)
            {
                // Physical Right Alt reported as something else (VK_HANGUL on the Korean layout).
                return AltSource(AltMapped, k, d, false);
            }

            if (k.Vk == VK_HANGUL && !k.Extended && (k.Scan == SC_LANG1 || k.Scan == SC_LANG1_ALT))
            {
                if (dedicatedHold)
                    return AltSource(AltDedicated, k, d, false);

                // Dedicated key: hardware may never send a break, so a held modifier cannot
                // be tracked reliably. Emit a complete Right Alt pulse, never a held Alt.
                if (k.Up)
                {
                    dedicatedDown = false;
                    return true;
                }
                if (dedicatedDown && !Reached(k.Time, lastDedicatedDown, DedicatedRepeatGapMs))
                {
                    lastDedicatedDown = k.Time; // autorepeat
                    return true;
                }
                dedicatedDown = true;
                lastDedicatedDown = k.Time;
                if (altMask != 0)
                    return true; // Alt already held: a pulse's up would release the other source
                Pulse(d.Out, VK_RMENU, SC_ALT, true);
                DedicatedPulses++;
                return true;
            }
            return false;
        }

        public List<KeyOut> OnTick(uint now)
        {
            List<KeyOut> o = new List<KeyOut>();
            if (state == CapsState.Pending && Reached(now, pressTime, HoldMs))
            {
                CapsPulse(o);
                Holds++;
                state = CapsState.Done;
            }
            return o;
        }

        // Lock/unlock/suspend/exit: cancel pending decisions and release Right Alt.
        // Releases seen after this are lost on the secure desktop, so the next Caps down is
        // treated as a fresh press; immediate autorepeat reveals a key held across the reset.
        public List<KeyOut> Reset()
        {
            List<KeyOut> o = new List<KeyOut>();
            if (altMask != 0)
                o.Add(new KeyOut(VK_RMENU, SC_ALT, true, true));
            altMask = 0;
            dedicatedDown = false;
            postReset = state != CapsState.Idle;
            state = CapsState.Idle;
            Resets++;
            return o;
        }
    }

    // What the system actually received from us: synthesized keys whose injected down
    // succeeded and whose up has not. Survives failed/partial SendInput batches so the
    // release can be retried; independent of the Engine's desired state.
    internal sealed class OutputTracker
    {
        readonly List<ushort> owned = new List<ushort>();

        static bool Tracked(ushort vk)
        {
            return vk == Engine.VK_RMENU || vk == Engine.VK_HANGUL || vk == Engine.VK_CAPITAL;
        }

        public bool Owns(ushort vk) { return owned.Contains(vk); }
        public int Count { get { return owned.Count; } }

        // A genuine Right Alt up can be the final edge of an aggregate hold that
        // began with one of our mapped downs. Do not retain a stale ownership claim.
        public void ObserveNative(KeyIn key)
        {
            if (!key.Injected && !key.Own && key.Up && key.Vk == Engine.VK_RMENU)
                owned.Remove(Engine.VK_RMENU);
        }

        // Record the first `sent` events of a batch as delivered.
        public void Record(List<KeyOut> keys, int sent)
        {
            for (int i = 0; i < sent && i < keys.Count; i++)
            {
                ushort vk = keys[i].Vk;
                if (!Tracked(vk)) continue;
                if (keys[i].Up) owned.Remove(vk);
                else if (!owned.Contains(vk)) owned.Add(vk);
            }
        }

        // Releases still owed. Right Alt stays down while the Engine wants it held.
        public List<KeyOut> Outstanding(bool rightAltWanted)
        {
            List<KeyOut> o = new List<KeyOut>();
            foreach (ushort vk in owned)
            {
                if (vk == Engine.VK_RMENU)
                {
                    if (!rightAltWanted) o.Add(new KeyOut(vk, Engine.SC_ALT, true, true));
                }
                else
                {
                    o.Add(new KeyOut(vk, vk == Engine.VK_CAPITAL ? Engine.SC_CAPITAL : Engine.SC_HANGUL_OUT, true, false));
                }
            }
            return o;
        }
    }

    // ------------------------------------------------------------------ Win32

    internal static class Native
    {
        public const int WH_KEYBOARD_LL = 13;
        public const uint INPUT_KEYBOARD = 1;
        public const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
        public const uint KEYEVENTF_KEYUP = 0x0002;
        public const uint KEYEVENTF_SCANCODE = 0x0008;
        public const uint LLKHF_EXTENDED = 0x01;
        public const uint LLKHF_INJECTED = 0x10;
        public const uint LLKHF_UP = 0x80;

        public const int WM_ENDSESSION = 0x0016;
        public const int WM_POWERBROADCAST = 0x0218;
        public const int WM_WTSSESSION_CHANGE = 0x02B1;
        public const int WM_APP_STOP = 0x8001;
        public const int WM_APP_NOTIFY = 0x8002;
        public const int WM_APP_READY = 0x8003;
        public const int PBT_APMSUSPEND = 0x4;
        public const int PBT_APMRESUMESUSPEND = 0x7;
        public const int PBT_APMRESUMEAUTOMATIC = 0x12;

        // "CLKH": marks events we inject so our hook passes them through.
        public static readonly IntPtr OwnTag = new IntPtr(0x434C4B48);

        public delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        public struct KBDLLHOOKSTRUCT
        {
            public uint vkCode;
            public uint scanCode;
            public uint flags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct MOUSEINPUT
        {
            public int dx;
            public int dy;
            public uint mouseData;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct KEYBDINPUT
        {
            public ushort wVk;
            public ushort wScan;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct HARDWAREINPUT
        {
            public uint uMsg;
            public ushort wParamL;
            public ushort wParamH;
        }

        // Full union so sizeof(INPUT) is 40 on x64 and 28 on x86.
        [StructLayout(LayoutKind.Explicit)]
        public struct InputUnion
        {
            [FieldOffset(0)] public MOUSEINPUT mi;
            [FieldOffset(0)] public KEYBDINPUT ki;
            [FieldOffset(0)] public HARDWAREINPUT hi;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct INPUT
        {
            public uint type;
            public InputUnion u;
        }

        public static readonly int InputSize = Marshal.SizeOf(typeof(INPUT));

        // Virtual-key injection: wVk is authoritative. KEYEVENTF_SCANCODE is never set
        // (it would make Windows ignore wVk and re-derive VK_HANGUL from scan 0x38 on the Korean layout).
        public static INPUT BuildInput(KeyOut k)
        {
            INPUT i = new INPUT();
            i.type = INPUT_KEYBOARD;
            i.u.ki.wVk = k.Vk;
            i.u.ki.wScan = k.Scan;
            i.u.ki.dwFlags = (k.Up ? KEYEVENTF_KEYUP : 0) | (k.Extended ? KEYEVENTF_EXTENDEDKEY : 0);
            i.u.ki.time = 0;
            i.u.ki.dwExtraInfo = OwnTag;
            return i;
        }

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc fn, IntPtr hMod, uint threadId);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool UnhookWindowsHookEx(IntPtr hhk);

        [DllImport("user32.dll")]
        public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr GetModuleHandle(string name);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern uint SendInput(uint nInputs, [In] INPUT[] inputs, int cbSize);

        [DllImport("kernel32.dll")]
        public static extern uint GetTickCount();

        [DllImport("wtsapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool WTSRegisterSessionNotification(IntPtr hWnd, int flags);

        [DllImport("wtsapi32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool WTSUnRegisterSessionNotification(IntPtr hWnd);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool PostMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

        [DllImport("kernel32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool AttachConsole(int pid);
    }

    // ------------------------------------------------------------------ logging

    // Asynchronous, bounded, best effort. Records lifecycle and errors only, never key contents.
    internal static class Log
    {
        const long MaxBytes = 1024 * 1024;
        static readonly BlockingCollection<string> queue = new BlockingCollection<string>(256);
        static Thread worker;
        static string path;
        static readonly int pid = System.Diagnostics.Process.GetCurrentProcess().Id;

        public static string PathName { get { return path; } }

        public static void Start()
        {
            // Keep logs beside the installed app, outside MSIX AppData virtualization.
            string dir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "logs");
            path = Path.Combine(dir, "CapsLockHangul.log");
            worker = new Thread(delegate ()
            {
                try { Directory.CreateDirectory(dir); } catch { }
                foreach (string line in queue.GetConsumingEnumerable())
                {
                    try
                    {
                        FileInfo fi = new FileInfo(path);
                        if (fi.Exists && fi.Length > MaxBytes)
                        {
                            string old = path + ".1";
                            if (File.Exists(old)) File.Delete(old);
                            File.Move(path, old);
                        }
                        File.AppendAllText(path, line + "\r\n", Encoding.UTF8);
                    }
                    catch { }
                }
            });
            worker.IsBackground = true;
            worker.Name = "CapsLockHangul log";
            worker.Start();
        }

        public static void Write(string msg)
        {
            if (worker == null || queue.IsAddingCompleted) return;
            queue.TryAdd(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " [" + pid + "] " + msg);
        }

        public static void Stop()
        {
            if (worker == null) return;
            queue.CompleteAdding();
            worker.Join(2000);
        }
    }

    // ------------------------------------------------------------------ app

    internal sealed class MsgWindow : NativeWindow
    {
        readonly HookApp app;

        public MsgWindow(HookApp app)
        {
            this.app = app;
            // Hidden top-level window (not message-only) so WM_POWERBROADCAST arrives.
            CreateParams cp = new CreateParams();
            cp.Caption = "CapsLockHangul.Message";
            CreateHandle(cp);
        }

        protected override void WndProc(ref Message m)
        {
            switch (m.Msg)
            {
                case Native.WM_WTSSESSION_CHANGE:
                    app.ResetState("session change " + m.WParam.ToInt64());
                    break;
                case Native.WM_POWERBROADCAST:
                    long ev = m.WParam.ToInt64();
                    if (ev == Native.PBT_APMSUSPEND || ev == Native.PBT_APMRESUMESUSPEND || ev == Native.PBT_APMRESUMEAUTOMATIC)
                        app.ResetState("power event " + ev);
                    break;
                case Native.WM_ENDSESSION:
                    if (m.WParam != IntPtr.Zero)
                    {
                        Log.Write("session ending");
                        app.ExitThread(); // destroys this window; do not call base
                        return;
                    }
                    break;
                case Native.WM_APP_STOP:
                    Log.Write("stop requested");
                    app.ExitThread();
                    return;
                case Native.WM_APP_NOTIFY:
                    app.ShowFailureNotice();
                    return;
                case Native.WM_APP_READY:
                    app.MarkReady();
                    return;
            }
            base.WndProc(ref m);
        }
    }

    internal sealed class HookApp : ApplicationContext
    {
        readonly Engine engine;
        readonly OutputTracker tracker = new OutputTracker();
        readonly Native.LowLevelKeyboardProc proc;
        readonly System.Windows.Forms.Timer timer;
        readonly MsgWindow win;
        readonly NotifyIcon tray;
        readonly EventWaitHandle stopEvent;
        readonly EventWaitHandle readyEvent; // null when not requested
        RegisteredWaitHandle stopWait;
        IntPtr hook;
        IntPtr winHandle;
        bool sessionNotify;
        bool cleaned;
        int sendFailures;
        int lastSendError;
        int lastNoticeTick;
        bool noticeShownOnce;

        public HookApp(string stopEventName) : this(stopEventName, null, false) { }

        // readyEventName: manual-reset event set once the message loop is running with the
        // hook installed (consumed by --status). dedicatedHold: see Engine(bool).
        public HookApp(string stopEventName, string readyEventName, bool dedicatedHold)
        {
            engine = new Engine(dedicatedHold);
            try
            {
            win = new MsgWindow(this);
            winHandle = win.Handle;

            timer = new System.Windows.Forms.Timer();
            timer.Tick += OnTimer;

            proc = HookCallback; // field keeps the delegate alive for the hook's lifetime
            hook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, proc, Native.GetModuleHandle(null), 0);
            if (hook == IntPtr.Zero)
            {
                int err = Marshal.GetLastWin32Error();
                throw new InvalidOperationException("SetWindowsHookEx(WH_KEYBOARD_LL) failed: error " + err +
                                                    " (" + new Win32Exception(err).Message + ")");
            }

            sessionNotify = Native.WTSRegisterSessionNotification(winHandle, 0 /* NOTIFY_FOR_THIS_SESSION */);
            if (!sessionNotify)
                Log.Write("warning: WTSRegisterSessionNotification failed: error " + Marshal.GetLastWin32Error());

            bool createdNew;
            stopEvent = new EventWaitHandle(false, EventResetMode.AutoReset, stopEventName, out createdNew);
            stopEvent.Reset();
            IntPtr h = winHandle;
            stopWait = ThreadPool.RegisterWaitForSingleObject(stopEvent,
                delegate { Native.PostMessage(h, Native.WM_APP_STOP, IntPtr.Zero, IntPtr.Zero); },
                null, Timeout.Infinite, true);

            ContextMenuStrip menu = new ContextMenuStrip();
            ToolStripItem title = menu.Items.Add("CapsLockHangul: running");
            title.Enabled = false;
            menu.Items.Add("Status...", null, delegate { ShowStatus(); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Exit", null, delegate { ExitThread(); });

            tray = new NotifyIcon();
            tray.Icon = MakeIcon();
            tray.Text = "CapsLockHangul (Caps Lock: tap = Han/Eng, hold = Caps)";
            tray.ContextMenuStrip = menu;
            tray.DoubleClick += delegate { ShowStatus(); };
            tray.Visible = true;

            if (readyEventName != null)
            {
                readyEvent = new EventWaitHandle(false, EventResetMode.ManualReset, readyEventName, out createdNew);
                readyEvent.Reset();
                // Processed only once Application.Run is pumping messages.
                if (!Native.PostMessage(winHandle, Native.WM_APP_READY, IntPtr.Zero, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not post readiness notification");
            }

            Log.Write("started: x" + (IntPtr.Size * 8) + ", INPUT size " + Native.InputSize +
                      ", session " + System.Diagnostics.Process.GetCurrentProcess().SessionId +
                      ", dedicated key " + (dedicatedHold ? "hold" : "pulse"));
            }
            catch
            {
                Cleanup();
                throw;
            }
        }

        public void MarkReady()
        {
            if (readyEvent != null && !cleaned && hook != IntPtr.Zero)
            {
                readyEvent.Set();
                Log.Write("ready");
            }
        }

        static Icon MakeIcon()
        {
            try
            {
                using (Bitmap bmp = new Bitmap(16, 16))
                using (Graphics g = Graphics.FromImage(bmp))
                using (Font f = new Font("Malgun Gothic", 8.5f, FontStyle.Bold, GraphicsUnit.Point))
                {
                    g.Clear(Color.FromArgb(30, 90, 170));
                    g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                    StringFormat sf = new StringFormat();
                    sf.Alignment = StringAlignment.Center;
                    sf.LineAlignment = StringAlignment.Center;
                    g.DrawString("한", f, Brushes.White, new RectangleF(0, 0, 16, 16), sf);
                    return Icon.FromHandle(bmp.GetHicon());
                }
            }
            catch
            {
                return SystemIcons.Application;
            }
        }

        IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0)
            {
                try
                {
                    Native.KBDLLHOOKSTRUCT s = (Native.KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(Native.KBDLLHOOKSTRUCT));
                    KeyIn k = new KeyIn();
                    k.Vk = (ushort)s.vkCode;
                    k.Scan = (ushort)s.scanCode;
                    k.Up = (s.flags & Native.LLKHF_UP) != 0;
                    k.Extended = (s.flags & Native.LLKHF_EXTENDED) != 0;
                    k.Injected = (s.flags & Native.LLKHF_INJECTED) != 0;
#if HOOK_INTEGRATION_TEST
                    // Compile-only test seam: the production build rejects all injected input.
                    if (s.dwExtraInfo == new IntPtr(0x48544C31)) k.Injected = false;
#endif
                    k.Own = s.dwExtraInfo == Native.OwnTag;
                    k.Time = s.time;

                    if (!k.Own && !k.Injected)
                    {
                        Decision d = engine.OnKey(k);
                        if (d.Suppress)
                        {
                            int sent = d.Out.Count == 0 ? 0 : Send(d.Out);
                            FlushReleases();
                            ScheduleTimer();
                            // The original is the last element; if it was not sent, deliver it
                            // natively rather than losing the user's key.
                            if (d.ReinjectsOriginal && sent < d.Out.Count)
                                return Native.CallNextHookEx(hook, nCode, wParam, lParam);
                            return new IntPtr(1);
                        }
                        tracker.ObserveNative(k);
                        FlushReleases();
                        ScheduleTimer();
                    }
                }
                catch (Exception ex)
                {
                    Log.Write("error in hook: " + ex.GetType().Name + ": " + ex.Message);
                }
            }
            return Native.CallNextHookEx(hook, nCode, wParam, lParam);
        }

        // One SendInput batch keeps synthesized and reinjected keys contiguous and ordered.
        // Note: UIPI blocking (elevated foreground window) is not reported by SendInput.
        int Send(List<KeyOut> keys)
        {
            Native.INPUT[] arr = new Native.INPUT[keys.Count];
            for (int i = 0; i < arr.Length; i++)
                arr[i] = Native.BuildInput(keys[i]);
            int sent = (int)Native.SendInput((uint)arr.Length, arr, Native.InputSize);
            if (sent < 0) sent = 0;
            tracker.Record(keys, sent);
            if (sent != arr.Length)
            {
                lastSendError = Marshal.GetLastWin32Error();
                sendFailures++;
                Log.Write("SendInput failed: sent " + sent + "/" + arr.Length + ", error " + lastSendError +
                          ", owned keys outstanding " + tracker.Count);
                Native.PostMessage(winHandle, Native.WM_APP_NOTIFY, IntPtr.Zero, IntPtr.Zero);
            }
            return sent;
        }

        // Retry releases for synthesized keys the system still holds from us (partial or
        // failed batches). Ownership is cleared only when the up is actually delivered.
        void FlushReleases()
        {
            if (tracker.Count == 0) return;
            List<KeyOut> o = tracker.Outstanding(engine.RightAltDown);
            if (o.Count > 0)
                Send(o);
        }

        void ScheduleTimer()
        {
            if (cleaned || timer == null) return;
            bool retryRelease = tracker.Outstanding(engine.RightAltDown).Count != 0;
            if (!engine.HasDeadline)
            {
                if (retryRelease)
                {
                    timer.Interval = 250;
                    timer.Start();
                }
                else timer.Stop();
                return;
            }
            int remaining = unchecked((int)(engine.Deadline - Native.GetTickCount()));
            if (retryRelease) remaining = Math.Min(remaining, 250);
            timer.Interval = Math.Max(1, remaining);
            timer.Start();
        }

        void OnTimer(object sender, EventArgs e)
        {
            timer.Stop();
            List<KeyOut> o = engine.OnTick(Native.GetTickCount());
            if (o.Count > 0)
                Send(o);
            FlushReleases();
            ScheduleTimer();
        }

        public void ResetState(string reason)
        {
            List<KeyOut> o = engine.Reset();
            timer.Stop();
            if (o.Count > 0)
                Send(o);
            FlushReleases();
            ScheduleTimer();
            Log.Write("reset: " + reason + (tracker.Count > 0 ? "; release still pending for " + tracker.Count + " key(s)" : ""));
        }

        public void ShowFailureNotice()
        {
            int now = Environment.TickCount;
            if (noticeShownOnce && unchecked(now - lastNoticeTick) < 60000) return;
            noticeShownOnce = true;
            lastNoticeTick = now;
            tray.ShowBalloonTip(5000, "CapsLockHangul",
                "Key injection failed (error " + lastSendError + "). Some keys may not have been delivered. See " + Log.PathName,
                ToolTipIcon.Warning);
        }

        void ShowStatus()
        {
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("CapsLockHangul is running.");
            sb.AppendLine();
            sb.AppendLine("Hook installed: " + (hook != IntPtr.Zero));
            sb.AppendLine("Caps state: " + engine.State);
            sb.AppendLine("Hangul taps: " + engine.Taps + " (overlap commits " + engine.OverlapCommits + ")");
            sb.AppendLine("Caps Lock holds: " + engine.Holds);
            sb.AppendLine("Dedicated Hangul-key pulses: " + engine.DedicatedPulses);
            sb.AppendLine("Missed-release recoveries: " + engine.MissedReleases);
            sb.AppendLine("Resets: " + engine.Resets);
            sb.AppendLine("SendInput failures: " + sendFailures + (sendFailures > 0 ? " (last error " + lastSendError + ")" : ""));
            sb.AppendLine();
            sb.AppendLine("Elevated (administrator) windows cannot receive the remapped keys.");
            sb.AppendLine("Log: " + Log.PathName);
            MessageBox.Show(sb.ToString(), "CapsLockHangul", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        protected override void ExitThreadCore()
        {
            Cleanup();
            base.ExitThreadCore();
        }

        void Cleanup()
        {
            if (cleaned) return;
            cleaned = true;
            if (readyEvent != null) { readyEvent.Reset(); readyEvent.Dispose(); }
            try { ResetState("exit"); } catch { }
            try { FlushReleases(); } catch { } // one more attempt for owned keys
            if (hook != IntPtr.Zero)
            {
                Native.UnhookWindowsHookEx(hook);
                hook = IntPtr.Zero;
            }
            if (timer != null) { timer.Stop(); timer.Dispose(); }
            if (stopWait != null) stopWait.Unregister(null);
            if (stopEvent != null) stopEvent.Dispose();
            if (sessionNotify) Native.WTSUnRegisterSessionNotification(winHandle);
            if (win != null) win.DestroyHandle();
            if (tray != null) { tray.Visible = false; tray.Dispose(); }
            Log.Write("stopped");
        }
    }

    // ------------------------------------------------------------------ entry point

    internal static class Program
    {
        // ExitNotReady: an instance holds the mutex but has not finished starting (or is stopping).
        const int ExitOk = 0, ExitFail = 1, ExitUsage = 2, ExitNotRunning = 3, ExitNotReady = 4;

        [STAThread]
        static int Main(string[] args)
        {
            string mode = "run";
            string report = null;
            int timeoutMs = 5000;
            bool dedicatedHold = false;
            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i];
                if (a == "--stop" || a == "--status" || a == "--self-test")
                {
                    if (mode != "run") return Usage("only one of --stop, --status, --self-test");
                    mode = a;
                }
                else if (a == "--dedicated-hold") dedicatedHold = true;
                else if (a == "--report" && i + 1 < args.Length) report = args[++i];
                else if (a == "--timeout" && i + 1 < args.Length)
                {
                    if (!int.TryParse(args[++i], out timeoutMs) || timeoutMs < 0) return Usage("bad --timeout");
                }
                else return Usage("unknown argument: " + a);
            }

            if (mode == "--self-test")
            {
                Native.AttachConsole(-1);
                return SelfTest.Run(report) ? ExitOk : ExitFail;
            }

            string sid = WindowsIdentity.GetCurrent().User.Value;
            string mutexName = "Local\\CapsLockHangul." + sid;
            string stopName = "Local\\CapsLockHangul.Stop." + sid;
            string readyName = "Local\\CapsLockHangul.Ready." + sid;

            if (mode == "--status")
            {
                if (!IsRunning(mutexName)) return ExitNotRunning;
                return IsReady(readyName) ? ExitOk : ExitNotReady;
            }
            if (mode == "--stop")
                return Stop(mutexName, stopName, timeoutMs);
            return RunApp(mutexName, stopName, readyName, dedicatedHold);
        }

        static int Usage(string msg)
        {
            Native.AttachConsole(-1);
            Console.Error.WriteLine("CapsLockHangul: " + msg);
            Console.Error.WriteLine("usage: CapsLockHangul.exe [--dedicated-hold] | --stop [--timeout ms] | --status | --self-test [--report path]");
            return ExitUsage;
        }

        static bool IsReady(string readyName)
        {
            try
            {
                using (EventWaitHandle ev = EventWaitHandle.OpenExisting(readyName))
                    return ev.WaitOne(0);
            }
            catch (WaitHandleCannotBeOpenedException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
        }

        static bool IsRunning(string mutexName)
        {
            try
            {
                using (Mutex.OpenExisting(mutexName)) { }
                return true;
            }
            catch (WaitHandleCannotBeOpenedException) { return false; }
            catch (UnauthorizedAccessException) { return true; } // exists, but not openable
        }

        static int Stop(string mutexName, string stopName, int timeoutMs)
        {
            Mutex m;
            try { m = Mutex.OpenExisting(mutexName); }
            catch (WaitHandleCannotBeOpenedException) { return ExitOk; }
            catch (UnauthorizedAccessException) { return ExitFail; }
            using (m)
            {
                try
                {
                    using (EventWaitHandle ev = EventWaitHandle.OpenExisting(stopName))
                        ev.Set();
                }
                catch (WaitHandleCannotBeOpenedException)
                {
                    // Instance is starting up or shutting down; fall through and wait.
                }
                bool released;
                try { released = m.WaitOne(timeoutMs); }
                catch (AbandonedMutexException) { released = true; }
                if (!released) return ExitFail;
                m.ReleaseMutex();
                return ExitOk;
            }
        }

        static int RunApp(string mutexName, string stopName, string readyName, bool dedicatedHold)
        {
            bool created;
            using (Mutex m = new Mutex(true, mutexName, out created))
            {
                Log.Start();
                if (!created)
                {
                    Log.Write("another instance is already running; exiting");
                    Log.Stop();
                    return ExitOk;
                }
                try
                {
                    Application.EnableVisualStyles();
                    Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
                    Application.ThreadException += delegate (object s, ThreadExceptionEventArgs e)
                    {
                        Log.Write("unhandled UI exception: " + e.Exception);
                    };
                    AppDomain.CurrentDomain.UnhandledException += delegate (object s, UnhandledExceptionEventArgs e)
                    {
                        Log.Write("fatal: " + e.ExceptionObject);
                    };

                    HookApp app;
                    try
                    {
                        app = new HookApp(stopName, readyName, dedicatedHold);
                    }
                    catch (Exception ex)
                    {
                        // No modal dialog: an unattended logon start must not block. The
                        // installer sees the failure through --status (never ready) and the log.
                        Log.Write("startup failed: " + ex.Message);
                        return ExitFail;
                    }
                    Application.Run(app);
                    return ExitOk;
                }
                finally
                {
                    Log.Stop();
                    m.ReleaseMutex();
                }
            }
        }
    }

    // ------------------------------------------------------------------ self-test

    // Drives Engine only: no hook, no SendInput, no mutex/event (cannot affect a running instance).
    internal static class SelfTest
    {
        sealed class Sim
        {
            public readonly Engine E;
            public Sim() : this(false) { }
            public Sim(bool dedicatedHold) { E = new Engine(dedicatedHold); }
            public uint T;
            public readonly List<KeyOut> Injected = new List<KeyOut>();
            public Decision Last;
            readonly StringBuilder stream = new StringBuilder();

            public string Stream { get { return stream.ToString(); } }

            void Tok(bool up, ushort vk)
            {
                if (stream.Length > 0) stream.Append(' ');
                stream.Append(up ? '-' : '+').Append(Name(vk));
            }

            void Emit(List<KeyOut> o)
            {
                foreach (KeyOut k in o) { Injected.Add(k); Tok(k.Up, k.Vk); }
            }

            public void Feed(KeyIn k)
            {
                Last = E.OnKey(k);
                if (Last.Suppress) Emit(Last.Out);
                else
                {
                    if (Last.Out.Count != 0) throw new Exception("passthrough decision carries output");
                    Tok(k.Up, k.Vk);
                }
            }

            public void Down(string n) { Feed(Key(n, false, T)); }
            public void Up(string n) { Feed(Key(n, true, T)); }

            public void Inject(string n, bool up, bool own)
            {
                KeyIn k = Key(n, up, T);
                k.Injected = true;
                k.Own = own;
                Feed(k);
            }

            // Advance time with an ideal timer that fires exactly at the deadline.
            public void Wait(uint ms)
            {
                if (E.HasDeadline)
                {
                    int d = unchecked((int)(E.Deadline - T));
                    if (d <= (int)ms) Emit(E.OnTick(d < 0 ? T : E.Deadline));
                }
                T = unchecked(T + ms);
            }

            // Advance time while the timer is late (does not fire).
            public void Late(uint ms) { T = unchecked(T + ms); }

            public void Reset() { Emit(E.Reset()); }

            public static string BatchText(List<KeyOut> o)
            {
                StringBuilder b = new StringBuilder();
                foreach (KeyOut k in o)
                {
                    if (b.Length > 0) b.Append(' ');
                    b.Append(k.Up ? '-' : '+').Append(Name(k.Vk));
                }
                return b.ToString();
            }
        }

        static KeyIn Key(string n, bool up, uint t)
        {
            KeyIn k = new KeyIn();
            k.Up = up;
            k.Time = t;
            switch (n)
            {
                case "CAPS": k.Vk = 0x14; k.Scan = 0x3A; break;
                case "A": k.Vk = 0x41; k.Scan = 0x1E; break;
                case "X": k.Vk = 0x58; k.Scan = 0x2D; break;
                case "F": k.Vk = 0x46; k.Scan = 0x21; break;
                case "TAB": k.Vk = 0x09; k.Scan = 0x0F; break;
                case "LSHIFT": k.Vk = 0xA0; k.Scan = 0x2A; break;
                case "LCTRL": k.Vk = 0xA2; k.Scan = 0x1D; break;
                case "LALT": k.Vk = 0xA4; k.Scan = 0x38; break;
                case "RALT": k.Vk = 0xA5; k.Scan = 0x38; k.Extended = true; break;
                // Right Alt position as reported on the Korean layout.
                case "KO_RALT": k.Vk = 0x15; k.Scan = 0x38; k.Extended = true; break;
                // Dedicated Hangul key variants.
                case "LANG1": k.Vk = 0x15; k.Scan = 0xF2; break;
                case "LANG1_72": k.Vk = 0x15; k.Scan = 0x72; break;
                default: throw new ArgumentException("unknown key " + n);
            }
            return k;
        }

        static string Name(ushort vk)
        {
            switch (vk)
            {
                case 0x14: return "CAPS";
                case 0x15: return "HANGUL";
                case 0x41: return "A";
                case 0x58: return "X";
                case 0x46: return "F";
                case 0x09: return "TAB";
                case 0xA0: return "LSHIFT";
                case 0xA2: return "LCTRL";
                case 0xA4: return "LALT";
                case 0xA5: return "RALT";
                default: return "VK" + vk.ToString("X2");
            }
        }

        const string H = "+HANGUL -HANGUL";
        const string C = "+CAPS -CAPS";
        const string R = "+RALT -RALT";

        static StringBuilder log;
        static int passed, failed;

        static void Check(string name, bool ok, string detail)
        {
            if (ok) { passed++; log.AppendLine("PASS " + name); }
            else { failed++; log.AppendLine("FAIL " + name + ": " + detail); }
        }

        delegate string Extra(Sim s);

        static void Expect(string name, Action<Sim> body, string expected)
        {
            Expect(name, body, expected, null);
        }

        static void Expect(string name, Action<Sim> body, string expected, Extra extra)
        {
            ExpectMode(name, false, body, expected, extra);
        }

        static void ExpectMode(string name, bool dedicatedHold, Action<Sim> body, string expected, Extra extra)
        {
            Sim s = new Sim(dedicatedHold);
            s.T = 1000;
            try
            {
                body(s);
                string err = null;
                if (s.Stream != expected) err = "expected [" + expected + "] got [" + s.Stream + "]";
                else if (extra != null) err = extra(s);
                Check(name, err == null, err);
            }
            catch (Exception ex)
            {
                Check(name, false, ex.ToString());
            }
        }

        static string RightAltShape(Sim s)
        {
            foreach (KeyOut k in s.Injected)
                if (k.Vk == Engine.VK_RMENU && (!k.Extended || k.Scan != Engine.SC_ALT))
                    return "synthesized Right Alt is not extended scan 0x38";
            return null;
        }

        static string Balanced(Sim s)
        {
            int downs = 0;
            foreach (KeyOut k in s.Injected)
                if (k.Vk == Engine.VK_RMENU) downs += k.Up ? -1 : 1;
            if (downs != 0) return "Right Alt left down (balance " + downs + ")";
            if (s.E.RightAltDown) return "engine believes Right Alt is down";
            return RightAltShape(s);
        }

        public static bool Run(string reportPath)
        {
            log = new StringBuilder();
            passed = failed = 0;

            // Boundaries
            Expect("tap-100ms", delegate (Sim s) { s.Down("CAPS"); s.Wait(100); s.Up("CAPS"); }, H);
            Expect("tap-same-ms", delegate (Sim s) { s.Down("CAPS"); s.Up("CAPS"); }, H);
            Expect("tap-0ms-then-idle", delegate (Sim s) { s.Down("CAPS"); s.Up("CAPS"); s.Wait(400); s.Down("X"); s.Up("X"); }, H + " +X -X");
            Expect("boundary-299", delegate (Sim s) { s.Down("CAPS"); s.Wait(299); s.Up("CAPS"); }, H);
            Expect("boundary-300-timer", delegate (Sim s) { s.Down("CAPS"); s.Wait(300); s.Up("CAPS"); }, C);
            Expect("boundary-300-late-timer", delegate (Sim s) { s.Down("CAPS"); s.Late(300); s.Up("CAPS"); }, C);
            Expect("boundary-301", delegate (Sim s) { s.Down("CAPS"); s.Wait(301); s.Up("CAPS"); }, C);
            Expect("hold-toggles-while-held", delegate (Sim s) { s.Down("CAPS"); s.Wait(300); }, C,
                delegate (Sim s) { return s.E.State == CapsState.Done ? null : "state " + s.E.State; });

            // Repeat handling
            Expect("hold-with-autorepeat-once", delegate (Sim s)
            {
                s.Down("CAPS");
                for (int i = 0; i < 30; i++) { s.Wait(33); s.Down("CAPS"); }
                s.Up("CAPS");
            }, C);
            Expect("repeat-does-not-restart-deadline", delegate (Sim s)
            {
                s.Down("CAPS"); s.Wait(200); s.Down("CAPS"); s.Wait(100); // deadline is 300 from first down
            }, C);
            Expect("repeat-before-deadline-then-tap", delegate (Sim s)
            {
                s.Down("CAPS"); s.Wait(100); s.Down("CAPS"); s.Wait(100); s.Up("CAPS");
            }, H);

            // Sequences
            Expect("tap-after-hold", delegate (Sim s) { s.Down("CAPS"); s.Wait(400); s.Up("CAPS"); s.Wait(100); s.Down("CAPS"); s.Wait(100); s.Up("CAPS"); }, C + " " + H);
            Expect("hold-twice", delegate (Sim s) { s.Down("CAPS"); s.Wait(500); s.Up("CAPS"); s.Wait(50); s.Down("CAPS"); s.Wait(500); s.Up("CAPS"); }, C + " " + C);
            Expect("double-tap", delegate (Sim s) { s.Down("CAPS"); s.Wait(40); s.Up("CAPS"); s.Wait(30); s.Down("CAPS"); s.Wait(40); s.Up("CAPS"); }, H + " " + H);
            Expect("double-tap-same-ms", delegate (Sim s) { s.Down("CAPS"); s.Wait(100); s.Up("CAPS"); s.Down("CAPS"); s.Up("CAPS"); }, H + " " + H);
            Expect("triple-tap", delegate (Sim s)
            {
                s.Down("CAPS"); s.Wait(20); s.Up("CAPS"); s.Wait(20);
                s.Down("CAPS"); s.Wait(20); s.Up("CAPS"); s.Wait(20);
                s.Down("CAPS"); s.Up("CAPS"); s.Wait(500);
                s.Down("X"); s.Up("X");
            }, H + " " + H + " " + H + " +X -X");
            Expect("caps-up-without-down", delegate (Sim s) { s.Up("CAPS"); }, "");

            // Overlap
            Expect("overlap-before-timeout", delegate (Sim s)
            {
                s.Down("CAPS"); s.Wait(50); s.Down("A"); s.Up("A"); s.Wait(1000); s.Up("CAPS");
            }, H + " +A -A");
            Expect("overlap-single-ordered-batch", delegate (Sim s) { s.Down("CAPS"); s.Wait(50); s.Down("A"); }, H + " +A",
                delegate (Sim s)
                {
                    string b = Sim.BatchText(s.Last.Out);
                    if (!s.Last.Suppress || !s.Last.ReinjectsOriginal || b != H + " +A") return "batch [" + b + "]";
                    KeyOut a = s.Last.Out[2];
                    return a.Scan == 0x1E && !a.Extended ? null : "reinjected key lost scan/flags";
                });
            Expect("overlap-release-order", delegate (Sim s)
            {
                s.Down("CAPS"); s.Wait(50); s.Down("A"); s.Up("CAPS"); s.Up("A");
            }, H + " +A -A");
            Expect("overlap-no-late-hold", delegate (Sim s)
            {
                s.Down("CAPS"); s.Wait(50); s.Down("A"); s.Up("A"); s.Wait(1000);
                for (int i = 0; i < 10; i++) { s.Down("CAPS"); s.Wait(33); }
                s.Up("CAPS");
            }, H + " +A -A");
            Expect("rollover-other-up-does-not-commit", delegate (Sim s)
            {
                s.Down("A"); s.Down("CAPS"); s.Up("A");
            }, "+A -A", delegate (Sim s) { return s.E.State == CapsState.Pending ? null : "state " + s.E.State; });
            Expect("rollover", delegate (Sim s) { s.Down("A"); s.Down("CAPS"); s.Up("A"); s.Wait(100); s.Up("CAPS"); }, "+A -A " + H);
            Expect("rollover-then-long-hold", delegate (Sim s)
            {
                s.Down("CAPS"); s.Wait(50); s.Down("A"); s.Up("A"); s.Wait(1000); s.Up("CAPS");
            }, H + " +A -A");
            Expect("overlap-after-timeout", delegate (Sim s) { s.Down("CAPS"); s.Wait(400); s.Down("A"); s.Up("A"); s.Up("CAPS"); }, C + " +A -A");
            Expect("overlap-after-deadline-late-timer", delegate (Sim s) { s.Down("CAPS"); s.Late(350); s.Down("A"); s.Up("A"); s.Up("CAPS"); }, C + " +A -A");
            Expect("shift-chord-inside-caps", delegate (Sim s)
            {
                s.Down("CAPS"); s.Wait(50); s.Down("LSHIFT"); s.Down("A"); s.Up("A"); s.Up("LSHIFT"); s.Up("CAPS");
            }, H + " +LSHIFT +A -A -LSHIFT");

            // Pre-held modifiers and passthrough
            Expect("preheld-shift-tap", delegate (Sim s) { s.Down("LSHIFT"); s.Down("CAPS"); s.Wait(100); s.Up("CAPS"); s.Up("LSHIFT"); }, "+LSHIFT " + H + " -LSHIFT");
            Expect("preheld-control-hold", delegate (Sim s) { s.Down("LCTRL"); s.Down("CAPS"); s.Wait(400); s.Up("CAPS"); s.Up("LCTRL"); }, "+LCTRL " + C + " -LCTRL");
            Expect("leftalt-combo", delegate (Sim s) { s.Down("LALT"); s.Down("TAB"); s.Up("TAB"); s.Up("LALT"); }, "+LALT +TAB -TAB -LALT",
                delegate (Sim s) { return s.Injected.Count == 0 ? null : "injected on passthrough"; });

            // Right Alt / Korean key
            Expect("ko-ralt-becomes-rmenu", delegate (Sim s) { s.Down("KO_RALT"); s.Wait(50); s.Up("KO_RALT"); }, R, Balanced);
            Expect("ko-ralt-held-is-modifier", delegate (Sim s) { s.Down("KO_RALT"); s.Wait(500); s.Down("A"); s.Up("A"); s.Up("KO_RALT"); }, "+RALT +A -A -RALT", Balanced);
            Expect("genuine-rmenu-passthrough", delegate (Sim s)
            {
                s.Down("RALT"); s.Wait(50); s.Up("RALT"); s.Down("RALT"); s.Down("F"); s.Up("F"); s.Up("RALT");
            }, R + " +RALT +F -F -RALT", delegate (Sim s) { return s.Injected.Count == 0 ? null : "injected on passthrough"; });
            Expect("caps-tap-while-ko-ralt-held", delegate (Sim s)
            {
                s.Down("KO_RALT"); s.Down("CAPS"); s.Wait(100); s.Up("CAPS"); s.Up("KO_RALT");
            }, "+RALT " + H + " -RALT", Balanced);
            Expect("dedicated-make-only-pulses", delegate (Sim s) { s.Down("LANG1"); s.Wait(1000); s.Down("LANG1"); }, R + " " + R, Balanced);
            Expect("dedicated-with-break-and-repeat", delegate (Sim s)
            {
                s.Down("LANG1_72"); s.Wait(500); s.Down("LANG1_72"); s.Wait(33); s.Down("LANG1_72"); s.Up("LANG1_72");
            }, R, Balanced);
            Expect("overlap-with-dedicated", delegate (Sim s) { s.Down("CAPS"); s.Wait(50); s.Down("LANG1"); s.Up("CAPS"); }, H + " " + R, Balanced);
            Expect("passthrough-mixed", delegate (Sim s)
            {
                s.Down("X"); s.Up("X"); s.Down("KO_RALT"); s.Up("KO_RALT"); s.Down("RALT"); s.Up("RALT");
                s.Down("LSHIFT"); s.Down("A"); s.Up("A"); s.Up("LSHIFT");
            }, "+X -X " + R + " " + R + " +LSHIFT +A -A -LSHIFT", Balanced);

            // Windows has a single Boolean Right Alt state: a duplicate down followed
            // by up must never release a modifier that another source still owns.
            Expect("dedicated-pulse-preserves-mapped-alt", delegate (Sim s)
            {
                s.Down("KO_RALT"); s.Down("LANG1"); s.Up("LANG1");
                s.Down("A"); s.Up("A"); s.Up("KO_RALT");
            }, "+RALT +A -A -RALT", Balanced);
            Expect("dedicated-pulse-preserves-genuine-alt", delegate (Sim s)
            {
                s.Down("RALT"); s.Down("LANG1_72"); s.Up("LANG1_72");
                s.Down("A"); s.Up("A"); s.Up("RALT");
            }, "+RALT +A -A -RALT", delegate (Sim s) { return s.Injected.Count == 0 ? null : "injected over physical Alt"; });
            Expect("aggregate-mapped-then-genuine", delegate (Sim s)
            {
                s.Down("KO_RALT"); s.Down("RALT"); s.Up("KO_RALT");
                s.Down("A"); s.Up("A"); s.Up("RALT");
            }, "+RALT +A -A -RALT");
            Expect("aggregate-genuine-then-mapped", delegate (Sim s)
            {
                s.Down("RALT"); s.Down("KO_RALT"); s.Up("RALT");
                s.Down("A"); s.Up("A"); s.Up("KO_RALT");
            }, "+RALT +A -A -RALT");
            ExpectMode("dedicated-hold-chord", true, delegate (Sim s)
            {
                s.Down("LANG1_72"); s.Wait(500); s.Down("A"); s.Up("A"); s.Up("LANG1_72");
            }, "+RALT +A -A -RALT", Balanced);
            ExpectMode("dedicated-hold-f2-chord", true, delegate (Sim s)
            {
                s.Down("LANG1"); s.Down("A"); s.Up("A"); s.Up("LANG1");
            }, "+RALT +A -A -RALT", Balanced);
            ExpectMode("dedicated-hold-aggregate-release-mapped-first", true, delegate (Sim s)
            {
                s.Down("KO_RALT"); s.Down("LANG1"); s.Up("KO_RALT");
                s.Down("A"); s.Up("A"); s.Up("LANG1");
            }, "+RALT +A -A -RALT", Balanced);
            ExpectMode("dedicated-hold-aggregate-release-dedicated-first", true, delegate (Sim s)
            {
                s.Down("LANG1"); s.Down("KO_RALT"); s.Up("LANG1");
                s.Down("A"); s.Up("A"); s.Up("KO_RALT");
            }, "+RALT +A -A -RALT", Balanced);
            ExpectMode("dedicated-hold-reset", true, delegate (Sim s)
            {
                s.Down("LANG1"); s.Reset();
            }, R, Balanced);

            // Reset / cancellation
            Expect("reset-cancels-pending", delegate (Sim s)
            {
                s.Down("CAPS"); s.Wait(100); s.Reset(); s.Wait(500);
                s.Down("CAPS"); s.Wait(33); s.Down("CAPS"); s.Up("CAPS");
                s.Down("CAPS"); s.Wait(50); s.Up("CAPS");
            }, H);
            Expect("reset-releases-right-alt", delegate (Sim s) { s.Down("KO_RALT"); s.Reset(); }, R, Balanced);
            Expect("missed-release-recovery", delegate (Sim s)
            {
                s.Down("CAPS"); s.Wait(400); /* release lost */ s.Late(5000); s.Down("CAPS"); s.Wait(100); s.Up("CAPS");
            }, C + " " + H);
            Expect("reset-then-immediate-fresh-tap", delegate (Sim s)
            {
                s.Down("CAPS"); s.Wait(50); s.Reset(); // release was lost on the secure desktop
                s.Down("CAPS"); s.Wait(80); s.Up("CAPS");
            }, H);
            Expect("reset-then-fresh-hold", delegate (Sim s)
            {
                s.Down("CAPS"); s.Wait(50); s.Reset();
                s.Down("CAPS"); s.Wait(300); s.Up("CAPS");
            }, C);
            Expect("reset-then-fresh-hold-with-fast-repeat", delegate (Sim s)
            {
                s.Down("CAPS"); s.Wait(50); s.Reset();
                s.Down("CAPS"); s.Wait(250); s.Down("CAPS");
                s.Wait(33); s.Down("CAPS"); s.Wait(17); s.Up("CAPS");
            }, C);
            Expect("overlap-exact-boundary-late-timer", delegate (Sim s)
            {
                s.Down("CAPS"); s.Late(300); s.Down("A"); s.Up("A"); s.Up("CAPS");
            }, C + " +A -A");

            // Delivery tracking uses successful prefixes, not the Engine's desired state.
            OutputTracker tr = new OutputTracker();
            List<KeyOut> altDown = new List<KeyOut> { new KeyOut(Engine.VK_RMENU, Engine.SC_ALT, false, true) };
            List<KeyOut> altUp = new List<KeyOut> { new KeyOut(Engine.VK_RMENU, Engine.SC_ALT, true, true) };
            tr.Record(altDown, 0);
            Check("failed-down-does-not-create-output-ownership", tr.Count == 0, "owned=" + tr.Count);
            tr.Record(altDown, 1);
            tr.Record(altUp, 0);
            Check("failed-up-retains-output-ownership", tr.Owns(Engine.VK_RMENU) && tr.Outstanding(false).Count == 1, "ownership lost");
            Check("held-alt-is-not-flushed", tr.Outstanding(true).Count == 0, "held Alt scheduled for release");
            tr.Record(altUp, 0);
            Check("repeated-up-failure-retains-retry", tr.Outstanding(false).Count == 1, "retry lost");
            tr.Record(altUp, 1);
            Check("successful-up-clears-output-ownership", tr.Count == 0, "owned=" + tr.Count);
            List<KeyOut> partial = new List<KeyOut> {
                new KeyOut(Engine.VK_HANGUL, Engine.SC_HANGUL_OUT, false, false),
                new KeyOut(Engine.VK_HANGUL, Engine.SC_HANGUL_OUT, true, false),
                new KeyOut(0x41, 0x1E, false, false) };
            tr.Record(partial, 1);
            Check("partial-pulse-retains-only-unreleased-key", tr.Owns(Engine.VK_HANGUL) && tr.Count == 1, "partial output untracked");
            tr.Record(tr.Outstanding(false), 1);
            Check("partial-pulse-cleanup-clears-ownership", tr.Count == 0, "cleanup did not clear");
            tr.Record(partial, 2);
            Check("delivered-pulse-before-unsent-original-is-balanced", tr.Count == 0, "balanced pulse remains owned");
            tr.Record(altDown, 1);
            tr.Record(altDown, 1);
            Check("duplicate-down-is-boolean-not-counter", tr.Count == 1, "duplicate output ownership");
            tr.ObserveNative(Key("RALT", true, 100));
            Check("native-final-alt-up-clears-injected-owner", tr.Count == 0, "stale native ownership");

            // Injection bypass
            Expect("own-injection-bypass", delegate (Sim s)
            {
                s.Inject("CAPS", false, true); s.Inject("KO_RALT", false, true); s.Inject("LANG1", false, true);
            }, "+CAPS +HANGUL +HANGUL", delegate (Sim s) { return s.E.State == CapsState.Idle && !s.E.RightAltDown ? null : "state changed"; });
            Expect("foreign-injection-no-commit", delegate (Sim s)
            {
                s.Down("CAPS"); s.Wait(50); s.Inject("A", false, false); s.Inject("A", true, false); s.Wait(50); s.Up("CAPS");
            }, "+A -A " + H);

            // Monotonic wraparound
            Expect("tick-wraparound", delegate (Sim s)
            {
                s.T = 0xFFFFFFA0u; // tap crosses the 32-bit tick wrap
                s.Down("CAPS"); s.Wait(200); s.Up("CAPS");
                // hold whose deadline lies past the wrap
                s.T = 0xFFFFFFF0u;
                s.Down("CAPS"); s.Wait(400); s.Up("CAPS");
            }, H + " " + C);

            // ABI
            int expectInput = IntPtr.Size == 8 ? 40 : 28;
            Check("abi-input-size", Native.InputSize == expectInput, "sizeof(INPUT)=" + Native.InputSize + ", expected " + expectInput);
            int expectKbd = IntPtr.Size == 8 ? 24 : 16;
            int kbd = Marshal.SizeOf(typeof(Native.KEYBDINPUT));
            Check("abi-keybdinput-size", kbd == expectKbd, "sizeof(KEYBDINPUT)=" + kbd + ", expected " + expectKbd);
            int expectHook = IntPtr.Size == 8 ? 24 : 20;
            int hk = Marshal.SizeOf(typeof(Native.KBDLLHOOKSTRUCT));
            Check("abi-kbdllhookstruct-size", hk == expectHook, "sizeof(KBDLLHOOKSTRUCT)=" + hk + ", expected " + expectHook);
            Native.INPUT ra = Native.BuildInput(new KeyOut(Engine.VK_RMENU, Engine.SC_ALT, false, true));
            Check("rmenu-input-flags", ra.type == Native.INPUT_KEYBOARD && ra.u.ki.wVk == 0xA5 &&
                  ra.u.ki.dwFlags == Native.KEYEVENTF_EXTENDEDKEY && ra.u.ki.dwExtraInfo == Native.OwnTag,
                  "vk=" + ra.u.ki.wVk + " flags=" + ra.u.ki.dwFlags);
            Native.INPUT ru = Native.BuildInput(new KeyOut(Engine.VK_RMENU, Engine.SC_ALT, true, true));
            Check("rmenu-up-flags-no-scancode", ru.u.ki.dwFlags == (Native.KEYEVENTF_EXTENDEDKEY | Native.KEYEVENTF_KEYUP) &&
                  (ru.u.ki.dwFlags & Native.KEYEVENTF_SCANCODE) == 0, "flags=" + ru.u.ki.dwFlags);
            Native.INPUT hg = Native.BuildInput(new KeyOut(Engine.VK_HANGUL, Engine.SC_HANGUL_OUT, false, false));
            Check("hangul-input-vk", hg.u.ki.wVk == 0x15 && hg.u.ki.dwFlags == 0, "vk=" + hg.u.ki.wVk + " flags=" + hg.u.ki.dwFlags);

            log.AppendLine();
            log.AppendLine("self-test: " + passed + " passed, " + failed + " failed (pure state machine and ABI only; no hook, no SendInput)");
            string text = log.ToString();
            try { Console.Out.Write(text); } catch { }
            if (reportPath != null)
            {
                try { File.WriteAllText(reportPath, text, new UTF8Encoding(false)); }
                catch (Exception ex)
                {
                    try { Console.Error.WriteLine("cannot write report: " + ex.Message); } catch { }
                    return false;
                }
            }
            return failed == 0;
        }
    }
}
