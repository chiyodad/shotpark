using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

namespace ShotPark.Win;

static class Native
{
    public const int WM_HOTKEY = 0x0312;
    public const int WM_DPICHANGED = 0x02E0;
    public const int WM_CLIPBOARDUPDATE = 0x031D;
    public const uint MOD_NOREPEAT = 0x4000;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int cmd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool AllowSetForegroundWindow(int processId);

    [DllImport("user32.dll")]
    public static extern uint GetDpiForSystem();

    [DllImport("user32.dll")]
    static extern short GetKeyState(int vk);

    public static bool IsKeyDown(int vk) => (GetKeyState(vk) & 0x8000) != 0;

    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int X, Y; }

    [DllImport("user32.dll")]
    static extern IntPtr MonitorFromPoint(POINT pt, uint flags);

    [DllImport("shcore.dll")]
    static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);

    /// Effective DPI of the monitor containing the centre of `area` (falls back to the system DPI).
    public static uint DpiForArea(Rectangle area)
    {
        try
        {
            var mon = MonitorFromPoint(new POINT { X = area.X + area.Width / 2, Y = area.Y + area.Height / 2 }, 2 /* NEAREST */);
            if (mon != IntPtr.Zero && GetDpiForMonitor(mon, 0 /* MDT_EFFECTIVE_DPI */, out var x, out _) == 0 && x > 0) return x;
        }
        catch (DllNotFoundException) { }
        catch (EntryPointNotFoundException) { }
        return GetDpiForSystem();
    }

    // ───────────────────────── clipboard ─────────────────────────

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool AddClipboardFormatListener(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RemoveClipboardFormatListener(IntPtr hwnd);

    // ───────────────────────── windows (click to select a window) ─────────────────────────

    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int index);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetClassName(IntPtr hWnd, StringBuilder name, int max);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out int pid);

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("dwmapi.dll")]
    static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT value, int size);

    [DllImport("dwmapi.dll")]
    static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int value, int size);

    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    static readonly HashSet<string> ShellClasses = new(StringComparer.OrdinalIgnoreCase)
    {
        "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Windows.UI.Core.CoreWindow",
        "NotifyIconOverflowWindow", "TopLevelWindowForOverflowXamlIsland", "XamlExplorerHostIslandWindow",
    };

    /// Visible top-level windows (screen pixels), front to back — the targets of "click to select a window".
    public static List<Rectangle> VisibleWindows()
    {
        var list = new List<Rectangle>();
        var self = Environment.ProcessId;
        EnumWindows((h, _) =>
        {
            try
            {
                if (!IsWindowVisible(h) || IsIconic(h)) return true;
                var ex = (long)GetWindowLongPtr(h, -20 /* GWL_EXSTYLE */);
                if ((ex & 0x80 /* WS_EX_TOOLWINDOW */) != 0 && (ex & 0x40000 /* WS_EX_APPWINDOW */) == 0)
                {
                    GetWindowThreadProcessId(h, out var owner);
                    if (owner != self) return true; // menus, tooltips, overlays of other apps
                }
                if (DwmGetWindowAttribute(h, 14 /* DWMWA_CLOAKED */, out int cloaked, 4) == 0 && cloaked != 0) return true;
                var cls = new StringBuilder(256);
                GetClassName(h, cls, cls.Capacity);
                if (ShellClasses.Contains(cls.ToString())) return true;
                RECT r;
                if (DwmGetWindowAttribute(h, 9 /* DWMWA_EXTENDED_FRAME_BOUNDS */, out r, Marshal.SizeOf<RECT>()) != 0 && !GetWindowRect(h, out r))
                    return true;
                var rect = Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
                if (rect.Width >= 20 && rect.Height >= 20) list.Add(rect);
            }
            catch (Exception) { }
            return true;
        }, IntPtr.Zero);
        return list;
    }

    // ───────────────────────── cursors ─────────────────────────

    [StructLayout(LayoutKind.Sequential)]
    struct ICONINFO
    {
        public bool fIcon;
        public int xHotspot, yHotspot;
        public IntPtr hbmMask, hbmColor;
    }

    [DllImport("user32.dll")]
    static extern IntPtr CreateIconIndirect(ref ICONINFO info);

    [DllImport("gdi32.dll")]
    static extern bool DeleteObject(IntPtr obj);

    /// A cursor from a 32-bit bitmap with the hotspot at (x, y).
    public static Cursor CursorFrom(Bitmap bmp, int x, int y)
    {
        var color = bmp.GetHbitmap(Color.FromArgb(0, 0, 0, 0));
        using var maskBmp = new Bitmap(bmp.Width, bmp.Height, PixelFormat.Format1bppIndexed);
        var mask = maskBmp.GetHbitmap();
        var info = new ICONINFO { fIcon = false, xHotspot = x, yHotspot = y, hbmMask = mask, hbmColor = color };
        var handle = CreateIconIndirect(ref info);
        DeleteObject(color);
        DeleteObject(mask);
        return handle == IntPtr.Zero ? Cursors.Cross : new Cursor(handle);
    }

    // ───────────────────────── keyboard input (emoji panel) ─────────────────────────

    [DllImport("user32.dll")]
    static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

    /// Win + . opens the Windows emoji panel for the focused text box.
    public static void OpenEmojiPanel()
    {
        const byte LWin = 0x5B, Period = 0xBE;
        const uint Up = 0x0002;
        keybd_event(LWin, 0, 0, UIntPtr.Zero);
        keybd_event(Period, 0, 0, UIntPtr.Zero);
        keybd_event(Period, 0, Up, UIntPtr.Zero);
        keybd_event(LWin, 0, Up, UIntPtr.Zero);
    }
}

