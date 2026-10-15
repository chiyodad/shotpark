using System.Drawing;

namespace ShotPark.Core;

public enum PointerButton { Left, Right }

public enum OverlayAction { Copy, Save, Close, Share, Ocr, Pin }

public enum CursorKind { Cross, Arrow, Move, SizeNWSE, SizeNESW, SizeNS, SizeWE, IBeam, Hand, Grab, Emoji, Number, Eraser }

/// Everything the capture overlay does, independent of the UI toolkit: selection, tools, shapes,
/// toolbar / option bar hit-testing and keyboard shortcuts — a port of the Mac app's CaptureView.
/// The window feeds it input and paints its state.
public sealed class OverlayController
{
    enum Drag { None, NewSelection, MoveSelection, ResizeSelection, Draw, MoveShape, ScaleShape, Erase, Slider }

    Drag _drag;
    PointF _dragStart;
    RectangleF _dragOrigin;
    Handle _dragHandle;
    List<PointF> _dragPoints = new();
    float _scaleStartSize, _scaleStartDist;
    PointF _scaleCenter;
    string _sliderId = "";
    RectangleF _sliderRect;
    bool _clickOutsideSelection;
    readonly List<(int, Shape)> _eraseGesture = new();
    /// The text annotation being re-edited: taken out of Doc while its text box is open.
    (int Index, Shape Shape)? _editing;

    public OverlayController(RectangleF screen, IReadOnlyList<RectangleF> monitors, float scale, AppSettings? settings = null)
    {
        Screen = screen;
        Monitors = monitors.Count > 0 ? monitors : new[] { screen };
        Scale = scale;
        Settings = settings ?? new AppSettings();
        Colors = Settings.Colors;
    }

    public RectangleF Screen { get; }
    public IReadOnlyList<RectangleF> Monitors { get; }
    public float Scale { get; }
    public AppSettings Settings { get; }
    public AnnotationPrefs Prefs => Settings.Annotation;
    public Color[] Colors { get; }

    /// Top-level windows in overlay coordinates, front to back (click one to select it).
    public IReadOnlyList<RectangleF> WindowRects { get; set; } = Array.Empty<RectangleF>();
    /// The user's image stamps (file names), supplied by the UI.
    public Func<IReadOnlyList<string>> StampImages { get; set; } = () => Array.Empty<string>();

    public RectangleF? Selection { get; private set; }
    public Tool Tool { get; private set; }
    public Document Doc { get; } = new();
    /// The shape being drawn right now (not yet in Doc).
    public Shape? Drawing { get; private set; }
    /// Index of the selected annotation (also the shape just drawn / stamped).
    public int? Selected { get; private set; }
    public bool PaletteOpen { get; private set; }
    public int HoverItem { get; private set; } = -1;
    public string? HoverCell { get; private set; }
    public bool TipVisible { get; set; }
    public PointF Pointer { get; private set; }
    public RectangleF? HoverWindow { get; private set; }
    public int EraserHover { get; private set; } = -1;
    public bool EditingText => _editing != null || _textOpen;
    bool _textOpen;
    public bool Selecting => _drag == Drag.NewSelection;
    public bool Dragging => _drag != Drag.None;

    public event Action? Changed;
    public event Action<OverlayAction>? ActionRequested;
    /// Open a text box with its glyphs' top-left corner at the point; the shape is non-null when re-editing.
    public event Action<PointF, Shape?>? TextRequested;
    /// Text size / colour / style changed while a text box is open.
    public event Action? TextStyleChanged;
    /// Show a box to type a font size over this rectangle.
    public event Action<RectangleF, int>? SizeEntryRequested;
    public event Action? EmojiPickerRequested;
    public event Action? AddImageRequested;
    /// Right-click on a user image in the stamp bar (name, pointer).
    public event Action<string, PointF>? ImageMenuRequested;
    /// Ctrl+V: the UI places a clipboard image with PlaceImage().
    public event Action? PasteRequested;
    /// A short message for a toast.
    public event Action<string>? Notice;

    static string L(string ko, string en) => Strings.L(ko, en);

    public float HandleRadius => 6 * Scale;
    public Color Color
    {
        get => Palette.FromHex(Prefs.Color) ?? Colors[0];
        private set => Prefs.Color = Palette.ToHex(value);
    }
    public float StrokeWidth => Prefs.Width * Scale;
    public float TextSize => Prefs.TextSize * Scale;
    public float EmojiSize => Prefs.EmojiSize * Scale;
    public Color BoxColor => Palette.FromHex(Prefs.BoxColor) ?? Color.White;

    void Notify() => Changed?.Invoke();

    public RectangleF MonitorAt(PointF p)
    {
        foreach (var m in Monitors) if (m.Contains(p)) return m;
        return Monitors.OrderBy(m => Geometry.Distance(p, Geometry.Center(m))).First();
    }

    // ───────────────────────── layout ─────────────────────────

    public RectangleF? ToolbarRect => Selection is { } s && !Selecting
        ? ToolbarLayout.Place(s, MonitorAt(new PointF(s.X + s.Width / 2, s.Bottom)), Scale)
        : null;

    public int ToolbarItemAt(PointF p)
    {
        if (ToolbarRect is not { } tb || !tb.Contains(p)) return -1;
        var (rects, _) = ToolbarLayout.Rects(Scale);
        for (var i = 0; i < rects.Length; i++)
            if (rects[i].Contains(p.X - tb.X, p.Y - tb.Y)) return i;
        return -1;
    }

