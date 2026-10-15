using System.Drawing.Drawing2D;
using ShotPark.Core;

namespace ShotPark.Win;

/// A capture pinned on screen: borderless, always on top, draggable. Scroll to resize,
/// double-click / Esc to close, right-click for copy / save / opacity — like the Mac app.
sealed class PinForm : Form
{
    static readonly List<PinForm> Open = new();
    public static int Count => Open.Count;
    public static event Action? CountChanged;

    readonly Bitmap _image;
    float _zoom = 1;
    Point _dragFrom;
    bool _dragging;

    static string L(string ko, string en) => Strings.L(ko, en);

    public static void Pin(Bitmap image, Rectangle screenRect)
    {
        var f = new PinForm(image, screenRect);
        Open.Add(f);
        f.FormClosed += (_, _) => { Open.Remove(f); CountChanged?.Invoke(); };
        f.Show();
        f.Activate();
        CountChanged?.Invoke();
    }

    public static void CloseAll()
    {
        foreach (var f in Open.ToList()) f.Close();
    }

    PinForm(Bitmap image, Rectangle screenRect)
    {
        _image = image;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.None;
        ShowInTaskbar = false;
        TopMost = true;
        DoubleBuffered = true;
        KeyPreview = true;
        Text = "ShotPark";
        Bounds = screenRect;
        Icon = TrayApp.AppIcon;
        BuildMenu();
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x00000080;   // WS_EX_TOOLWINDOW: not in Alt+Tab
            cp.ClassStyle |= 0x00020000; // CS_DROPSHADOW
            return cp;
        }
    }

    protected override void WndProc(ref Message m)
    {
        // Sized in physical pixels already; don't rescale when dragged to another monitor.
        if (m.Msg == Native.WM_DPICHANGED) { m.Result = IntPtr.Zero; return; }
        base.WndProc(ref m);
    }

    void BuildMenu()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add(L("복사", "Copy"), null, (_, _) => CopyImage());
        menu.Items.Add(L("저장…", "Save…"), null, (_, _) => SaveImage());
        var opacity = new ToolStripMenuItem(L("투명도", "Opacity"));
        foreach (var v in new[] { 100, 75, 50, 30 })
        {
            var item = new ToolStripMenuItem($"{v}%") { Tag = v };
            item.Click += (_, _) => Opacity = v / 100.0;
            opacity.DropDownItems.Add(item);
        }
        opacity.DropDownOpening += (_, _) =>
        {
            foreach (ToolStripMenuItem i in opacity.DropDownItems) i.Checked = (int)i.Tag! == (int)Math.Round(Opacity * 100);
        };
        menu.Items.Add(opacity);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(L("닫기", "Close"), null, (_, _) => Close());
        ContextMenuStrip = menu;
    }

    void CopyImage()
    {
        if (Exporter.Copy(_image))
            Toast.Show(L("클립보드에 복사됨", "Copied to clipboard"), null, Screen.FromControl(this).WorkingArea, 1000);
    }

    void SaveImage()
    {
        using var dlg = new SaveFileDialog { Filter = "PNG (*.png)|*.png", FileName = FileNames.ForCapture(DateTime.Now), AddExtension = true };
        if (dlg.ShowDialog(this) != DialogResult.OK) return;
        try { _image.Save(dlg.FileName, System.Drawing.Imaging.ImageFormat.Png); }
        catch (Exception ex) { Toast.Show(L("저장하지 못했습니다", "Couldn't save"), subtitle: ex.Message); }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.InterpolationMode = _zoom == 1 ? InterpolationMode.NearestNeighbor : InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.Half;
        g.DrawImage(_image, ClientRectangle);
        using var edge = new Pen(Color.FromArgb(90, 255, 255, 255), 1);
        g.DrawRectangle(edge, 0, 0, Width - 1, Height - 1);
    }

    protected override void OnPaintBackground(PaintEventArgs e) { }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        if (e.Clicks >= 2) { Close(); return; }
        _dragging = true;
        _dragFrom = e.Location;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (_dragging) Location = new Point(Left + e.X - _dragFrom.X, Top + e.Y - _dragFrom.Y);
    }

    protected override void OnMouseUp(MouseEventArgs e) => _dragging = false;

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        var f = 1 + Math.Clamp(e.Delta / 1200f, -0.3f, 0.3f);
        var z = Math.Clamp(_zoom * f, 0.2f, 4f);
        if (z == _zoom) return;
        _zoom = z;
        var size = new Size(Math.Max(16, (int)(_image.Width * _zoom)), Math.Max(16, (int)(_image.Height * _zoom)));
        var c = new Point(Left + Width / 2, Top + Height / 2);
        Bounds = new Rectangle(c.X - size.Width / 2, c.Y - size.Height / 2, size.Width, size.Height);
        Invalidate();
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        switch (keyData)
        {
            case Keys.Escape:
            case Keys.Control | Keys.W:
                Close();
                return true;
            case Keys.Control | Keys.C:
                CopyImage();
                return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _image.Dispose();
        base.Dispose(disposing);
    }
}
