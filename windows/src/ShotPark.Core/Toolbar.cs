using System.Drawing;

namespace ShotPark.Core;

public enum ToolbarAction { Tool, Color, Undo, Beautify, Copy, Ocr, Pin, Save, Share, Close }

public sealed record ToolbarItem(ToolbarAction Action, Tool Tool, bool SeparatorBefore = false);

/// Toolbar contents and geometry, in logical units (multiply by the UI scale for pixels).
/// Same buttons, in the same order, as the Mac app.
public static class ToolbarLayout
{
    public const float Pad = 5, Item = 34, Separator = 9, Height = 44;

    public static readonly ToolbarItem[] Items =
    {
        new(ToolbarAction.Tool, Tool.Pen),
        new(ToolbarAction.Tool, Tool.Line),
        new(ToolbarAction.Tool, Tool.Arrow),
        new(ToolbarAction.Tool, Tool.Rect),
        new(ToolbarAction.Tool, Tool.Ellipse),
        new(ToolbarAction.Tool, Tool.Mosaic, SeparatorBefore: true),
        new(ToolbarAction.Tool, Tool.Marker),
        new(ToolbarAction.Tool, Tool.Text),
        new(ToolbarAction.Tool, Tool.Number),
        new(ToolbarAction.Tool, Tool.Emoji),
        new(ToolbarAction.Tool, Tool.Eraser, SeparatorBefore: true),
        new(ToolbarAction.Color, Tool.None),
        new(ToolbarAction.Undo, Tool.None),
        new(ToolbarAction.Beautify, Tool.None, SeparatorBefore: true),
        new(ToolbarAction.Copy, Tool.None),
        new(ToolbarAction.Ocr, Tool.None),
        new(ToolbarAction.Pin, Tool.None),
        new(ToolbarAction.Save, Tool.None),
        new(ToolbarAction.Share, Tool.None),
        new(ToolbarAction.Close, Tool.None),
    };

    public static int IndexOf(ToolbarAction a, Tool t = Tool.None) =>
        Array.FindIndex(Items, i => i.Action == a && (a != ToolbarAction.Tool || i.Tool == t));

    static string L(string ko, string en) => Strings.L(ko, en);

    public static string Tip(ToolbarItem item, string mosaicKey, string ocrKey, string pinKey) => item.Action switch
    {
        ToolbarAction.Tool => item.Tool switch
        {
            Tool.Pen => L("펜 (P) — 자유롭게 그리기", "Pen (P) — freehand drawing"),
            Tool.Line => L("선 (L)", "Line (L)"),
            Tool.Arrow => L("화살표 (A)", "Arrow (A)"),
            Tool.Rect => L("사각형 (R)", "Rectangle (R)"),
            Tool.Ellipse => L("타원 (E)", "Ellipse (E)"),
            Tool.Mosaic => L($"모자이크 · 블러 ({mosaicKey}) — 가릴 영역을 드래그", $"Mosaic · blur ({mosaicKey}) — drag over what to hide"),
            Tool.Marker => L("마커 (M)", "Marker (M)"),
            Tool.Text => L("텍스트 (T) — Shift+Enter 줄바꿈, 크기·스타일은 아래 옵션 바", "Text (T) — Shift+Enter new line; size & style in the bar below"),
            Tool.Number => L("번호 도장 (N) — 클릭할 때마다 ①, ②, ③… 순서 표시", "Number stamp (N) — each click places ①, ②, ③…"),
            Tool.Emoji => L("이모지 도장 (S) — 아래에서 이모지를 고르고 클릭해 찍기", "Emoji stamp (S) — pick an emoji below, then click to place"),
            Tool.Eraser => L("지우개 (X) — 지울 주석을 클릭하거나 문지르기", "Eraser (X) — click or scrub over annotations to remove them"),
            _ => "",
        },
        ToolbarAction.Color => L("색상", "Color"),
        ToolbarAction.Undo => L("실행 취소 (Ctrl+Z)", "Undo (Ctrl+Z)"),
        ToolbarAction.Beautify => L("꾸미기 — 그림자·둥근 모서리 (설정에서 선택)", "Beautify — shadow, rounded corners (choose in Settings)"),
        ToolbarAction.Copy => L("클립보드로 복사 (Ctrl+C / Enter)", "Copy to clipboard (Ctrl+C / Enter)"),
        ToolbarAction.Ocr => L($"텍스트 추출 ({ocrKey}) — 영역의 글자를 텍스트로 복사", $"Extract text ({ocrKey}) — copy the text in the selection"),
        ToolbarAction.Pin => L($"화면에 고정 ({pinKey}) — 캡처를 떠 있는 창으로", $"Pin to screen ({pinKey}) — keep the capture floating on top"),
        ToolbarAction.Save => L("저장 (Ctrl+S)", "Save (Ctrl+S)"),
        ToolbarAction.Share => L("공유 (Ctrl+Shift+S)", "Share (Ctrl+Shift+S)"),
        ToolbarAction.Close => L("닫기 (Esc)", "Close (Esc)"),
        _ => "",
    };

