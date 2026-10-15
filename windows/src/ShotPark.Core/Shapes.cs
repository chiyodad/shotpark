using System.Drawing;

namespace ShotPark.Core;

/// Same tools as the Mac app. `None` is the select / move tool.
public enum Tool { None, Pen, Line, Arrow, Rect, Ellipse, Marker, Text, Number, Emoji, Eraser, Mosaic }

/// How annotation text is set off from the background. Any combination can be on at once.
[Flags]
public enum TextStyles { None = 0, Shadow = 1, Outline = 2, Box = 4 }

public enum ArrowHead { Chevron = 0, Circle = 1 }

public enum MosaicStyle { Pixelate = 0, Blur = 1 }

/// Sizes the core cannot measure itself (fonts, emoji, images). The UI installs real measurers;
/// the defaults are rough approximations good enough for tests.
public static class Metrics
{
    /// Size of a (multi-line) text block at a font size in pixels.
    public static Func<string, float, SizeF> Text { get; set; } = (t, px) =>
    {
        var lines = (t.Length == 0 ? " " : t).Split('\n');
        return new SizeF(lines.Max(l => Math.Max(1, l.Length)) * px * 0.6f, lines.Length * px * 1.3f);
    };

    /// Size of an emoji drawn at a font size in pixels.
    public static Func<string, float, SizeF> Emoji { get; set; } = (_, px) => new SizeF(px * 1.2f, px * 1.2f);

    /// Width / height of a stamp image, or null when it can't be loaded.
    public static Func<string, float?> ImageAspect { get; set; } = _ => 1f;

    /// Width of a UI label (option bars) at a font size in pixels.
    public static Func<string, float, float> UiText { get; set; } = (t, px) => t.Length * px * 0.62f;
}

/// One annotation. Coordinates are overlay pixels (physical screen pixels from the virtual-screen origin).
public sealed class Shape
{
    public Tool Tool { get; set; }
    public List<PointF> Points { get; set; } = new();
    public Color Color { get; set; } = Palette.Default[0];
    /// Stroke width in pixels.
    public float Width { get; set; } = 4;
    /// Dashed stroke (line / arrow / rect / ellipse).
    public bool Dashed { get; set; }
    public ArrowHead ArrowHead { get; set; }
    /// Text annotation, or the emoji of an emoji stamp.
    public string Text { get; set; } = "";
    /// Font size in pixels (text, number stamps, emoji / image stamps).
    public float FontSize { get; set; } = 24;
    public TextStyles TextStyle { get; set; } = TextStyles.Shadow;
    public Color BoxColor { get; set; } = Color.White;
    public float BoxAlpha { get; set; } = 0.85f;
    /// Image stamp (signature, logo…) instead of an emoji.
    public string? ImageName { get; set; }
    /// Clockwise rotation in degrees around the centre of the unrotated bounds (text and stamps).
    public float Rotation { get; set; }
    public MosaicStyle MosaicStyle { get; set; }
    public int MosaicLevel { get; set; } = 1;
    /// Rectangle / ellipse fill in the shape's colour: 0 none, 1 filled at `FillAlpha`.
    public int Fill { get; set; }
    public float FillAlpha { get; set; } = 0.3f;
    public int Number { get; set; }

    public Shape Clone()
    {
        var c = (Shape)MemberwiseClone();
        c.Points = new List<PointF>(Points);
        return c;
    }

    public bool SameAs(Shape o) =>
        Tool == o.Tool && Points.SequenceEqual(o.Points) && Color.ToArgb() == o.Color.ToArgb() && Width == o.Width &&
        Dashed == o.Dashed && ArrowHead == o.ArrowHead && Text == o.Text && FontSize == o.FontSize &&
        TextStyle == o.TextStyle && BoxColor.ToArgb() == o.BoxColor.ToArgb() && BoxAlpha == o.BoxAlpha &&
        ImageName == o.ImageName && Rotation == o.Rotation && MosaicStyle == o.MosaicStyle &&
        MosaicLevel == o.MosaicLevel && Fill == o.Fill && FillAlpha == o.FillAlpha && Number == o.Number;

    public PointF Start => Points.Count > 0 ? Points[0] : PointF.Empty;
    public PointF End => Points.Count > 0 ? Points[^1] : PointF.Empty;

    public bool IsRotatable => Tool is Tool.Text or Tool.Emoji;
    public bool IsStamp => Tool is Tool.Emoji or Tool.Number;
    public static bool IsStrokeTool(Tool t) => t is Tool.Pen or Tool.Line or Tool.Arrow or Tool.Rect or Tool.Ellipse or Tool.Marker;