/// Receives WM_HOTKEY for several global hotkeys on a hidden message window.
sealed class HotKeyListener : NativeWindow, IDisposable
{
    readonly Dictionary<int, bool> _registered = new();

    public event Action<int>? Pressed;

    public HotKeyListener() => CreateHandle(new CreateParams());

    public bool Register(int id, ShotPark.Core.HotKeySpec spec)
    {
        Unregister(id);
        var ok = Native.RegisterHotKey(Handle, id, (uint)spec.Mods | Native.MOD_NOREPEAT, (uint)spec.Key);
        _registered[id] = ok;
        return ok;
    }

    public void Unregister(int id)
    {
        if (_registered.TryGetValue(id, out var on) && on) Native.UnregisterHotKey(Handle, id);
        _registered[id] = false;
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == Native.WM_HOTKEY) Pressed?.Invoke(m.WParam.ToInt32());
        base.WndProc(ref m);
    }

    public void Dispose()
    {
        foreach (var id in _registered.Keys.ToList()) Unregister(id);
        DestroyHandle();
    }
}

static class ScreenGrab
{
    /// The whole virtual desktop (all monitors), in physical pixels, as an opaque premultiplied bitmap.
    public static Bitmap Capture(Rectangle bounds)
    {
        using var raw = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppRgb);
        using (var g = Graphics.FromImage(raw))
            g.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size, CopyPixelOperation.SourceCopy);
        return ToPArgb(raw);
    }

    /// Converts to 32bppPArgb (fast to draw) with alpha forced opaque.
    public static Bitmap ToPArgb(Image src)
    {
        var bmp = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppPArgb);
        using var g = Graphics.FromImage(bmp);
        g.Clear(Color.Black);
        g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceOver;
        g.DrawImage(src, new Rectangle(0, 0, src.Width, src.Height), new Rectangle(0, 0, src.Width, src.Height), GraphicsUnit.Pixel);
        return bmp;
    }

    /// Copies pixels of a region as 0xAARRGGBB ints.
    public static int[] Pixels(Bitmap bmp, Rectangle r)
    {
        var px = new int[r.Width * r.Height];
        var data = bmp.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            for (var y = 0; y < r.Height; y++)
                Marshal.Copy(data.Scan0 + y * data.Stride, px, y * r.Width, r.Width);
        }
        finally { bmp.UnlockBits(data); }
        return px;
    }

    public static Bitmap FromPixels(int[] px, int w, int h)
    {
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        var data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        try
        {
            for (var y = 0; y < h; y++)
                Marshal.Copy(px, y * w, data.Scan0 + y * data.Stride, w);
        }
        finally { bmp.UnlockBits(data); }
        return bmp;
    }
}
