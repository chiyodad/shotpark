using ShotPark.Core;
using WinTimer = System.Windows.Forms.Timer;

namespace ShotPark.Win;

/// A borderless top-most window covering every monitor, showing the frozen screenshot.
sealed class OverlayForm : Form
{
    readonly Bitmap _shot, _dim, _mosaic;
    readonly WinTimer _tipTimer = new() { Interval = 450 };
    TextBox? _textBox;
    PointF _textAt;
    bool _textReedit;
    int _lastHover = -1;

    public OverlayController Controller { get; }

    /// Raised once with the result of the capture (or null when cancelled).
    public event Action<OverlayAction, Bitmap?>? Finished;

    public OverlayForm(Bitmap shot, Rectangle virtualScreen, IReadOnlyList<RectangleF> monitors, float scale, AppSettings settings)
    {
        _shot = shot;
        _dim = Painter.Dimmed(shot);
        _mosaic = Painter.Pixelated(shot, scale);

        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.None;
        Bounds = virtualScreen;
        TopMost = true;
        ShowInTaskbar = false;
        KeyPreview = true;
        DoubleBuffered = true;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.Opaque, true);
        Text = "ShotPark";
        Cursor = Cursors.Cross;

        Controller = new OverlayController(new RectangleF(0, 0, virtualScreen.Width, virtualScreen.Height), monitors, scale)
        {
            ColorIndex = settings.ColorIndex,
            WidthIndex = settings.WidthIndex,
            MeasureText = Painter.MeasureText,
        };
        Controller.Changed += OnChanged;
        Controller.ActionRequested += OnAction;
        Controller.TextRequested += BeginText;
        _tipTimer.Tick += (_, _) =>
        {
            _tipTimer.Stop();
            if (Controller.HoverItem >= 0) Controller.SetHover(Controller.HoverItem, true);
        };
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW: keep out of Alt+Tab
            return cp;
        }
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        Activate();
        Native.SetForegroundWindow(Handle);
        Focus();
    }

    protected override void WndProc(ref Message m)
    {
        // One window spans monitors with different DPIs; don't let Windows rescale it when it "moves".
        if (m.Msg == Native.WM_DPICHANGED) { m.Result = IntPtr.Zero; return; }
        base.WndProc(ref m);
    }

    void OnChanged()
    {
        if (Controller.HoverItem != _lastHover)
        {
            _lastHover = Controller.HoverItem;
            _tipTimer.Stop();
            if (_lastHover >= 0) _tipTimer.Start();
        }
        Cursor = Controller.Cursor switch
        {
            CursorKind.Arrow => Cursors.Default,
            CursorKind.Move => Cursors.SizeAll,
            CursorKind.SizeNWSE => Cursors.SizeNWSE,
            CursorKind.SizeNESW => Cursors.SizeNESW,
            CursorKind.SizeNS => Cursors.SizeNS,
            CursorKind.SizeWE => Cursors.SizeWE,
            CursorKind.IBeam => Cursors.IBeam,
            CursorKind.Hand => Cursors.Hand,
            _ => Cursors.Cross,
        };
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e) =>
        Painter.PaintOverlay(e.Graphics, Controller, _shot, _dim, _mosaic, e.ClipRectangle);

    protected override void OnPaintBackground(PaintEventArgs e) { }

    // ───────────────────────── input ─────────────────────────

    static bool Shift => (ModifierKeys & Keys.Shift) != 0;

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (_textBox != null) EndText(commit: true);
        if (e.Button is MouseButtons.Left or MouseButtons.Right)
            Controller.PointerDown(e.Location, e.Button == MouseButtons.Right ? PointerButton.Right : PointerButton.Left, Shift);
    }

    protected override void OnMouseMove(MouseEventArgs e) => Controller.PointerMove(e.Location, Shift);

    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left) Controller.PointerUp(e.Location, Shift);
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (_textBox != null) return base.ProcessCmdKey(ref msg, keyData);
        var key = Map(keyData & Keys.KeyCode);
        if (key != KeyCode.Other && Controller.Key(key, (keyData & Keys.Control) != 0, (keyData & Keys.Shift) != 0))
            return true;
        return base.ProcessCmdKey(ref msg, keyData);
    }

    static KeyCode Map(Keys k) => k switch
    {
        Keys.Escape => KeyCode.Escape,
        Keys.Enter => KeyCode.Enter,
        Keys.Delete => KeyCode.Delete,
        Keys.Back => KeyCode.Back,
        Keys.Left => KeyCode.Left,
        Keys.Right => KeyCode.Right,
        Keys.Up => KeyCode.Up,
        Keys.Down => KeyCode.Down,
        Keys.A => KeyCode.A, Keys.B => KeyCode.B, Keys.C => KeyCode.C, Keys.E => KeyCode.E,
        Keys.L => KeyCode.L, Keys.N => KeyCode.N, Keys.P => KeyCode.P, Keys.R => KeyCode.R,
        Keys.S => KeyCode.S, Keys.T => KeyCode.T, Keys.V => KeyCode.V, Keys.Y => KeyCode.Y,
        Keys.Z => KeyCode.Z,
        Keys.D1 or Keys.NumPad1 => KeyCode.D1,
        Keys.D2 or Keys.NumPad2 => KeyCode.D2,
        Keys.D3 or Keys.NumPad3 => KeyCode.D3,
        _ => KeyCode.Other,
    };

    // ───────────────────────── text entry ─────────────────────────

    void BeginText(PointF at, Shape? existing)
    {
        _textAt = at;
        _textReedit = existing != null;
        var size = existing?.FontSize ?? Controller.FontSize;
        if (existing != null)
        {
            Controller.ColorIndex = Math.Max(0, Array.IndexOf(Palette.Default, existing.Color));
        }
        var color = existing?.Color ?? Controller.Color;
        _textBox = new TextBox
        {
            Multiline = true,
            BorderStyle = BorderStyle.None,
            Font = Painter.TextFont(existing?.Text ?? "가", size),
            ForeColor = color,
            BackColor = Painter.IsLight(color) ? Color.FromArgb(60, 60, 64) : Color.White,
            Text = existing?.Text ?? "",
            Location = Point.Round(at),
            ScrollBars = ScrollBars.None,
            WordWrap = false,
        };
        ResizeTextBox();
        _textBox.TextChanged += (_, _) => ResizeTextBox();
        _textBox.KeyDown += (_, e) =>
        {
            if (e.KeyCode == Keys.Enter && !e.Shift) { e.SuppressKeyPress = true; EndText(commit: true); }
            else if (e.KeyCode == Keys.Escape) { e.SuppressKeyPress = true; EndText(commit: false); }
        };
        _textBox.LostFocus += (_, _) => { if (_textBox != null) BeginInvoke(() => EndText(commit: true)); };
        Controls.Add(_textBox);
        _textBox.Focus();
        _textBox.SelectionStart = _textBox.TextLength;
    }

    void ResizeTextBox()
    {
        if (_textBox == null) return;
        var size = Painter.MeasureText(_textBox.Text + "W", _textBox.Font.Size);
        _textBox.Size = new Size((int)Math.Ceiling(size.Width) + 4, (int)Math.Ceiling(size.Height) + 2);
    }

    void EndText(bool commit)
    {
        var box = _textBox;
        if (box == null) return;
        _textBox = null;
        var text = box.Text;
        Controls.Remove(box);
        box.Dispose();
        Focus();
        if (commit) Controller.CommitText(_textAt, text);
        else if (_textReedit) Controller.Undo(); // put the original back
        else Invalidate();
    }

    // ───────────────────────── results ─────────────────────────

    public Bitmap? RenderResult() => Controller.Selection is { } s && s.Width >= 1 && s.Height >= 1
        ? Painter.RenderResult(_shot, _mosaic, s, Controller.Doc.Shapes)
        : null;

    void OnAction(OverlayAction action)
    {
        if (_textBox != null) EndText(commit: true);
        var result = action == OverlayAction.Close ? null : RenderResult();
        if (action != OverlayAction.Close && result == null) return; // nothing selected yet
        Finished?.Invoke(action, result);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _tipTimer.Dispose();
            _dim.Dispose();
            _mosaic.Dispose();
            _shot.Dispose();
        }
        base.Dispose(disposing);
    }
}