    public RectangleF? ToolbarItemRect(ToolbarAction a)
    {
        if (ToolbarRect is not { } tb) return null;
        var i = ToolbarLayout.IndexOf(a);
        if (i < 0) return null;
        var r = ToolbarLayout.Rects(Scale).Items[i];
        r.Offset(tb.X, tb.Y);
        return r;
    }

    public string Tip(int item) => ToolbarLayout.Tip(ToolbarLayout.Items[item],
        Settings.MosaicKeySpec.Display, Settings.OcrKeySpec.Display, Settings.PinKeySpec.Display);

    /// The selected annotation, when the option bars should edit it.
    public int? EditableSelection
    {
        get
        {
            if (Selected is not { } i || i >= Doc.Shapes.Count) return null;
            // Select / text tool: whatever is selected. A drawing tool: the shape it just drew.
            return Tool is Tool.None or Tool.Text || Doc.Shapes[i].Tool == Tool ? i : null;
        }
    }

    /// Which tool's option bars to show: the selected annotation's kind, otherwise the current tool.
    public Tool OptionsTool => EditableSelection is { } i ? Doc.Shapes[i].Tool : Tool;

    /// True when the option bars stack below the toolbar (tooltips then go above it).
    public bool BarsBelow
    {
        get
        {
            if (ToolbarRect is not { } tb) return true;
            var m = MonitorAt(Geometry.Center(tb));
            return tb.Bottom + (6 + 40) * Scale <= m.Bottom;
        }
    }

    /// The visible option bars, positioned under (or above) the toolbar.
    public IReadOnlyList<OptionBar> Bars
    {
        get
        {
            if (ToolbarRect is not { } tb || Selecting) return Array.Empty<OptionBar>();
            var list = new List<OptionBar>();
            var sel = EditableSelection is { } i ? Doc.Shapes[i] : null;
            var ot = OptionsTool;
            if (ot is Tool.Text or Tool.Number)
                list.Add(BarBuilder.Text(Scale, sel != null ? MathF.Round(sel.FontSize / Scale) : Prefs.TextSize,
                    sel is { Tool: Tool.Text } ? sel.TextStyle : Prefs.TextStyle,
                    sel is { Tool: Tool.Text } ? sel.BoxColor : BoxColor,
                    sel is { Tool: Tool.Text } ? sel.BoxAlpha : Prefs.BoxAlpha));
            if (Shape.IsStrokeTool(ot))
                list.Add(BarBuilder.Stroke(Scale, ot, sel != null ? MathF.Round(sel.Width / Scale * 10) / 10 : Prefs.Width,
                    sel?.Color ?? Color, sel?.Dashed ?? Prefs.Dashed, sel?.ArrowHead ?? Prefs.ArrowHead,
                    sel?.Fill ?? Prefs.Fill, sel?.FillAlpha ?? Prefs.FillAlpha));
            if (ot == Tool.Mosaic)
                list.Add(BarBuilder.Mosaic(Scale, sel?.MosaicStyle ?? Prefs.MosaicStyle, sel?.MosaicLevel ?? Prefs.MosaicLevel));
            if (Tool == Tool.Emoji)
            {
                var images = StampImages();
                var image = Prefs.StampImage != null && images.Contains(Prefs.StampImage) ? Prefs.StampImage : null;
                list.Add(BarBuilder.Emoji(Scale, Prefs.EmojiChoices(), Prefs.Emoji, Prefs.EmojiSize, images, image));
            }
            if (PaletteOpen && ot != Tool.Mosaic)
                list.Add(BarBuilder.Palette(Scale, Colors, sel != null && sel.Tool is not (Tool.Emoji or Tool.Mosaic) ? sel.Color : Color));

            var m = MonitorAt(Geometry.Center(tb));
            var below = BarsBelow;
            var gap = 6 * Scale;
            var y = below ? tb.Bottom + gap : tb.Top - gap;
            var placed = new List<OptionBar>();
            foreach (var bar in list)
            {
                var w = bar.Frame.Width;
                var h = bar.Frame.Height;
                var x = MathF.Max(m.Left + 4 * Scale, MathF.Min(tb.X, m.Right - w - 4 * Scale));
                var top = below ? y : y - h;
                placed.Add(bar with { Frame = new RectangleF(x, top, w, h) });
                y = below ? top + h + gap : top - gap;
            }
            return placed;
        }
    }

    (OptionBar Bar, BarCell Cell)? CellAt(PointF p)
    {
        foreach (var b in Bars)
            if (b.CellAt(p) is { } c) return (b, c);
        return null;
    }

    bool InBar(PointF p) => Bars.Any(b => b.Frame.Contains(p));

    /// The small square at the bottom-right of the selected stamp; dragging it scales the stamp.
    public RectangleF? StampHandle
    {
        get
        {
            if (Selection == null || Selected is not { } i || i >= Doc.Shapes.Count || !Doc.Shapes[i].IsStamp) return null;
            var b = RectangleF.Inflate(Doc.Shapes[i].Bounds, 3 * Scale, 3 * Scale);
            return new RectangleF(b.Right - 5 * Scale, b.Bottom - 5 * Scale, 10 * Scale, 10 * Scale);
        }
    }

