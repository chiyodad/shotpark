using System.Drawing;
using ShotPark.Core;
using Xunit;

namespace ShotPark.Tests;

public class HotKeyTests
{
    [Fact]
    public void DefaultIsCtrlShift9() => Assert.Equal("Ctrl+Shift+9", HotKeySpec.Default.Display);

    [Fact]
    public void RoundTrips()
    {
        var spec = new HotKeySpec(Mods.Ctrl | Mods.Alt, 0x41);
        Assert.Equal(spec, HotKeySpec.Parse(spec.Serialize(), HotKeySpec.Default));
        Assert.Equal("Ctrl+Alt+A", spec.Display);
    }

    [Fact]
    public void PlainKeysNeedModifiersExceptPrintScreenAndF()
    {
        Assert.False(new HotKeySpec(Mods.None, 0x41).IsValid);
        Assert.True(new HotKeySpec(Mods.None, HotKeySpec.VkSnapshot).IsValid);
        Assert.True(new HotKeySpec(Mods.None, 0x70).IsValid);
        Assert.False(new HotKeySpec(Mods.Ctrl, 0x11).IsValid); // Ctrl alone
    }

    [Fact]
    public void GarbageFallsBack() => Assert.Equal(HotKeySpec.Default, HotKeySpec.Parse("nope", HotKeySpec.Default));

    [Fact]
    public void InCaptureKeysAllowSingleLettersButNotOverlayKeys()
    {
        Assert.True(new HotKeySpec(Mods.None, Vk.B).IsValidInCapture);
        Assert.False(new HotKeySpec(Mods.None, Vk.Escape).IsValidInCapture);
        Assert.False(new HotKeySpec(Mods.Ctrl, Vk.C).IsValidInCapture);
        Assert.True(new HotKeySpec(Mods.Ctrl | Mods.Shift, Vk.C).IsValidInCapture);
        Assert.Equal("B", HotKeySpec.Parse(new HotKeySpec(Mods.None, Vk.B).Serialize(), HotKeySpec.DefaultOcr, inCapture: true).Display);
        Assert.Equal(HotKeySpec.Default, HotKeySpec.Parse(new HotKeySpec(Mods.None, Vk.B).Serialize(), HotKeySpec.Default));
    }

    [Fact]
    public void Defaults()
    {
        Assert.Equal("Ctrl+Shift+V", HotKeySpec.DefaultHistory.Display);
        Assert.Equal("Ctrl+Shift+C", HotKeySpec.DefaultOcr.Display);
        Assert.Equal("Ctrl+Shift+P", HotKeySpec.DefaultPin.Display);
        Assert.True(HotKeySpec.DefaultOcr.Matches(Vk.C, true, true, false));
        Assert.False(HotKeySpec.DefaultOcr.Matches(Vk.C, true, false, false));
    }
}

public class SettingsTests
{
    [Fact]
    public void SavesAndLoads()
    {
        var dir = Path.Combine(Path.GetTempPath(), "sp-test-" + Guid.NewGuid());
        var path = Path.Combine(dir, "settings.json");
        var s = AppSettings.Load(path);
        Assert.Equal(HotKeySpec.Default, s.CaptureHotKey);
        s.CaptureHotKey = new HotKeySpec(Mods.None, HotKeySpec.VkSnapshot);
        s.SaveDirectly = false;
        s.Annotation.TextStyle = TextStyles.Box | TextStyles.Outline;
        s.Annotation.UseEmoji("🐱");
        var colors = s.Colors;
        colors[3] = Color.FromArgb(1, 2, 3);
        s.Colors = colors;
        s.Save();
        var t = AppSettings.Load(path);
        Assert.Equal("PrtSc", t.CaptureHotKey.Display);
        Assert.False(t.SaveDirectly);
        Assert.Equal(TextStyles.Box | TextStyles.Outline, t.Annotation.TextStyle);
        Assert.Equal("🐱", t.Annotation.EmojiChoices()[0]);
        Assert.Equal(Color.FromArgb(1, 2, 3).ToArgb(), t.Colors[3].ToArgb());
        Directory.Delete(dir, true);
    }

    [Fact]
    public void CorruptFileStartsFresh()
    {
        var path = Path.Combine(Path.GetTempPath(), "sp-bad-" + Guid.NewGuid() + ".json");
        File.WriteAllText(path, "{not json");
        Assert.Equal(HotKeySpec.Default, AppSettings.Load(path).CaptureHotKey);
        File.Delete(path);
    }

    [Fact]
    public void MigratesTheOldColourIndexAndWidth()
    {
        var path = Path.Combine(Path.GetTempPath(), "sp-old-" + Guid.NewGuid() + ".json");
        File.WriteAllText(path, "{\"ColorIndex\": 4, \"WidthIndex\": 2}");
        var s = AppSettings.Load(path);
        Assert.Equal(Palette.ToHex(Palette.Default[4]), s.Annotation.Color);
        Assert.Equal(7, s.Annotation.Width);
        File.Delete(path);
    }

