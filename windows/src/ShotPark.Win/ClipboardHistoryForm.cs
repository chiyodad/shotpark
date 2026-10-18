using System.Drawing.Drawing2D;
using ShotPark.Core;

namespace ShotPark.Win;

/// "Clipboard Images": the last 30 copied images in a thumbnail grid. Click / Enter copies one
/// again, drag it into another app, Delete removes it, right-click for more.
sealed class ClipboardHistoryForm : Form
{
    readonly ClipboardHistory _history;
    readonly ClipGrid _grid;
    readonly Label _count;
    readonly Label _empty;

    static string L(string ko, string en) => Strings.L(ko, en);

    public ClipboardHistoryForm(ClipboardHistory history)
    {
        _history = history;
        Text = L("클립보드 이미지", "Clipboard Images");
        Font = new Font(Strings.Korean ? "Malgun Gothic" : "Segoe UI", 9.5f);
        AutoScaleMode = AutoScaleMode.Dpi;
        StartPosition = FormStartPosition.Manual;
        ClientSize = new Size(780, 520);
        MinimumSize = new Size(440, 320);
        TopMost = true;
        ShowInTaskbar = true;
        KeyPreview = true;
        Icon = TrayApp.AppIcon;
        BackColor = SystemColors.Window;

        var header = new TableLayoutPanel { Dock = DockStyle.Top, Height = 44, ColumnCount = 3, Padding = new Padding(12, 8, 12, 4) };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        _count = new Label { AutoSize = true, ForeColor = SystemColors.GrayText, Anchor = AnchorStyles.Left, Margin = new Padding(0, 6, 12, 0) };
        var hint = new Label
        {
            AutoSize = false, Dock = DockStyle.Fill, AutoEllipsis = true, ForeColor = Color.FromArgb(150, 150, 150), TextAlign = ContentAlignment.MiddleLeft,
            Text = L("클릭·Enter 복사  ·  드래그로 다른 앱에 넣기  ·  Delete 삭제  ·  우클릭 더보기",
                     "Click / Enter to copy  ·  drag into another app  ·  Delete removes  ·  right-click for more"),
        };
        var clear = new Button { Text = L("모두 지우기", "Clear All"), AutoSize = true, Anchor = AnchorStyles.Right };
        clear.Click += (_, _) => ClearAll();
        header.Controls.Add(_count, 0, 0);
        header.Controls.Add(hint, 1, 0);
        header.Controls.Add(clear, 2, 0);

        _grid = new ClipGrid(history) { Dock = DockStyle.Fill };
        _grid.CopyRequested += CopyAndClose;
        _grid.SaveRequested += Save;
        _empty = new Label
        {
            Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, ForeColor = SystemColors.GrayText, Visible = false,
        };
        Controls.Add(_grid);
        Controls.Add(_empty);
        Controls.Add(header);
        history.Changed += Reload;
        FormClosed += (_, _) => history.Changed -= Reload;
        Reload();
    }

    void Reload()
    {
        if (IsDisposed) return;
        var n = _history.Entries.Count;
        _count.Text = L($"{n}개 / 최근 {ClipHistoryIndex.MaxCount}개 보관", $"{n} of last {ClipHistoryIndex.MaxCount}");
        _empty.Text = _history.Enabled
            ? L("아직 복사한 이미지가 없습니다.\n이미지를 Ctrl+C 하거나 ShotPark으로 캡처하면 여기에 쌓입니다.",
                "No images copied yet.\nCopy an image with Ctrl+C or capture with ShotPark and it shows up here.")
            : L("클립보드 이미지 기록이 꺼져 있습니다.\n설정에서 켤 수 있습니다.", "Clipboard image history is off.\nTurn it on in Settings.");
        _empty.Visible = n == 0;
        _grid.Visible = n > 0;
        _grid.Refresh();
    }

    public void ShowCentered()
    {
        var area = Screen.FromPoint(Cursor.Position).WorkingArea;
        Location = new Point(area.X + (area.Width - Width) / 2, area.Y + (area.Height - Height) / 2);
        _grid.Selected = _history.Entries.Count > 0 ? 0 : -1;
        _grid.AutoScrollPosition = Point.Empty;
        Show();
        Activate();
        Native.SetForegroundWindow(Handle);
        _grid.Focus();
    }

    void CopyAndClose(ClipEntry e)
    {
        if (!_history.CopyToClipboard(e)) return;
        Close();
        Toast.Show(L("클립보드에 복사됨", "Copied to clipboard"), null, null, 1400, L("Ctrl+V로 붙여넣기", "Paste with Ctrl+V"));
    }

