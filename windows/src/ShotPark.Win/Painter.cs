using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using ShotPark.Core;

namespace ShotPark.Win;

/// Draws the capture overlay, the annotations and the final image. Shared by the live overlay,
/// the exported result and the --rendertest previews, so all three look the same.
static class Painter
{
    static readonly Color ToolbarBg = Color.FromArgb(246, 43, 43, 46);
    static readonly Color ToolbarBorder = Color.FromArgb(60, 255, 255, 255);
    static readonly Color ActiveBg = Color.FromArgb(70, 255, 255, 255);
    static readonly Color TipBg = Color.FromArgb(240, 87, 87, 90);
    static readonly Color Accent = Color.FromArgb(0, 120, 215);

    // ───────────────────────── backdrops ─────────────────────────

    public static Bitmap Dimmed(Bitmap shot)
    {
        var bmp = (Bitmap)shot.Clone(new Rectangle(0, 0, shot.Width, shot.Height), PixelFormat.Format32bppPArgb);
        using var g = Graphics.FromImage(bmp);
        using var b = new SolidBrush(Color.FromArgb(115, 0, 0, 0));
        g.FillRectangle(b, 0, 0, bmp.Width, bmp.Height);
        return bmp;
    }

    /// The whole screen, pixelated — mosaic shapes are cut out of this.
    public static Bitmap Pixelated(Bitmap shot, float scale)
    {
        var block = Math.Max(6, (int)MathF.Round(11 * scale));
        int w = Math.Max(1, shot.Width / block), h = Math.Max(1, shot.Height / block);
        using var small = new Bitmap(w, h, PixelFormat.Format32bppPArgb);
        using (var g = Graphics.FromImage(small))
        {
            g.InterpolationMode = InterpolationMode.HighQualityBilinear;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.DrawImage(shot, new Rectangle(0, 0, w, h), new Rectangle(0, 0, shot.Width, shot.Height), GraphicsUnit.Pixel);
        }
        var big = new Bitmap(shot.Width, shot.Height, PixelFormat.Format32bppPArgb);
        using (var g = Graphics.FromImage(big))
        {
            g.InterpolationMode = InterpolationMode.NearestNeighbor;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.DrawImage(small, new Rectangle(0, 0, w * block, h * block), new Rectangle(0, 0, w, h), GraphicsUnit.Pixel);
        }
        return big;
    }

    // ───────────────────────── overlay ─────────────────────────

    public static void PaintOverlay(Graphics g, OverlayController c, Bitmap shot, Bitmap dim, Bitmap mosaic, Rectangle clip)
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

        if (sel is not { } selection || selection.Width < 1)
        {
            DrawHint(g, c);
            return;
        }

        var state = g.Save();
        g.SetClip(selection);
        foreach (var shape in c.Doc.Shapes) DrawShape(g, shape, mosaic);
        if (c.Drawing is { } d) DrawShape(g, d, mosaic);
        if (c.Picked is { } p && c.Doc.Shapes.Contains(p))
        {
            using var dash = new Pen(Accent, Math.Max(1, c.Scale)) { DashStyle = DashStyle.Dash };
            var b = RectangleF.Inflate(p.Bounds, 4 * c.Scale + p.Width / 2, 4 * c.Scale + p.Width / 2);
            g.DrawRectangle(dash, b.X, b.Y, b.Width, b.Height);
        }
        g.Restore(state);

        // selection frame + handles
        using (var frame = new Pen(Color.FromArgb(235, 255, 255, 255), 1))
            g.DrawRectangle(frame, selection.X - 0.5f, selection.Y - 0.5f, selection.Width, selection.Height);
        if (!c.Selecting)
        {
            var hr = c.HandleRadius * 0.7f;
            using var fill = new SolidBrush(Color.White);
            using var edge = new Pen(Accent, Math.Max(1, c.Scale));
            foreach (var (_, pt) in Geometry.HandlePoints(selection))
            {
                var hrect = new RectangleF(pt.X - hr, pt.Y - hr, hr * 2, hr * 2);
                g.FillRectangle(fill, hrect);
                g.DrawRectangle(edge, hrect.X, hrect.Y, hrect.Width, hrect.Height);
            }
        }

        DrawSizeLabel(g, c, selection);