    /// ↺ / ↻ / "30° ✕" buttons next to the selected text or stamp: on the side with the most room,
    /// outside the circle the object sweeps while rotating, so they stay put while you click them.
    public IReadOnlyList<(int Dir, RectangleF Rect)> RotateButtons
    {
        get
        {
            if (Selection == null || EditingText || _drag != Drag.None || Selected is not { } i || i >= Doc.Shapes.Count || !Doc.Shapes[i].IsRotatable)
                return Array.Empty<(int, RectangleF)>();
            var sh = Doc.Shapes[i];
            var ub = sh.UnrotatedBounds;
            var c = sh.Pivot;
            var m = MonitorAt(c);
            var reach = MathF.Sqrt(ub.Width * ub.Width + ub.Height * ub.Height) / 2 + 8 * Scale;
            float btn = 26 * Scale, resetW = 54 * Scale, gap = 2 * Scale, pad = 4 * Scale;
            var room = new (string Side, float Room)[]
            {
                ("top", c.Y - reach - m.Top), ("bottom", m.Bottom - (c.Y + reach)),
                ("left", c.X - reach - m.Left), ("right", m.Right - (c.X + reach)),
            };
            var side = room.OrderByDescending(r => r.Room).First().Side;
            var rects = new List<(int, RectangleF)>();
            if (side is "top" or "bottom")
            {
                var w = btn * 2 + resetW + gap * 2;
                var x = Math.Clamp(c.X - w / 2, m.Left + pad, MathF.Max(m.Left + pad, m.Right - w - pad));
                var y = side == "top" ? c.Y - reach - btn : c.Y + reach;
                y = Math.Clamp(y, m.Top + pad, MathF.Max(m.Top + pad, m.Bottom - btn - pad));
                rects.Add((-1, new RectangleF(x, y, btn, btn)));
                rects.Add((1, new RectangleF(x + btn + gap, y, btn, btn)));
                rects.Add((0, new RectangleF(x + (btn + gap) * 2, y, resetW, btn)));
            }
            else
            {
                var h = btn * 3 + gap * 2;
                var y = Math.Clamp(c.Y - h / 2, m.Top + pad, MathF.Max(m.Top + pad, m.Bottom - h - pad));
                var x = side == "right" ? c.X + reach : c.X - reach - resetW;
                x = Math.Clamp(x, m.Left + pad, MathF.Max(m.Left + pad, m.Right - resetW - pad));
                rects.Add((-1, new RectangleF(x, y, resetW, btn)));
                rects.Add((1, new RectangleF(x, y + btn + gap, resetW, btn)));
                rects.Add((0, new RectangleF(x, y + (btn + gap) * 2, resetW, btn)));
            }
            if (sh.Rotation == 0) rects.RemoveAt(rects.Count - 1);
            return rects;
        }
    }

    // ───────────────────────── pointer ─────────────────────────

    public void PointerDown(PointF p, PointerButton button, int clicks = 1, bool alt = false)
    {
        Pointer = p;
        TipVisible = false;
        if (button == PointerButton.Right)
        {
            if (CellAt(p) is { Cell.Kind: CellKind.Image } img) { ImageMenuRequested?.Invoke(img.Cell.Text, p); return; }
            if (InBar(p) || ToolbarRect is { } t && t.Contains(p)) return;
            // Right-click steps back: cancel the stroke, drop the selection, and only then close.
            if (Drawing != null || _drag != Drag.None) { Drawing = null; _drag = Drag.None; Notify(); }
            else if (Selection != null) ClearSelection();
            else ActionRequested?.Invoke(OverlayAction.Close);
            return;
        }

        if (CellAt(p) is { } hit)
        {
            HandleCell(hit.Bar, hit.Cell, p);
            return;
        }
        if (InBar(p)) return;

        var paletteWasOpen = PaletteOpen;
        PaletteOpen = false;
        var item = ToolbarItemAt(p);
        if (item >= 0)
        {
            var it = ToolbarLayout.Items[item];
            if (it.Action == ToolbarAction.Color) { PaletteOpen = !paletteWasOpen; Notify(); }
            else Activate(it);
            return;
        }
        if (ToolbarRect is { } tbr && tbr.Contains(p)) { Notify(); return; } // padding between buttons

        foreach (var (dir, r) in RotateButtons)
            if (r.Contains(p)) { Rotate(dir); return; }

        if (StampHandle is { } h && RectangleF.Inflate(h, 4 * Scale, 4 * Scale).Contains(p) && Selected is { } si)
        {
            var c = Doc.Shapes[si].Start;
            Doc.BeginEdit(si);
            _scaleStartSize = Doc.Shapes[si].FontSize;
            _scaleCenter = c;
            _scaleStartDist = MathF.Max(Geometry.Distance(p, c), 1);
            _drag = Drag.ScaleShape;
            Notify();
            return;
        }

        if (Selection is not { } sel)
        {
            _clickOutsideSelection = false;
            BeginNewSelection(p);
            return;
        }

        var tol = 7 * Scale;
        // An existing annotation: drag to move it, double-click a text to edit it again.
        if (Tool is Tool.None or Tool.Text)
        {
            var i = Doc.IndexAt(p, tol, s => Tool == Tool.None || s.Tool == Tool.Text);
            if (i >= 0)
            {
                if (clicks >= 2 && Doc.Shapes[i].Tool == Tool.Text) { EditText(i); return; }
                GrabShape(i, p);
                return;
            }
        }
        // With a stamp tool, pressing on an existing stamp grabs it instead of stamping on top.
        if (Tool is Tool.Emoji or Tool.Number)
        {
            var i = Doc.IndexAt(p, 0, s => s.IsStamp);
            if (i >= 0) { GrabShape(i, p); return; }
        }
        Selected = null;

        if (Tool == Tool.None)
        {
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
            if (sel.Contains(p))
            {
                _drag = Drag.MoveSelection;
                _dragStart = p;
                _dragOrigin = sel;
                Notify();
                return;
            }
        }
        else if (RectangleF.Inflate(sel, 2, 2).Contains(p))
        {
            switch (Tool)
            {
                case Tool.Text:
                    _textOpen = true;
                    TextRequested?.Invoke(p, null);
                    Notify();
                    return;
                case Tool.Eraser:
                    _eraseGesture.Clear();
                    Erase(p);
                    _drag = Drag.Erase;
                    Notify();
                    return;
                case Tool.Emoji:
                {
                    var images = StampImages();
                    var image = Prefs.StampImage != null && images.Contains(Prefs.StampImage) ? Prefs.StampImage : null;
                    var sh = new Shape
                    {
                        Tool = Tool.Emoji, Points = { p }, Color = Color, Width = StrokeWidth,
                        Text = image == null ? Prefs.Emoji : "", FontSize = EmojiSize, ImageName = image,
                    };
                    // A photo / signature is usually placed once and then moved, resized or rotated:
                    // switch to the select tool. Alt-click keeps the image loaded to stamp it again.
                    if (image != null && !alt) Tool = Tool.None;
                    Selected = Doc.RecordAdd(sh);
                    Notify();
                    return;
                }
                case Tool.Number:
                    Selected = Doc.RecordAdd(new Shape
                    {
                        Tool = Tool.Number, Points = { p }, Color = Color, Width = StrokeWidth,
                        FontSize = TextSize, Number = Doc.NextNumber,
                    });
                    Notify();
                    return;
                default:
                    Drawing = new Shape
                    {
                        Tool = Tool,
                        Points = Tool is Tool.Pen or Tool.Marker ? new List<PointF> { p } : new List<PointF> { p, p },
                        Color = Color, Width = StrokeWidth, Dashed = Prefs.Dashed, ArrowHead = Prefs.ArrowHead,
                        Fill = Tool is Tool.Rect or Tool.Ellipse ? Prefs.Fill : 0, FillAlpha = Prefs.FillAlpha,
                        MosaicStyle = Prefs.MosaicStyle, MosaicLevel = Prefs.MosaicLevel,
                    };
                    _drag = Drag.Draw;
                    Notify();
                    return;
            }
        }

        // Anywhere else: start over with a new selection.
        _clickOutsideSelection = true;
        Doc.Clear();
        Drawing = null;
        BeginNewSelection(p);
    }

