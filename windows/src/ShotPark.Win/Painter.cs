using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using ShotPark.Core;

namespace ShotPark.Win;

/// Mosaic / blur fills for annotation areas, taken from the original screenshot (so annotations
/// drawn on top are never blurred). Cached per rectangle, style and strength.
sealed class MosaicSource : IDisposable
{
    readonly Bitmap _shot;
    readonly float _scale;
    readonly Dictionary<string, (Rectangle, Bitmap)> _cache = new();

    public MosaicSource(Bitmap shot, float scale)
    {
        _shot = shot;
        _scale = scale;
    }

    public (Rectangle Rect, Bitmap Image)? Get(RectangleF area, MosaicStyle style, int level)
    {
        var r = Geometry.ToPixels(area);
        r.Intersect(new Rectangle(0, 0, _shot.Width, _shot.Height));
        if (r.Width < 1 || r.Height < 1) return null;
        var key = $"{r.X},{r.Y},{r.Width},{r.Height},{(int)style},{level}";
        if (_cache.TryGetValue(key, out var hit)) return hit;
        if (_cache.Count > 40) Clear();
        var amount = Effects.Amount(style, level) * _scale;
        Bitmap bmp;
        if (style == MosaicStyle.Pixelate)
        {
            var px = ScreenGrab.Pixels(_shot, r);
            Effects.Pixelate(px, r.Width, r.Height, (int)MathF.Round(amount));
            bmp = ScreenGrab.FromPixels(px, r.Width, r.Height);
        }
        else
        {
            // blur a margin around the area too, so its edges don't fade to the clamp colour
            var m = (int)MathF.Ceiling(amount * 1.5f);
            var big = Rectangle.Inflate(r, m, m);
            big.Intersect(new Rectangle(0, 0, _shot.Width, _shot.Height));
            var px = ScreenGrab.Pixels(_shot, big);
            Effects.Blur(px, big.Width, big.Height, amount);
            using var blurred = ScreenGrab.FromPixels(px, big.Width, big.Height);
            bmp = blurred.Clone(new Rectangle(r.X - big.X, r.Y - big.Y, r.Width, r.Height), PixelFormat.Format32bppArgb);
        }
        _cache[key] = (r, bmp);
        return (r, bmp);
    }

    void Clear()
    {
        foreach (var (_, b) in _cache.Values) b.Dispose();
        _cache.Clear();
    }

    public void Dispose() => Clear();
}

/// Draws the capture overlay, the annotations and the final image. Shared by the live overlay,
/// the exported result and the --rendertest previews, so all three look the same.
static class Painter
{
    // Same look as the Mac app's dark floating bars.
    public static readonly Color BarBg = Color.FromArgb(240, 31, 31, 31);
    public static readonly Color BarBorder = Color.FromArgb(46, 255, 255, 255);
    static readonly Color OnBg = Color.FromArgb(71, 255, 255, 255);
    static readonly Color HoverBg = Color.FromArgb(31, 255, 255, 255);
    public static readonly Color Purple = Color.FromArgb(92, 77, 219);
    static readonly Color TipBg = Color.FromArgb(245, 87, 87, 87);
    static readonly Color LabelFg = Color.FromArgb(153, 255, 255, 255);

    /// Installs the measurers the core uses for text, emoji and image sizes.
    public static void InstallMetrics()
    {
        Metrics.Text = MeasureText;
        Metrics.Emoji = EmojiRenderer.Measure;
        Metrics.ImageAspect = ImageStamps.Aspect;
        Metrics.UiText = (t, px) => MeasureUi(t, px).Width;
    }

    // ───────────────────────── backdrops ─────────────────────────

    public static Bitmap Dimmed(Bitmap shot)
    {
        var bmp = (Bitmap)shot.Clone(new Rectangle(0, 0, shot.Width, shot.Height), PixelFormat.Format32bppPArgb);
        using var g = Graphics.FromImage(bmp);
        using var b = new SolidBrush(Color.FromArgb(115, 0, 0, 0));
        g.FillRectangle(b, 0, 0, bmp.Width, bmp.Height);
        return bmp;
    }

    // ───────────────────────── overlay ─────────────────────────