        if (c.ToolbarRect is { } tb)
        {
            DrawToolbar(g, c, tb);
            RectangleF? pal = c.PaletteRect;
            if (pal is { } pr) DrawPalette(g, c, pr);
            if (c.TipVisible && c.HoverItem >= 0) DrawTip(g, c, tb, pal);
        }
    }

    static void DrawHint(Graphics g, OverlayController c)
    {
        var m = c.MonitorAt(c.Pointer);
        var text = Strings.L("드래그해서 캡처할 영역을 선택하세요   ·   Ctrl+A 이 모니터 전체   ·   Esc 취소",
                             "Drag to select an area   ·   Ctrl+A this monitor   ·   Esc to cancel");
        using var font = UiFont(13 * c.Scale);
        var size = g.MeasureString(text, font);
        var box = new RectangleF(m.X + (m.Width - size.Width) / 2 - 14 * c.Scale, m.Y + 28 * c.Scale, size.Width + 28 * c.Scale, size.Height + 14 * c.Scale);
        using (var path = RoundRect(box, box.Height / 2))
        using (var bg = new SolidBrush(Color.FromArgb(215, 30, 30, 32)))
            g.FillPath(bg, path);
        using var fg = new SolidBrush(Color.White);
        g.DrawString(text, font, fg, box.X + 14 * c.Scale, box.Y + 7 * c.Scale);
    }

    static void DrawSizeLabel(Graphics g, OverlayController c, RectangleF s)
    {
        var text = $"{(int)MathF.Round(s.Width)} × {(int)MathF.Round(s.Height)}";
        using var font = UiFont(11.5f * c.Scale);
        var size = g.MeasureString(text, font);
        float padX = 7 * c.Scale, padY = 3 * c.Scale;
        var box = new RectangleF(s.X, s.Y - size.Height - 2 * padY - 6 * c.Scale, size.Width + 2 * padX, size.Height + 2 * padY);
        if (box.Y < c.MonitorAt(new PointF(s.X, s.Y)).Top + 2) box.Y = s.Y + 6 * c.Scale;
        using (var path = RoundRect(box, 5 * c.Scale))
        using (var bg = new SolidBrush(Color.FromArgb(200, 0, 0, 0)))
            g.FillPath(bg, path);
        using var fg = new SolidBrush(Color.White);
        g.DrawString(text, font, fg, box.X + padX, box.Y + padY);
    }

    public static void DrawToolbar(Graphics g, OverlayController c, RectangleF tb)
    {
        var sc = c.Scale;
        using (var path = RoundRect(tb, 10 * sc))
        {
            using var shadow = new SolidBrush(Color.FromArgb(50, 0, 0, 0));
            var sh = tb;
            sh.Offset(0, 3 * sc);
            using (var sp = RoundRect(sh, 10 * sc)) g.FillPath(shadow, sp);
            using var bg = new SolidBrush(ToolbarBg);
            g.FillPath(bg, path);
            using var border = new Pen(ToolbarBorder, 1);
            g.DrawPath(border, path);
        }
        var (rects, seps) = ToolbarLayout.Rects(sc);
        using (var sepPen = new Pen(Color.FromArgb(70, 255, 255, 255), Math.Max(1, sc)))
            foreach (var x in seps)
                g.DrawLine(sepPen, tb.X + x, tb.Y + 12 * sc, tb.X + x, tb.Bottom - 12 * sc);

        for (var i = 0; i < rects.Length; i++)
        {
            var item = ToolbarLayout.Items[i];
            var r = rects[i];
            r.Offset(tb.X, tb.Y);
            var active = item.Action == ToolbarAction.Tool && item.Tool == c.Tool
                         || item.Action == ToolbarAction.Color && c.PaletteOpen;
            var hover = i == c.HoverItem;
            if (active || hover)
            {
                using var hl = new SolidBrush(active ? ActiveBg : Color.FromArgb(32, 255, 255, 255));
                using var hp = RoundRect(RectangleF.Inflate(r, -2 * sc, 0), 6 * sc);
                g.FillPath(hl, hp);
            }
            var disabled = item.Action == ToolbarAction.Undo && !c.Doc.CanUndo;
            Icons.Draw(g, item, r, sc, c.Color, disabled ? Color.FromArgb(110, 255, 255, 255) : Color.White);
        }
    }

    static void DrawPalette(Graphics g, OverlayController c, RectangleF pr)
    {
        var sc = c.Scale;
        using (var path = RoundRect(pr, 10 * sc))
        {
            using var bg = new SolidBrush(ToolbarBg);
            g.FillPath(bg, path);
            using var border = new Pen(ToolbarBorder, 1);
            g.DrawPath(border, path);
        }
        var (colors, widths) = PaletteLayout.Rects(sc);
        for (var i = 0; i < colors.Length; i++)
        {
            var r = colors[i];
            r.Offset(pr.X, pr.Y);
            var dot = RectangleF.Inflate(r, -3 * sc, -3 * sc);
            using (var b = new SolidBrush(Palette.Default[i])) g.FillEllipse(b, dot);
            using (var ring = new Pen(Color.FromArgb(90, 255, 255, 255), 1)) g.DrawEllipse(ring, dot);
            if (i == c.ColorIndex)
            {
                using var sel = new Pen(Color.White, 2 * sc);
                g.DrawEllipse(sel, RectangleF.Inflate(r, -0.5f * sc, -0.5f * sc));
            }
        }
        var sepX = pr.X + widths[0].X - (PaletteLayout.Separator / 2 + PaletteLayout.Gap / 2) * sc;
        using (var sepPen = new Pen(Color.FromArgb(70, 255, 255, 255), Math.Max(1, sc)))
            g.DrawLine(sepPen, sepX, pr.Y + 10 * sc, sepX, pr.Bottom - 10 * sc);
        for (var i = 0; i < widths.Length; i++)
        {
            var r = widths[i];
            r.Offset(pr.X, pr.Y);
            if (i == c.WidthIndex)
            {
                using var hl = new SolidBrush(ActiveBg);
                using var hp = RoundRect(r, 6 * sc);
                g.FillPath(hl, hp);
            }
            var d = (3 + i * 3.5f) * sc;
            using var b = new SolidBrush(Color.White);
            g.FillEllipse(b, r.X + (r.Width - d) / 2, r.Y + (r.Height - d) / 2, d, d);
        }
    }

    static void DrawTip(Graphics g, OverlayController c, RectangleF tb, RectangleF? palette)
    {
        var sc = c.Scale;
        var (rects, _) = ToolbarLayout.Rects(sc);
        var item = rects[c.HoverItem];
        item.Offset(tb.X, tb.Y);
        var text = ToolbarLayout.Items[c.HoverItem].Tip;
        using var font = UiFont(12 * sc);
        var size = g.MeasureString(text, font);
        float padX = 8 * sc, padY = 4 * sc;
        var w = size.Width + 2 * padX;
        var h = size.Height + 2 * padY;
        var monitor = c.MonitorAt(new PointF(tb.X + tb.Width / 2, tb.Y + tb.Height / 2));
        var x = Math.Clamp(item.X + item.Width / 2 - w / 2, monitor.Left + 4, monitor.Right - w - 4);
        var above = palette is not { } p || p.Top > tb.Top;
        var y = above ? tb.Top - h - 6 * sc : tb.Bottom + 6 * sc;
        if (y < monitor.Top + 2) y = tb.Bottom + 6 * sc;
        var box = new RectangleF(x, y, w, h);
        using (var path = RoundRect(box, 6 * sc))
        using (var bg = new SolidBrush(TipBg))
            g.FillPath(bg, path);
        using var fg = new SolidBrush(Color.White);
        g.DrawString(text, font, fg, box.X + padX, box.Y + padY);
    }

    // ───────────────────────── shapes ─────────────────────────

    public static void DrawShape(Graphics g, Shape s, Bitmap mosaic)
    {
        switch (s.Tool)
        {
            case Tool.Mosaic:
            {
                var r = Geometry.ToPixels(s.Bounds);
                r.Intersect(new Rectangle(0, 0, mosaic.Width, mosaic.Height));
                if (r.Width <= 0 || r.Height <= 0) return;
                var st = g.Save();
                g.InterpolationMode = InterpolationMode.NearestNeighbor;
                g.PixelOffsetMode = PixelOffsetMode.Half;
                g.SmoothingMode = SmoothingMode.None;
                g.DrawImage(mosaic, r, r, GraphicsUnit.Pixel);
                g.Restore(st);
                return;
            }
            case Tool.Text:
            {
                using var font = TextFont(s.Text, s.FontSize);
                using var brush = new SolidBrush(s.Color);
                // a soft contrasting halo keeps text readable on any background
                using var halo = new SolidBrush(IsLight(s.Color) ? Color.FromArgb(150, 0, 0, 0) : Color.FromArgb(170, 255, 255, 255));
                var o = Math.Max(1f, s.FontSize / 16f);
                foreach (var (dx, dy) in new[] { (-o, 0f), (o, 0f), (0f, -o), (0f, o) })
                    g.DrawString(s.Text, font, halo, s.Start.X + dx, s.Start.Y + dy, StringFormat.GenericTypographic);
                g.DrawString(s.Text, font, brush, s.Start, StringFormat.GenericTypographic);
                return;
            }
            case Tool.Number:
            {
                var r = s.Bounds;
                using (var fill = new SolidBrush(s.Color)) g.FillEllipse(fill, r);
                using (var ring = new Pen(Color.FromArgb(220, 255, 255, 255), MathF.Max(1.5f, s.Width / 14))) g.DrawEllipse(ring, r);
                using var font = new Font("Segoe UI", s.Width * 0.5f, FontStyle.Bold, GraphicsUnit.Pixel);
                using var fg = new SolidBrush(IsLight(s.Color) ? Color.Black : Color.White);
                using var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                g.DrawString(s.Number.ToString(), font, fg, new RectangleF(r.X, r.Y + s.Width * 0.02f, r.Width, r.Height), fmt);
                return;
            }
        }

        using var pen = new Pen(s.Color, s.Width) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        switch (s.Tool)
        {
            case Tool.Pen:
                if (s.Points.Count == 1) { g.DrawLine(pen, s.Start, new PointF(s.Start.X + 0.1f, s.Start.Y)); return; }
                var pts = s.Points.ToArray();
                if (pts.Length > 2) g.DrawCurve(pen, pts, 0.4f); else g.DrawLines(pen, pts);
                return;
            case Tool.Line:
                g.DrawLine(pen, s.Start, s.End);
                return;
            case Tool.Arrow:
            {
                g.DrawLine(pen, s.Start, s.End);
                var (a, tip, b) = Geometry.ArrowHead(s.Start, s.End, s.Width);
                g.DrawLines(pen, new[] { a, tip, b });
                return;
            }
            case Tool.Rect:
            {
                var r = s.Bounds;
                using var rp = RoundRect(r, Math.Min(2 + s.Width / 2, Math.Min(r.Width, r.Height) / 4));
                g.DrawPath(pen, rp);
                return;
            }
            case Tool.Ellipse:
                g.DrawEllipse(pen, s.Bounds);
                return;
        }
    }

    /// The finished capture: the selected part of the screen with the annotations burnt in.
    public static Bitmap RenderResult(Bitmap shot, Bitmap mosaic, RectangleF selection, IEnumerable<Shape> shapes)
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

    // ───────────────────────── text helpers ─────────────────────────

    public static Font UiFont(float px) =>
        new(Strings.Korean ? "Malgun Gothic" : "Segoe UI", px, FontStyle.Regular, GraphicsUnit.Pixel);

    /// GDI+ does little font fallback, so pick a face that has the script being typed.
    public static Font TextFont(string text, float px)
    {
        string family = "Segoe UI";
        foreach (var ch in text)
        {
            if (ch is >= '가' and <= '힣' or >= 'ᄀ' and <= 'ᇿ' or >= '㄰' and <= '㆏') { family = "Malgun Gothic"; break; }
            if (ch is >= '぀' and <= 'ヿ') { family = "Yu Gothic UI"; break; }
            if (ch is >= '一' and <= '鿿') family = "Microsoft YaHei UI";
        }
        if (family == "Segoe UI" && Strings.Korean) family = "Malgun Gothic";
        return new Font(family, px, FontStyle.Bold, GraphicsUnit.Pixel);
    }

    public static SizeF MeasureText(string text, float px)
    {
        using var bmp = new Bitmap(1, 1);
        using var g = Graphics.FromImage(bmp);
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        using var font = TextFont(text, px);
        var size = g.MeasureString(text.Length == 0 ? " " : text, font, PointF.Empty, StringFormat.GenericTypographic);
        return new SizeF(size.Width + px * 0.15f, size.Height);
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
