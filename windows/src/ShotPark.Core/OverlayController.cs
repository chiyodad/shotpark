using System.Drawing;

namespace ShotPark.Core;

public enum PointerButton { Left, Right }

/// The keys the overlay reacts to (the UI maps its own key codes onto these).
public enum KeyCode
{
    Other, Escape, Enter, Delete, Back, Left, Right, Up, Down,
    A, B, C, E, L, N, P, R, S, T, V, Y, Z, D1, D2, D3,
}

public enum OverlayAction { Copy, Save, Close }

public enum CursorKind { Cross, Arrow, Move, SizeNWSE, SizeNESW, SizeNS, SizeWE, IBeam, Hand }

/// Everything the capture overlay does, independent of the UI toolkit: selection, tools, shapes,
/// toolbar and palette hit-testing, keyboard shortcuts. The window feeds it input and paints its state.
public sealed class OverlayController
{
    enum Drag { None, NewSelection, MoveSelection, ResizeSelection, Draw, MoveShape }

    Drag _drag;
    PointF _dragStart;
    RectangleF _dragOrigin;
    Handle _dragHandle;
    bool _shapeMoved;

    public OverlayController(RectangleF screen, IReadOnlyList<RectangleF> monitors, float scale)
    {
        Screen = screen;
        Monitors = monitors.Count > 0 ? monitors : new[] { screen };
        Scale = scale;
    }

    public RectangleF Screen { get; }
    public IReadOnlyList<RectangleF> Monitors { get; }
    public float Scale { get; }

    public RectangleF? Selection { get; private set; }
    public Tool Tool { get; private set; }
    public int ColorIndex { get; set; }
    public int WidthIndex { get; set; } = 1;
    public Color Color => Palette.Default[ColorIndex];
    public Annotations Doc { get; } = new();
    /// The shape being drawn right now (not yet in Doc).
    public Shape? Drawing { get; private set; }
    /// The shape picked in select mode (move with drag / arrow keys, Delete removes).
    public Shape? Picked { get; private set; }
    public bool PaletteOpen { get; private set; }
    public int HoverItem { get; private set; } = -1;
    public bool TipVisible { get; set; }
    public PointF Pointer { get; private set; }
    public bool Selecting => _drag == Drag.NewSelection;

    /// Measures a text block (font size in pixels) — supplied by the UI.
    public Func<string, float, SizeF> MeasureText { get; set; } = (t, size) => new SizeF(t.Length * size * 0.6f, size * 1.4f);

    public event Action? Changed;
    public event Action<OverlayAction>? ActionRequested;
    /// Show a text box at the point; the shape is non-null when re-editing an existing text.
    public event Action<PointF, Shape?>? TextRequested;

    public float HandleRadius => 6 * Scale;
    public float StrokeWidth => PaletteLayout.WidthLevels[WidthIndex] * Scale;
    public float FontSize => PaletteLayout.FontLevels[WidthIndex] * Scale;
    public float NumberSize => PaletteLayout.NumberLevels[WidthIndex] * Scale;

    public RectangleF MonitorAt(PointF p)
    {
        foreach (var m in Monitors) if (m.Contains(p)) return m;
        return Monitors.OrderBy(m => Geometry.Distance(p, new PointF(m.X + m.Width / 2, m.Y + m.Height / 2))).First();
    }

    public RectangleF? ToolbarRect => Selection is { } s && !Selecting
        ? ToolbarLayout.Place(s, MonitorAt(new PointF(s.X + s.Width / 2, s.Bottom)), Scale)
        : null;

    public RectangleF? PaletteRect => PaletteOpen && Selection is { } s && ToolbarRect is { } tb
        ? PaletteLayout.Place(tb, s, MonitorAt(new PointF(tb.X + tb.Width / 2, tb.Y)), Scale)
        : null;

    public int ToolbarItemAt(PointF p)
    {
        if (ToolbarRect is not { } tb || !tb.Contains(p)) return -1;
        var (rects, _) = ToolbarLayout.Rects(Scale);
        for (var i = 0; i < rects.Length; i++)
            if (rects[i].Contains(p.X - tb.X, p.Y - tb.Y)) return i;
        return -1;
    }

    void Notify() => Changed?.Invoke();

    // ───────────────────────── pointer ─────────────────────────

