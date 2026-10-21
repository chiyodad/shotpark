using System.Drawing.Imaging;
using ShotPark.Core;
using WinTimer = System.Windows.Forms.Timer;

namespace ShotPark.Win;

/// A borderless top-most window covering every monitor, showing the frozen screenshot.
sealed class OverlayForm : Form
{
    readonly Bitmap _baseShot, _dim;
    /// The screenshot the overlay and the export use: the real one, or a copy with the picked window
    /// pasted in on its own (as if nothing covered it).
    Bitmap _shot;
    MosaicSource _mosaic;
    readonly IReadOnlyList<Native.WindowInfo> _windows;
    readonly Point _origin;
    /// The window shown on its own, and its corner radius, while Controller.PickedWindow is set.
    int? _windowShown;
    float _windowRadius;
    readonly AppSettings _settings;
    readonly WinTimer _tipTimer = new() { Interval = 450 };
    TextBox? _textBox;
    PointF _textAt;
    TextBox? _sizeBox;
    TextBox? _emojiReceiver;
    int _lastHover = -1;
    readonly Dictionary<string, Cursor> _cursors = new();

    public OverlayController Controller { get; }

    /// Raised with the result of the capture. `extra`: the share target (null = Windows share),
    /// the pin's screen rectangle, or nothing.
    public event Action<OverlayAction, Bitmap?, object?>? Finished;

    static string L(string ko, string en) => Strings.L(ko, en);

    public OverlayForm(Bitmap shot, Rectangle virtualScreen, IReadOnlyList<RectangleF> monitors, float scale, AppSettings settings, IReadOnlyList<Native.WindowInfo> windows)
    {
        _baseShot = _shot = shot;
        _windows = windows;
        _origin = virtualScreen.Location;
        _settings = settings;
        _dim = Painter.Dimmed(shot);
        _mosaic = new MosaicSource(shot, scale);

        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.None;
        Bounds = virtualScreen;
        TopMost = true;
        ShowInTaskbar = false;
        KeyPreview = false;
        // A Korean/Japanese/Chinese IME would swallow the tool letters (P, L, A, R…) as
        // composition input and float a candidate box over the capture. The text box re-enables it.
        ImeMode = ImeMode.Disable;
        DoubleBuffered = true;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.Opaque | ControlStyles.StandardDoubleClick, true);
        Text = "ShotPark";
        Cursor = Cursors.Cross;