    void GrabShape(int i, PointF p)
    {
        Selected = i;
        Doc.BeginEdit(i);
        _dragPoints = new List<PointF>(Doc.Shapes[i].Points);
        _dragStart = p;
        _drag = Drag.MoveShape;
        Notify();
    }

    void ClearSelection()
    {
        Selected = null;
        PaletteOpen = false;
        Doc.Clear();
        Selection = null;
        Notify();
    }

    void BeginNewSelection(PointF p)
    {
        Selected = null;
        _drag = Drag.NewSelection;
        _dragStart = p;
        Selection = new RectangleF(p, SizeF.Empty);
        HoverWindow = null;
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
                if (Drawing.Tool is Tool.Pen or Tool.Marker)
                {
                    if (Geometry.Distance(Drawing.End, p) >= 1.5f) Drawing.Points.Add(p);
                }
                else
                {
                    Drawing.Points[1] = shift ? Snap(Drawing.Start, p, Drawing.Tool) : p;
                }
                break;
            case Drag.MoveShape when Selected is { } i && i < Doc.Shapes.Count:
                Doc.Shapes[i].Points = _dragPoints.Select(q => new PointF(q.X + p.X - _dragStart.X, q.Y + p.Y - _dragStart.Y)).ToList();
                break;
            case Drag.ScaleShape when Selected is { } si && si < Doc.Shapes.Count:
                Doc.Shapes[si].FontSize = Math.Clamp(_scaleStartSize * Geometry.Distance(p, _scaleCenter) / _scaleStartDist, 8 * Scale, 400 * Scale);
                break;
            case Drag.Erase:
                Erase(p);
                break;
            case Drag.Slider:
                SetSlider(_sliderId, (p.X - _sliderRect.X) / MathF.Max(1, _sliderRect.Width));
                break;
            default:
                Hover(p, last);
                return;
        }
        Notify();
    }

    void Hover(PointF p, PointF last)
    {
        var changed = false;
        var hover = ToolbarItemAt(p);
        if (hover != HoverItem)
        {
            HoverItem = hover;
            TipVisible = false;
            changed = true;
        }
        var cell = CellAt(p)?.Cell.Id;
        if (cell != HoverCell) { HoverCell = cell; changed = true; }
        if (Selection != null && Tool == Tool.Eraser)
        {
            var e = Doc.IndexAt(p, 10 * Scale);
            if (e != EraserHover) { EraserHover = e; changed = true; }
        }
        if (Selection == null)
        {
            var w = WindowAt(p);
            if (w != HoverWindow) { HoverWindow = w; changed = true; }
            // Before anything is selected the hint follows the pointer's monitor.
            if (MonitorAt(last) != MonitorAt(p)) changed = true;
        }
        if (changed) Notify();
    }

    RectangleF? WindowAt(PointF p)
    {
        foreach (var w in WindowRects)
            if (w.Contains(p))
            {
                var r = RectangleF.Intersect(w, Screen);
                return r.Width >= 4 && r.Height >= 4 ? r : null;
            }
        return null;
    }

    public void PointerUp(PointF p)
    {
        Pointer = p;
        switch (_drag)
        {
            case Drag.NewSelection:
                if (Selection is { } s && (s.Width < 4 || s.Height < 4))
                {
                    // A plain click: from the idle screen it grabs the window under the pointer;
                    // outside an existing selection it just clears that selection.
                    var under = WindowAt(p);
                    if (!_clickOutsideSelection && under is { } w) Selection = RectangleF.FromLTRB(MathF.Round(w.Left), MathF.Round(w.Top), MathF.Round(w.Right), MathF.Round(w.Bottom));
                    else { Selection = null; HoverWindow = under; }
                }
                else if (Selection is { } sel) Selection = Geometry.ToPixels(sel);
                break;
            case Drag.ResizeSelection:
                if (Selection is { } rs && (rs.Width < 4 || rs.Height < 4)) Selection = _dragOrigin;
                else if (Selection is { } r2) Selection = Geometry.ToPixels(r2);
                break;
            case Drag.MoveSelection:
                if (Selection is { } ms) Selection = new RectangleF(MathF.Round(ms.X), MathF.Round(ms.Y), ms.Width, ms.Height);
                break;
            case Drag.Draw when Drawing != null:
                // Kept "current": width / dash / colour changes right after drawing apply to it.
                if (!Drawing.IsDegenerate) Selected = Doc.RecordAdd(Drawing);
                Drawing = null;
                break;
            case Drag.Erase:
                Doc.RecordRemoved(_eraseGesture.ToList());
                _eraseGesture.Clear();
                break;
            case Drag.MoveShape:
                Doc.EndEdit();
                break;
            case Drag.ScaleShape:
                Doc.EndEdit();
                if (Selected is { } i && i < Doc.Shapes.Count && Doc.Shapes[i].Tool == Tool.Emoji)
                    Prefs.EmojiSize = MathF.Round(Doc.Shapes[i].FontSize / Scale); // the next stamp keeps this size
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

    void Erase(PointF p)
    {
        var i = Doc.IndexAt(p, 10 * Scale);
        if (i < 0) return;
        _eraseGesture.Add((i, Doc.Shapes[i]));
        Doc.Shapes.RemoveAt(i);
        Selected = null;
        EraserHover = -1;
    }

    public CursorKind Cursor
    {
        get
        {
            if (_drag is Drag.MoveSelection or Drag.MoveShape) return CursorKind.Grab;
            if (_drag == Drag.Erase) return CursorKind.Eraser;
            if (_drag != Drag.None) return CursorKind.Cross;
            if (ToolbarRect is { } tb && tb.Contains(Pointer)) return CursorKind.Arrow;
            if (InBar(Pointer)) return CursorKind.Arrow;
            if (Selection is not { } sel) return CursorKind.Cross;
            if (RotateButtons.Any(b => b.Rect.Contains(Pointer))) return CursorKind.Hand;
            if (StampHandle is { } h && RectangleF.Inflate(h, 4 * Scale, 4 * Scale).Contains(Pointer)) return CursorKind.SizeNWSE;
            if (Tool == Tool.None)
            {
                switch (Geometry.HandleAt(sel, Pointer, HandleRadius * 1.5f))
                {
                    case Handle.TopLeft or Handle.BottomRight: return CursorKind.SizeNWSE;
                    case Handle.TopRight or Handle.BottomLeft: return CursorKind.SizeNESW;
                    case Handle.Top or Handle.Bottom: return CursorKind.SizeNS;
                    case Handle.Left or Handle.Right: return CursorKind.SizeWE;
                }
                if (!sel.Contains(Pointer)) return CursorKind.Arrow;
                return Doc.IndexAt(Pointer, 7 * Scale) >= 0 ? CursorKind.Hand : CursorKind.Move;
            }
            if (!RectangleF.Inflate(sel, 2, 2).Contains(Pointer)) return CursorKind.Cross;
            return Tool switch
            {
                Tool.Text => Doc.IndexAt(Pointer, 7 * Scale, s => s.Tool == Tool.Text) >= 0 ? CursorKind.Hand : CursorKind.IBeam,
                Tool.Emoji => Doc.IndexAt(Pointer, 0, s => s.IsStamp) >= 0 ? CursorKind.Hand : CursorKind.Emoji,
                Tool.Number => Doc.IndexAt(Pointer, 0, s => s.IsStamp) >= 0 ? CursorKind.Hand : CursorKind.Number,
                Tool.Eraser => CursorKind.Eraser,
                _ => CursorKind.Cross,
            };
        }
    }

    // ───────────────────────── toolbar / option bars ─────────────────────────

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
            case ToolbarAction.Beautify:
                Settings.Beautify = !Settings.Beautify;
                Notice?.Invoke(Settings.Beautify ? L("꾸미기 켜짐 · 복사·저장·공유에 적용", "Beautify on · applies to copy, save, share") : L("꾸미기 꺼짐", "Beautify off"));
                Notify();
                break;
            case ToolbarAction.Copy: ActionRequested?.Invoke(OverlayAction.Copy); break;
            case ToolbarAction.Save: ActionRequested?.Invoke(OverlayAction.Save); break;
            case ToolbarAction.Share: ActionRequested?.Invoke(OverlayAction.Share); break;
            case ToolbarAction.Ocr: ActionRequested?.Invoke(OverlayAction.Ocr); break;
            case ToolbarAction.Pin: ActionRequested?.Invoke(OverlayAction.Pin); break;
            case ToolbarAction.Close: ActionRequested?.Invoke(OverlayAction.Close); break;
        }
    }

    public void SetTool(Tool tool)
    {
        Tool = tool;
        if (tool != Tool.None) Selected = null;
        if (tool != Tool.Eraser) EraserHover = -1;
        PaletteOpen = false;
        Notify();
    }

    /// Applies a change to the selected annotation as one (mergeable) undo step. False when nothing is selected.
    bool ApplyToSelection(Action<Shape> change, string key = "style")
    {
        if (EditableSelection is not { } i) return false;
        var before = Doc.Shapes[i].Clone();
        change(Doc.Shapes[i]);
        Doc.RecordReplace(i, before, key);
        return true;
    }

    void HandleCell(OptionBar bar, BarCell cell, PointF p)
    {
        var parts = cell.Id.Split(':');
        var id = parts[0];
        var n = parts.Length > 1 && float.TryParse(parts[1], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var v) ? v : 0;
        var k = (int)n;
        switch (id)
        {
            case "size": SetTextSize(n); break;
            case "sizefield": SizeEntryRequested?.Invoke(bar.Abs(cell), (int)MathF.Round(EditableSelection is { } si ? Doc.Shapes[si].FontSize / Scale : Prefs.TextSize)); return;
            case "style":
            {
                var flag = (TextStyles)k;
                var current = EditableSelection is { } ti && Doc.Shapes[ti].Tool == Tool.Text ? Doc.Shapes[ti].TextStyle : Prefs.TextStyle;
                var next = current ^ flag;
                Prefs.TextStyle = next;
                ApplyToSelection(s => { if (s.Tool == Tool.Text) s.TextStyle = next; });
                TextStyleChanged?.Invoke();
                break;
            }
            case "box":
                Prefs.BoxColor = Palette.ToHex(Shape.BoxColors[k]);
                ApplyToSelection(s => { if (s.Tool == Tool.Text) s.BoxColor = Shape.BoxColors[k]; });
                TextStyleChanged?.Invoke();
                break;
            case "boxalpha" or "fillalpha":
                _drag = Drag.Slider;
                _sliderId = id;
                _sliderRect = bar.Abs(cell);
                SetSlider(id, (p.X - _sliderRect.X) / MathF.Max(1, _sliderRect.Width));
                break;
            case "width":
            {
                var w = AnnotationPrefs.Widths[k];
                Prefs.Width = w;
                ApplyToSelection(s => { if (Shape.IsStrokeTool(s.Tool)) s.Width = w * Scale; });
                break;
            }
            case "dash":
            {
                var d = !(EditableSelection is { } di ? Doc.Shapes[di].Dashed : Prefs.Dashed);
                Prefs.Dashed = d;
                ApplyToSelection(s => { if (Shape.IsStrokeTool(s.Tool)) s.Dashed = d; });
                break;
            }
            case "head":
                Prefs.ArrowHead = (ArrowHead)k;
                ApplyToSelection(s => { if (s.Tool == Tool.Arrow) s.ArrowHead = (ArrowHead)k; });
                break;
            case "fill":
                Prefs.Fill = k;
                ApplyToSelection(s => { if (s.Tool is Tool.Rect or Tool.Ellipse) s.Fill = k; });
                break;
            case "mstyle":
                Prefs.MosaicStyle = (MosaicStyle)k;
                ApplyToSelection(s => { if (s.Tool == Tool.Mosaic) s.MosaicStyle = (MosaicStyle)k; });
                break;
            case "mlevel":
                Prefs.MosaicLevel = k;
                ApplyToSelection(s => { if (s.Tool == Tool.Mosaic) s.MosaicLevel = k; });
                break;
            case "emoji":
                PickEmoji(Prefs.EmojiChoices()[k]);
                return;
            case "more": EmojiPickerRequested?.Invoke(); return;
            case "eminus": StepStampSize(-1); return;
            case "eplus": StepStampSize(1); return;
            case "esize":
            {
                var size = AnnotationPrefs.EmojiSizes[k];
                Prefs.EmojiSize = size;
                if (Selected is { } ei && ei < Doc.Shapes.Count && Doc.Shapes[ei].Tool == Tool.Emoji)
                {
                    var before = Doc.Shapes[ei].Clone();
                    Doc.Shapes[ei].FontSize = size * Scale;
                    Doc.RecordReplace(ei, before, "size");
                }
                break;
            }
            case "img":
            {
                var images = StampImages();
                if (k < images.Count) Prefs.StampImage = images[k];
                break;
            }
            case "imgadd": AddImageRequested?.Invoke(); return;
            case "color":
            {
                var c = Colors[k];
                Color = c;
                PaletteOpen = false;
                if (!ApplyToSelection(s => { if (s.Tool is not (Tool.Emoji or Tool.Mosaic)) s.Color = c; }) && Tool == Tool.None)
                    Tool = Tool.Pen;
                TextStyleChanged?.Invoke();
                break;
            }
        }
        Notify();
    }

    void SetSlider(string id, float t)
    {
        t = Math.Clamp(t, 0, 1);
        if (id == "boxalpha")
        {
            var a = MathF.Round((0.15f + t * 0.85f) * 100) / 100;
            Prefs.BoxAlpha = a;
            ApplyToSelection(s => { if (s.Tool == Tool.Text) s.BoxAlpha = a; }, "boxalpha");
            TextStyleChanged?.Invoke();
        }
        else
        {
            var a = MathF.Round((0.1f + t * 0.9f) * 100) / 100;
            Prefs.FillAlpha = a;
            ApplyToSelection(s => { if (s.Tool is Tool.Rect or Tool.Ellipse) s.FillAlpha = a; }, "fillalpha");
        }
    }

    public void SetTextSize(float logical)
    {
        logical = Math.Clamp(MathF.Round(logical), 8, 200);
        Prefs.TextSize = logical;
        ApplyToSelection(s => { if (s.Tool is Tool.Text or Tool.Number) s.FontSize = logical * Scale; }, "size");
        TextStyleChanged?.Invoke();
        Notify();
    }

    public void PickEmoji(string e)
    {
        Prefs.UseEmoji(e);
        Prefs.StampImage = null;
        Notify();
    }

    /// A user image was added from a file: use it for the next stamp.
    public void ImageAdded(string name)
    {
        Prefs.StampImage = name;
        Tool = Tool.Emoji;
        Selected = null;
        Notify();
    }

    public void ImageRemoved(string name)
    {
        if (Prefs.StampImage == name) Prefs.StampImage = null;
        Notify();
    }

    /// Ctrl+V: a clipboard image becomes a stamp in the middle of the selection (selected, select tool).
    public void PlaceImage(string name)
    {
        if (Selection is not { } s) return;
        Selected = Doc.RecordAdd(new Shape
        {
            Tool = Tool.Emoji, Points = { Geometry.Center(s) }, Color = Color, Width = StrokeWidth,
            FontSize = EmojiSize, ImageName = name,
        });
        Tool = Tool.None;
        Notify();
    }

    /// Ctrl+= / Ctrl+- and the stamp bar's −/＋: resize the selected stamp, or the next one.
    public void StepStampSize(int dir)
    {
        var f = dir > 0 ? 1.15f : 1 / 1.15f;
        if (Selected is { } i && i < Doc.Shapes.Count && Doc.Shapes[i].IsStamp)
        {
            var before = Doc.Shapes[i].Clone();
            Doc.Shapes[i].FontSize = Math.Clamp(Doc.Shapes[i].FontSize * f, 8 * Scale, 400 * Scale);
            Doc.RecordReplace(i, before, "size");
            if (Doc.Shapes[i].Tool == Tool.Emoji) Prefs.EmojiSize = MathF.Round(Doc.Shapes[i].FontSize / Scale);
        }
        else
        {
            Prefs.EmojiSize = MathF.Round(Math.Clamp(Prefs.EmojiSize * f, 12, 300));
        }
        Notify();
    }

    void StepTextSize(int dir) => SetTextSize(Prefs.TextSize + dir * 2);

    /// dir: -1 counter-clockwise, 1 clockwise (15° steps), 0 straighten.
    public void Rotate(int dir)
    {
        if (Selected is not { } i || i >= Doc.Shapes.Count || !Doc.Shapes[i].IsRotatable) return;
        var before = Doc.Shapes[i].Clone();
        var sh = Doc.Shapes[i];
        if (dir == 0) sh.Rotation = 0;
        else
        {
            var r = MathF.Round((sh.Rotation + dir * 15) / 15) * 15;
            if (MathF.Abs(r) >= 360) r = 0;
            sh.Rotation = r;
        }
        Doc.RecordReplace(i, before, "rotate");
        Notify();
    }

    public void Undo()
    {
        Selected = null;
        Drawing = null;
        if (Doc.Undo()) Notify();
    }

    public void Redo()
    {
        Selected = null;
        if (Doc.Redo()) Notify();
    }

    // ───────────────────────── text ─────────────────────────

    /// Re-open an existing text annotation (double-click). Its settings become the current ones.
    void EditText(int i)
    {
        var sh = Doc.Shapes[i];
        Doc.Shapes.RemoveAt(i);
        _editing = (i, sh);
        Selected = null;
        _drag = Drag.None;
        Color = sh.Color;
        Prefs.TextSize = sh.FontSize / Scale;
        Prefs.TextStyle = sh.TextStyle;
        Prefs.BoxColor = Palette.ToHex(sh.BoxColor);
        Prefs.BoxAlpha = sh.BoxAlpha;
        Tool = Tool.Text;
        _textOpen = true;
        TextRequested?.Invoke(sh.Start, sh);
        Notify();
    }

    /// Called by the UI when the text box closes with Enter / a click elsewhere. `at` is the glyphs'
    /// top-left corner. A new text is one undo step; a re-edit replaces the original in place
    /// (also one step); emptying a re-edited text deletes it.
    public void CommitText(PointF at, string text)
    {
        var editing = _editing;
        _editing = null;
        _textOpen = false;
        var trimmed = text.Trim('\r', '\n', ' ', '\t').Replace("\r\n", "\n");
        if (trimmed.Length > 0)
        {
            var sh = new Shape
            {
                Tool = Tool.Text, Points = { at }, Color = Color, Width = StrokeWidth, Text = trimmed,
                FontSize = TextSize, TextStyle = Prefs.TextStyle, BoxColor = BoxColor, BoxAlpha = Prefs.BoxAlpha,
                Rotation = editing?.Shape.Rotation ?? 0,
            };
            if (editing is { } e)
            {
                var idx = Math.Min(e.Index, Doc.Shapes.Count);
                Doc.Shapes.Insert(idx, sh);
                Doc.RecordReplace(idx, e.Shape);
            }
            else
            {
                Doc.RecordAdd(sh);
                Selected = null;
            }
        }
        else if (editing is { } gone)
        {
            var idx = Math.Min(gone.Index, Doc.Shapes.Count);
            Doc.Shapes.Insert(idx, gone.Shape);
            Doc.RecordRemove(idx);
        }
        Notify();
    }

    /// Called when the text box is cancelled (Esc): a re-edited text comes back unchanged.
    public void CancelText()
    {
        if (_editing is { } e) Doc.Shapes.Insert(Math.Min(e.Index, Doc.Shapes.Count), e.Shape);
        _editing = null;
        _textOpen = false;
        Notify();
    }

    // ───────────────────────── keyboard ─────────────────────────

    /// Win32 virtual-key code plus modifiers. Returns true when the key was handled.
    public bool Key(int vk, bool ctrl, bool shift, bool alt = false)
    {
        if (Selection != null && !EditingText)
        {
            if (Settings.OcrKeySpec.Matches(vk, ctrl, shift, alt)) { ActionRequested?.Invoke(OverlayAction.Ocr); return true; }
            if (Settings.PinKeySpec.Matches(vk, ctrl, shift, alt)) { ActionRequested?.Invoke(OverlayAction.Pin); return true; }
            if (Settings.MosaicKeySpec.Matches(vk, ctrl, shift, alt)) { SetTool(Tool == Tool.Mosaic ? Tool.None : Tool.Mosaic); return true; }
        }
        if (ctrl)
        {
            switch (vk)
            {
                case Vk.C: if (Selection != null) ActionRequested?.Invoke(OverlayAction.Copy); return true;
                case Vk.S: if (Selection != null) ActionRequested?.Invoke(shift ? OverlayAction.Share : OverlayAction.Save); return true;
                case Vk.Z when shift: Redo(); return true;
                case Vk.Z: Undo(); return true;
                case Vk.Y: Redo(); return true;
                case Vk.A:
                    Selection = MonitorAt(Pointer);
                    Notify();
                    return true;
                case Vk.V: if (Selection != null) PasteRequested?.Invoke(); return true;
                case Vk.OemOpenBracket: Rotate(-1); return true;
                case Vk.OemCloseBracket: Rotate(1); return true;
                case Vk.OemPlus or Vk.Add or Vk.OemMinus or Vk.Subtract:
                {
                    var dir = vk is Vk.OemPlus or Vk.Add ? 1 : -1;
                    if (Selected is { } i && i < Doc.Shapes.Count && Doc.Shapes[i].IsStamp || Tool == Tool.Emoji) StepStampSize(dir);
                    else if (Tool is Tool.Text or Tool.Number || EditableSelection is { } t && Doc.Shapes[t].Tool == Tool.Text) StepTextSize(dir);
                    return true;
                }
            }
            return false;
        }

        switch (vk)
        {
            case Vk.Escape:
                // One step back at a time: stroke → palette → tool → selected annotation → selection → close.
                if (Drawing != null) { Drawing = null; _drag = Drag.None; Notify(); }
                else if (PaletteOpen) { PaletteOpen = false; Notify(); }
                else if (Tool != Tool.None) SetTool(Tool.None);
                else if (Selected != null) { Selected = null; Notify(); }
                else if (Selection != null) ClearSelection();
                else ActionRequested?.Invoke(OverlayAction.Close);
                return true;
            case Vk.Enter:
                if (Selection != null) ActionRequested?.Invoke(OverlayAction.Copy);
                return true;
            case Vk.Delete or Vk.Back:
                if (Selected is { } d && d < Doc.Shapes.Count)
                {
                    Doc.RecordRemove(d);
                    Selected = null;
                    Notify();
                }
                return true;
            case Vk.Left or Vk.Right or Vk.Up or Vk.Down:
                Nudge(vk, shift ? 10 : 1);
                return true;
            case Vk.D1 or Vk.D2 or Vk.D3 or Vk.NumPad1 or Vk.NumPad2 or Vk.NumPad3:
            {
                var k = vk >= Vk.NumPad1 ? vk - Vk.NumPad1 : vk - Vk.D1;
                var w = AnnotationPrefs.Widths[k];
                Prefs.Width = w;
                ApplyToSelection(s => { if (Shape.IsStrokeTool(s.Tool)) s.Width = w * Scale; });
                Notify();
                return true;
            }
        }

        if (Selection == null || alt) return false;
        Tool? tool = vk switch
        {
            Vk.P => Tool.Pen, Vk.L => Tool.Line, Vk.A => Tool.Arrow, Vk.R => Tool.Rect, Vk.E => Tool.Ellipse,
            Vk.M => Tool.Marker, Vk.T => Tool.Text, Vk.N => Tool.Number, Vk.S => Tool.Emoji, Vk.X => Tool.Eraser,
            Vk.V => Tool.None, _ => null,
        };
        if (tool is not { } t2) return false;
        SetTool(t2);
        return true;
    }

    void Nudge(int vk, float step)
    {
        float dx = vk == Vk.Left ? -step : vk == Vk.Right ? step : 0;
        float dy = vk == Vk.Up ? -step : vk == Vk.Down ? step : 0;
        if (Selected is { } i && i < Doc.Shapes.Count)
        {
            var before = Doc.Shapes[i].Clone();
            Doc.Shapes[i].Offset(dx, dy);
            Doc.RecordReplace(i, before, "nudge"); // a run of nudges is one undo step
        }
        else if (Selection is { } s)
        {
            Selection = Geometry.Clamp(new RectangleF(s.X + dx, s.Y + dy, s.Width, s.Height), Screen);
        }
        Notify();
    }

    // ───────────────────────── tests / previews ─────────────────────────

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

    public void Select(int? index)
    {
        Selected = index;
        Notify();
    }
}