    /// Stroke width actually drawn (the marker is a wide translucent band).
    public float EffectiveWidth => Tool == Tool.Marker ? Width * 5 : Width;

    /// Radius of a number stamp (follows the text size).
    public float StampRadius => MathF.Max(12, FontSize * 0.7f);

    /// The rectangle spanned by the first two points (rect / ellipse / mosaic / line ends).
    public RectangleF Rect => Points.Count >= 2 ? Geometry.Normalize(Points[0], Points[1]) : RectangleF.Empty;

    /// Padding of the text background box, proportional to the font size.
    public static SizeF BoxPadding(float fontSize) =>
        new(MathF.Max(12, MathF.Round(fontSize * 0.55f)), MathF.Max(8, MathF.Round(fontSize * 0.4f)));

    public static float BoxCornerRadius(float fontSize) => MathF.Min(10, fontSize * 0.3f);

    /// The glyph block of a text annotation (origin = its top-left corner).
    public RectangleF TextRect => new(Start, Metrics.Text(Text, FontSize));

    /// The text background box (also the text's hit area).
    public RectangleF BoxRect
    {
        get
        {
            var pad = BoxPadding(FontSize);
            return RectangleF.Inflate(TextRect, pad.Width, pad.Height);
        }
    }

    /// Where an image stamp is drawn: centred on its point, height from the stamp size, aspect kept.
    public RectangleF? ImageRect
    {
        get
        {
            if (Tool != Tool.Emoji || ImageName is not { } name || Points.Count == 0) return null;
            if (Metrics.ImageAspect(name) is not { } aspect) return null;
            var h = FontSize * 2.2f;
            var w = h * aspect;
            return new RectangleF(Start.X - w / 2, Start.Y - h / 2, w, h);
        }
    }

    /// Bounding box ignoring rotation.
    public RectangleF UnrotatedBounds
    {
        get
        {
            switch (Tool)
            {
                case Tool.Text:
                    return BoxRect;
                case Tool.Emoji:
                {
                    if (ImageRect is { } ir) return ir;
                    var sz = Metrics.Emoji(Text, FontSize);
                    return new RectangleF(Start.X - sz.Width / 2, Start.Y - sz.Height / 2, sz.Width, sz.Height);
                }
                case Tool.Number:
                    return new RectangleF(Start.X - StampRadius, Start.Y - StampRadius, StampRadius * 2, StampRadius * 2);
                default:
                {
                    if (Points.Count == 0) return RectangleF.Empty;
                    float x0 = Points.Min(p => p.X), y0 = Points.Min(p => p.Y);
                    float x1 = Points.Max(p => p.X), y1 = Points.Max(p => p.Y);
                    var pad = Tool == Tool.Mosaic ? 0 : EffectiveWidth / 2 + (Tool == Tool.Arrow ? MathF.Max(14, Width * 4.5f) * 0.6f : 0);
                    return RectangleF.Inflate(RectangleF.FromLTRB(x0, y0, x1, y1), pad, pad);
                }
            }
        }
    }

    public PointF Pivot
    {
        get
        {
            var b = UnrotatedBounds;
            return new PointF(b.X + b.Width / 2, b.Y + b.Height / 2);
        }
    }

    bool Rotated => Rotation != 0 && IsRotatable;

    /// Axis-aligned bounding box (of the rotated object when rotated).
    public RectangleF Bounds
    {
        get
        {
            var b = UnrotatedBounds;
            if (!Rotated) return b;
            var pts = Geometry.Corners(b).Select(p => Geometry.Rotate(p, Pivot, Rotation)).ToArray();
            return RectangleF.FromLTRB(pts.Min(p => p.X), pts.Min(p => p.Y), pts.Max(p => p.X), pts.Max(p => p.Y));
        }
    }

    /// The outline as drawn: four corners of the (rotated) bounds, inflated by `inset` pixels.
    public PointF[] Outline(float inflate)
    {
        var b = RectangleF.Inflate(UnrotatedBounds, inflate, inflate);
        var pts = Geometry.Corners(b);
        return Rotated ? pts.Select(p => Geometry.Rotate(p, Pivot, Rotation)).ToArray() : pts;
    }