    public static float Width => 2 * Pad + Items.Length * Item + Items.Count(i => i.SeparatorBefore) * Separator;

    /// Item rectangles relative to the toolbar's top-left corner, plus separator x positions.
    public static (RectangleF[] Items, float[] Separators) Rects(float scale)
    {
        var rects = new RectangleF[Items.Length];
        var seps = new List<float>();
        var x = Pad;
        for (var i = 0; i < Items.Length; i++)
        {
            if (Items[i].SeparatorBefore)
            {
                seps.Add((x + Separator / 2) * scale);
                x += Separator;
            }
            rects[i] = new RectangleF(x * scale, Pad * scale, Item * scale, (Height - 2 * Pad) * scale);
            x += Item;
        }
        return (rects, seps.ToArray());
    }

    /// Like the Mac app: left-aligned under the selection; above it when there's no room; inside it as a last resort.
    public static RectangleF Place(RectangleF selection, RectangleF monitor, float scale)
    {
        float w = Width * scale, h = Height * scale, gap = 8 * scale, margin = 4 * scale;
        var x = Math.Clamp(selection.Left, monitor.Left + margin, MathF.Max(monitor.Left + margin, monitor.Right - w - margin));
        float y;
        if (selection.Bottom + gap + h <= monitor.Bottom - margin) y = selection.Bottom + gap;
        else if (selection.Top - gap - h >= monitor.Top + margin) y = selection.Top - gap - h;
        else y = MathF.Max(monitor.Top + margin, selection.Bottom - gap - h);
        return new RectangleF(x, y, w, h);
    }
}

public enum BarKind { Text, Stroke, Mosaic, Emoji, Palette }

public enum CellKind
{
    Label,      // grey caption
    Choice,     // a pill that can be on (sizes, styles, levels…)
    Width,      // stroke width: coloured dot + label
    Dash,       // dashed sample + label
    Head,       // arrow head: Value 0 chevron, 1 dot
    FillChoice, // swatch + label; Value 0 none, 1 filled
    Slider,     // Value 0…1
    Percent,    // small text after a slider
    SizeField,  // the font size number, click to type
    Emoji,
    Button,     // "More…", "+ Add", "−", "+"
    Image,      // a user image stamp (Text = name)
    Swatch,     // a colour
    Separator,
}

public sealed record BarCell(string Id, CellKind Kind, RectangleF Rect, string Text = "", bool On = false, Color Color = default, float Value = 0);

public sealed record OptionBar(BarKind Kind, RectangleF Frame, IReadOnlyList<BarCell> Cells)
{
    /// The cell under an absolute point (only clickable kinds).
    public BarCell? CellAt(PointF p)
    {
        foreach (var c in Cells)
        {
            if (c.Kind is CellKind.Label or CellKind.Separator or CellKind.Percent) continue;
            var r = c.Rect;
            r.Offset(Frame.X, Frame.Y);
            if (c.Kind == CellKind.Slider) r.Inflate(4, 6);
            if (c.Kind == CellKind.Swatch) r.Inflate(3, 3);
            if (r.Contains(p)) return c;
        }
        return null;
    }

