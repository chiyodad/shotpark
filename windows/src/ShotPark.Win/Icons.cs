using System.Drawing.Drawing2D;
using ShotPark.Core;

namespace ShotPark.Win;

/// Toolbar icons, drawn as vectors so they look the same on every Windows version and DPI.
/// Modelled on the SF Symbols the Mac app uses.
static class Icons
{
    public static void Draw(Graphics g, ToolbarItem item, RectangleF cell, float scale, Color current, Color fg)
    {
        var s = 18 * scale; // icon box
        var b = new RectangleF(cell.X + (cell.Width - s) / 2, cell.Y + (cell.Height - s) / 2, s, s);
        using var pen = new Pen(fg, 1.6f * scale) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        using var brush = new SolidBrush(fg);
        PointF P(float x, float y) => new(b.X + x * s, b.Y + y * s);
        RectangleF R(float x, float y, float w, float h) => new(b.X + x * s, b.Y + y * s, w * s, h * s);

        switch (item.Action)
        {
            case ToolbarAction.Color:
            {
                var d = RectangleF.Inflate(b, -1.5f * scale, -1.5f * scale);
                using (var fill = new SolidBrush(current)) g.FillEllipse(fill, d);
                using var ring = new Pen(Color.FromArgb(230, 255, 255, 255), 1.5f * scale);
                g.DrawEllipse(ring, d);
                return;
            }
            case ToolbarAction.Undo:
            {
                // arrow.uturn.backward
                using var path = new GraphicsPath();
                path.AddLine(P(0.22f, 0.38f), P(0.62f, 0.38f));
                path.AddArc(R(0.42f, 0.38f, 0.42f, 0.42f), 270, 180);
                path.AddLine(P(0.63f, 0.8f), P(0.4f, 0.8f));
                g.DrawPath(pen, path);
                g.DrawLines(pen, new[] { P(0.38f, 0.2f), P(0.2f, 0.38f), P(0.38f, 0.56f) });
                return;
            }
            case ToolbarAction.Beautify:
            {
                // wand.and.stars
                g.DrawLine(pen, P(0.12f, 0.9f), P(0.62f, 0.4f));
                using (var tip = new Pen(fg, 2.6f * scale) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                    g.DrawLine(tip, P(0.58f, 0.44f), P(0.68f, 0.34f));
                Star(g, brush, P(0.74f, 0.16f), 0.13f * s);
                Star(g, brush, P(0.86f, 0.52f), 0.09f * s);
                Star(g, brush, P(0.36f, 0.14f), 0.08f * s);
                return;
            }
            case ToolbarAction.Copy:
            {
                using (var back = Painter.RoundRect(R(0.1f, 0.06f, 0.52f, 0.62f), 2.5f * scale)) g.DrawPath(pen, back);
                var front = R(0.36f, 0.3f, 0.52f, 0.62f);
                using (var bgb = new SolidBrush(Color.FromArgb(255, 31, 31, 31)))
                using (var fp = Painter.RoundRect(front, 2.5f * scale))
                {
                    g.FillPath(bgb, fp);
                    g.DrawPath(pen, fp);
                }
                return;
            }
            case ToolbarAction.Ocr:
            {
                // text.viewfinder: corner brackets around a "T"
                var k = 0.26f;
                g.DrawLines(pen, new[] { P(0.04f, k), P(0.04f, 0.04f), P(k, 0.04f) });
                g.DrawLines(pen, new[] { P(1 - k, 0.04f), P(0.96f, 0.04f), P(0.96f, k) });
                g.DrawLines(pen, new[] { P(0.96f, 1 - k), P(0.96f, 0.96f), P(1 - k, 0.96f) });
                g.DrawLines(pen, new[] { P(k, 0.96f), P(0.04f, 0.96f), P(0.04f, 1 - k) });
                g.DrawLine(pen, P(0.3f, 0.32f), P(0.7f, 0.32f));
                g.DrawLine(pen, P(0.5f, 0.32f), P(0.5f, 0.72f));
                return;
            }
            case ToolbarAction.Pin:
            {
                // pin: head, body, needle (tilted)
                var st = g.Save();
                var c = P(0.5f, 0.5f);
                g.TranslateTransform(c.X, c.Y);
                g.RotateTransform(35);
                g.TranslateTransform(-c.X, -c.Y);
                using (var head = Painter.RoundRect(R(0.3f, 0.02f, 0.4f, 0.14f), 2 * scale)) g.DrawPath(pen, head);
                g.DrawLines(pen, new[] { P(0.38f, 0.16f), P(0.36f, 0.46f), P(0.22f, 0.6f), P(0.78f, 0.6f), P(0.64f, 0.46f), P(0.62f, 0.16f) });
                g.DrawLine(pen, P(0.5f, 0.6f), P(0.5f, 0.98f));
                g.Restore(st);
                return;
            }
            case ToolbarAction.Save:
            {
                // square.and.arrow.down
                g.DrawLines(pen, new[] { P(0.32f, 0.36f), P(0.12f, 0.36f), P(0.12f, 0.96f), P(0.88f, 0.96f), P(0.88f, 0.36f), P(0.68f, 0.36f) });
                g.DrawLine(pen, P(0.5f, 0.04f), P(0.5f, 0.66f));
                g.DrawLines(pen, new[] { P(0.32f, 0.48f), P(0.5f, 0.66f), P(0.68f, 0.48f) });
                return;
            }
            case ToolbarAction.Share:
            {
                // square.and.arrow.up
                g.DrawLines(pen, new[] { P(0.32f, 0.4f), P(0.12f, 0.4f), P(0.12f, 0.96f), P(0.88f, 0.96f), P(0.88f, 0.4f), P(0.68f, 0.4f) });
                g.DrawLine(pen, P(0.5f, 0.02f), P(0.5f, 0.64f));
                g.DrawLines(pen, new[] { P(0.32f, 0.2f), P(0.5f, 0.02f), P(0.68f, 0.2f) });
                return;
            }
            case ToolbarAction.Close:
                g.DrawLine(pen, P(0.2f, 0.2f), P(0.8f, 0.8f));
                g.DrawLine(pen, P(0.8f, 0.2f), P(0.2f, 0.8f));
                return;
        }

        switch (item.Tool)
        {
            case Tool.Pen:
            {
                // a pencil over a free-hand scribble
                var body = new[] { P(0.30f, 0.62f), P(0.78f, 0.14f), P(0.92f, 0.28f), P(0.44f, 0.76f), P(0.26f, 0.80f) };
                g.DrawPolygon(pen, body);
                g.DrawLine(pen, P(0.68f, 0.24f), P(0.82f, 0.38f));
                using var path = new GraphicsPath();
                path.AddBezier(P(0.04f, 0.92f), P(0.14f, 0.80f), P(0.20f, 1.0f), P(0.30f, 0.92f));
                g.DrawPath(pen, path);
                return;
            }
            case Tool.Line:
                g.DrawLine(pen, P(0.14f, 0.86f), P(0.86f, 0.14f));
                return;
            case Tool.Arrow:
                g.DrawLine(pen, P(0.14f, 0.86f), P(0.84f, 0.16f));
                g.DrawLines(pen, new[] { P(0.42f, 0.16f), P(0.84f, 0.16f), P(0.84f, 0.58f) });
                return;
            case Tool.Rect:
            {
                using var rp = Painter.RoundRect(R(0.06f, 0.18f, 0.88f, 0.64f), 2.5f * scale);
                g.DrawPath(pen, rp);
                return;
            }
            case Tool.Ellipse:
                g.DrawEllipse(pen, R(0.08f, 0.08f, 0.84f, 0.84f));
                return;
            case Tool.Mosaic:
            {
                // checkerboard.rectangle
                using (var rp = Painter.RoundRect(R(0.04f, 0.14f, 0.92f, 0.72f), 2.5f * scale)) g.DrawPath(pen, rp);
                var cw = 0.92f * s / 4;
                var ch = 0.72f * s / 3;
                for (var y = 0; y < 3; y++)
                for (var x = 0; x < 4; x++)
                    if ((x + y) % 2 == 0)
                        g.FillRectangle(brush, b.X + 0.04f * s + x * cw, b.Y + 0.14f * s + y * ch, cw, ch);
                return;
            }
            case Tool.Marker:
            {
                // highlighter: a tilted chisel-tipped marker over a band
                using (var band = new SolidBrush(Color.FromArgb(110, fg))) g.FillRectangle(band, R(0.02f, 0.82f, 0.62f, 0.14f));
                var st = g.Save();
                var c = P(0.6f, 0.45f);
                g.TranslateTransform(c.X, c.Y);
                g.RotateTransform(40);
                g.TranslateTransform(-c.X, -c.Y);
                using (var bp = Painter.RoundRect(R(0.46f, 0.0f, 0.28f, 0.56f), 2 * scale)) g.DrawPath(pen, bp);
                g.DrawLines(pen, new[] { P(0.48f, 0.56f), P(0.52f, 0.76f), P(0.68f, 0.76f), P(0.72f, 0.56f) });
                g.Restore(st);
                return;
            }
            case Tool.Text:
            {
                using var font = new Font(Strings.Korean ? "Malgun Gothic" : "Segoe UI", 15 * scale, FontStyle.Bold, GraphicsUnit.Pixel);
                using var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                g.DrawString(Strings.Korean ? "가" : "A", font, brush, new RectangleF(b.X - 4 * scale, b.Y - 2 * scale, b.Width + 8 * scale, b.Height + 4 * scale), fmt);
                return;
            }
            case Tool.Number:
            {
                g.DrawEllipse(pen, R(0.04f, 0.04f, 0.92f, 0.92f));
                using var font = new Font("Segoe UI", 11 * scale, FontStyle.Bold, GraphicsUnit.Pixel);
                using var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                g.DrawString("1", font, brush, new RectangleF(b.X, b.Y + 0.5f * scale, b.Width, b.Height), fmt);
                return;
            }
            case Tool.Emoji:
            {
                // face.smiling
                g.DrawEllipse(pen, R(0.04f, 0.04f, 0.92f, 0.92f));
                g.FillEllipse(brush, R(0.3f, 0.32f, 0.11f, 0.15f));
                g.FillEllipse(brush, R(0.59f, 0.32f, 0.11f, 0.15f));
                g.DrawArc(pen, R(0.28f, 0.36f, 0.44f, 0.36f), 20, 140);
                return;
            }
            case Tool.Eraser:
            {
                var st = g.Save();
                var c = P(0.5f, 0.5f);
                g.TranslateTransform(c.X, c.Y);
                g.RotateTransform(-40);
                g.TranslateTransform(-c.X, -c.Y);
                using (var ep = Painter.RoundRect(R(0.1f, 0.3f, 0.8f, 0.4f), 2.5f * scale)) g.DrawPath(pen, ep);
                g.DrawLine(pen, P(0.46f, 0.3f), P(0.46f, 0.7f));
                using (var fillEnd = Painter.RoundRect(R(0.1f, 0.3f, 0.36f, 0.4f), 2.5f * scale)) g.FillPath(brush, fillEnd);
                g.Restore(st);
                g.DrawLine(pen, P(0.5f, 0.95f), P(0.95f, 0.95f));
                return;
            }
        }
    }

    static void Star(Graphics g, Brush b, PointF c, float r)
    {
        var pts = new PointF[8];
        for (var i = 0; i < 8; i++)
        {
            var a = i * MathF.PI / 4 - MathF.PI / 2;
            var rr = i % 2 == 0 ? r : r * 0.32f;
            pts[i] = new PointF(c.X + MathF.Cos(a) * rr, c.Y + MathF.Sin(a) * rr);
        }
        g.FillPolygon(b, pts);
    }

    /// ↺ / ↻ for the rotate buttons.
    public static void RotateArrow(Graphics g, RectangleF r, float scale, bool clockwise)
    {
        var s = 13 * scale;
        var b = new RectangleF(r.X + (r.Width - s) / 2, r.Y + (r.Height - s) / 2, s, s);
        using var pen = new Pen(Color.White, 1.7f * scale) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        if (clockwise)
        {
            g.DrawArc(pen, b, -60, 290);
            var end = new PointF(b.X + b.Width / 2 + b.Width / 2 * MathF.Cos(-60 * MathF.PI / 180), b.Y + b.Height / 2 + b.Height / 2 * MathF.Sin(-60 * MathF.PI / 180));
            g.DrawLines(pen, new[] { new PointF(end.X - 4 * scale, end.Y - 1 * scale), end, new PointF(end.X + 0.5f * scale, end.Y + 4 * scale) });
        }
        else
        {
            g.DrawArc(pen, b, 240, -290);
            var end = new PointF(b.X + b.Width / 2 + b.Width / 2 * MathF.Cos(240 * MathF.PI / 180), b.Y + b.Height / 2 + b.Height / 2 * MathF.Sin(240 * MathF.PI / 180));
            g.DrawLines(pen, new[] { new PointF(end.X + 4 * scale, end.Y - 1 * scale), end, new PointF(end.X - 0.5f * scale, end.Y + 4 * scale) });
        }
    }

    /// A small camera (window mode).
    public static void Camera(Graphics g, Pen pen, RectangleF b)
    {
        var body = new RectangleF(b.X, b.Y + b.Height * 0.25f, b.Width, b.Height * 0.65f);
        using (var p = Painter.RoundRect(body, b.Height * 0.12f)) g.DrawPath(pen, p);
        g.DrawLines(pen, new[]
        {
            new PointF(b.X + b.Width * 0.3f, body.Y), new PointF(b.X + b.Width * 0.38f, b.Y + b.Height * 0.1f),
            new PointF(b.X + b.Width * 0.62f, b.Y + b.Height * 0.1f), new PointF(b.X + b.Width * 0.7f, body.Y),
        });
        var lens = b.Width * 0.34f;
        g.DrawEllipse(pen, b.X + (b.Width - lens) / 2, body.Y + (body.Height - lens) / 2, lens, lens);
    }

    /// The window-mode cursor: a camera with a dark halo so it shows on any background.
    public static Bitmap CameraCursor(float scale)
    {
        var side = (int)MathF.Ceiling(28 * scale);
        var bmp = new Bitmap(side, side);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var b = new RectangleF(4 * scale, 5 * scale, side - 8 * scale, side - 10 * scale);
        using (var halo = new Pen(Color.FromArgb(170, 0, 0, 0), 4 * scale) { LineJoin = LineJoin.Round })
            Camera(g, halo, b);
        using (var pen = new Pen(Color.White, 1.8f * scale) { LineJoin = LineJoin.Round })
            Camera(g, pen, b);
        return bmp;
    }

    /// The eraser cursor image.
    public static Bitmap EraserCursor(float scale)
    {
        var side = (int)MathF.Ceiling(26 * scale);
        var bmp = new Bitmap(side, side);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var cell = new RectangleF(0, 0, side, side);
        var shadowCell = cell;
        shadowCell.Offset(1, 1);
        Draw(g, new ToolbarItem(ToolbarAction.Tool, Tool.Eraser), shadowCell, scale * 1.1f, Color.Black, Color.FromArgb(160, 0, 0, 0));
        Draw(g, new ToolbarItem(ToolbarAction.Tool, Tool.Eraser), cell, scale * 1.1f, Color.White, Color.White);
        return bmp;
    }
}