    [Fact]
    public void BadPaletteFallsBackToDefault()
    {
        var s = new AppSettings { Palette = new() { "#zzz" } };
        Assert.Equal(Palette.Default.Length, s.Colors.Length);
        Assert.Equal(Palette.Default[0].ToArgb(), s.Colors[0].ToArgb());
    }

    [Fact]
    public void EmojiSlotsKeepTenMostRecentFirst()
    {
        var p = new AnnotationPrefs();
        Assert.Equal(10, p.EmojiChoices().Count);
        p.UseEmoji("🐶");
        p.UseEmoji("🐱");
        p.UseEmoji("🐶");
        Assert.Equal(new[] { "🐶", "🐱" }, p.EmojiChoices().Take(2));
        Assert.Equal(10, p.EmojiChoices().Count);
    }

    [Fact]
    public void UniqueFileNames()
    {
        var now = new DateTime(2026, 10, 13, 9, 5, 7);
        var taken = new HashSet<string> { Path.Combine("x", "shotpark-20261013-090507.png") };
        Assert.Equal(Path.Combine("x", "shotpark-20261013-090507-2.png"), FileNames.Unique("x", now, taken.Contains));
    }

    [Fact]
    public void VersionCompare()
    {
        Assert.True(Versions.IsNewer("1.22.0", "1.21.9"));
        Assert.True(Versions.IsNewer("v1.21.10", "1.21.9"));
        Assert.False(Versions.IsNewer("1.21.0", "1.21.0"));
        Assert.False(Versions.IsNewer("", "1.0"));
    }
}

public class GeometryTests
{
    [Fact]
    public void SegmentDistance()
    {
        Assert.Equal(5, Geometry.DistanceToSegment(new PointF(5, 5), new PointF(0, 0), new PointF(10, 0)), 3);
        Assert.Equal(5, Geometry.DistanceToSegment(new PointF(15, 0), new PointF(0, 0), new PointF(10, 0)), 3);
    }

    [Fact]
    public void ResizeFlipsPastOppositeEdge()
    {
        var r = Geometry.Resize(new RectangleF(10, 10, 100, 50), Handle.Right, -150, 0);
        Assert.Equal(new RectangleF(-40, 10, 50, 50), r);
    }

    [Fact]
    public void HandleHit()
    {
        var r = new RectangleF(100, 100, 200, 100);
        Assert.Equal(Handle.BottomRight, Geometry.HandleAt(r, new PointF(302, 199), 6));
        Assert.Equal(Handle.Top, Geometry.HandleAt(r, new PointF(200, 100), 6));
        Assert.Equal(Handle.None, Geometry.HandleAt(r, new PointF(200, 150), 6));
    }

    [Fact]
    public void RectHitsOnlyNearItsOutlineUnlessFilled()
    {
        var s = new Shape { Tool = Tool.Rect, Points = { new(0, 0), new(100, 100) }, Width = 4 };
        Assert.True(s.HitTest(new PointF(1, 50), 3));
        Assert.False(s.HitTest(new PointF(50, 50), 3));
        s.Fill = 1;
        Assert.True(s.HitTest(new PointF(50, 50), 3));
        var m = new Shape { Tool = Tool.Mosaic, Points = { new(0, 0), new(100, 100) } };
        Assert.True(m.HitTest(new PointF(50, 50), 3));
    }

    [Fact]
    public void EllipseOutline()
    {
        var s = new Shape { Tool = Tool.Ellipse, Points = { new(0, 0), new(200, 100) }, Width = 4 };
        Assert.True(s.HitTest(new PointF(100, 1), 3));
        Assert.False(s.HitTest(new PointF(100, 50), 3));
    }

    [Fact]
    public void ArrowHeadPointsBackwards()
    {
        var (l, tip, r) = Geometry.ArrowHead(new PointF(0, 0), new PointF(100, 0), 4);
        Assert.Equal(new PointF(100, 0), tip);
        Assert.True(l.X < 100 && r.X < 100);
        Assert.Equal(-l.Y, r.Y, 3);
    }

    [Fact]
    public void RotatedTextHitsAlongItsRotation()
    {
        var s = new Shape { Tool = Tool.Text, Points = { new(100, 100) }, Text = "WWWWWWWWWW", FontSize = 20 };
        var b = s.UnrotatedBounds;
        var farRight = new PointF(b.Right - 2, b.Y + b.Height / 2);
        Assert.True(s.HitTest(farRight));
        s.Rotation = 90;
        Assert.False(s.HitTest(farRight)); // now it stands upright around its centre
        var below = Geometry.Rotate(farRight, s.Pivot, 90);
        Assert.True(s.HitTest(below));
        Assert.True(s.Bounds.Height > s.Bounds.Width);
    }