    public RectangleF Abs(BarCell c)
    {
        var r = c.Rect;
        r.Offset(Frame.X, Frame.Y);
        return r;
    }
}

/// Builds the option bars (contents and size); the controller positions them.
public sealed class BarBuilder
{
    readonly float _s;
    readonly List<BarCell> _cells = new();
    float _x;
    readonly float _h;

    BarBuilder(float scale, float height)
    {
        _s = scale;
        _h = height;
        _x = 6;
    }

    static string L(string ko, string en) => Strings.L(ko, en);
    float TextW(string t) => Metrics.UiText(t, 12) + 16;

    RectangleF R(float x, float w, float inset = 4) => new(x * _s, inset * _s, w * _s, (_h - 2 * inset) * _s);

    void Label(string text)
    {
        var w = Metrics.UiText(text, 11) + 12;
        _cells.Add(new BarCell("", CellKind.Label, R(_x + 6, w - 6), text));
        _x += w + 2;
    }

    void Add(string id, CellKind kind, float w, string text = "", bool on = false, Color color = default, float value = 0, float inset = 4)
    {
        _cells.Add(new BarCell(id, kind, R(_x, w, inset), text, on, color, value));
        _x += w;
    }

    void Sep()
    {
        _x += 5;
        _cells.Add(new BarCell("", CellKind.Separator, R(_x, 1, 8)));
        _x += 6;
    }

    OptionBar Build(BarKind kind) => new(kind, new RectangleF(0, 0, (_x + 6) * _s, _h * _s), _cells.ToList());

    public static OptionBar Text(float scale, float size, TextStyles style, Color box, float boxAlpha)
    {
        var b = new BarBuilder(scale, 34);
        b.Label(L("크기", "Size"));
        foreach (var s in AnnotationPrefs.TextSizes) b.Add($"size:{s}", CellKind.Choice, 36, ((int)s).ToString(), size == s);
        b._x += 4;
        b.Add("sizefield", CellKind.SizeField, 44, ((int)MathF.Round(size)).ToString(), inset: 7);
        b.Sep();
        foreach (var (st, ko, en) in new[] { (TextStyles.Shadow, "그림자", "Shadow"), (TextStyles.Outline, "외곽선", "Outline"), (TextStyles.Box, "배경", "Box") })
        {
            var on = style.HasFlag(st);
            var label = (on ? "✓ " : "") + L(ko, en);
            b.Add($"style:{(int)st}", CellKind.Choice, MathF.Max(52, b.TextW("✓ " + L(ko, en))), label, on);
        }
        if (style.HasFlag(TextStyles.Box))
        {
            b.Sep();
            b.Label(L("배경", "Box"));
            for (var i = 0; i < Shape.BoxColors.Length; i++)
            {
                b.Add($"box:{i}", CellKind.Swatch, 23, on: Core.Palette.Close(box, Shape.BoxColors[i]), color: Shape.BoxColors[i], inset: 8);
            }
            b._x += 8;
            b.Add("boxalpha", CellKind.Slider, 90, value: (boxAlpha - 0.15f) / 0.85f, inset: 9);
            b.Add("", CellKind.Percent, 40, $"{(int)MathF.Round(boxAlpha * 100)}%");
        }
        return b.Build(BarKind.Text);
    }

