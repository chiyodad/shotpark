using System.Drawing;

namespace ShotPark.Core;

public enum Tool { None, Pen, Line, Arrow, Rect, Ellipse, Mosaic, Text, Number }

/// One annotation. Coordinates are overlay pixels (physical screen pixels from the virtual-screen origin).
public sealed class Shape
{
    public Tool Tool { get; init; }
    public List<PointF> Points { get; set; } = new();
    public Color Color { get; set; } = Palette.Default[0];
    /// Stroke width for lines/shapes; circle diameter for numbers.
    public float Width { get; set; } = 4;
    public string Text { get; set; } = "";
    public float FontSize { get; set; } = 22;
    /// Measured size of the text block, set by the UI (the core cannot measure fonts).
    public SizeF TextSize { get; set; }
    public int Number { get; set; }

    public Shape Clone() => new()
    {
        Tool = Tool, Points = new List<PointF>(Points), Color = Color, Width = Width,
        Text = Text, FontSize = FontSize, TextSize = TextSize, Number = Number,
    };

    public PointF Start => Points.Count > 0 ? Points[0] : PointF.Empty;
    public PointF End => Points.Count > 0 ? Points[^1] : PointF.Empty;

    public RectangleF Bounds
    {
        get
        {
            switch (Tool)
            {
                case Tool.Text:
                    return new RectangleF(Start, TextSize);
                case Tool.Number:
                    return new RectangleF(Start.X - Width / 2, Start.Y - Width / 2, Width, Width);
                default:
                    if (Points.Count == 0) return RectangleF.Empty;
                    float x0 = Points.Min(p => p.X), y0 = Points.Min(p => p.Y);
                    float x1 = Points.Max(p => p.X), y1 = Points.Max(p => p.Y);
                    return RectangleF.FromLTRB(x0, y0, x1, y1);
            }
        }
    }

    /// Whether the point "touches" this shape, with `tol` pixels of slack.
    public bool HitTest(PointF p, float tol)
    {
        var slack = tol + Width / 2;
        switch (Tool)
        {
            case Tool.Pen:
                for (var i = 1; i < Points.Count; i++)
                    if (Geometry.DistanceToSegment(p, Points[i - 1], Points[i]) <= slack) return true;
                return Points.Count == 1 && Geometry.Distance(p, Points[0]) <= slack;
            case Tool.Line:
            case Tool.Arrow:
                return Geometry.DistanceToSegment(p, Start, End) <= slack;
            case Tool.Rect:
            {
                var r = Bounds;
                var outer = RectangleF.Inflate(r, slack, slack);
                var inner = RectangleF.Inflate(r, -slack, -slack);
                return outer.Contains(p) && !(inner.Width > 0 && inner.Height > 0 && inner.Contains(p));
            }
            case Tool.Ellipse:
            {
                var r = Bounds;
                float rx = r.Width / 2, ry = r.Height / 2;
                if (rx < 1 || ry < 1) return RectangleF.Inflate(r, slack, slack).Contains(p);
                float cx = r.X + rx, cy = r.Y + ry;
                var d = MathF.Sqrt(MathF.Pow((p.X - cx) / rx, 2) + MathF.Pow((p.Y - cy) / ry, 2));
                return MathF.Abs(d - 1) * MathF.Min(rx, ry) <= slack;
            }
            default: // Mosaic, Text, Number: anywhere inside
                return RectangleF.Inflate(Bounds, tol, tol).Contains(p);
        }
    }

    public void Offset(float dx, float dy)
    {
        for (var i = 0; i < Points.Count; i++) Points[i] = new PointF(Points[i].X + dx, Points[i].Y + dy);
    }

    /// Too small to keep (an accidental click with a drawing tool).
    public bool IsDegenerate => Tool switch
    {
        Tool.Text => string.IsNullOrWhiteSpace(Text),
        Tool.Number => false,
        Tool.Pen => Points.Count < 2,
        _ => Geometry.Distance(Start, End) < 3,
    };
}

public enum Handle { None, TopLeft, Top, TopRight, Right, BottomRight, Bottom, BottomLeft, Left }