    public static void PaintOverlay(Graphics g, OverlayController c, Bitmap shot, Bitmap dim, MosaicSource mosaic, Rectangle clip)
    {
        g.CompositingMode = CompositingMode.SourceCopy;
        g.InterpolationMode = InterpolationMode.NearestNeighbor;
        g.PixelOffsetMode = PixelOffsetMode.Half;
        g.DrawImage(dim, clip, clip, GraphicsUnit.Pixel);

        var sel = c.Selection;
        if (sel is { } s && s.Width >= 1 && s.Height >= 1)
        {
            var r = Geometry.ToPixels(s);
            var bright = Rectangle.Intersect(r, clip);
            if (!bright.IsEmpty) g.DrawImage(shot, bright, bright, GraphicsUnit.Pixel);
        }

        g.CompositingMode = CompositingMode.SourceOver;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        var sc = c.Scale;

        if (sel is not { } selection || selection.Width < 1)
        {
            if (c.HoverWindow is { } hw)
            {
                // the window a click would select
                using var o = new Pen(Color.FromArgb(217, 255, 255, 255), 2 * sc) { DashPattern = new[] { 3f, 2f } };
                g.DrawRectangle(o, hw.X + sc, hw.Y + sc, hw.Width - 2 * sc, hw.Height - 2 * sc);
            }
            DrawHint(g, c);
            return;
        }

        var state = g.Save();
        g.SetClip(selection);
        foreach (var shape in c.Doc.Shapes) DrawShape(g, shape, mosaic);
        if (c.Drawing is { } d) DrawShape(g, d, mosaic);
        g.Restore(state);

        // eraser: what a click would remove
        if (c.Tool == Tool.Eraser && c.EraserHover >= 0 && c.EraserHover < c.Doc.Shapes.Count)
        {
            using var red = new Pen(Color.FromArgb(255, 59, 48), 1.5f * sc) { DashPattern = new[] { 3f, 2f } };
            g.DrawPolygon(red, c.Doc.Shapes[c.EraserHover].Outline(4 * sc));
        }
        // the selected annotation (a shape just drawn with a drawing tool stays current silently)
        if (c.Selected is { } si && si < c.Doc.Shapes.Count && !Shape.IsStrokeTool(c.Tool))
        {
            using var dash = new Pen(Color.White, Math.Max(1, sc)) { DashPattern = new[] { 4f, 3f } };
            g.DrawPolygon(dash, c.Doc.Shapes[si].Outline(3 * sc));
        }
        if (c.StampHandle is { } h)
        {
            using var p = RoundRect(h, 2 * sc);
            g.FillPath(Brushes.White, p);
            using var edge = new Pen(Color.FromArgb(140, 0, 0, 0), 1);
            g.DrawPath(edge, p);
        }
        DrawRotateButtons(g, c);

        // selection frame + handles (select tool only, like the Mac app)
        using (var frame = new Pen(Color.White, 1))
            g.DrawRectangle(frame, selection.X - 0.5f, selection.Y - 0.5f, selection.Width, selection.Height);
        if (!c.Selecting && c.Tool == Tool.None)
        {
            var hr = 4 * sc;
            using var edge = new Pen(Color.FromArgb(128, 0, 0, 0), 1);
            foreach (var (_, pt) in Geometry.HandlePoints(selection))
            {
                var hrect = new RectangleF(pt.X - hr, pt.Y - hr, hr * 2, hr * 2);
                g.FillEllipse(Brushes.White, hrect);
                g.DrawEllipse(edge, hrect);
            }
        }

        DrawSizeLabel(g, c, selection);

        if (c.ToolbarRect is { } tb)
        {
            DrawToolbar(g, c, tb);
            foreach (var bar in c.Bars) DrawBar(g, c, bar);
            if (c.TipVisible && c.HoverItem >= 0) DrawTip(g, c, tb);
        }
    }

    static void DrawHint(Graphics g, OverlayController c)
    {
        var sc = c.Scale;
        var m = c.MonitorAt(c.Pointer);
        var rows = new (int Icon, string Text)[]
        {
            (0, Strings.L("드래그로 영역 선택", "Drag to select a region")),
            (1, Strings.L("클릭하여 창 선택", "Click to grab a window")),
            (2, Strings.L("Ctrl+A  이 모니터 전체", "Ctrl+A  this monitor")),
            (3, Strings.L("Esc  취소", "Esc  cancel")),
        };
        using var font = UiFont(15 * sc, FontStyle.Bold);
        float icon = 20 * sc, gap = 10 * sc, rowH = 28 * sc, pad = 16 * sc;
        var textW = rows.Max(r => g.MeasureString(r.Text, font).Width);
        var boxW = pad + icon + gap + textW + pad;
        var boxH = pad + rowH * rows.Length + pad - 6 * sc;
        var box = new RectangleF(MathF.Round(m.X + (m.Width - boxW) / 2), MathF.Round(m.Y + (m.Height - boxH) / 2), boxW, boxH);
        using (var path = RoundRect(box, 12 * sc))
        {
            using var bg = new SolidBrush(Color.FromArgb(209, 26, 26, 26));
            g.FillPath(bg, path);
            using var edge = new Pen(Color.FromArgb(31, 255, 255, 255), 1);
            g.DrawPath(edge, path);
        }
        using var fg = new SolidBrush(Color.FromArgb(242, 255, 255, 255));
        using var pen = new Pen(Color.FromArgb(235, 255, 255, 255), 1.6f * sc) { LineJoin = LineJoin.Round, StartCap = LineCap.Round, EndCap = LineCap.Round };
        for (var i = 0; i < rows.Length; i++)
        {
            var y = box.Y + pad - 3 * sc + rowH * i;
            var ib = new RectangleF(box.X + pad + 2 * sc, y + (rowH - 16 * sc) / 2, 16 * sc, 16 * sc);
            switch (rows[i].Icon)
            {
                case 0:
                    pen.DashPattern = new[] { 2f, 1.5f };
                    g.DrawRectangle(pen, ib.X, ib.Y + 2 * sc, ib.Width, ib.Height - 4 * sc);
                    pen.DashStyle = DashStyle.Solid;
                    break;
                case 1:
                    g.DrawRectangle(pen, ib.X, ib.Y + 1 * sc, ib.Width, ib.Height - 2 * sc);
                    g.DrawLine(pen, ib.X, ib.Y + 5 * sc, ib.Right, ib.Y + 5 * sc);
                    break;
                case 2:
                    g.DrawLines(pen, new[] { new PointF(ib.X, ib.Y + 5 * sc), new PointF(ib.X, ib.Y), new PointF(ib.X + 5 * sc, ib.Y) });
                    g.DrawLine(pen, ib.X, ib.Y, ib.X + 6 * sc, ib.Y + 6 * sc);
                    g.DrawLines(pen, new[] { new PointF(ib.Right, ib.Bottom - 5 * sc), new PointF(ib.Right, ib.Bottom), new PointF(ib.Right - 5 * sc, ib.Bottom) });
                    g.DrawLine(pen, ib.Right, ib.Bottom, ib.Right - 6 * sc, ib.Bottom - 6 * sc);
                    break;
                default:
                    g.DrawEllipse(pen, ib);
                    var k = 4.5f * sc;
                    g.DrawLine(pen, ib.X + k, ib.Y + k, ib.Right - k, ib.Bottom - k);
                    g.DrawLine(pen, ib.Right - k, ib.Y + k, ib.X + k, ib.Bottom - k);
                    break;
            }
            var th = g.MeasureString(rows[i].Text, font).Height;
            g.DrawString(rows[i].Text, font, fg, box.X + pad + icon + gap, y + (rowH - th) / 2);
        }
    }

