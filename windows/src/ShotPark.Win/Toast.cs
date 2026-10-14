using WinTimer = System.Windows.Forms.Timer;

namespace ShotPark.Win;

/// A small rounded notice near the bottom of the screen that fades out on its own.
sealed class Toast : Form
{
    readonly string _text;
    readonly Action? _onClick;
    readonly WinTimer _timer = new() { Interval = 30 };
    readonly float _scale;
    int _ticks;

    Toast(string text, Action? onClick, Rectangle area)
    {
        _text = text;
        _onClick = onClick;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        DoubleBuffered = true;
        BackColor = Color.FromArgb(32, 32, 34);
        Cursor = onClick != null ? Cursors.Hand : Cursors.Default;
        // Lay out for the DPI of the monitor the toast appears on (not the primary monitor's).
        var scale = _scale = Native.DpiForArea(area) / 96f;
        AutoScaleMode = AutoScaleMode.None;
        using var font = Painter.UiFont(14 * scale);
        var size = TextRenderer.MeasureText(_text, font);
        var w = size.Width + (int)(36 * scale);
        var h = size.Height + (int)(22 * scale);
        Bounds = new Rectangle(area.X + (area.Width - w) / 2, area.Bottom - h - (int)(70 * scale), w, h);
        using (var path = Painter.RoundRect(new RectangleF(0, 0, w, h), 12 * scale)) Region = new Region(path);
        Opacity = 0.96;
        _timer.Tick += (_, _) =>
        {
            _ticks++;
            if (_ticks > 60) Opacity -= 0.08; // ~1.8 s, then fade
            if (Opacity <= 0.05) Close();
        };
        Click += (_, _) => { _onClick?.Invoke(); Close(); };
    }

    protected override bool ShowWithoutActivation => true;

    protected override void WndProc(ref Message m)
    {
        // Already sized for its monitor; don't let Windows rescale it when it appears there.
        if (m.Msg == Native.WM_DPICHANGED) { m.Result = IntPtr.Zero; return; }
        base.WndProc(ref m);
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x00000080 | 0x08000000; // WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE
            return cp;
        }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        using var font = Painter.UiFont(14 * _scale);
        TextRenderer.DrawText(e.Graphics, _text, font, ClientRectangle, Color.White,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        _timer.Start();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _timer.Dispose();
        base.Dispose(disposing);
    }

    static Toast? _current;

    public static void Show(string text, Action? onClick = null, Rectangle? area = null)
    {
        _current?.Close();
        var a = area ?? Screen.FromPoint(Cursor.Position).WorkingArea;
        var toast = new Toast(text, onClick, a);
        toast.FormClosed += (_, _) => { if (_current == toast) _current = null; };
        _current = toast;
        toast.Show();
    }
}
