using System.Drawing;

namespace ShotPark.Core;

public enum ToolbarAction { Tool, Color, Undo, Copy, Save, Close }

public sealed record ToolbarItem(ToolbarAction Action, Tool Tool, string TipKo, string TipEn, bool SeparatorBefore = false)
{
    public string Tip => Strings.L(TipKo, TipEn);
}

/// Toolbar contents and geometry, in logical units (multiply by the UI scale for pixels).
public static class ToolbarLayout
{
    public const float Pad = 5, Item = 34, Separator = 9, Height = 44;

    public static readonly ToolbarItem[] Items =
    {
        new(ToolbarAction.Tool, Tool.Pen, "펜 (P)", "Pen (P)"),
        new(ToolbarAction.Tool, Tool.Line, "선 (L)", "Line (L)"),
        new(ToolbarAction.Tool, Tool.Arrow, "화살표 (A)", "Arrow (A)"),
        new(ToolbarAction.Tool, Tool.Rect, "사각형 (R)", "Rectangle (R)"),
        new(ToolbarAction.Tool, Tool.Ellipse, "타원 (E)", "Ellipse (E)"),
        new(ToolbarAction.Tool, Tool.Mosaic, "모자이크 (B)", "Mosaic (B)", SeparatorBefore: true),
        new(ToolbarAction.Tool, Tool.Text, "텍스트 (T)", "Text (T)"),
        new(ToolbarAction.Tool, Tool.Number, "번호 (N)", "Number (N)"),
        new(ToolbarAction.Color, Tool.None, "색상 · 굵기", "Color · width", SeparatorBefore: true),
        new(ToolbarAction.Undo, Tool.None, "실행 취소 (Ctrl+Z)", "Undo (Ctrl+Z)"),
        new(ToolbarAction.Copy, Tool.None, "클립보드로 복사 (Ctrl+C / Enter)", "Copy to clipboard (Ctrl+C / Enter)", SeparatorBefore: true),
        new(ToolbarAction.Save, Tool.None, "저장 (Ctrl+S)", "Save (Ctrl+S)"),
        new(ToolbarAction.Close, Tool.None, "닫기 (Esc)", "Close (Esc)"),
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

    /// Below the selection, right-aligned; above it when there's no room; inside it as a last resort.
    public static RectangleF Place(RectangleF selection, RectangleF monitor, float scale)
    {
        float w = Width * scale, h = Height * scale, gap = 8 * scale, margin = 4 * scale;
        var x = Math.Clamp(selection.Right - w, monitor.Left + margin, MathF.Max(monitor.Left + margin, monitor.Right - w - margin));
        var y = selection.Bottom + gap;
        if (y + h > monitor.Bottom - margin) y = selection.Top - gap - h;
        if (y < monitor.Top + margin) y = MathF.Max(monitor.Top + margin, selection.Bottom - gap - h);
        return new RectangleF(x, y, w, h);
    }
}

/// The colour/width popup shown from the toolbar's colour button.
public static class PaletteLayout
{
    public const float Pad = 8, Swatch = 24, Gap = 4, Separator = 14, Height = 40;
    public static readonly float[] WidthLevels = { 2, 4, 7 };
    public static readonly float[] FontLevels = { 16, 22, 32 };
    public static readonly float[] NumberLevels = { 22, 28, 36 };

    public static float Width => 2 * Pad + (Palette.Default.Length + WidthLevels.Length) * (Swatch + Gap) - Gap + Separator;

    /// Swatch rects then width rects, relative to the popup's top-left corner.
    public static (RectangleF[] Colors, RectangleF[] Widths) Rects(float scale)
    {
        var colors = new RectangleF[Palette.Default.Length];
        var widths = new RectangleF[WidthLevels.Length];
        var x = Pad;
        var y = (Height - Swatch) / 2;
        for (var i = 0; i < colors.Length; i++, x += Swatch + Gap)
            colors[i] = new RectangleF(x * scale, y * scale, Swatch * scale, Swatch * scale);
        x += Separator - Gap;
        for (var i = 0; i < widths.Length; i++, x += Swatch + Gap)
            widths[i] = new RectangleF(x * scale, y * scale, Swatch * scale, Swatch * scale);
        return (colors, widths);
    }

    /// On the far side of the toolbar from the selection, so it never covers the capture.
    public static RectangleF Place(RectangleF toolbar, RectangleF selection, RectangleF monitor, float scale)
    {
        float w = Width * scale, h = Height * scale, gap = 6 * scale, margin = 4 * scale;
        var x = Math.Clamp(toolbar.Right - w, monitor.Left + margin, MathF.Max(monitor.Left + margin, monitor.Right - w - margin));
        var below = toolbar.Top >= selection.Bottom - 1;
        var y = below ? toolbar.Bottom + gap : toolbar.Top - gap - h;
        if (y + h > monitor.Bottom - margin) y = toolbar.Top - gap - h;
        if (y < monitor.Top + margin) y = toolbar.Bottom + gap;
        return new RectangleF(x, y, w, h);
    }
}