    /// True when `p` is on / very near the drawn marks (clicks inside an empty rectangle don't grab it).
    public bool HitTest(PointF p, float tolerance = 7)
    {
        var tol = tolerance + EffectiveWidth / 2;
        switch (Tool)
        {
            case Tool.None or Tool.Eraser:
                return false;
            case Tool.Text or Tool.Emoji:
                return UnrotatedBounds.Contains(Rotated ? Geometry.Rotate(p, Pivot, -Rotation) : p);
            case Tool.Number:
                return Geometry.Distance(p, Start) <= StampRadius + 2;
            case Tool.Rect:
            {
                var r = Rect;
                var outer = RectangleF.Inflate(r, tol, tol);
                if (Fill > 0) return outer.Contains(p);
                var inner = RectangleF.Inflate(r, -tol, -tol);
                return outer.Contains(p) && !(inner.Width > 0 && inner.Height > 0 && inner.Contains(p));
            }
            case Tool.Mosaic:
                return RectangleF.Inflate(Rect, 3, 3).Contains(p);
            case Tool.Ellipse:
            {
                var r = Rect;
                if (r.Width <= 0 || r.Height <= 0) return false;
                float nx = (p.X - (r.X + r.Width / 2)) / (r.Width / 2), ny = (p.Y - (r.Y + r.Height / 2)) / (r.Height / 2);
                var d = MathF.Sqrt(nx * nx + ny * ny);
                var band = tol / MathF.Max(1, MathF.Min(r.Width, r.Height) / 2);
                return Fill > 0 ? d <= 1 + band : MathF.Abs(d - 1) <= band;
            }
            case Tool.Line or Tool.Arrow:
                return Points.Count >= 2 && Geometry.DistanceToSegment(p, Points[0], Points[1]) <= tol;
            default: // pen, marker
                if (Points.Count == 1) return Geometry.Distance(p, Points[0]) <= tol;
                for (var i = 1; i < Points.Count; i++)
                    if (Geometry.DistanceToSegment(p, Points[i - 1], Points[i]) <= tol) return true;
                return false;
        }
    }

    public void Offset(float dx, float dy)
    {
        for (var i = 0; i < Points.Count; i++) Points[i] = new PointF(Points[i].X + dx, Points[i].Y + dy);
    }

    /// Too small to keep (an accidental click with a drawing tool). A single pen / marker dot is fine.
    public bool IsDegenerate => Tool switch
    {
        Tool.Text => string.IsNullOrWhiteSpace(Text),
        Tool.Number or Tool.Emoji => false,
        Tool.Pen or Tool.Marker => Points.Count == 0,
        _ => Rect.Width < 3 && Rect.Height < 3,
    };