    public void PointerDown(PointF p, PointerButton button, bool shift = false)
    {
        Pointer = p;
        TipVisible = false;
        if (button == PointerButton.Right)
        {
            if (Drawing != null || _drag != Drag.None) { Drawing = null; _drag = Drag.None; Notify(); }
            else ActionRequested?.Invoke(OverlayAction.Close);
            return;
        }

        if (PaletteRect is { } pr)
        {
            if (pr.Contains(p)) { PaletteClick(p, pr); return; }
            PaletteOpen = false;
        }

        var item = ToolbarItemAt(p);
        if (item >= 0) { Activate(ToolbarLayout.Items[item]); return; }
        if (ToolbarRect is { } tbr && tbr.Contains(p)) return; // padding between buttons

        if (Selection is not { } sel)
        {
            BeginNewSelection(p);
            return;
        }

        var handle = Geometry.HandleAt(sel, p, HandleRadius * 1.5f);
        if (handle != Handle.None)
        {
            _drag = Drag.ResizeSelection;
            _dragHandle = handle;
            _dragStart = p;
            _dragOrigin = sel;
            Notify();
            return;
        }

        if (Tool != Tool.None)
        {
            if (!sel.Contains(p)) return; // drawing tools only work inside the capture
            Picked = null;
            switch (Tool)
            {
                case Tool.Text:
                    var existing = Doc.HitTest(p, 2 * Scale);
                    if (existing is { Tool: Tool.Text })
                    {
                        Doc.Checkpoint();
                        Doc.Shapes.Remove(existing);
                        TextRequested?.Invoke(existing.Start, existing);
                    }
                    else
                    {
                        TextRequested?.Invoke(p, null);
                    }
                    Notify();
                    return;
                case Tool.Number:
                    Doc.Checkpoint();
                    Doc.Shapes.Add(new Shape { Tool = Tool.Number, Points = { p }, Color = Color, Width = NumberSize, Number = Doc.NextNumber });
                    Notify();
                    return;
                default:
                    Drawing = new Shape
                    {
                        Tool = Tool,
                        Points = Tool == Tool.Pen ? new List<PointF> { p } : new List<PointF> { p, p },
                        Color = Color,
                        Width = Tool == Tool.Mosaic ? 0 : StrokeWidth,
                    };
                    _drag = Drag.Draw;
                    Notify();
                    return;
            }
        }

        // Select mode: grab a shape, move the selection, or start over outside it.
        var hit = sel.Contains(p) ? Doc.HitTest(p, 4 * Scale) : null;
        if (hit != null)
        {
            Picked = hit;
            _drag = Drag.MoveShape;
            _dragStart = p;
            _shapeMoved = false;
        }
        else if (sel.Contains(p))
        {
            Picked = null;
            _drag = Drag.MoveSelection;
            _dragStart = p;
            _dragOrigin = sel;
        }
        else
        {
            Picked = null;
            Doc.Clear();
            Selection = null;
            BeginNewSelection(p);
        }
        Notify();
    }

    void BeginNewSelection(PointF p)
    {
        _drag = Drag.NewSelection;
        _dragStart = p;
        Selection = new RectangleF(p, SizeF.Empty);
        Notify();
    }

    public void PointerMove(PointF p, bool shift = false)
    {
        var last = Pointer;
        Pointer = p;
        switch (_drag)
        {
            case Drag.NewSelection:
                Selection = RectangleF.Intersect(Geometry.Normalize(_dragStart, p), Screen);
                break;
            case Drag.MoveSelection:
                Selection = Geometry.Clamp(new RectangleF(_dragOrigin.X + p.X - _dragStart.X, _dragOrigin.Y + p.Y - _dragStart.Y, _dragOrigin.Width, _dragOrigin.Height), Screen);
                break;
            case Drag.ResizeSelection:
                Selection = RectangleF.Intersect(Geometry.Resize(_dragOrigin, _dragHandle, p.X - _dragStart.X, p.Y - _dragStart.Y), Screen);
                break;
            case Drag.Draw when Drawing != null:
                if (Drawing.Tool == Tool.Pen)
                {
                    if (Geometry.Distance(Drawing.End, p) >= 1.5f) Drawing.Points.Add(p);
                }
                else
                {
                    Drawing.Points[1] = shift ? Snap(Drawing.Start, p, Drawing.Tool) : p;
                }
                break;
            case Drag.MoveShape when Picked != null:
                if (!_shapeMoved)
                {
                    Doc.Checkpoint();
                    // the checkpoint cloned everything; keep pointing at the live shape
                    _shapeMoved = true;
                }
                Picked.Offset(p.X - last.X, p.Y - last.Y);
                break;
            default:
                var hover = ToolbarItemAt(p);
                if (hover != HoverItem)
                {
                    HoverItem = hover;
                    TipVisible = false;
                    Notify();
                }
                return;
        }
        Notify();
    }