    static void DrawSizeLabel(Graphics g, OverlayController c, RectangleF s)
    {
        var text = $"{(int)MathF.Round(s.Width)} × {(int)MathF.Round(s.Height)}";
        using var font = UiFont(11.5f * c.Scale);
        var size = g.MeasureString(text, font);
        float padX = 6 * c.Scale, padY = 2 * c.Scale;
        var box = new RectangleF(s.X, s.Y - size.Height - 2 * padY - 4 * c.Scale, size.Width + 2 * padX, size.Height + 2 * padY);
        var m = c.MonitorAt(new PointF(s.X, s.Y));
        if (box.Y < m.Top + 2) box.Y = s.Y + 4 * c.Scale;
        if (box.Right > m.Right) box.X = m.Right - box.Width;
        using (var path = RoundRect(box, 4 * c.Scale))
        using (var bg = new SolidBrush(Color.FromArgb(217, 26, 26, 26)))
            g.FillPath(bg, path);
        g.DrawString(text, font, Brushes.White, box.X + padX, box.Y + padY);
    }

    static void Panel(Graphics g, RectangleF r, float radius, float scale)
    {
        using var shadowPath = RoundRect(new RectangleF(r.X, r.Y + 2 * scale, r.Width, r.Height), radius);
        using (var shadow = new SolidBrush(Color.FromArgb(70, 0, 0, 0))) g.FillPath(shadow, shadowPath);
        using var path = RoundRect(r, radius);
        using (var bg = new SolidBrush(BarBg)) g.FillPath(bg, path);
        using var border = new Pen(BarBorder, 1);
        g.DrawPath(border, path);
    }

    public static void DrawToolbar(Graphics g, OverlayController c, RectangleF tb)
    {
        var sc = c.Scale;
        Panel(g, tb, 9 * sc, sc);
        var (rects, seps) = ToolbarLayout.Rects(sc);
        using (var sepPen = new Pen(BarBorder, Math.Max(1, sc)))
            foreach (var x in seps)
                g.DrawLine(sepPen, tb.X + x, tb.Y + 12 * sc, tb.X + x, tb.Bottom - 12 * sc);

        for (var i = 0; i < rects.Length; i++)
        {
            var item = ToolbarLayout.Items[i];
            var r = rects[i];
            r.Offset(tb.X, tb.Y);
            var active = item.Action == ToolbarAction.Tool && item.Tool == c.Tool
                         || item.Action == ToolbarAction.Color && c.PaletteOpen
                         || item.Action == ToolbarAction.Beautify && c.Settings.Beautify;
            var hover = i == c.HoverItem;
            if (active || hover)
            {
                using var hl = new SolidBrush(active ? OnBg : HoverBg);
                using var hp = RoundRect(RectangleF.Inflate(r, -2 * sc, -2 * sc), 6 * sc);
                g.FillPath(hl, hp);
            }
            var disabled = item.Action == ToolbarAction.Undo && !c.Doc.CanUndo;
            var color = c.Selected is { } s && s < c.Doc.Shapes.Count && c.EditableSelection != null ? c.Doc.Shapes[s].Color : c.Color;
            Icons.Draw(g, item, r, sc, color, disabled ? Color.FromArgb(110, 255, 255, 255) : Color.White);
        }
    }