    void Save(ClipEntry e)
    {
        using var dlg = new SaveFileDialog { Filter = "PNG (*.png)|*.png", FileName = FileNames.ForCapture(e.Date), AddExtension = true };
        if (dlg.ShowDialog(this) != DialogResult.OK) return;
        try { File.Copy(_history.PathOf(e), dlg.FileName, true); }
        catch (Exception ex) { Toast.Show(L("저장하지 못했습니다", "Couldn't save"), subtitle: ex.Message); }
    }

    void ClearAll()
    {
        if (_history.Entries.Count == 0) return;
        var yes = new TaskDialogButton(L("모두 지우기", "Clear All"));
        var page = new TaskDialogPage
        {
            Caption = "ShotPark",
            Heading = L("클립보드 이미지 기록을 모두 지울까요?", "Clear all clipboard images?"),
            Text = L("ShotPark이 보관한 사본만 지워집니다. 지금 클립보드에 있는 내용은 그대로입니다.",
                     "Only ShotPark's copies are removed; what's on the clipboard right now stays."),
            Buttons = { yes, TaskDialogButton.Cancel },
            DefaultButton = TaskDialogButton.Cancel,
        };
        if (TaskDialog.ShowDialog(this, page) == yes) _history.Clear();
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == Keys.Escape) { Close(); return true; }
        return base.ProcessCmdKey(ref msg, keyData);
    }
}

/// The thumbnail grid.
sealed class ClipGrid : ScrollableControl
{
    readonly ClipboardHistory _history;
    const int CellW = 172, CellH = 150, Gap = 10, Inset = 8;
    int _hover = -1;
    int _selected = -1;
    Point _downAt;
    int _downIndex = -1;

    public event Action<ClipEntry>? CopyRequested;
    public event Action<ClipEntry>? SaveRequested;

    static string L(string ko, string en) => Strings.L(ko, en);