    [Fact]
    public void MarkerIsWideAndNumberIsRound()
    {
        var m = new Shape { Tool = Tool.Marker, Points = { new(0, 0), new(100, 0) }, Width = 4 };
        Assert.True(m.HitTest(new PointF(50, 12), 3)); // 5× width band
        Assert.False(m.HitTest(new PointF(50, 16), 3));
        var n = new Shape { Tool = Tool.Number, Points = { new(50, 50) }, FontSize = 20 };
        Assert.True(n.HitTest(new PointF(50 + n.StampRadius, 50)));
        Assert.False(n.HitTest(new PointF(50 + n.StampRadius + 5, 50)));
    }
}

public class EffectsTests
{
    [Fact]
    public void PixelateAveragesBlocks()
    {
        var px = new int[4 * 2];
        for (var i = 0; i < px.Length; i++) px[i] = unchecked((int)0xFF000000) | (i % 2 == 0 ? 0xFFFFFF : 0);
        Effects.Pixelate(px, 4, 2, 2);
        Assert.All(px, p => Assert.Equal(0x7F, p & 0xFF));
    }

    [Fact]
    public void BlurSpreadsAnEdge()
    {
        const int w = 40, h = 4;
        var px = new int[w * h];
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
                px[y * w + x] = unchecked((int)0xFF000000) | (x < w / 2 ? 0xFFFFFF : 0);
        Effects.Blur(px, w, h, 6);
        var mid = px[w / 2] & 0xFF;
        Assert.InRange(mid, 40, 215);
        Assert.Equal(0xFF, px[0] & 0xFF);
    }

    [Fact]
    public void StrengthsMatchTheMac()
    {
        Assert.Equal(12, Effects.Amount(MosaicStyle.Pixelate, 1));
        Assert.Equal(18, Effects.Amount(MosaicStyle.Blur, 2));
    }
}

public class DocumentTests
{
    static Shape R(float x) => new() { Tool = Tool.Rect, Points = { new(x, 0), new(x + 10, 10) } };

    [Fact]
    public void AddRemoveReplaceUndoRedo()
    {
        var d = new Document();
        d.RecordAdd(R(0));
        d.RecordAdd(R(20));
        var before = d.Shapes[0].Clone();
        d.Shapes[0].Color = Color.Blue;
        d.RecordReplace(0, before);
        d.RecordRemove(1);
        Assert.Single(d.Shapes);
        Assert.True(d.Undo()); // remove
        Assert.Equal(2, d.Shapes.Count);
        Assert.True(d.Undo()); // replace
        Assert.Equal(Palette.Default[0].ToArgb(), d.Shapes[0].Color.ToArgb());
        Assert.True(d.Redo());
        Assert.Equal(Color.Blue.ToArgb(), d.Shapes[0].Color.ToArgb());
    }

    [Fact]
    public void SameKeyEditsMerge()
    {
        var d = new Document();
        d.RecordAdd(R(0));
        for (var i = 0; i < 5; i++)
        {
            var b = d.Shapes[0].Clone();
            d.Shapes[0].Offset(1, 0);
            d.RecordReplace(0, b, "nudge");
        }
        Assert.True(d.Undo());
        Assert.Equal(0, d.Shapes[0].Start.X);
        Assert.True(d.Undo());
        Assert.Empty(d.Shapes);
    }

    [Fact]
    public void NoOpEditIsDropped()
    {
        var d = new Document();
        d.RecordAdd(R(0));
        d.RecordReplace(0, d.Shapes[0].Clone());
        d.Undo();
        Assert.Empty(d.Shapes);
    }

    [Fact]
    public void EraserGroupIsOneStep()
    {
        var d = new Document();
        d.RecordAdd(R(0)); d.RecordAdd(R(20)); d.RecordAdd(R(40));
        var removed = new List<(int, Shape)>();
        removed.Add((2, d.Shapes[2])); d.Shapes.RemoveAt(2);
        removed.Add((0, d.Shapes[0])); d.Shapes.RemoveAt(0);
        d.RecordRemoved(removed);
        Assert.Single(d.Shapes);
        d.Undo();
        Assert.Equal(new[] { 0f, 20, 40 }, d.Shapes.Select(s => s.Start.X));
        d.Redo();
        Assert.Equal(20, d.Shapes.Single().Start.X);
    }
}

public class ClipHistoryTests
{
    [Fact]
    public void DedupesAndKeepsThirty()
    {
        var idx = new ClipHistoryIndex();
        var now = DateTime.Now;
        for (var i = 0; i < 31; i++) idx.Add($"h{i}", $"f{i}.png", 10, 10, now);
        Assert.Equal(30, idx.Entries.Count);
        var (e, isNew, evicted) = idx.Add("h5", "new.png", 10, 10, now);
        Assert.False(isNew);
        Assert.Equal("f5.png", e.Name);
        Assert.Equal("f5.png", idx.Entries[0].Name);
        Assert.Empty(evicted);
        var (_, _, ev2) = idx.Add("h99", "f99.png", 10, 10, now);
        Assert.Single(ev2);
    }

