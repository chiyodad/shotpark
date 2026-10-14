using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace ShotPark.Win;

static class Native
{
    public const int WM_HOTKEY = 0x0312;
    public const int WM_DPICHANGED = 0x02E0;
    public const uint MOD_NOREPEAT = 0x4000;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

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
}

/// Receives WM_HOTKEY for one global hotkey on a hidden message window.
sealed class HotKeyListener : NativeWindow, IDisposable
{
    const int Id = 0x5350; // "SP"
    bool _registered;

    public event Action? Pressed;

    public HotKeyListener() => CreateHandle(new CreateParams());

    public bool Register(ShotPark.Core.HotKeySpec spec)
    {
        Unregister();
        _registered = Native.RegisterHotKey(Handle, Id, (uint)spec.Mods | Native.MOD_NOREPEAT, (uint)spec.Key);
        return _registered;
    }

    public void Unregister()
    {
        if (_registered) Native.UnregisterHotKey(Handle, Id);
        _registered = false;
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == Native.WM_HOTKEY && m.WParam.ToInt32() == Id) Pressed?.Invoke();
        base.WndProc(ref m);
    }

    public void Dispose()
    {
        Unregister();
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
}