    static void DrawTip(Graphics g, OverlayController c, RectangleF tb)
    {
        var sc = c.Scale;
        var (rects, _) = ToolbarLayout.Rects(sc);
        var item = rects[c.HoverItem];
        item.Offset(tb.X, tb.Y);
        var text = c.Tip(c.HoverItem);
        using var font = UiFont(12 * sc, FontStyle.Bold);
        var size = g.MeasureString(text, font, (int)(300 * sc));
        float padX = 9 * sc, padY = 6 * sc;
        var w = size.Width + 2 * padX;
        var h = size.Height + 2 * padY;
        var monitor = c.MonitorAt(Geometry.Center(tb));
        var x = Math.Clamp(item.X + item.Width / 2 - w / 2, monitor.Left + 4, MathF.Max(monitor.Left + 4, monitor.Right - w - 4));
        // on the side away from the option bars
        var y = c.BarsBelow ? tb.Top - h - 6 * sc : tb.Bottom + 6 * sc;
        if (y < monitor.Top + 2) y = tb.Bottom + 6 * sc;
        if (y + h > monitor.Bottom - 2) y = tb.Top - h - 6 * sc;
        var box = new RectangleF(x, y, w, h);
        using (var path = RoundRect(box, 6 * sc))
        {
            using var bg = new SolidBrush(TipBg);
            g.FillPath(bg, path);
            using var edge = new Pen(Color.FromArgb(64, 255, 255, 255), 1);
            g.DrawPath(edge, path);
        }
        g.DrawString(text, font, Brushes.White, new RectangleF(box.X + padX, box.Y + padY, size.Width + 2, size.Height + 2));
    }

    // ───────────────────────── option bars ─────────────────────────

    public static void DrawBar(Graphics g, OverlayController c, OptionBar bar)
    {
        var sc = c.Scale;
        Panel(g, bar.Frame, 8 * sc, sc);
        using var label = UiFont(11 * sc, FontStyle.Bold);
        using var itemFont = UiFont(12 * sc, FontStyle.Bold);
        using var labelBrush = new SolidBrush(LabelFg);
        using var center = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center, FormatFlags = StringFormatFlags.NoWrap };
        using var left = new StringFormat { LineAlignment = StringAlignment.Center, FormatFlags = StringFormatFlags.NoWrap };

        void Pill(RectangleF r, bool on, bool hover, bool purple = false)
        {
            if (!on && !hover) return;
            using var b = new SolidBrush(on ? (purple ? Purple : OnBg) : HoverBg);
            using var p = RoundRect(RectangleF.Inflate(r, -2 * sc, 0), 6 * sc);
            g.FillPath(b, p);
        }