    [Fact]
    public void LoadSkipsMissingFiles()
    {
        var idx = new ClipHistoryIndex();
        idx.Add("a", "a.png", 1, 1, DateTime.Now);
        idx.Add("b", "b.png", 1, 1, DateTime.Now);
        var back = ClipHistoryIndex.Load(idx.Serialize(), n => n == "a.png");
        Assert.Equal("a.png", back.Entries.Single().Name);
        Assert.Empty(ClipHistoryIndex.Load("garbage", _ => true).Entries);
    }
}

public class ToolbarTests
{
    [Fact]
    public void SitsBelowSelectionLeftAligned()
    {
        var tb = ToolbarLayout.Place(new RectangleF(100, 100, 800, 300), new RectangleF(0, 0, 1920, 1080), 1);
        Assert.True(tb.Top > 400);
        Assert.Equal(100, tb.Left, 1);
    }

    [Fact]
    public void FlipsAboveAtScreenBottom()
    {
        var tb = ToolbarLayout.Place(new RectangleF(100, 700, 800, 370), new RectangleF(0, 0, 1920, 1080), 1);
        Assert.True(tb.Bottom < 700);
    }

    [Fact]
    public void StaysOnScreenForFullScreenSelection()
    {
        var screen = new RectangleF(0, 0, 1920, 1080);
        var tb = ToolbarLayout.Place(screen, screen, 1.5f);
        Assert.True(screen.Contains(tb));
    }

    [Fact]
    public void SameButtonsAsTheMac()
    {
        Assert.Equal(20, ToolbarLayout.Items.Length);
        foreach (var t in new[] { Tool.Pen, Tool.Line, Tool.Arrow, Tool.Rect, Tool.Ellipse, Tool.Mosaic, Tool.Marker, Tool.Text, Tool.Number, Tool.Emoji, Tool.Eraser })
            Assert.True(ToolbarLayout.IndexOf(ToolbarAction.Tool, t) >= 0);
        foreach (var a in new[] { ToolbarAction.Beautify, ToolbarAction.Ocr, ToolbarAction.Pin, ToolbarAction.Share })
            Assert.True(ToolbarLayout.IndexOf(a) >= 0);
        Assert.Contains("Ctrl+Shift+C", ToolbarLayout.Tip(ToolbarLayout.Items[ToolbarLayout.IndexOf(ToolbarAction.Ocr)], "B", "Ctrl+Shift+C", "Ctrl+Shift+P"));
    }

    [Fact]
    public void ItemRectsDoNotOverlap()
    {
        var (rects, seps) = ToolbarLayout.Rects(1.25f);
        for (var i = 1; i < rects.Length; i++) Assert.True(rects[i].Left >= rects[i - 1].Right - 0.01f);
        Assert.Equal(3, seps.Length);
        Assert.Equal(ToolbarLayout.Width * 1.25f, rects[^1].Right + ToolbarLayout.Pad * 1.25f, 2);
    }
}

public class ControllerTests
{
    static readonly RectangleF Screen = new(0, 0, 1920, 1080);

    static OverlayController New(AppSettings? s = null) => new(Screen, new[] { Screen }, 1, s ?? new AppSettings());

    static void Drag(OverlayController c, PointF a, PointF b, bool shift = false)
    {
        c.PointerDown(a, PointerButton.Left);
        c.PointerMove(new PointF((a.X + b.X) / 2, (a.Y + b.Y) / 2), shift);
        c.PointerMove(b, shift);
        c.PointerUp(b);
    }

    static void Click(OverlayController c, PointF p, int clicks = 1)
    {
        c.PointerDown(p, PointerButton.Left, clicks);
        c.PointerUp(p);
    }

    static OverlayController Selected()
    {
        var c = New();
        Drag(c, new PointF(100, 100), new PointF(900, 700));
        return c;
    }

    static void ClickCell(OverlayController c, string id)
    {
        var bar = c.Bars.First(b => b.Cells.Any(x => x.Id == id));
        var cell = bar.Cells.First(x => x.Id == id);
        var r = bar.Abs(cell);
        c.PointerDown(new PointF(r.X + r.Width / 2, r.Y + r.Height / 2), PointerButton.Left);
        c.PointerUp(new PointF(r.X + r.Width / 2, r.Y + r.Height / 2));
    }

    [Fact]
    public void DragMakesSelection()
    {
        var c = Selected();
        Assert.Equal(new RectangleF(100, 100, 800, 600), c.Selection);
        Assert.NotNull(c.ToolbarRect);
    }

    [Fact]
    public void TinyClickLeavesNoSelection()
    {
        var c = New();
        Click(c, new PointF(50, 50));
        Assert.Null(c.Selection);
    }