    public static OptionBar Stroke(float scale, Tool tool, float width, Color color, bool dashed, ArrowHead head, int fill, float fillAlpha)
    {
        var b = new BarBuilder(scale, 34);
        b.Label(L("굵기", "Width"));
        var labels = new[] { L("가늘게", "Thin"), L("보통", "Normal"), L("굵게", "Thick") };
        for (var i = 0; i < 3; i++)
            b.Add($"width:{i}", CellKind.Width, MathF.Max(64, b.TextW(labels[i]) + 22), labels[i], width == AnnotationPrefs.Widths[i], color, AnnotationPrefs.Widths[i]);
        if (tool is Tool.Line or Tool.Arrow or Tool.Rect or Tool.Ellipse)
        {
            b.Sep();
            b.Add("dash", CellKind.Dash, MathF.Max(58, b.TextW(L("점선", "Dash")) + 22), L("점선", "Dash"), dashed);
        }
        if (tool == Tool.Arrow)
        {
            b.Sep();
            b.Label(L("머리", "Head"));
            b.Add("head:0", CellKind.Head, 38, on: head == ArrowHead.Chevron, value: 0);
            b.Add("head:1", CellKind.Head, 38, on: head == ArrowHead.Circle, value: 1);
        }
        if (tool is Tool.Rect or Tool.Ellipse)
        {
            b.Sep();
            b.Label(L("채우기", "Fill"));
            var fl = new[] { L("없음", "None"), L("채움", "Fill") };
            for (var i = 0; i < 2; i++)
                b.Add($"fill:{i}", CellKind.FillChoice, MathF.Max(56, b.TextW(fl[i]) + 22), fl[i], fill == i, color, i == 0 ? 0 : MathF.Max(fillAlpha, 0.2f));
            if (fill > 0)
            {
                b._x += 8;
                b.Add("fillalpha", CellKind.Slider, 80, value: (fillAlpha - 0.1f) / 0.9f, inset: 9);
                b.Add("", CellKind.Percent, 40, $"{(int)MathF.Round(fillAlpha * 100)}%");
            }
        }
        return b.Build(BarKind.Stroke);
    }

    public static OptionBar Mosaic(float scale, MosaicStyle style, int level)
    {
        var b = new BarBuilder(scale, 34);
        var styles = new[] { L("모자이크", "Mosaic"), L("블러", "Blur") };
        for (var i = 0; i < 2; i++) b.Add($"mstyle:{i}", CellKind.Choice, MathF.Max(66, b.TextW(styles[i])), styles[i], (int)style == i);
        b.Sep();
        var levels = new[] { L("약", "Light"), L("중", "Medium"), L("강", "Strong") };
        for (var i = 0; i < 3; i++) b.Add($"mlevel:{i}", CellKind.Choice, MathF.Max(40, b.TextW(levels[i])), levels[i], level == i);
        return b.Build(BarKind.Mosaic);
    }

    public static OptionBar Emoji(float scale, IReadOnlyList<string> choices, string emoji, float size, IReadOnlyList<string> images, string? image)
    {
        var b = new BarBuilder(scale, 36);
        b.Label(L("도장", "Stamp"));
        for (var i = 0; i < choices.Count; i++) b.Add($"emoji:{i}", CellKind.Emoji, 30, choices[i], image == null && choices[i] == emoji, inset: 3);
        b._x += 12;
        b.Add("more", CellKind.Button, MathF.Max(64, b.TextW(L("더보기…", "More…"))), L("더보기…", "More…"), inset: 5);
        b._x += 10;
        b.Add("eminus", CellKind.Button, 28, "−");
        var sl = new[] { L("작게", "S"), L("보통", "M"), L("크게", "L") };
        for (var i = 0; i < 3; i++) b.Add($"esize:{i}", CellKind.Choice, 46, sl[i], size == AnnotationPrefs.EmojiSizes[i]);
        b.Add("eplus", CellKind.Button, 28, "＋");
        b.Sep();
        b.Label(L("이미지", "Image"));
        for (var i = 0; i < images.Count; i++) b.Add($"img:{i}", CellKind.Image, 36, images[i], images[i] == image, inset: 3);
        b._x += 4;
        b.Add("imgadd", CellKind.Button, MathF.Max(58, b.TextW(L("＋ 추가", "＋ Add"))), L("＋ 추가", "＋ Add"), inset: 5);
        return b.Build(BarKind.Emoji);
    }

    public static OptionBar Palette(float scale, IReadOnlyList<Color> colors, Color selected)
    {
        var b = new BarBuilder(scale, 34) { _x = 6 };
        for (var i = 0; i < colors.Count; i++)
        {
            b.Add($"color:{i}", CellKind.Swatch, 22, on: Core.Palette.Close(colors[i], selected), color: colors[i], inset: 6);
            b._x += 6;
        }
        return b.Build(BarKind.Palette);
    }
}