    public void PointerUp(PointF p, bool shift = false)
    {
        Pointer = p;
        switch (_drag)
        {
            case Drag.NewSelection:
            case Drag.ResizeSelection:
                if (Selection is { } s && (s.Width < 4 || s.Height < 4))
                    Selection = _drag == Drag.ResizeSelection ? _dragOrigin : null;
                break;
            case Drag.Draw when Drawing != null:
                if (!Drawing.IsDegenerate)
                {
                    Doc.Checkpoint();
                    Doc.Shapes.Add(Drawing);
                }
                Drawing = null;
                break;
        }
        _drag = Drag.None;
        Notify();
    }

    /// Shift: lines snap to 45°, rectangles/ellipses become squares/circles.
    static PointF Snap(PointF a, PointF b, Tool tool)
    {
        float dx = b.X - a.X, dy = b.Y - a.Y;
        if (tool is Tool.Rect or Tool.Ellipse or Tool.Mosaic)
        {
            var side = MathF.Max(MathF.Abs(dx), MathF.Abs(dy));
            return new PointF(a.X + MathF.CopySign(side, dx), a.Y + MathF.CopySign(side, dy));
        }
        var angle = MathF.Round(MathF.Atan2(dy, dx) / (MathF.PI / 4)) * (MathF.PI / 4);
        var len = MathF.Sqrt(dx * dx + dy * dy);
        return new PointF(a.X + len * MathF.Cos(angle), a.Y + len * MathF.Sin(angle));
    }

    public CursorKind Cursor
    {
        get
        {
            if (_drag == Drag.MoveSelection || _drag == Drag.MoveShape) return CursorKind.Move;
            if (_drag != Drag.None) return CursorKind.Cross;
            if (ToolbarRect is { } tb && tb.Contains(Pointer)) return CursorKind.Hand;
            if (PaletteRect is { } pr && pr.Contains(Pointer)) return CursorKind.Hand;
            if (Selection is not { } sel) return CursorKind.Cross;
            switch (Geometry.HandleAt(sel, Pointer, HandleRadius * 1.5f))
            {
                case Handle.TopLeft or Handle.BottomRight: return CursorKind.SizeNWSE;
                case Handle.TopRight or Handle.BottomLeft: return CursorKind.SizeNESW;
                case Handle.Top or Handle.Bottom: return CursorKind.SizeNS;
                case Handle.Left or Handle.Right: return CursorKind.SizeWE;
            }
            if (!sel.Contains(Pointer)) return Tool == Tool.None ? CursorKind.Cross : CursorKind.Arrow;
            if (Tool == Tool.Text) return CursorKind.IBeam;
            if (Tool != Tool.None) return CursorKind.Cross;
            return Doc.HitTest(Pointer, 4 * Scale) != null ? CursorKind.Hand : CursorKind.Move;
        }
    }

    // ───────────────────────── toolbar / palette ─────────────────────────

    public void Activate(ToolbarItem item)
    {
        switch (item.Action)
        {
            case ToolbarAction.Tool:
                SetTool(Tool == item.Tool ? Tool.None : item.Tool);
                break;
            case ToolbarAction.Color:
                PaletteOpen = !PaletteOpen;
                Notify();
                break;
            case ToolbarAction.Undo:
                Undo();
                break;
            case ToolbarAction.Copy:
                ActionRequested?.Invoke(OverlayAction.Copy);
                break;
            case ToolbarAction.Save:
                ActionRequested?.Invoke(OverlayAction.Save);
                break;
            case ToolbarAction.Close:
                ActionRequested?.Invoke(OverlayAction.Close);
                break;
        }
    }

    public void SetTool(Tool tool)
    {
        Tool = tool;
        Picked = null;
        Notify();
    }

    void PaletteClick(PointF p, RectangleF popup)
    {
        var (colors, widths) = PaletteLayout.Rects(Scale);
        var local = new PointF(p.X - popup.X, p.Y - popup.Y);
        for (var i = 0; i < colors.Length; i++)
            if (colors[i].Contains(local)) { ColorIndex = i; ApplyStyleToPicked(); Notify(); return; }
        for (var i = 0; i < widths.Length; i++)
            if (widths[i].Contains(local)) { WidthIndex = i; ApplyStyleToPicked(); Notify(); return; }
    }