    [Fact]
    public void ClickOnAWindowSelectsIt()
    {
        var c = New();
        c.WindowRects = new[] { new RectangleF(200, 150, 600, 400), new RectangleF(0, 0, 1920, 1040) };
        c.PointerMove(new PointF(300, 300));
        Assert.Equal(new RectangleF(200, 150, 600, 400), c.HoverWindow);
        Click(c, new PointF(300, 300));
        Assert.Equal(new RectangleF(200, 150, 600, 400), c.Selection);
    }

    [Fact]
    public void ClickOutsideASelectionOnlyClearsIt()
    {
        var c = Selected();
        c.WindowRects = new[] { new RectangleF(1000, 100, 500, 500) };
        Click(c, new PointF(1200, 300));
        Assert.Null(c.Selection);
    }

    [Fact]
    public void DragInsideMovesSelection()
    {
        var c = Selected();
        Drag(c, new PointF(500, 400), new PointF(550, 420));
        Assert.Equal(new RectangleF(150, 120, 800, 600), c.Selection);
    }

    [Fact]
    public void HandleResizes()
    {
        var c = Selected();
        Drag(c, new PointF(900, 700), new PointF(1000, 750));
        Assert.Equal(new RectangleF(100, 100, 900, 650), c.Selection);
    }

    [Fact]
    public void SelectionStaysOnScreen()
    {
        var c = Selected();
        Drag(c, new PointF(500, 400), new PointF(-500, -500));
        Assert.Equal(new RectangleF(0, 0, 800, 600), c.Selection);
    }

    [Fact]
    public void DrawsRectWithToolAndUndoes()
    {
        var c = Selected();
        Assert.True(c.Key(Vk.R, false, false));
        Drag(c, new PointF(200, 200), new PointF(300, 260));
        Assert.Single(c.Doc.Shapes);
        Assert.Equal(new RectangleF(200, 200, 100, 60), c.Doc.Shapes[0].Rect);
        c.Key(Vk.Z, true, false);
        Assert.Empty(c.Doc.Shapes);
        c.Key(Vk.Z, true, true);
        Assert.Single(c.Doc.Shapes);
    }

    [Fact]
    public void ClickWithToolDoesNotMakeDegenerateShape()
    {
        var c = Selected();
        c.Key(Vk.R, false, false);
        Click(c, new PointF(300, 300));
        Assert.Empty(c.Doc.Shapes);
    }

    [Fact]
    public void ShiftSnapsLinesTo45Degrees()
    {
        var c = Selected();
        c.Key(Vk.L, false, false);
        Drag(c, new PointF(200, 200), new PointF(300, 290), shift: true);
        var s = c.Doc.Shapes[0];
        Assert.Equal(s.End.X - s.Start.X, s.End.Y - s.Start.Y, 2);
    }

    [Fact]
    public void NumbersCountUpAndFollowTextSize()
    {
        var c = Selected();
        c.Key(Vk.N, false, false);
        Click(c, new PointF(200, 200));
        Click(c, new PointF(300, 200));
        Assert.Equal(new[] { 1, 2 }, c.Doc.Shapes.Select(s => s.Number));
        Assert.Equal(c.TextSize, c.Doc.Shapes[0].FontSize);
    }

    [Fact]
    public void StampToolGrabsAnExistingStampInsteadOfStampingOnTop()
    {
        var c = Selected();
        c.Key(Vk.N, false, false);
        Click(c, new PointF(200, 200));
        Drag(c, new PointF(200, 200), new PointF(260, 230));
        Assert.Single(c.Doc.Shapes);
        Assert.Equal(new PointF(260, 230), c.Doc.Shapes[0].Start);
    }

    [Fact]
    public void TextToolRequestsTextBoxAndCommits()
    {
        var c = Selected();
        PointF? at = null;
        c.TextRequested += (p, _) => at = p;
        c.Key(Vk.T, false, false);
        Click(c, new PointF(400, 300));
        Assert.NotNull(at);
        c.CommitText(at!.Value, "여기를 클릭!");
        Assert.Equal("여기를 클릭!", c.Doc.Shapes.Single().Text);
        c.Key(Vk.Z, true, false);
        Assert.Empty(c.Doc.Shapes);
    }

    [Fact]
    public void DoubleClickReEditsTextAsOneUndoStepAndKeepsSize()
    {
        var c = Selected();
        Shape? editing = null;
        c.TextRequested += (_, s) => editing = s;
        c.Key(Vk.T, false, false);
        Click(c, new PointF(400, 300));
        c.CommitText(new PointF(400, 300), "one");
        c.SetTextSize(40);
        c.SetTool(Tool.None);
        var inside = Geometry.Center(c.Doc.Shapes[0].BoxRect);
        Click(c, inside);
        Click(c, inside, clicks: 2);
        Assert.NotNull(editing);
        Assert.Empty(c.Doc.Shapes); // hidden while its box is open
        c.CommitText(editing!.Start, "two");
        Assert.Equal("two", c.Doc.Shapes.Single().Text);
        Assert.Equal(24, c.Doc.Shapes.Single().FontSize); // re-edit keeps its own size
        c.Key(Vk.Z, true, false);
        Assert.Equal("one", c.Doc.Shapes.Single().Text);
    }