    public static readonly Color[] BoxColors =
    {
        Color.White, Color.Black,
        Color.FromArgb(255, 237, 89),  // yellow
        Color.FromArgb(191, 242, 140), // lime
        Color.FromArgb(179, 224, 255), // sky
        Color.FromArgb(255, 204, 219), // pink
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

    public static PointF Center(RectangleF r) => new(r.X + r.Width / 2, r.Y + r.Height / 2);

    public static PointF[] Corners(RectangleF r) =>
        new[] { new PointF(r.Left, r.Top), new PointF(r.Right, r.Top), new PointF(r.Right, r.Bottom), new PointF(r.Left, r.Bottom) };

    /// Rotates `p` clockwise (screen coordinates, y down) by `degrees` around `c`.
    public static PointF Rotate(PointF p, PointF c, float degrees)
    {
        var a = degrees * MathF.PI / 180;
        float cos = MathF.Cos(a), sin = MathF.Sin(a);
        float dx = p.X - c.X, dy = p.Y - c.Y;
        return new PointF(c.X + dx * cos - dy * sin, c.Y + dx * sin + dy * cos);
    }

    /// The open ">" head of an arrow: (left wing, tip, right wing). Same proportions as the Mac app.
    public static (PointF, PointF, PointF) ArrowHead(PointF from, PointF to, float width)
    {
        var len = MathF.Max(Distance(from, to), 0.001f);
        float ux = (to.X - from.X) / len, uy = (to.Y - from.Y) / len;
        var head = MathF.Max(16, width * 4.5f);
        const float spread = 0.6f; // ~31° each side
        float cos = MathF.Cos(spread), sin = MathF.Sin(spread);
        var w1 = new PointF(to.X - head * (ux * cos - uy * sin), to.Y - head * (uy * cos + ux * sin));
        var w2 = new PointF(to.X - head * (ux * cos + uy * sin), to.Y - head * (uy * cos - ux * sin));
        return (w1, to, w2);
    }

    /// Radius of the "pointer" dot of a circle-headed arrow.
    public static float ArrowDot(float width) => MathF.Max(7, width * 1.9f);

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

/// The shapes of one capture with a command-based undo / redo, like the Mac app: every edit —
/// drawing, stamping, deleting, erasing, moving, resizing, rotating, restyling, re-editing text —
/// is one step, and consecutive edits with the same key (slider drags, nudges) merge into one.
public sealed class Document
{
    abstract record Edit;
    sealed record Add(int Index, Shape Shape) : Edit;
    sealed record Remove(List<(int Index, Shape Shape)> Items) : Edit;
    sealed record Replace(int Index, Shape Before, Shape After, string? Key) : Edit;

    readonly List<Edit> _undo = new();
    readonly List<Edit> _redo = new();
    (int Index, Shape Before)? _editBefore;

    public List<Shape> Shapes { get; } = new();

    public bool CanUndo => _undo.Count > 0;
    public bool CanRedo => _redo.Count > 0;

    void Push(Edit e)
    {
        _undo.Add(e);
        _redo.Clear();
    }

    /// Appends a shape as one undo step; returns its index.
    public int RecordAdd(Shape s)
    {
        Shapes.Add(s);
        Push(new Add(Shapes.Count - 1, s.Clone()));
        return Shapes.Count - 1;
    }

    public void RecordRemove(int i)
    {
        if (i < 0 || i >= Shapes.Count) return;
        var s = Shapes[i];
        Shapes.RemoveAt(i);
        Push(new Remove(new() { (i, s) }));
    }

    /// Several shapes already taken out (the eraser), in removal order, as one step.
    public void RecordRemoved(List<(int, Shape)> removed)
    {
        if (removed.Count > 0) Push(new Remove(new(removed)));
    }

    /// Records an in-place edit of Shapes[i]. Equal non-null keys merge; no-op edits are dropped.
    public void RecordReplace(int i, Shape before, string? key = null)
    {
        if (i < 0 || i >= Shapes.Count || Shapes[i].SameAs(before)) return;
        var after = Shapes[i].Clone();
        if (key != null && _undo.Count > 0 && _undo[^1] is Replace last && last.Index == i && last.Key == key)
            _undo[^1] = last with { After = after };
        else
            Push(new Replace(i, before.Clone(), after, key));
    }

    /// Call when a drag that edits Shapes[i] starts; EndEdit turns the whole drag into one step.
    public void BeginEdit(int i) => _editBefore = i >= 0 && i < Shapes.Count ? (i, Shapes[i].Clone()) : null;

    public void EndEdit()
    {
        if (_editBefore is { } e) RecordReplace(e.Index, e.Before);
        _editBefore = null;
    }

    public bool Undo()
    {
        if (_undo.Count == 0) return false;
        var e = _undo[^1];
        _undo.RemoveAt(_undo.Count - 1);
        switch (e)
        {
            case Add a:
                if (a.Index >= Shapes.Count) return false;
                e = a with { Shape = Shapes[a.Index].Clone() };
                Shapes.RemoveAt(a.Index);
                break;
            case Remove r:
                for (var k = r.Items.Count - 1; k >= 0; k--)
                    Shapes.Insert(Math.Min(r.Items[k].Index, Shapes.Count), r.Items[k].Shape);
                break;
            case Replace rp:
                if (rp.Index >= Shapes.Count) return false;
                Shapes[rp.Index] = rp.Before.Clone();
                break;
        }
        _redo.Add(e);
        return true;
    }

    public bool Redo()
    {
        if (_redo.Count == 0) return false;
        var e = _redo[^1];
        _redo.RemoveAt(_redo.Count - 1);
        switch (e)
        {
            case Add a:
                Shapes.Insert(Math.Min(a.Index, Shapes.Count), a.Shape.Clone());
                break;
            case Remove r:
                foreach (var (i, _) in r.Items)
                    if (i < Shapes.Count) Shapes.RemoveAt(i);
                break;
            case Replace rp:
                if (rp.Index >= Shapes.Count) return false;
                Shapes[rp.Index] = rp.After.Clone();
                break;
        }
        _undo.Add(e);
        return true;
    }

    public void Clear()
    {
        Shapes.Clear();
        _undo.Clear();
        _redo.Clear();
        _editBefore = null;
    }

    public int NextNumber => Shapes.Where(s => s.Tool == Tool.Number).Select(s => s.Number).DefaultIfEmpty(0).Max() + 1;

    /// Index of the topmost shape under the point that passes `filter`, or -1.
    public int IndexAt(PointF p, float tol, Func<Shape, bool>? filter = null)
    {
        for (var i = Shapes.Count - 1; i >= 0; i--)
            if ((filter == null || filter(Shapes[i])) && Shapes[i].HitTest(p, tol)) return i;
        return -1;
    }
}