        Controller = new OverlayController(new RectangleF(0, 0, virtualScreen.Width, virtualScreen.Height), monitors, scale, settings)
        {
            Windows = windows.Select(w => new WindowTarget(
                new RectangleF(w.Frame.X - virtualScreen.X, w.Frame.Y - virtualScreen.Y, w.Frame.Width, w.Frame.Height), WindowLabel(w))).ToList(),
            StampImages = () => ImageStamps.Names,
        };
        Controller.Changed += OnChanged;
        Controller.ActionRequested += OnAction;
        Controller.TextRequested += BeginText;
        Controller.TextStyleChanged += RestyleText;
        Controller.SizeEntryRequested += BeginSizeEntry;
        Controller.EmojiPickerRequested += OpenEmojiPicker;
        Controller.AddImageRequested += AddImage;
        Controller.ImageMenuRequested += ShowImageMenu;
        Controller.PasteRequested += PasteImage;
        Controller.WindowPicked += ShowWindowAlone;
        Controller.Notice += t => Toast.Show(t, null, Screen.FromPoint(Cursor.Position).WorkingArea, 1200);
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
        var p = PointToClient(Cursor.Position);
        Controller.PointerMove(p); // outline the window under the pointer right away
    }

    protected override void WndProc(ref Message m)
    {
        // One window spans monitors with different DPIs; don't let Windows rescale it when it "moves".
        if (m.Msg == Native.WM_DPICHANGED) { m.Result = IntPtr.Zero; return; }
        base.WndProc(ref m);
    }

    void OnChanged()
    {
        if (Controller.PickedWindow == null) DropWindowAlone();
        if (Controller.HoverItem != _lastHover)
        {
            _lastHover = Controller.HoverItem;
            _tipTimer.Stop();
            if (_lastHover >= 0) _tipTimer.Start();
        }
        Cursor = CursorFor(Controller.Cursor);
        Invalidate();
    }

    Cursor CursorFor(CursorKind kind)
    {
        switch (kind)
        {
            case CursorKind.Arrow: return Cursors.Default;
            case CursorKind.Move: return Cursors.SizeAll;
            case CursorKind.Grab: return Cursors.SizeAll;
            case CursorKind.SizeNWSE: return Cursors.SizeNWSE;
            case CursorKind.SizeNESW: return Cursors.SizeNESW;
            case CursorKind.SizeNS: return Cursors.SizeNS;
            case CursorKind.SizeWE: return Cursors.SizeWE;
            case CursorKind.IBeam: return Cursors.IBeam;
            case CursorKind.Hand: return Cursors.Hand;
            case CursorKind.Eraser: return Cached("eraser", () => { using var b = Icons.EraserCursor(Controller.Scale); return Native.CursorFrom(b, (int)(7 * Controller.Scale), (int)(19 * Controller.Scale)); });
            case CursorKind.Number: return NumberCursor();
            case CursorKind.Emoji: return EmojiCursor();
            case CursorKind.Camera: return Cached("camera", () => { using var b = Icons.CameraCursor(Controller.Scale); return Native.CursorFrom(b, b.Width / 2, b.Height / 2); });
            default: return Cursors.Cross;
        }
    }

    Cursor Cached(string key, Func<Cursor> make)
    {
        if (_cursors.TryGetValue(key, out var c)) return c;
        if (_cursors.Count > 20)
        {
            foreach (var old in _cursors.Values) if (old != Cursors.Cross) old.Dispose();
            _cursors.Clear();
        }
        c = make();
        _cursors[key] = c;
        return c;
    }

    /// The stamp itself is the cursor, so you see exactly what you're about to place.
    Cursor EmojiCursor()
    {
        var sc = Controller.Scale;
        var prefs = Controller.Prefs;
        if (prefs.StampImage is { } name && ImageStamps.Names.Contains(name) && ImageStamps.Image(name) is { } img)
        {
            var h = Math.Clamp(prefs.EmojiSize * 1.2f, 28, 96) * sc;
            var w = Math.Min(h * img.Width / Math.Max(img.Height, 1), 160 * sc);
            return Cached($"img:{name}@{(int)w}x{(int)h}", () =>
            {
                using var b = new Bitmap(Math.Max(2, (int)w), Math.Max(2, (int)h));
                using (var g = Graphics.FromImage(b))
                {
                    g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                    using var attr = new ImageAttributes();
                    attr.SetColorMatrix(new ColorMatrix { Matrix33 = 0.85f });
                    g.DrawImage(img, new Rectangle(0, 0, b.Width, b.Height), 0, 0, img.Width, img.Height, GraphicsUnit.Pixel, attr);
                    using var pen = new Pen(Color.FromArgb(150, 0, 122, 255), 1) { DashPattern = new[] { 3f, 2f } };
                    g.DrawRectangle(pen, 0, 0, b.Width - 1, b.Height - 1);
                }
                return Native.CursorFrom(b, b.Width / 2, b.Height / 2);
            });
        }
        var side = Math.Clamp(prefs.EmojiSize * 0.8f, 24, 64) * sc;
        return Cached($"{prefs.Emoji}@{(int)side}", () =>
        {
            var em = EmojiRenderer.Render(prefs.Emoji, side * 0.78f);
            using var b = new Bitmap((int)side, (int)side);
            using (var g = Graphics.FromImage(b))
            {
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.DrawImage(em, (b.Width - em.Width) / 2f, (b.Height - em.Height) / 2f, em.Width, em.Height);
            }
            return Native.CursorFrom(b, b.Width / 2, b.Height / 2);
        });
    }

    /// The next number stamp, drawn exactly as it will be placed.
    Cursor NumberCursor()
    {
        var c = Controller;
        var probe = new Shape { Tool = Tool.Number, Points = { PointF.Empty }, Color = c.Color, FontSize = c.TextSize, Number = c.Doc.NextNumber };
        var r = MathF.Min(probe.StampRadius, 30 * c.Scale);
        var side = (int)MathF.Round(r * 2 + 8 * c.Scale);
        return Cached($"n{probe.Number}@{side}@{probe.Color.ToArgb()}", () =>
        {
            using var b = new Bitmap(side, side);
            using (var g = Graphics.FromImage(b))
            {
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                probe.Points[0] = new PointF(side / 2f, side / 2f);
                probe.FontSize = r / 0.7f;
                Painter.DrawShape(g, probe, null);
            }
            return Native.CursorFrom(b, side / 2, side / 2);
        });
    }

    protected override void OnPaint(PaintEventArgs e) =>
        Painter.PaintOverlay(e.Graphics, Controller, _shot, _dim, _mosaic, e.ClipRectangle);

    protected override void OnPaintBackground(PaintEventArgs e) { }

    // ───────────────────────── input ─────────────────────────

    static bool Shift => (ModifierKeys & Keys.Shift) != 0;
    static bool Alt => (ModifierKeys & Keys.Alt) != 0;

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (_sizeBox != null) { EndSizeEntry(commit: true); return; }
        if (_textBox != null) { EndText(commit: true); return; } // a click elsewhere commits the text (and nothing else)
        if (e.Button is MouseButtons.Left or MouseButtons.Right)
            Controller.PointerDown(e.Location, e.Button == MouseButtons.Right ? PointerButton.Right : PointerButton.Left, e.Clicks, Alt);
    }

    protected override void OnMouseMove(MouseEventArgs e) => Controller.PointerMove(e.Location, Shift);

    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left) Controller.PointerUp(e.Location);
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (_textBox != null || _sizeBox != null || _emojiReceiver?.Focused == true) return base.ProcessCmdKey(ref msg, keyData);
        var vk = (int)(keyData & Keys.KeyCode);
        if (Controller.Key(vk, (keyData & Keys.Control) != 0, (keyData & Keys.Shift) != 0, (keyData & Keys.Alt) != 0))
            return true;
        return base.ProcessCmdKey(ref msg, keyData);
    }

    // ───────────────────────── text entry ─────────────────────────

    void BeginText(PointF at, Shape? existing)
    {
        _textAt = at;
        _textBox = new TextBox
        {
            Multiline = true,
            AcceptsReturn = true, // Shift+Enter → new line; plain Enter commits (handled in KeyDown)
            BorderStyle = BorderStyle.None,
            Text = existing?.Text.Replace("\n", "\r\n") ?? "",
            Location = new Point((int)MathF.Round(at.X) - 1, (int)MathF.Round(at.Y)),
            ScrollBars = ScrollBars.None,
            WordWrap = false,
            ImeMode = ImeMode.NoControl, // follow the user's own IME state (the form disables it)
        };
        RestyleText();
        _textBox.TextChanged += (_, _) => { RestyleText(); };
        _textBox.KeyDown += (_, e) =>
        {
            if (e.KeyCode == Keys.Enter && !e.Shift && !e.Alt) { e.SuppressKeyPress = true; EndText(commit: true); }
            else if (e.KeyCode == Keys.Escape) { e.SuppressKeyPress = true; EndText(commit: false); }
        };
        _textBox.LostFocus += (_, _) => { if (_textBox != null && _sizeBox == null) BeginInvoke(() => EndText(commit: true)); };
        Controls.Add(_textBox);
        _textBox.Focus();
        _textBox.SelectionStart = _textBox.TextLength;
    }

    /// Size / colour / style follow the option bars while typing.
    void RestyleText()
    {
        if (_textBox == null) return;
        var c = Controller;
        var font = Painter.TextFont(_textBox.Text.Length > 0 ? _textBox.Text : "가", c.TextSize);
        var old = _textBox.Font;
        _textBox.Font = font;
        if (!ReferenceEquals(old, Font)) old.Dispose();
        _textBox.ForeColor = c.Color;
        _textBox.BackColor = c.Prefs.TextStyle.HasFlag(TextStyles.Box)
            ? Blend(c.BoxColor, c.Prefs.BoxAlpha)
            : Painter.IsLight(c.Color) ? Color.FromArgb(60, 60, 64) : Color.FromArgb(250, 250, 250);
        var size = Painter.MeasureText(_textBox.Text + "W", font.Size);
        var min = Painter.MeasureText(L("텍스트 입력…", "Type text…"), font.Size);
        _textBox.Size = new Size((int)Math.Ceiling(Math.Max(size.Width, min.Width)) + 6, (int)Math.Ceiling(size.Height) + 4);
    }

    /// What a translucent box colour looks like over a mid-grey background.
    static Color Blend(Color c, float a) => Color.FromArgb(
        (int)(c.R * a + 128 * (1 - a)), (int)(c.G * a + 128 * (1 - a)), (int)(c.B * a + 128 * (1 - a)));

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
        else Controller.CancelText(); // a re-edited text comes back unchanged
    }

    // ───────────────────────── font size field ─────────────────────────

    void BeginSizeEntry(RectangleF r, int value)
    {
        _sizeBox = new TextBox
        {
            Text = value.ToString(),
            Bounds = Rectangle.Round(r),
            TextAlign = HorizontalAlignment.Center,
            Font = Painter.UiFont(r.Height * 0.55f, FontStyle.Bold),
            BorderStyle = BorderStyle.FixedSingle,
            MaxLength = 3,
        };
        _sizeBox.KeyDown += (_, e) =>
        {
            if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; EndSizeEntry(commit: true); }
            else if (e.KeyCode == Keys.Escape) { e.SuppressKeyPress = true; EndSizeEntry(commit: false); }
        };
        _sizeBox.LostFocus += (_, _) => { if (_sizeBox != null) BeginInvoke(() => EndSizeEntry(commit: true)); };
        Controls.Add(_sizeBox);
        _sizeBox.Focus();
        _sizeBox.SelectAll();
    }

    void EndSizeEntry(bool commit)
    {
        var box = _sizeBox;
        if (box == null) return;
        _sizeBox = null;
        var text = box.Text.Trim();
        Controls.Remove(box);
        box.Dispose();
        if (_textBox != null) _textBox.Focus(); else Focus();
        if (commit && int.TryParse(text, out var v)) Controller.SetTextSize(v);
    }

    // ───────────────────────── stamps ─────────────────────────

    /// "More…": the Windows emoji panel (Win + .) types into a hidden box.
    void OpenEmojiPicker()
    {
        if (_emojiReceiver == null)
        {
            _emojiReceiver = new TextBox { Bounds = new Rectangle(-200, -200, 120, 30), ImeMode = ImeMode.NoControl };
            _emojiReceiver.TextChanged += (_, _) =>
            {
                var t = _emojiReceiver.Text.Trim();
                if (t.Length == 0) return;
                var e = System.Globalization.StringInfo.GetNextTextElement(t);
                _emojiReceiver.Text = "";
                Controller.PickEmoji(e);
                Focus();
            };
            Controls.Add(_emojiReceiver);
        }
        if (Controller.Bars.FirstOrDefault(b => b.Kind == BarKind.Emoji) is { } bar)
            _emojiReceiver.Location = new Point((int)bar.Frame.X, (int)bar.Frame.Y); // the panel opens near the caret
        _emojiReceiver.Text = "";
        _emojiReceiver.Focus();
        Native.OpenEmojiPanel();
    }

    void AddImage()
    {
        using var dlg = new OpenFileDialog
        {
            Title = L("도장으로 쓸 이미지를 고르세요 (서명·로고 등, 투명 배경 PNG 권장)", "Choose an image to use as a stamp (signature, logo… a transparent PNG works best)"),
            Filter = L("이미지", "Images") + " (*.png;*.jpg;*.jpeg;*.gif;*.bmp;*.tif;*.tiff)|*.png;*.jpg;*.jpeg;*.gif;*.bmp;*.tif;*.tiff",
        };
        var ok = dlg.ShowDialog(this) == DialogResult.OK;
        Activate();
        Focus();
        if (!ok) return;
        if (ImageStamps.Add(dlg.FileName) is { } name) Controller.ImageAdded(name);
        else Toast.Show(L("이미지를 불러오지 못했습니다", "Couldn't load that image"), null, Screen.FromPoint(Cursor.Position).WorkingArea);
    }

    void ShowImageMenu(string name, PointF p)
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add(L("이 이미지 삭제", "Remove this image"), null, (_, _) =>
        {
            ImageStamps.Remove(name);
            Controller.ImageRemoved(name);
        });
        menu.Closed += (_, _) => BeginInvoke(() => menu.Dispose());
        menu.Show(this, Point.Round(p));
    }

    /// Ctrl+V: an image on the clipboard becomes a stamp in the middle of the selection.
    void PasteImage()
    {
        try
        {
            Image? img = null;
            var data = Clipboard.GetDataObject();
            if (data?.GetData("PNG") is MemoryStream png) img = Image.FromStream(png);
            img ??= Clipboard.GetImage();
            if (img == null) return;
            using (img) Controller.PlaceImage(ImageStamps.AddTransient(img));
        }
        catch (Exception) { }
    }

    // ───────────────────────── picked window ─────────────────────────

    static string WindowLabel(Native.WindowInfo w)
    {
        var title = w.Title.Trim();
        if (title.Length > 40) title = title[..39] + "…";
        var size = $"{w.Frame.Width} × {w.Frame.Height}";
        return title.Length > 0 ? $"{title}  ·  {size}" : size;
    }

    /// A window picked with a click: paste the window on its own (also the parts other windows
    /// covered) over the screenshot, so the overlay, mosaic and export all see just that window.
    void ShowWindowAlone(int i)
    {
        if (i < 0 || i >= _windows.Count) return;
        var w = _windows[i];
        _windowRadius = Native.CornerRadius(w, Controller.Scale);
        using var alone = Native.CaptureWindow(w);
        if (alone == null) { _windowShown = i; return; } // the app won't draw itself: keep the screen pixels
        var composite = (Bitmap)_baseShot.Clone();
        using (var g = Graphics.FromImage(composite))
        {
            g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
            g.DrawImageUnscaled(alone, w.Frame.X - _origin.X, w.Frame.Y - _origin.Y);
        }
        SwapShot(composite);
        _windowShown = i;
    }

    void SwapShot(Bitmap shot)
    {
        if (!ReferenceEquals(_shot, _baseShot)) _shot.Dispose();
        _mosaic.Dispose();
        _shot = shot;
        _mosaic = new MosaicSource(shot, Controller.Scale);
    }

    /// The selection moved or changed: back to the real screenshot.
    void DropWindowAlone()
    {
        if (_windowShown == null) return;
        _windowShown = null;
        if (!ReferenceEquals(_shot, _baseShot)) SwapShot(_baseShot);
    }

    // ───────────────────────── results ─────────────────────────

    /// The annotated selection; `decorated` applies Beautify when it is on (copy / save / share do, pin doesn't).
    public Bitmap? RenderResult(bool decorated = true)
    {
        if (Controller.Selection is not { } s || s.Width < 1 || s.Height < 1) return null;
        var plain = Painter.RenderResult(_shot, _mosaic, s, Controller.Doc.Shapes);
        if (Controller.PickedWindow != null && _windowShown != null)
        {
            // A picked window keeps its own shape: rounded corners, transparent around it, and
            // (except when pinned) a soft window shadow.
            if (!decorated && _windowRadius <= 0) return plain;
            var shaped = Painter.Beautify(plain, Controller.Scale, shadow: decorated, rounded: _windowRadius > 0, radius: _windowRadius);
            plain.Dispose();
            return shaped;
        }
        if (!decorated || !_settings.Beautify) return plain;
        var pretty = Painter.Beautify(plain, Controller.Scale, _settings.BeautifyShadow, _settings.BeautifyRounded);
        plain.Dispose();
        return pretty;
    }

    /// The selection from the original screenshot (no annotations) — what text extraction reads.
    Bitmap? SelectionPixels()
    {
        if (Controller.Selection is not { } s || s.Width < 4 || s.Height < 4) return null;
        var r = Geometry.ToPixels(s);
        r.Intersect(new Rectangle(0, 0, _shot.Width, _shot.Height));
        return _shot.Clone(r, PixelFormat.Format32bppArgb);
    }

    void OnAction(OverlayAction action)
    {
        if (_textBox != null) EndText(commit: true);
        switch (action)
        {
            case OverlayAction.Close:
                Finished?.Invoke(action, null, null);
                return;
            case OverlayAction.Ocr:
                if (SelectionPixels() is { } px) Finished?.Invoke(action, px, null);
                return;
            case OverlayAction.Pin:
                if (Controller.Selection is { } s && RenderResult(decorated: false) is { } pin)
                {
                    var r = Geometry.ToPixels(s);
                    r.Offset(Bounds.Location);
                    Finished?.Invoke(action, pin, r);
                }
                return;
            case OverlayAction.Share:
                ShowShareMenu();
                return;
            default:
                if (RenderResult() is { } result) Finished?.Invoke(action, result, null);
                return;
        }
    }

    void ShowShareMenu()
    {
        if (Controller.Selection == null) return;
        var menu = new ContextMenuStrip { ShowImageMargin = true };
        foreach (var target in ShareTargets.Available())
        {
            var title = target.Installed
                ? L($"{target.Name}{Particle(target.Name)} 보내기", $"Send to {target.Name}")
                : L($"{target.Name}{Particle(target.Name)} 보내기 (웹)", $"Send to {target.Name} (web)");
            var item = new ToolStripMenuItem(title, target.Icon, (_, _) => { if (RenderResult() is { } img) Finished?.Invoke(OverlayAction.Share, img, target); });
            menu.Items.Add(item);
        }
        if (menu.Items.Count > 0) menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(L("다른 앱으로 공유… (Windows 공유)", "Share to another app… (Windows share)"), null,
            (_, _) => { if (RenderResult() is { } img) Finished?.Invoke(OverlayAction.Share, img, null); });
        menu.Closed += (_, _) => BeginInvoke(() => menu.Dispose());
        var anchor = Controller.ToolbarItemRect(ToolbarAction.Share) ?? Controller.ToolbarRect ?? RectangleF.Empty;
        menu.Show(this, new Point((int)anchor.X, (int)(anchor.Bottom + 4)));
    }

    /// "로" after a vowel- or ㄹ-ending Hangul syllable (and Latin names), "으로" otherwise.
    public static string Particle(string name)
    {
        var last = name.Length > 0 ? name[^1] : 'a';
        if (last < '가' || last > '힣') return "로";
        var jong = (last - '가') % 28;
        return jong == 0 || jong == 8 ? "로" : "으로";
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _tipTimer.Dispose();
            _dim.Dispose();
            _mosaic.Dispose();
            if (!ReferenceEquals(_shot, _baseShot)) _shot.Dispose();
            _baseShot.Dispose();
            foreach (var c in _cursors.Values) if (c != Cursors.Cross) c.Dispose();
        }
        base.Dispose(disposing);
    }
}