    [Fact]
    public void CancelledReEditPutsTheTextBack()
    {
        var c = Selected();
        c.Key(Vk.T, false, false);
        Click(c, new PointF(400, 300));
        c.CommitText(new PointF(400, 300), "keep");
        var inside = Geometry.Center(c.Doc.Shapes[0].BoxRect);
        Click(c, inside, clicks: 2);
        c.CancelText();
        Assert.Equal("keep", c.Doc.Shapes.Single().Text);
    }

    [Fact]
    public void SelectModeMovesAndDeletesShapes()
    {
        var c = Selected();
        c.Key(Vk.R, false, false);
        Drag(c, new PointF(200, 200), new PointF(300, 300));
        c.Key(Vk.V, false, false);
        Drag(c, new PointF(200, 250), new PointF(200, 300));
        Assert.Equal(new PointF(200, 250), c.Doc.Shapes[0].Start);
        c.Key(Vk.Delete, false, false);
        Assert.Empty(c.Doc.Shapes);
        c.Key(Vk.Z, true, false);
        Assert.Single(c.Doc.Shapes);
        c.Key(Vk.Z, true, false);
        Assert.Equal(new PointF(200, 200), c.Doc.Shapes[0].Start);
    }

    [Fact]
    public void NudgesMergeIntoOneUndoStep()
    {
        var c = Selected();
        c.Key(Vk.R, false, false);
        Drag(c, new PointF(200, 200), new PointF(300, 300));
        c.Key(Vk.V, false, false);
        Click(c, new PointF(200, 250));
        for (var i = 0; i < 5; i++) c.Key(Vk.Right, false, i == 0);
        Assert.Equal(214, c.Doc.Shapes[0].Start.X);
        c.Key(Vk.Z, true, false);
        Assert.Equal(200, c.Doc.Shapes[0].Start.X);
    }

    [Fact]
    public void EraserRemovesWhatItTouchesAsOneStep()
    {
        var c = Selected();
        c.Key(Vk.L, false, false);
        Drag(c, new PointF(200, 200), new PointF(400, 200));
        Drag(c, new PointF(200, 300), new PointF(400, 300));
        c.Key(Vk.X, false, false);
        c.PointerDown(new PointF(300, 200), PointerButton.Left);
        c.PointerMove(new PointF(300, 250));
        c.PointerMove(new PointF(300, 300));
        c.PointerUp(new PointF(300, 300));
        Assert.Empty(c.Doc.Shapes);
        c.Key(Vk.Z, true, false);
        Assert.Equal(2, c.Doc.Shapes.Count);
    }

    [Fact]
    public void ClickOutsideStartsOver()
    {
        var c = Selected();
        c.Key(Vk.R, false, false);
        Drag(c, new PointF(200, 200), new PointF(300, 300));
        c.Key(Vk.V, false, false);
        Drag(c, new PointF(1000, 800), new PointF(1200, 900));
        Assert.Equal(new RectangleF(1000, 800, 200, 100), c.Selection);
        Assert.Empty(c.Doc.Shapes);
    }

    [Fact]
    public void ToolbarClickPicksTool()
    {
        var c = Selected();
        var tb = c.ToolbarRect!.Value;
        var (rects, _) = ToolbarLayout.Rects(1);
        var arrow = ToolbarLayout.IndexOf(ToolbarAction.Tool, Tool.Arrow);
        var r = rects[arrow];
        Click(c, new PointF(tb.X + r.X + r.Width / 2, tb.Y + r.Y + r.Height / 2));
        Assert.Equal(Tool.Arrow, c.Tool);
        Click(c, new PointF(tb.X + r.X + r.Width / 2, tb.Y + r.Y + r.Height / 2));
        Assert.Equal(Tool.None, c.Tool);
    }

    [Fact]
    public void BarsFollowTheTool()
    {
        var c = Selected();
        c.Key(Vk.A, false, false);
        Assert.Contains(c.Bars, b => b.Kind == BarKind.Stroke && b.Cells.Any(x => x.Id == "head:1"));
        c.Key(Vk.R, false, false);
        Assert.Contains(c.Bars, b => b.Cells.Any(x => x.Id == "fill:1"));
        c.Key(Vk.T, false, false);
        Assert.Contains(c.Bars, b => b.Kind == BarKind.Text);
        c.Key(Vk.B, false, false);
        Assert.Contains(c.Bars, b => b.Kind == BarKind.Mosaic);
        c.Key(Vk.S, false, false);
        Assert.Contains(c.Bars, b => b.Kind == BarKind.Emoji);
        foreach (var b in c.Bars) Assert.True(b.Frame.Top >= c.ToolbarRect!.Value.Bottom);
    }

