using System.Drawing.Drawing2D;
using ShotPark.Core;

namespace ShotPark.Win;

/// Toolbar icons, drawn as vectors so they look the same on every Windows version and DPI.
static class Icons
{
    public static void Draw(Graphics g, ToolbarItem item, RectangleF cell, float scale, Color current, Color fg)
    {
        var s = 18 * scale; // icon box
        var b = new RectangleF(cell.X + (cell.Width - s) / 2, cell.Y + (cell.Height - s) / 2, s, s);
        using var pen = new Pen(fg, 1.7f * scale) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        using var brush = new SolidBrush(fg);
        PointF P(float x, float y) => new(b.X + x * s, b.Y + y * s);

        switch (item.Action)
        {
            case ToolbarAction.Color:
            {
                var d = RectangleF.Inflate(b, -1.5f * scale, -1.5f * scale);
                using (var fill = new SolidBrush(current)) g.FillEllipse(fill, d);
                using var ring = new Pen(Color.White, 1.6f * scale);
                g.DrawEllipse(ring, d);
                return;
            }
            case ToolbarAction.Undo:
            {
                g.DrawArc(pen, b.X + 0.22f * s, b.Y + 0.22f * s, 0.64f * s, 0.6f * s, 180, 200);
                g.DrawLines(pen, new[] { P(0.08f, 0.32f), P(0.22f, 0.54f), P(0.44f, 0.42f) });
                return;
            }
            case ToolbarAction.Copy:
            {
                using (var back = Painter.RoundRect(new RectangleF(b.X + 0.12f * s, b.Y + 0.08f * s, 0.52f * s, 0.62f * s), 2.5f * scale)) g.DrawPath(pen, back);
                var front = new RectangleF(b.X + 0.36f * s, b.Y + 0.3f * s, 0.52f * s, 0.62f * s);
                using (var bgb = new SolidBrush(Color.FromArgb(255, 43, 43, 46)))
                using (var fp = Painter.RoundRect(front, 2.5f * scale))
                {
                    g.FillPath(bgb, fp);
                    g.DrawPath(pen, fp);
                }
                return;
            }
            case ToolbarAction.Save:
            {
                g.DrawLine(pen, P(0.5f, 0.08f), P(0.5f, 0.62f));
                g.DrawLines(pen, new[] { P(0.28f, 0.42f), P(0.5f, 0.64f), P(0.72f, 0.42f) });
                g.DrawLines(pen, new[] { P(0.1f, 0.66f), P(0.1f, 0.9f), P(0.9f, 0.9f), P(0.9f, 0.66f) });
                return;
            }
            case ToolbarAction.Close:
                g.DrawLine(pen, P(0.18f, 0.18f), P(0.82f, 0.82f));
                g.DrawLine(pen, P(0.82f, 0.18f), P(0.18f, 0.82f));
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
                using var rp = Painter.RoundRect(new RectangleF(b.X + 0.06f * s, b.Y + 0.18f * s, 0.88f * s, 0.64f * s), 2.5f * scale);
                g.DrawPath(pen, rp);
                return;
            }
            case Tool.Ellipse:
                g.DrawEllipse(pen, b.X + 0.08f * s, b.Y + 0.08f * s, 0.84f * s, 0.84f * s);
                return;
            case Tool.Mosaic:
            {
                var cellSize = 0.88f * s / 4;
                for (var y = 0; y < 4; y++)
                for (var x = 0; x < 4; x++)
                {
                    var alpha = (x + y) % 2 == 0 ? 255 : 90;
                    using var cb = new SolidBrush(Color.FromArgb(alpha * fg.A / 255, fg));
                    g.FillRectangle(cb, b.X + 0.06f * s + x * cellSize, b.Y + 0.06f * s + y * cellSize, cellSize, cellSize);
                }
                return;
            }
            case Tool.Text:
            {
                using var font = new Font(Strings.Korean ? "Malgun Gothic" : "Segoe UI", 15 * scale, FontStyle.Bold, GraphicsUnit.Pixel);
                using var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                g.DrawString(Strings.Korean ? "가" : "T", font, brush, new RectangleF(b.X - 4 * scale, b.Y - 2 * scale, b.Width + 8 * scale, b.Height + 4 * scale), fmt);
                return;
            }
            case Tool.Number:
            {
                g.DrawEllipse(pen, b.X + 0.04f * s, b.Y + 0.04f * s, 0.92f * s, 0.92f * s);
                using var font = new Font("Segoe UI", 11 * scale, FontStyle.Bold, GraphicsUnit.Pixel);
                using var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                g.DrawString("1", font, brush, new RectangleF(b.X, b.Y + 0.5f * scale, b.Width, b.Height), fmt);
                return;
            }
        }
    }
}