public static class Geometry
{
    public static float Distance(PointF a, PointF b) => MathF.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));

    public static float DistanceToSegment(PointF p, PointF a, PointF b)
    {
        float dx = b.X - a.X, dy = b.Y - a.Y;
        var len2 = dx * dx + dy * dy;
        if (len2 < 1e-6f) return Distance(p, a);
        var t = Math.Clamp(((p.X - a.X) * dx + (p.Y - a.Y) * dy) / len2, 0f, 1f);
        return Distance(p, new PointF(a.X + t * dx, a.Y + t * dy));
    }

    public static RectangleF Normalize(PointF a, PointF b) =>
        RectangleF.FromLTRB(MathF.Min(a.X, b.X), MathF.Min(a.Y, b.Y), MathF.Max(a.X, b.X), MathF.Max(a.Y, b.Y));

    /// The chevron of an arrow head: (left wing, tip, right wing).
    public static (PointF, PointF, PointF) ArrowHead(PointF from, PointF to, float width)
    {
        var len = Distance(from, to);
        var head = MathF.Min(MathF.Max(12, width * 4f), len * 0.6f);
        float ux = (to.X - from.X) / MathF.Max(len, 0.001f), uy = (to.Y - from.Y) / MathF.Max(len, 0.001f);
        float bx = to.X - ux * head, by = to.Y - uy * head;
        var spread = head * 0.6f;
        return (new PointF(bx - uy * spread, by + ux * spread), to, new PointF(bx + uy * spread, by - ux * spread));
    }

    public static IEnumerable<(Handle, PointF)> HandlePoints(RectangleF r)
    {
        float mx = r.X + r.Width / 2, my = r.Y + r.Height / 2;
        yield return (Handle.TopLeft, new PointF(r.Left, r.Top));
        yield return (Handle.Top, new PointF(mx, r.Top));
        yield return (Handle.TopRight, new PointF(r.Right, r.Top));
        yield return (Handle.Right, new PointF(r.Right, my));
        yield return (Handle.BottomRight, new PointF(r.Right, r.Bottom));
        yield return (Handle.Bottom, new PointF(mx, r.Bottom));
        yield return (Handle.BottomLeft, new PointF(r.Left, r.Bottom));
        yield return (Handle.Left, new PointF(r.Left, my));
    }

    public static Handle HandleAt(RectangleF r, PointF p, float radius)
    {
        foreach (var (h, pt) in HandlePoints(r))
            if (Math.Abs(p.X - pt.X) <= radius && Math.Abs(p.Y - pt.Y) <= radius) return h;
        return Handle.None;
    }

    /// Drags one handle of `r` by (dx, dy); the rectangle flips cleanly if dragged past the opposite edge.
    public static RectangleF Resize(RectangleF r, Handle h, float dx, float dy)
    {
        float l = r.Left, t = r.Top, rt = r.Right, b = r.Bottom;
        if (h is Handle.TopLeft or Handle.Left or Handle.BottomLeft) l += dx;
        if (h is Handle.TopRight or Handle.Right or Handle.BottomRight) rt += dx;
        if (h is Handle.TopLeft or Handle.Top or Handle.TopRight) t += dy;
        if (h is Handle.BottomLeft or Handle.Bottom or Handle.BottomRight) b += dy;
        return Normalize(new PointF(l, t), new PointF(rt, b));
    }

    public static RectangleF Clamp(RectangleF r, RectangleF bounds)
    {
        var x = Math.Clamp(r.X, bounds.Left, MathF.Max(bounds.Left, bounds.Right - r.Width));
        var y = Math.Clamp(r.Y, bounds.Top, MathF.Max(bounds.Top, bounds.Bottom - r.Height));
        return new RectangleF(x, y, MathF.Min(r.Width, bounds.Width), MathF.Min(r.Height, bounds.Height));
    }

    /// Rounds outward to whole pixels.
    public static Rectangle ToPixels(RectangleF r) =>
        Rectangle.FromLTRB((int)MathF.Floor(r.Left), (int)MathF.Floor(r.Top), (int)MathF.Ceiling(r.Right), (int)MathF.Ceiling(r.Bottom));
}

/// The shapes of one capture, with snapshot-based undo/redo.
public sealed class Annotations
{
    readonly List<List<Shape>> _undo = new();
    readonly List<List<Shape>> _redo = new();

    public List<Shape> Shapes { get; private set; } = new();

    public bool CanUndo => _undo.Count > 0;
    public bool CanRedo => _redo.Count > 0;

    /// Call before every change.
    public void Checkpoint()
    {
        _undo.Add(Shapes.Select(s => s.Clone()).ToList());
        _redo.Clear();
    }

    public bool Undo()
    {
        if (_undo.Count == 0) return false;
        _redo.Add(Shapes);
        Shapes = _undo[^1];
        _undo.RemoveAt(_undo.Count - 1);
        return true;
    }

    public bool Redo()
    {
        if (_redo.Count == 0) return false;
        _undo.Add(Shapes);
        Shapes = _redo[^1];
        _redo.RemoveAt(_redo.Count - 1);
        return true;
    }

    public void Clear()
    {
        Shapes = new List<Shape>();
        _undo.Clear();
        _redo.Clear();
    }

    public int NextNumber => Shapes.Where(s => s.Tool == Tool.Number).Select(s => s.Number).DefaultIfEmpty(0).Max() + 1;

    /// Topmost shape under the point.
    public Shape? HitTest(PointF p, float tol)
    {
        for (var i = Shapes.Count - 1; i >= 0; i--)
            if (Shapes[i].HitTest(p, tol)) return Shapes[i];
        return null;
    }
}