    /// A colour/width picked while a shape is selected restyles that shape.
    void ApplyStyleToPicked()
    {
        if (Picked == null) return;
        Doc.Checkpoint();
        Picked.Color = Color;
        switch (Picked.Tool)
        {
            case Tool.Text:
                Picked.FontSize = FontSize;
                Picked.TextSize = MeasureText(Picked.Text, Picked.FontSize);
                break;
            case Tool.Number:
                Picked.Width = NumberSize;
                break;
            case Tool.Mosaic:
                break;
            default:
                Picked.Width = StrokeWidth;
                break;
        }
    }

    public void Undo()
    {
        Picked = null;
        if (Doc.Undo()) Notify();
    }

    public void Redo()
    {
        Picked = null;
        if (Doc.Redo()) Notify();
    }

    // ───────────────────────── text ─────────────────────────

    /// Called by the UI when the text box closes. Empty text just drops it.
    public void CommitText(PointF at, string text)
    {
        if (!string.IsNullOrWhiteSpace(text))
        {
            Doc.Checkpoint();
            var size = FontSize;
            Doc.Shapes.Add(new Shape
            {
                Tool = Tool.Text, Points = { at }, Color = Color, Text = text.TrimEnd(),
                FontSize = size, TextSize = MeasureText(text.TrimEnd(), size),
            });
        }
        Notify();
    }

    // ───────────────────────── keyboard ─────────────────────────

    /// Returns true when the key was handled.
    public bool Key(KeyCode key, bool ctrl, bool shift)
    {
        if (ctrl)
        {
            switch (key)
            {
                case KeyCode.C: ActionRequested?.Invoke(OverlayAction.Copy); return true;
                case KeyCode.S: ActionRequested?.Invoke(OverlayAction.Save); return true;
                case KeyCode.Z when shift: Redo(); return true;
                case KeyCode.Z: Undo(); return true;
                case KeyCode.Y: Redo(); return true;
                case KeyCode.A:
                    Selection = MonitorAt(Pointer);
                    Notify();
                    return true;
            }
            return false;
        }

        switch (key)
        {
            case KeyCode.Escape:
                if (Drawing != null) { Drawing = null; _drag = Drag.None; Notify(); }
                else if (PaletteOpen) { PaletteOpen = false; Notify(); }
                else ActionRequested?.Invoke(OverlayAction.Close);
                return true;
            case KeyCode.Enter:
                if (Selection != null) ActionRequested?.Invoke(OverlayAction.Copy);
                return true;
            case KeyCode.Delete or KeyCode.Back:
                if (Picked != null)
                {
                    Doc.Checkpoint();
                    Doc.Shapes.RemoveAll(s => ReferenceEquals(s, Picked));
                    Picked = null;
                    Notify();
                }
                return true;
            case KeyCode.Left or KeyCode.Right or KeyCode.Up or KeyCode.Down:
                Nudge(key, shift ? 10 : 1);
                return true;
            case KeyCode.D1 or KeyCode.D2 or KeyCode.D3:
                WidthIndex = key - KeyCode.D1;
                ApplyStyleToPicked();
                Notify();
                return true;
        }

        if (Selection == null) return false;
        var tool = key switch
        {
            KeyCode.P => Tool.Pen, KeyCode.L => Tool.Line, KeyCode.A => Tool.Arrow, KeyCode.R => Tool.Rect,
            KeyCode.E => Tool.Ellipse, KeyCode.B => Tool.Mosaic, KeyCode.T => Tool.Text, KeyCode.N => Tool.Number,
            KeyCode.V => Tool.None, _ => (Tool?)null,
        };
        if (tool is not { } t) return false;
        SetTool(t != Tool.None && Tool == t ? Tool.None : t);
        return true;
    }

    void Nudge(KeyCode key, float step)
    {
        float dx = key == KeyCode.Left ? -step : key == KeyCode.Right ? step : 0;
        float dy = key == KeyCode.Up ? -step : key == KeyCode.Down ? step : 0;
        if (Picked != null)
        {
            Doc.Checkpoint();
            Picked.Offset(dx, dy);
        }
        else if (Selection is { } s)
        {
            Selection = Geometry.Clamp(new RectangleF(s.X + dx, s.Y + dy, s.Width, s.Height), Screen);
        }
        Notify();
    }

    /// For tests and the render preview: set the selection directly.
    public void SetSelection(RectangleF? r)
    {
        Selection = r;
        Notify();
    }

    public void SetPaletteOpen(bool open)
    {
        PaletteOpen = open;
        Notify();
    }

    public void SetHover(int item, bool tip)
    {
        HoverItem = item;
        TipVisible = tip;
        Notify();
    }
}