    [Fact]
    public void JustDrawnShapeTakesStrokeChanges()
    {
        var c = Selected();
        c.Key(Vk.A, false, false);
        Drag(c, new PointF(200, 200), new PointF(400, 260));
        ClickCell(c, "width:2");
        ClickCell(c, "dash");
        ClickCell(c, "head:1");
        var s = c.Doc.Shapes.Single();
        Assert.Equal(7, s.Width);
        Assert.True(s.Dashed);
        Assert.Equal(ArrowHead.Circle, s.ArrowHead);
        Assert.Equal(7, c.Prefs.Width);
        c.Key(Vk.Z, true, false);
        Assert.Equal(ArrowHead.Chevron, c.Doc.Shapes.Single().ArrowHead);
    }

    [Fact]
    public void FillAndOpacitySlider()
    {
        var c = Selected();
        c.Key(Vk.R, false, false);
        Drag(c, new PointF(200, 200), new PointF(400, 260));
        ClickCell(c, "fill:1");
        Assert.Equal(1, c.Doc.Shapes[0].Fill);
        var bar = c.Bars.First(b => b.Cells.Any(x => x.Id == "fillalpha"));
        var r = bar.Abs(bar.Cells.First(x => x.Id == "fillalpha"));
        c.PointerDown(new PointF(r.X + 1, r.Y + r.Height / 2), PointerButton.Left);
        c.PointerMove(new PointF(r.Right, r.Y + r.Height / 2));
        c.PointerUp(new PointF(r.Right, r.Y + r.Height / 2));
        Assert.Equal(1f, c.Doc.Shapes[0].FillAlpha, 2);
        c.Key(Vk.Z, true, false); // the whole drag is one step
        Assert.Equal(0.3f, c.Doc.Shapes[0].FillAlpha, 2);
    }

    [Fact]
    public void TextStylesToggle()
    {
        var c = Selected();
        c.Key(Vk.T, false, false);
        ClickCell(c, $"style:{(int)TextStyles.Box}");
        Assert.Equal(TextStyles.Shadow | TextStyles.Box, c.Prefs.TextStyle);
        Assert.Contains(c.Bars, b => b.Cells.Any(x => x.Id == "boxalpha"));
        ClickCell(c, $"style:{(int)TextStyles.Shadow}");
        Assert.Equal(TextStyles.Box, c.Prefs.TextStyle);
        ClickCell(c, "size:40");
        Assert.Equal(40, c.Prefs.TextSize);
    }

    [Fact]
    public void MosaicStyleAndLevel()
    {
        var c = Selected();
        c.Key(Vk.B, false, false);
        ClickCell(c, "mstyle:1");
        ClickCell(c, "mlevel:2");
        Drag(c, new PointF(200, 200), new PointF(300, 260));
        Assert.Equal(MosaicStyle.Blur, c.Doc.Shapes[0].MosaicStyle);
        Assert.Equal(2, c.Doc.Shapes[0].MosaicLevel);
    }

    [Fact]
    public void EmojiStampsResizeAndRotate()
    {
        var c = Selected();
        c.Key(Vk.S, false, false);
        ClickCell(c, "emoji:2");
        Click(c, new PointF(300, 300));
        var s = c.Doc.Shapes.Single();
        Assert.Equal(c.Prefs.EmojiChoices()[0], s.Text);
        Assert.Equal(c.Selected, 0);
        var size = s.FontSize;
        c.Key(Vk.OemPlus, true, false);
        Assert.True(c.Doc.Shapes[0].FontSize > size);
        c.Key(Vk.OemCloseBracket, true, false);
        Assert.Equal(15, c.Doc.Shapes[0].Rotation);
        c.SetTool(Tool.None);
        c.Select(0);
        Assert.Equal(3, c.RotateButtons.Count);
        c.Rotate(0);
        Assert.Equal(0, c.Doc.Shapes[0].Rotation);
        Assert.Equal(2, c.RotateButtons.Count);
    }

    [Fact]
    public void StampHandleScales()
    {
        var c = Selected();
        c.Key(Vk.S, false, false);
        Click(c, new PointF(300, 300));
        var h = c.StampHandle!.Value;
        var size = c.Doc.Shapes[0].FontSize;
        Drag(c, Geometry.Center(h), new PointF(h.X + 60, h.Y + 60));
        Assert.True(c.Doc.Shapes[0].FontSize > size);
        c.Key(Vk.Z, true, false);
        Assert.Equal(size, c.Doc.Shapes[0].FontSize);
    }

