using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using CapsLockHangul;

internal static class HookIntegration
{
    static readonly IntPtr TestTag = new IntPtr(0x48544C31);
    static readonly List<string> Out = new List<string>();
    static readonly List<object> Report = new List<object>();
    static Native.LowLevelKeyboardProc observer = Observe;
    static IntPtr observerHook;
    static HookApp app;
    static Form form;
    static TextBox box;
    static IntPtr priorForeground;
    static bool capsBefore;
    static bool initialImeOpen;
    static int initialConversion, initialSentence;
    static bool gotInitialIme;
    static bool aborted;
    static int failures;
    static string currentTest = "setup";
    static EventWaitHandle readyObserver;
    static Stopwatch runtime = Stopwatch.StartNew();

    [STAThread]
    static int Main(string[] args)
    {
        string path = args[0];
        priorForeground = Api.GetForegroundWindow();
        capsBefore = CapsOn();
        foreach (int vk in new int[] { 0x10, 0x11, 0x12, 0x5B, 0x5C })
            if (Down(vk)) { File.WriteAllText(path,"[{\"aborted\":\"physical modifier held\"}]"); return 2; }
        uint pid;
        uint thread = Api.GetWindowThreadProcessId(priorForeground, out pid);
        IntPtr hkl = Api.GetKeyboardLayout(thread);
        Api.ActivateKeyboardLayout(hkl, 0);
        Report.Add(new { environment = new { layout = Hex(hkl), inputSize = Native.InputSize, capsBefore = capsBefore, seam = "HOOK_INTEGRATION_TEST permits only the unique harness input tag; never enabled in release builds" } });
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        form = new Form { Text = "Disposable remapper integration test", Width = 580, Height = 180, StartPosition = FormStartPosition.CenterScreen, TopMost = true };
        box = new TextBox { Multiline = true, Dock = DockStyle.Fill, ImeMode = ImeMode.NoControl };
        form.Controls.Add(box);
        form.Shown += async delegate {
            try
            {
                form.Activate(); Api.SetForegroundWindow(form.Handle); box.Focus();
                await Wait(100);
                SaveIme();
                string testId = Guid.NewGuid().ToString("N");
                string readyName = "Local\\CapsLockHangul.Test.Ready." + testId;
                app = new HookApp("Local\\CapsLockHangul.Test." + testId, readyName, false);
                readyObserver = EventWaitHandle.OpenExisting(readyName);
                Result("not-ready-before-message-pump", !readyObserver.WaitOne(0));
                await Wait(30);
                Result("ready-after-hook-message-pump", readyObserver.WaitOne(0));
                observerHook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, observer, Native.GetModuleHandle(null), 0);
                if (observerHook == IntPtr.Zero) throw new Exception("Observer hook failed");
                await Run();
            }
            catch (Exception ex) { aborted = true; failures++; Report.Add(new { aborted = ex.ToString(), test = currentTest }); }
            finally
            {
                currentTest = "cleanup";
                try { if (app != null) { app.ResetState("integration cleanup"); app.ExitThread(); app = null; } } catch (Exception ex) { Report.Add(new { cleanupError = ex.Message }); }
                try
                {
                    if (Api.GetForegroundWindow() == form.Handle)
                    {
                        if (Down(0xA5)) SendOwn(new KeyOut(0xA5, 0x38, true, true));
                        if (CapsOn() != capsBefore) SendOwn(new KeyOut(0x14, 0x3A, false, false), new KeyOut(0x14, 0x3A, true, false));
                        RestoreIme();
                        Api.SetForegroundWindow(priorForeground);
                    }
                }
                catch (Exception ex) { Report.Add(new { cleanupError = ex.Message }); failures++; }
                if (observerHook != IntPtr.Zero) Native.UnhookWindowsHookEx(observerHook);
                if (readyObserver != null) readyObserver.Dispose();
                Report.Add(new { complete = new { failures = failures, aborted = aborted, elapsedMs = runtime.ElapsedMilliseconds, capsRestored = CapsOn() == capsBefore, altReleased = !Down(0xA5) } });
                string json = new JavaScriptSerializer().Serialize(Report);
                File.WriteAllText(path, json, new System.Text.UTF8Encoding(false));
                Console.WriteLine(json);
                form.Close();
            }
        };
        Application.Run(form);
        return failures == 0 ? 0 : 1;
    }

    static async Task Run()
    {
        Begin("tap");
        Input(0x14,0x3A,false,false); await Wait(100); Input(0x14,0x3A,true,false); await Wait(70);
        Check("tap-hangul-pulse", "+15 -15", CapsOn() == capsBefore);

        Begin("hold-repeat");
        Input(0x14,0x3A,false,false); await Wait(200); Input(0x14,0x3A,false,false); await Wait(200); Input(0x14,0x3A,false,false); await Wait(40); Input(0x14,0x3A,true,false); await Wait(70);
        Check("hold-caps-once", "+14 -14", CapsOn() != capsBefore);
        if (CapsOn() != capsBefore) SendOwn(new KeyOut(0x14,0x3A,false,false), new KeyOut(0x14,0x3A,true,false));
        await Wait(40);

        Begin("overlap");
        Input(0x14,0x3A,false,false); await Wait(40); Input(0x41,0x1E,false,false); Input(0x41,0x1E,true,false); Input(0x14,0x3A,true,false); await Wait(70);
        Check("overlap-hangul-before-replayed-letter", "+15 -15 +41", CapsOn() == capsBefore);

        Begin("korean-ralt");
        Input(0x15,0x38,false,true); await Wait(40); bool altDuring = Down(0xA5);
        Input(0x51,0x10,false,false); Input(0x51,0x10,true,false); Input(0x15,0x38,true,true); await Wait(50);
        Check("korean-ralt-held-and-released", "+A5 -A5", altDuring && !Down(0xA5));

        Begin("reset");
        Input(0x15,0x38,false,true); await Wait(30); app.ResetState("integration reset"); await Wait(40);
        Check("reset-releases-mapped-alt", "+A5 -A5", !Down(0xA5));
        Input(0x15,0x38,true,true); await Wait(20);

        Begin("dedicated-safe-default");
        Input(0x15,0x72,false,false); await Wait(40); bool dedicatedHeld = Down(0xA5);
        Input(0x15,0x72,true,false); await Wait(40);
        Check("dedicated-default-is-complete-pulse", "+A5 -A5", !dedicatedHeld);

        Begin("dedicated-pulse-while-ralt-held");
        Input(0x15,0x38,false,true); await Wait(25); Input(0x15,0xF2,false,false); await Wait(35); bool combinedHeld = Down(0xA5);
        Input(0x15,0x38,true,true); await Wait(30);
        bool retained = combinedHeld && !Down(0xA5);
        if (!retained) failures++;
        Report.Add(new { test = currentTest, pass = retained, outputs = string.Join(" ",Out.ToArray()), altStillHeldAfterDedicated = combinedHeld });
        Input(0x15,0xF2,true,false); await Wait(20);

        Begin("dedicated-pulse-while-genuine-alt-held");
        Input(0xA5,0x38,false,true); await Wait(25); Input(0x15,0x72,false,false); await Wait(35); bool genuineHeld = Down(0xA5);
        Input(0x15,0x72,true,false); Input(0xA5,0x38,true,true); await Wait(30);
        Check("default-pulse-preserves-genuine-alt", "", genuineHeld && !Down(0xA5));

        Begin("reset-immediate-fresh-caps");
        Input(0x14,0x3A,false,false); await Wait(35); app.ResetState("integration lock/unlock simulation");
        Input(0x14,0x3A,false,false); await Wait(65); Input(0x14,0x3A,true,false); await Wait(30);
        Check("reset-allows-immediate-fresh-tap", "+15 -15", true);

        Begin("exit-releases-alt");
        Input(0x15,0x38,false,true); await Wait(35); app.ExitThread(); app = null; await Wait(40);
        Check("exit-releases-mapped-alt", "+A5 -A5", !Down(0xA5));
        Result("exit-clears-readiness", !readyObserver.WaitOne(0));
        // Original injected test key was swallowed; send its release after hook cleanup
        // only to the same receiver to balance the harness's synthetic source state.
        Input(0x15,0x38,true,true); await Wait(20);

        Begin("constructor-failure-cleanup");
        bool rejected = false;
        try { new HookApp("Local\\CapsLockHangul.Test.Bad."+Guid.NewGuid().ToString("N"), new string('x',300), false); }
        catch (ArgumentException) { rejected = true; }
        Result("constructor-rejects-invalid-ready-name", rejected);
        Input(0x14,0x3A,false,false); Input(0x14,0x3A,true,false); await Wait(30);
        Check("failed-constructor-leaves-no-active-hook", "", CapsOn() != capsBefore);
        if (CapsOn() != capsBefore) SendOwn(new KeyOut(0x14,0x3A,false,false), new KeyOut(0x14,0x3A,true,false));
        await Wait(30);

        app = new HookApp("Local\\CapsLockHangul.Test.Hold."+Guid.NewGuid().ToString("N"), null, true);
        Begin("explicit-dedicated-hold");
        Input(0x15,0x72,false,false); await Wait(35); bool explicitHeld = Down(0xA5);
        Input(0x51,0x10,false,false); Input(0x51,0x10,true,false); Input(0x15,0x72,true,false); await Wait(35);
        Check("explicit-hold-maintains-dedicated-alt", "+A5 -A5", explicitHeld && !Down(0xA5));

        Begin("explicit-hold-mapped-release-first");
        Input(0x15,0x38,false,true); Input(0x15,0x72,false,false); Input(0x15,0x38,true,true); await Wait(35);
        bool dedicatedOwnerRemains = Down(0xA5); Input(0x15,0x72,true,false); await Wait(35);
        Check("aggregate-hold-mapped-release-first", "+A5 -A5", dedicatedOwnerRemains && !Down(0xA5));

        Begin("explicit-hold-dedicated-release-first");
        Input(0x15,0x72,false,false); Input(0x15,0x38,false,true); Input(0x15,0x72,true,false); await Wait(35);
        bool mappedOwnerRemains = Down(0xA5); Input(0x15,0x38,true,true); await Wait(35);
        Check("aggregate-hold-dedicated-release-first", "+A5 -A5", mappedOwnerRemains && !Down(0xA5));
    }

    static void Begin(string name) { currentTest = name; Out.Clear(); }
    static void Result(string name, bool pass) { if (!pass) failures++; Report.Add(new { test = name, pass = pass }); }
    static void Check(string name, string expected, bool state)
    {
        string got = string.Join(" ", Out.ToArray()); bool pass = got == expected && state;
        if (!pass) failures++;
        Report.Add(new { test = name, pass = pass, expected = expected, got = got, state = state });
    }
    static async Task Wait(int ms) { await Task.Delay(ms); Guard(); }
    static void Guard()
    {
        if (runtime.ElapsedMilliseconds > 8000) throw new Exception("Eight-second bound exceeded");
        if (Api.GetForegroundWindow() != form.Handle) throw new Exception("Foreground lost; injection aborted");
    }
    static void Input(ushort vk, ushort scan, bool up, bool ext)
    {
        Guard();
        Native.INPUT i = Native.BuildInput(new KeyOut(vk,scan,up,ext)); i.u.ki.dwExtraInfo = TestTag;
        if (Native.SendInput(1,new Native.INPUT[] { i },Native.InputSize) != 1) throw new Exception("Harness SendInput failed");
    }
    static void SendOwn(params KeyOut[] keys)
    {
        Guard(); Native.INPUT[] arr = new Native.INPUT[keys.Length];
        for (int i=0;i<keys.Length;i++) arr[i]=Native.BuildInput(keys[i]);
        if (Native.SendInput((uint)arr.Length,arr,Native.InputSize) != arr.Length) throw new Exception("Cleanup SendInput failed");
    }
    static IntPtr Observe(int code, IntPtr wp, IntPtr lp)
    {
        if (code >= 0)
        {
            Native.KBDLLHOOKSTRUCT key = (Native.KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lp,typeof(Native.KBDLLHOOKSTRUCT));
            if (key.dwExtraInfo == Native.OwnTag)
                Out.Add(((key.flags & Native.LLKHF_UP) != 0 ? "-" : "+") + key.vkCode.ToString("X"));
        }
        return Native.CallNextHookEx(observerHook,code,wp,lp);
    }
    static void SaveIme()
    {
        IntPtr ctx=Api.ImmGetContext(box.Handle);
        if(ctx != IntPtr.Zero) { initialImeOpen=Api.ImmGetOpenStatus(ctx); gotInitialIme=Api.ImmGetConversionStatus(ctx,out initialConversion,out initialSentence); Api.ImmReleaseContext(box.Handle,ctx); }
    }
    static void RestoreIme()
    {
        IntPtr ctx=Api.ImmGetContext(box.Handle);
        if(ctx != IntPtr.Zero) { if(gotInitialIme) Api.ImmSetConversionStatus(ctx,initialConversion,initialSentence); Api.ImmSetOpenStatus(ctx,initialImeOpen); Api.ImmReleaseContext(box.Handle,ctx); }
    }
    static bool Down(int vk) { return (Api.GetAsyncKeyState(vk) & 0x8000) != 0; }
    static bool CapsOn() { return (Api.GetKeyState(0x14) & 1) != 0; }
    static string Hex(IntPtr p) { return "0x"+p.ToInt64().ToString("X"); }
    static class Api
    {
        [DllImport("user32.dll")] internal static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] internal static extern bool SetForegroundWindow(IntPtr hwnd);
        [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int vk);
        [DllImport("user32.dll")] internal static extern short GetKeyState(int vk);
        [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
        [DllImport("user32.dll")] internal static extern IntPtr GetKeyboardLayout(uint thread);
        [DllImport("user32.dll")] internal static extern IntPtr ActivateKeyboardLayout(IntPtr hkl,uint flags);
        [DllImport("imm32.dll")] internal static extern IntPtr ImmGetContext(IntPtr hwnd);
        [DllImport("imm32.dll")] internal static extern bool ImmReleaseContext(IntPtr hwnd,IntPtr ctx);
        [DllImport("imm32.dll")] internal static extern bool ImmGetOpenStatus(IntPtr ctx);
        [DllImport("imm32.dll")] internal static extern bool ImmSetOpenStatus(IntPtr ctx,bool open);
        [DllImport("imm32.dll")] internal static extern bool ImmGetConversionStatus(IntPtr ctx,out int conv,out int sentence);
        [DllImport("imm32.dll")] internal static extern bool ImmSetConversionStatus(IntPtr ctx,int conv,int sentence);
    }
}