        foreach (var cell in bar.Cells)
        {
            var r = bar.Abs(cell);
            var hover = cell.Id.Length > 0 && cell.Id == c.HoverCell;
            switch (cell.Kind)
            {
                case CellKind.Label:
                    g.DrawString(cell.Text, label, labelBrush, r, left);
                    break;
                case CellKind.Separator:
                    using (var sep = new SolidBrush(BarBorder)) g.FillRectangle(sep, r.X, r.Y, Math.Max(1, sc * 0.75f), r.Height);
                    break;
                case CellKind.Choice:
                {
                    Pill(r, cell.On, hover);
                    var font = cell.Id.StartsWith("size:") ? UiFont(MathF.Min(15, 9 + float.Parse(cell.Id[5..], System.Globalization.CultureInfo.InvariantCulture) * 0.14f) * sc, FontStyle.Bold) : null;
                    g.DrawString(cell.Text, font ?? itemFont, Brushes.White, r, center);
                    font?.Dispose();
                    break;
                }
                case CellKind.Width:
                {
                    Pill(r, cell.On, hover);
                    var d = (cell.Value + 3) * sc;
                    using (var b = new SolidBrush(cell.Color)) g.FillEllipse(b, r.X + 10 * sc, r.Y + (r.Height - d) / 2, d, d);
                    g.DrawString(cell.Text, itemFont, Brushes.White, new RectangleF(r.X + 24 * sc, r.Y, r.Width - 24 * sc, r.Height), left);
                    break;
                }
                case CellKind.Dash:
                {
                    Pill(r, cell.On, hover, purple: true);
                    using var pen = new Pen(Color.White, 2 * sc) { DashPattern = new[] { 1.5f, 1f } };
                    g.DrawLine(pen, r.X + 8 * sc, r.Y + r.Height / 2, r.X + 22 * sc, r.Y + r.Height / 2);
                    g.DrawString(cell.Text, itemFont, Brushes.White, new RectangleF(r.X + 25 * sc, r.Y, r.Width - 25 * sc, r.Height), left);
                    break;
                }
                case CellKind.Head:
                {
                    Pill(r, cell.On, hover, purple: true);
                    var m = Geometry.Center(r);
                    if (cell.Value == 0)
                    {
                        using var pen = new Pen(Color.White, 2.4f * sc) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
                        g.DrawLines(pen, new[] { new PointF(m.X - 4 * sc, m.Y - 7 * sc), new PointF(m.X + 4 * sc, m.Y), new PointF(m.X - 4 * sc, m.Y + 7 * sc) });
                    }
                    else g.FillEllipse(Brushes.White, m.X - 6 * sc, m.Y - 6 * sc, 12 * sc, 12 * sc);
                    break;
                }
                case CellKind.FillChoice:
                {
                    Pill(r, cell.On, hover, purple: true);
                    var sw = new RectangleF(r.X + 7 * sc, r.Y + r.Height / 2 - 6 * sc, 12 * sc, 12 * sc);
                    using var sp = RoundRect(sw, 2 * sc);
                    if (cell.Value > 0) using (var fb = new SolidBrush(Color.FromArgb((int)(cell.Value * 255), cell.Color))) g.FillPath(fb, sp);
                    using (var pen = new Pen(cell.Color, 1.5f * sc)) g.DrawPath(pen, sp);
                    g.DrawString(cell.Text, itemFont, Brushes.White, new RectangleF(sw.Right + 5 * sc, r.Y, r.Right - sw.Right - 5 * sc, r.Height), left);
                    break;
                }
                case CellKind.Slider:
                {
                    var y = r.Y + r.Height / 2;
                    using (var track = new Pen(Color.FromArgb(90, 255, 255, 255), 3 * sc) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                        g.DrawLine(track, r.X, y, r.Right, y);
                    var x = r.X + r.Width * Math.Clamp(cell.Value, 0, 1);
                    using (var on = new Pen(Purple, 3 * sc) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                        g.DrawLine(on, r.X, y, x, y);
                    g.FillEllipse(Brushes.White, x - 6 * sc, y - 6 * sc, 12 * sc, 12 * sc);
                    break;
                }
                case CellKind.Percent:
                    g.DrawString(cell.Text, label, labelBrush, new RectangleF(r.X + 4 * sc, r.Y, r.Width, r.Height), left);
                    break;
                case CellKind.SizeField:
                {
                    using var p = RoundRect(r, 5 * sc);
                    using (var b = new SolidBrush(hover ? Color.FromArgb(70, 255, 255, 255) : Color.FromArgb(40, 255, 255, 255))) g.FillPath(b, p);
                    using (var e = new Pen(Color.FromArgb(70, 255, 255, 255), 1)) g.DrawPath(e, p);
                    g.DrawString(cell.Text, itemFont, Brushes.White, r, center);
                    break;
                }
                case CellKind.Emoji:
                {
                    Pill(r, cell.On, hover);
                    var img = EmojiRenderer.Render(cell.Text, 18 * sc);
                    g.DrawImage(img, r.X + (r.Width - img.Width) / 2, r.Y + (r.Height - img.Height) / 2, img.Width, img.Height);
                    break;
                }
                case CellKind.Button:
                {
                    using var p = RoundRect(RectangleF.Inflate(r, -1 * sc, 0), 6 * sc);
                    var plain = cell.Id is "eminus" or "eplus";
                    if (!plain || hover)
                        using (var b = new SolidBrush(hover ? Color.FromArgb(51, 255, 255, 255) : Color.FromArgb(26, 255, 255, 255))) g.FillPath(b, p);
                    using var f = plain ? UiFont(15 * sc, FontStyle.Bold) : null;
                    g.DrawString(cell.Text, f ?? itemFont, Brushes.White, r, center);
                    break;
                }
                case CellKind.Image:
                {
                    using var p = RoundRect(RectangleF.Inflate(r, -1 * sc, -1 * sc), 6 * sc);
                    using (var b = new SolidBrush(Color.FromArgb(cell.On ? 230 : hover ? 90 : 46, 255, 255, 255))) g.FillPath(b, p);
                    if (ImageStamps.Image(cell.Text) is { } img)
                    {
                        var box = RectangleF.Inflate(r, -4 * sc, -4 * sc);
                        var s = Math.Min(box.Width / Math.Max(img.Width, 1), box.Height / Math.Max(img.Height, 1));
                        float iw = img.Width * s, ih = img.Height * s;
                        var st = g.Save();
                        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        g.DrawImage(img, box.X + (box.Width - iw) / 2, box.Y + (box.Height - ih) / 2, iw, ih);
                        g.Restore(st);
                    }
                    if (cell.On) using (var ring = new Pen(Purple, 2 * sc)) g.DrawPath(ring, p);
                    break;
                }
                case CellKind.Swatch:
                {
                    var inset = hover ? 0 : 2 * sc;
                    var dot = RectangleF.Inflate(r, -inset, -inset);
                    using (var b = new SolidBrush(cell.Color)) g.FillEllipse(b, dot);
                    if (cell.On)
                    {
                        using var ring = new Pen(Color.White, 2 * sc);
                        g.DrawEllipse(ring, RectangleF.Inflate(r, 1.5f * sc, 1.5f * sc));
                    }
                    else
                    {
                        using var ring = new Pen(Color.FromArgb(90, 255, 255, 255), 1);
                        g.DrawEllipse(ring, dot);
                    }
                    break;
                }
            }
        }
    }

    static void DrawRotateButtons(Graphics g, OverlayController c)
    {
        var buttons = c.RotateButtons;
        if (buttons.Count == 0 || c.Selected is not { } i || i >= c.Doc.Shapes.Count) return;
        var sc = c.Scale;
        using var font = UiFont(11 * sc, FontStyle.Bold);
        using var center = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
        foreach (var (dir, r) in buttons)
        {
            using (var p = RoundRect(r, 7 * sc))
            {
                using var bg = new SolidBrush(dir == 0 ? Color.FromArgb(242, Purple) : Color.FromArgb(235, 31, 31, 31));
                g.FillPath(bg, p);
                using var edge = new Pen(Color.FromArgb(56, 255, 255, 255), 1);
                g.DrawPath(edge, p);
            }
            if (dir == 0)
            {
                var deg = (int)MathF.Round(c.Doc.Shapes[i].Rotation) % 360;
                if (deg > 180) deg -= 360; else if (deg <= -180) deg += 360;
                g.DrawString($"{deg}° ✕", font, Brushes.White, r, center);
            }
            else Icons.RotateArrow(g, r, sc, clockwise: dir > 0);
        }
    }

    // ───────────────────────── shapes ─────────────────────────

    public static void DrawShape(Graphics g, Shape s, MosaicSource? mosaic)
    {
        var state = g.Save();
        try
        {
            if (s.IsRotatable && s.Rotation != 0)
            {
                var c = s.Pivot;
                g.TranslateTransform(c.X, c.Y);
                g.RotateTransform(s.Rotation);
                g.TranslateTransform(-c.X, -c.Y);
            }
            DrawShapeCore(g, s, mosaic);
        }
        finally { g.Restore(state); }
    }

    static void DrawShapeCore(Graphics g, Shape s, MosaicSource? mosaic)
    {
        switch (s.Tool)
        {
            case Tool.Mosaic:
            {
                if (mosaic?.Get(s.Rect, s.MosaicStyle, s.MosaicLevel) is { } m)
                {
                    var st = g.Save();
                    g.InterpolationMode = InterpolationMode.NearestNeighbor;
                    g.PixelOffsetMode = PixelOffsetMode.Half;
                    g.SmoothingMode = SmoothingMode.None;
                    g.DrawImage(m.Image, m.Rect, new Rectangle(0, 0, m.Rect.Width, m.Rect.Height), GraphicsUnit.Pixel);
                    g.Restore(st);
                }
                else
                {
                    using var grey = new SolidBrush(Color.Gray);
                    g.FillRectangle(grey, s.Rect);
                }
                return;
            }
            case Tool.Text:
                DrawText(g, s);
                return;
            case Tool.Number:
            {
                var r = s.StampRadius;
                var circle = new RectangleF(s.Start.X - r, s.Start.Y - r, r * 2, r * 2);
                using (var sh = new SolidBrush(Color.FromArgb(70, 0, 0, 0)))
                    g.FillEllipse(sh, RectangleF.Inflate(new RectangleF(circle.X, circle.Y + 1.5f, circle.Width, circle.Height), 1, 1));
                using (var fill = new SolidBrush(s.Color)) g.FillEllipse(fill, circle);
                using (var ring = new Pen(Color.White, MathF.Max(1.5f, r * 0.12f))) g.DrawEllipse(ring, RectangleF.Inflate(circle, -1, -1));
                using var font = new Font("Segoe UI", r * 1.15f, FontStyle.Bold, GraphicsUnit.Pixel);
                using var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                g.DrawString(s.Number.ToString(), font, Brushes.White, new RectangleF(circle.X - r, circle.Y + r * 0.04f, circle.Width + 2 * r, circle.Height), fmt);
                return;
            }
            case Tool.Emoji:
            {
                if (s.ImageName is { } name && ImageStamps.Image(name) is { } img && s.ImageRect is { } ir)
                {
                    var st = g.Save();
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.DrawImage(img, ir);
                    g.Restore(st);
                    return;
                }
                if (s.Text.Length == 0) return;
                var b = s.UnrotatedBounds;
                var bmp = EmojiRenderer.Render(s.Text, s.FontSize);
                // a soft drop shadow, like the Mac app
                using (var attr = new ImageAttributes())
                {
                    attr.SetColorMatrix(new ColorMatrix(new[]
                    {
                        new float[] { 0, 0, 0, 0, 0 }, new float[] { 0, 0, 0, 0, 0 }, new float[] { 0, 0, 0, 0, 0 },
                        new float[] { 0, 0, 0, 0.3f, 0 }, new float[] { 0, 0, 0, 0, 1 },
                    }));
                    g.DrawImage(bmp, new Rectangle((int)b.X, (int)(b.Y + MathF.Max(1, s.FontSize * 0.03f)), (int)b.Width, (int)b.Height), 0, 0, bmp.Width, bmp.Height, GraphicsUnit.Pixel, attr);
                }
                var st2 = g.Save();
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.DrawImage(bmp, b);
                g.Restore(st2);
                return;
            }
        }

        if (s.Points.Count == 0) return;
        using var pen = new Pen(s.Color, s.Width) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        if (s.Dashed && s.Tool is Tool.Line or Tool.Arrow or Tool.Rect or Tool.Ellipse)
        {
            // dash/gap scale with the stroke so thin and thick lines look balanced
            pen.DashPattern = new[] { 3f, 2f };
            pen.DashCap = DashCap.Round;
        }
        switch (s.Tool)
        {
            case Tool.Pen:
                if (s.Points.Count == 1)
                {
                    using var dotBrush = new SolidBrush(s.Color);
                    g.FillEllipse(dotBrush, s.Start.X - s.Width / 2, s.Start.Y - s.Width / 2, s.Width, s.Width);
                    return;
                }
                var pts = s.Points.ToArray();
                if (pts.Length > 2) g.DrawCurve(pen, pts, 0.4f); else g.DrawLines(pen, pts);
                return;
            case Tool.Marker:
            {
                using var mp = new Pen(Color.FromArgb(115, s.Color), s.EffectiveWidth) { StartCap = LineCap.Square, EndCap = LineCap.Square, LineJoin = LineJoin.Round };
                if (s.Points.Count == 1) g.DrawLine(mp, s.Start, new PointF(s.Start.X + 0.1f, s.Start.Y));
                else g.DrawLines(mp, s.Points.ToArray());
                return;
            }
            case Tool.Line:
                g.DrawLine(pen, s.Start, s.End);
                return;
            case Tool.Arrow:
            {
                var start = s.Start;
                var end = s.End;
                var len = MathF.Max(Geometry.Distance(start, end), 0.001f);
                float ux = (end.X - start.X) / len, uy = (end.Y - start.Y) / len;
                if (s.ArrowHead == ArrowHead.Chevron)
                {
                    g.DrawLine(pen, start, end);
                    var (a, tip, b) = Geometry.ArrowHead(start, end, s.Width);
                    using var solid = new Pen(s.Color, s.Width) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
                    g.DrawLines(solid, new[] { a, tip, b });
                }
                else
                {
                    // a filled dot with a thin white ring: a "pointer" that marks an exact spot
                    var r = Geometry.ArrowDot(s.Width);
                    g.DrawLine(pen, start, new PointF(end.X - ux * r * 0.6f, end.Y - uy * r * 0.6f));
                    var dot = new RectangleF(end.X - r, end.Y - r, r * 2, r * 2);
                    using (var fill = new SolidBrush(s.Color)) g.FillEllipse(fill, dot);
                    using var ring = new Pen(Color.White, MathF.Max(1.2f, s.Width * 0.35f));
                    g.DrawEllipse(ring, RectangleF.Inflate(dot, -0.5f, -0.5f));
                }
                return;
            }
            case Tool.Rect:
            {
                var r = s.Rect;
                if (s.Fill > 0) using (var f = new SolidBrush(Color.FromArgb((int)(s.FillAlpha * 255), s.Color))) g.FillRectangle(f, r);
                g.DrawRectangle(pen, r.X, r.Y, r.Width, r.Height);
                return;
            }
            case Tool.Ellipse:
            {
                var r = s.Rect;
                if (s.Fill > 0) using (var f = new SolidBrush(Color.FromArgb((int)(s.FillAlpha * 255), s.Color))) g.FillEllipse(f, r);
                g.DrawEllipse(pen, r);
                return;
            }
        }
    }

    static void DrawText(Graphics g, Shape s)
    {
        if (s.Text.Length == 0) return;
        if (s.TextStyle.HasFlag(TextStyles.Box))
        {
            using var bp = RoundRect(s.BoxRect, Shape.BoxCornerRadius(s.FontSize));
            using var bb = new SolidBrush(Color.FromArgb((int)(Math.Clamp(s.BoxAlpha, 0, 1) * 255), s.BoxColor));
            g.FillPath(bb, bp);
        }
        using var path = TextPath(s.Text, s.FontSize, s.Start);
        if (s.TextStyle.HasFlag(TextStyles.Shadow))
        {
            // soft shadow: a few faint offset copies approximate the Mac's blurred shadow
            var blur = MathF.Max(2, s.FontSize * 0.1f) * 0.6f;
            var dy = MathF.Max(1, s.FontSize * 0.05f);
            using var sb = new SolidBrush(Color.FromArgb(38, 0, 0, 0));
            for (var k = 0; k < 8; k++)
            {
                var a = k * MathF.PI / 4;
                var st = g.Save();
                g.TranslateTransform(MathF.Cos(a) * blur, dy + MathF.Sin(a) * blur);
                g.FillPath(sb, path);
                g.Restore(st);
            }
            var st2 = g.Save();
            g.TranslateTransform(0, dy);
            using (var core = new SolidBrush(Color.FromArgb(90, 0, 0, 0))) g.FillPath(core, path);
            g.Restore(st2);
        }
        if (s.TextStyle.HasFlag(TextStyles.Outline))
        {
            using var outline = new Pen(Color.Black, s.FontSize * 0.07f) { LineJoin = LineJoin.Round };
            g.DrawPath(outline, path);
        }
        using var fill = new SolidBrush(s.Color);
        g.FillPath(fill, path);
    }

    /// The finished capture: the selected part of the screen with the annotations burnt in.
    public static Bitmap RenderResult(Bitmap shot, MosaicSource mosaic, RectangleF selection, IEnumerable<Shape> shapes)
    {
        var r = Geometry.ToPixels(selection);
        r.Intersect(new Rectangle(0, 0, shot.Width, shot.Height));
        var bmp = new Bitmap(Math.Max(1, r.Width), Math.Max(1, r.Height), PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);
        g.CompositingMode = CompositingMode.SourceCopy;
        g.DrawImage(shot, new Rectangle(0, 0, r.Width, r.Height), r, GraphicsUnit.Pixel);
        g.CompositingMode = CompositingMode.SourceOver;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        g.TranslateTransform(-r.X, -r.Y);
        foreach (var s in shapes) DrawShape(g, s, mosaic);
        return bmp;
    }

    /// "Beautify": a 10 pt margin with a soft shadow and rounded corners (transparent around the
    /// image). The margin is only added when there is a shadow to show in it.
    public static Bitmap Beautify(Bitmap image, float scale, bool shadow, bool rounded)
    {
        var pad = shadow ? (int)MathF.Round(10 * scale) : 0;
        int w = image.Width, h = image.Height, W = w + pad * 2, H = h + pad * 2;
        var radius = rounded ? MathF.Min(10 * scale, MathF.Min(w, h) / 4f) : 0;
        var rect = new RectangleF(pad, pad, w, h);
        var outBmp = new Bitmap(W, H, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(outBmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        if (shadow)
        {
            // a real blurred shadow: blur a white silhouette, then use it as the alpha of black
            using var mask = new Bitmap(W, H, PixelFormat.Format32bppArgb);
            using (var mg = Graphics.FromImage(mask))
            {
                mg.Clear(Color.Black);
                mg.SmoothingMode = SmoothingMode.AntiAlias;
                var sr = rect;
                sr.Offset(0, 2 * scale);
                using var sp = RoundRect(sr, MathF.Max(radius, 0.1f));
                mg.FillPath(Brushes.White, sp);
            }
            var px = ScreenGrab.Pixels(mask, new Rectangle(0, 0, W, H));
            Effects.Blur(px, W, H, 8 * scale);
            for (var i = 0; i < px.Length; i++) px[i] = (int)(((px[i] >> 16) & 0xFF) * 0.35f) << 24;
            using var sh = ScreenGrab.FromPixels(px, W, H);
            g.DrawImageUnscaled(sh, 0, 0);
        }
        if (radius > 0)
        {
            using var clip = RoundRect(rect, radius);
            using var tb = new TextureBrush(image, WrapMode.Clamp);
            tb.TranslateTransform(pad, pad);
            g.FillPath(tb, clip);
        }
        else g.DrawImageUnscaled(image, pad, pad);
        return outBmp;
    }

    // ───────────────────────── text helpers ─────────────────────────

    public static Font UiFont(float px, FontStyle style = FontStyle.Regular) =>
        new(Strings.Korean ? "Malgun Gothic" : "Segoe UI", px, style, GraphicsUnit.Pixel);

    static readonly Dictionary<(string, float), SizeF> UiCache = new();
    static readonly Dictionary<(string, float), SizeF> TextCache = new();

    static SizeF MeasureUi(string text, float px)
    {
        if (UiCache.TryGetValue((text, px), out var hit)) return hit;
        using var font = UiFont(px, FontStyle.Bold);
        SizeF size = TextRenderer.MeasureText(text, font, Size.Empty, TextFormatFlags.NoPadding);
        if (UiCache.Count > 500) UiCache.Clear();
        UiCache[(text, px)] = size;
        return size;
    }

    /// GDI+ does little font fallback, so pick a face that has the script being typed.
    public static string TextFamily(string text)
    {
        var family = Strings.Korean ? "Malgun Gothic" : "Segoe UI";
        foreach (var ch in text)
        {
            if (ch is >= '가' and <= '힣' or >= 'ᄀ' and <= 'ᇿ' or >= '㄰' and <= '㆏') return "Malgun Gothic";
            if (ch is >= '぀' and <= 'ヿ') return "Yu Gothic UI";
            if (ch is >= '一' and <= '鿿') family = "Microsoft YaHei UI";
        }
        return family;
    }

    public static Font TextFont(string text, float px) => new(TextFamily(text), px, FontStyle.Bold, GraphicsUnit.Pixel);

    static GraphicsPath TextPath(string text, float px, PointF origin)
    {
        var path = new GraphicsPath();
        using var family = new FontFamily(TextFamily(text));
        path.AddString(text, family, (int)FontStyle.Bold, px, origin, StringFormat.GenericTypographic);
        return path;
    }

    public static SizeF MeasureText(string text, float px)
    {
        if (TextCache.TryGetValue((text, px), out var hit)) return hit;
        var size = MeasureTextUncached(text, px);
        if (TextCache.Count > 500) TextCache.Clear();
        TextCache[(text, px)] = size;
        return size;
    }

    static SizeF MeasureTextUncached(string text, float px)
    {
        using var bmp = new Bitmap(1, 1);
        using var g = Graphics.FromImage(bmp);
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        using var font = TextFont(text, px);
        var size = g.MeasureString(text.Length == 0 ? " " : text, font, PointF.Empty, StringFormat.GenericTypographic);
        return new SizeF(size.Width + px * 0.1f, MathF.Max(size.Height, font.GetHeight(g)));
    }

    public static bool IsLight(Color c) => c.R * 0.299 + c.G * 0.587 + c.B * 0.114 > 186;

    public static GraphicsPath RoundRect(RectangleF r, float radius)
    {
        var path = new GraphicsPath();
        var d = Math.Max(0.1f, Math.Min(radius * 2, Math.Min(r.Width, r.Height)));
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}