    [Fact]
    public void PastedImageIsPlacedSelected()
    {
        var c = Selected();
        var asked = false;
        c.PasteRequested += () => asked = true;
        c.Key(Vk.V, true, false);
        Assert.True(asked);
        c.PlaceImage("paste-1");
        Assert.Equal("paste-1", c.Doc.Shapes.Single().ImageName);
        Assert.Equal(new PointF(500, 400), c.Doc.Shapes[0].Start);
        Assert.Equal(Tool.None, c.Tool);
        Assert.Equal(0, c.Selected);
    }

    [Fact]
    public void PaletteChangesColorAndRestylesSelectedShape()
    {
        var c = Selected();
        c.Key(Vk.R, false, false);
        Drag(c, new PointF(200, 200), new PointF(300, 300));
        c.SetTool(Tool.None);
        Click(c, new PointF(200, 250));
        c.SetPaletteOpen(true);
        ClickCell(c, "color:4");
        Assert.Equal(Palette.Default[4].ToArgb(), c.Doc.Shapes[0].Color.ToArgb());
        Assert.False(c.PaletteOpen);
    }

    [Fact]
    public void PickingAColourInSelectModeSwitchesToPen()
    {
        var c = Selected();
        c.SetPaletteOpen(true);
        ClickCell(c, "color:2");
        Assert.Equal(Tool.Pen, c.Tool);
    }

    [Fact]
    public void ActionsFire()
    {
        var c = Selected();
        var got = new List<OverlayAction>();
        c.ActionRequested += got.Add;
        c.Key(Vk.C, true, false);
        c.Key(Vk.Enter, false, false);
        c.Key(Vk.S, true, false);
        c.Key(Vk.S, true, true);
        c.Key(Vk.C, true, true);
        c.Key(Vk.P, true, true);
        Assert.Equal(new[] { OverlayAction.Copy, OverlayAction.Copy, OverlayAction.Save, OverlayAction.Share, OverlayAction.Ocr, OverlayAction.Pin }, got);
    }

    [Fact]
    public void CustomInCaptureShortcuts()
    {
        var s = new AppSettings { MosaicKeySpec = new HotKeySpec(Mods.None, Vk.Y) };
        var c = New(s);
        Drag(c, new PointF(100, 100), new PointF(900, 700));
        c.Key(Vk.Y, false, false);
        Assert.Equal(Tool.Mosaic, c.Tool);
        c.Key(Vk.Y, false, false);
        Assert.Equal(Tool.None, c.Tool);
    }

    [Fact]
    public void BeautifyToggles()
    {
        var c = Selected();
        string? notice = null;
        c.Notice += n => notice = n;
        var tb = c.ToolbarRect!.Value;
        var r = ToolbarLayout.Rects(1).Items[ToolbarLayout.IndexOf(ToolbarAction.Beautify)];
        Click(c, new PointF(tb.X + r.X + r.Width / 2, tb.Y + r.Y + r.Height / 2));
        Assert.True(c.Settings.Beautify);
        Assert.NotNull(notice);
    }

    [Fact]
    public void EscStepsBackInsteadOfDiscarding()
    {
        var c = Selected();
        var closed = false;
        c.ActionRequested += a => closed |= a == OverlayAction.Close;
        c.Key(Vk.R, false, false);
        Drag(c, new PointF(200, 200), new PointF(300, 300));
        c.Key(Vk.Escape, false, false);          // tool → select mode
        Assert.Equal(Tool.None, c.Tool);
        Assert.Single(c.Doc.Shapes);
        Click(c, new PointF(200, 250));          // select the shape
        Assert.NotNull(c.Selected);
        c.Key(Vk.Escape, false, false);          // deselect
        Assert.Null(c.Selected);
        Assert.Single(c.Doc.Shapes);
        c.Key(Vk.Escape, false, false);          // drop the selection
        Assert.Null(c.Selection);
        Assert.False(closed);
        c.Key(Vk.Escape, false, false);          // nothing left → close
        Assert.True(closed);
    }

    [Fact]
    public void RightClickDropsSelectionThenCloses()
    {
        var c = Selected();
        var closed = false;
        c.ActionRequested += a => closed |= a == OverlayAction.Close;
        c.PointerDown(new PointF(500, 400), PointerButton.Right);
        Assert.Null(c.Selection);
        Assert.False(closed);
        c.PointerDown(new PointF(500, 400), PointerButton.Right);
        Assert.True(closed);
    }

    [Fact]
    public void ColorButtonTogglesThePalette()
    {
        var c = Selected();
        var tb = c.ToolbarRect!.Value;
        var r = ToolbarLayout.Rects(1).Items[ToolbarLayout.IndexOf(ToolbarAction.Color)];
        var p = new PointF(tb.X + r.X + r.Width / 2, tb.Y + r.Y + r.Height / 2);
        Click(c, p);
        Assert.True(c.PaletteOpen);
        Assert.Contains(c.Bars, b => b.Kind == BarKind.Palette);
        Click(c, p);
        Assert.False(c.PaletteOpen);
    }
}