    public ClipGrid(ClipboardHistory history)
    {
        _history = history;
        DoubleBuffered = true;
        AutoScroll = true;
        SetStyle(ControlStyles.Selectable | ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
        TabStop = true;
    }

    float S => DeviceDpi / 96f;
    IReadOnlyList<ClipEntry> Entries => _history.Entries;

    int Columns => Math.Max(1, (int)((ClientSize.Width - Inset * 2 * S + Gap * S) / ((CellW + Gap) * S)));

    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public int Selected
    {
        get => _selected;
        set
        {
            _selected = Entries.Count == 0 ? -1 : Math.Clamp(value, 0, Entries.Count - 1);
            if (_selected >= 0)
            {
                var r = CellRect(_selected);
                if (r.Top < 0) AutoScrollPosition = new Point(0, -AutoScrollPosition.Y + r.Top - (int)(8 * S));
                else if (r.Bottom > ClientSize.Height) AutoScrollPosition = new Point(0, -AutoScrollPosition.Y + r.Bottom - ClientSize.Height + (int)(8 * S));
            }
            Invalidate();
        }
    }

    /// Cell rectangle in client coordinates (scroll applied).
    Rectangle CellRect(int i)
    {
        var cols = Columns;
        var used = cols * CellW * S + (cols - 1) * Gap * S;
        var x0 = Inset * S + Math.Max(0, (ClientSize.Width - Inset * 2 * S - used) / 2);
        int r = i / cols, c = i % cols;
        return new Rectangle((int)(x0 + c * (CellW + Gap) * S), (int)(Inset * S + r * (CellH + Gap) * S) + AutoScrollPosition.Y, (int)(CellW * S), (int)(CellH * S));
    }

    int IndexAt(Point p)
    {
        for (var i = 0; i < Entries.Count; i++) if (CellRect(i).Contains(p)) return i;
        return -1;
    }

    public override void Refresh()
    {
        var rows = (Entries.Count + Columns - 1) / Columns;
        AutoScrollMinSize = new Size(0, (int)(Inset * 2 * S + rows * (CellH + Gap) * S));
        if (_selected >= Entries.Count) _selected = Entries.Count - 1;
        base.Refresh();
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        Refresh();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        using var caption = new Font(Font.FontFamily, 8.5f);
        var accent = Color.FromArgb(0, 120, 215);
        for (var i = 0; i < Entries.Count; i++)
        {
            var r = CellRect(i);
            if (!r.IntersectsWith(e.ClipRectangle)) continue;
            var sel = i == _selected;
            using (var p = Painter.RoundRect(r, 10 * S))
            {
                using var bg = new SolidBrush(sel ? Color.FromArgb(70, accent) : Color.FromArgb(i == _hover ? 26 : 13, 0, 0, 0));
                g.FillPath(bg, p);
                if (sel) using (var ring = new Pen(accent, 2 * S)) g.DrawPath(ring, p);
            }
            var box = new Rectangle(r.X + (int)(8 * S), r.Y + (int)(8 * S), r.Width - (int)(16 * S), r.Height - (int)(34 * S));
            if (_history.Thumbnail(Entries[i], (int)(320 * S)) is { } t)
            {
                var s = Math.Min(Math.Min((float)box.Width / t.Width, (float)box.Height / t.Height), 1);
                float w = t.Width * s, h = t.Height * s;
                g.DrawImage(t, box.X + (box.Width - w) / 2, box.Y + (box.Height - h) / 2, w, h);
            }
            var e2 = Entries[i];
            var age = DateTime.Now - e2.Date;
            var when = age.TotalSeconds < 60 ? L("방금", "just now")
                : age.TotalMinutes < 60 ? L($"{(int)age.TotalMinutes}분 전", $"{(int)age.TotalMinutes} min ago")
                : age.TotalHours < 24 ? L($"{(int)age.TotalHours}시간 전", $"{(int)age.TotalHours} hr ago")
                : L($"{(int)age.TotalDays}일 전", $"{(int)age.TotalDays} d ago");
            TextRenderer.DrawText(g, $"{when}  ·  {e2.Width}×{e2.Height}", caption,
                new Rectangle(r.X + (int)(10 * S), r.Bottom - (int)(24 * S), r.Width - (int)(20 * S), (int)(18 * S)), SystemColors.GrayText,
                TextFormatFlags.Left | TextFormatFlags.EndEllipsis);
        }
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        var i = IndexAt(e.Location);
        if (i != _hover) { _hover = i; Invalidate(); }
        if (e.Button == MouseButtons.Left && _downIndex >= 0 && (Math.Abs(e.X - _downAt.X) > 4 || Math.Abs(e.Y - _downAt.Y) > 4))
        {
            // drag the image file (and the bitmap) into another app
            var entry = Entries[_downIndex];
            _downIndex = -1;
            var data = new DataObject();
            data.SetData(DataFormats.FileDrop, new[] { _history.PathOf(entry) });
            using var img = _history.Load(entry);
            if (img != null) data.SetData(DataFormats.Bitmap, new Bitmap(img));
            DoDragDrop(data, DragDropEffects.Copy);
        }
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        _hover = -1;
        Invalidate();
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        Focus();
        var i = IndexAt(e.Location);
        if (i < 0) return;
        Selected = i;
        if (e.Button == MouseButtons.Left) { _downAt = e.Location; _downIndex = i; }
        if (e.Button == MouseButtons.Right) ShowMenu(i, e.Location);
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left && _downIndex >= 0 && IndexAt(e.Location) == _downIndex)
            CopyRequested?.Invoke(Entries[_downIndex]);
        _downIndex = -1;
    }

    void ShowMenu(int i, Point p)
    {
        var entry = Entries[i];
        var menu = new ContextMenuStrip();
        menu.Items.Add(L("복사", "Copy"), null, (_, _) => CopyRequested?.Invoke(entry));
        menu.Items.Add(L("다른 이름으로 저장…", "Save As…"), null, (_, _) => SaveRequested?.Invoke(entry));
        menu.Items.Add(L("폴더에서 보기", "Show in Folder"), null, (_, _) => TrayApp.RevealFile(_history.PathOf(entry)));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(L("기록에서 삭제", "Remove from History"), null, (_, _) => _history.Remove(entry));
        menu.Closed += (_, _) => BeginInvoke(() => menu.Dispose());
        menu.Show(this, p);
    }

    protected override bool IsInputKey(Keys keyData) =>
        keyData is Keys.Left or Keys.Right or Keys.Up or Keys.Down or Keys.Enter || base.IsInputKey(keyData);

    protected override void OnKeyDown(KeyEventArgs e)
    {
        var n = Entries.Count;
        if (n == 0) return;
        switch (e.KeyCode)
        {
            case Keys.Enter: if (_selected >= 0) CopyRequested?.Invoke(Entries[_selected]); break;
            case Keys.Delete or Keys.Back: if (_selected >= 0) _history.Remove(Entries[_selected]); break;
            case Keys.Left: Selected = Math.Max(0, _selected - 1); break;
            case Keys.Right: Selected = Math.Min(n - 1, _selected + 1); break;
            case Keys.Down: Selected = Math.Min(n - 1, (_selected < 0 ? -Columns : _selected) + Columns); break;
            case Keys.Up: Selected = Math.Max(0, _selected - Columns); break;
            default: return;
        }
        e.Handled = true;
    }
}
