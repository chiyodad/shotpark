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
        s.Save();
        var t = AppSettings.Load(path);
        Assert.Equal("PrtSc", t.CaptureHotKey.Display);
        Assert.False(t.SaveDirectly);
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
    public void UniqueFileNames()
    {
        var now = new DateTime(2026, 10, 13, 9, 5, 7);
        var taken = new HashSet<string> { Path.Combine("x", "shotpark-20261013-090507.png") };
        Assert.Equal(Path.Combine("x", "shotpark-20261013-090507-2.png"), FileNames.Unique("x", now, taken.Contains));
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
    public void RectHitsOnlyNearItsOutline()
    {
        var s = new Shape { Tool = Tool.Rect, Points = { new(0, 0), new(100, 100) }, Width = 4 };
        Assert.True(s.HitTest(new PointF(1, 50), 3));
        Assert.False(s.HitTest(new PointF(50, 50), 3));
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
}

public class ToolbarTests
{
    [Fact]
    public void SitsBelowSelectionWhenThereIsRoom()
    {
        var tb = ToolbarLayout.Place(new RectangleF(100, 100, 800, 300), new RectangleF(0, 0, 1920, 1080), 1);
        Assert.True(tb.Top > 400);
        Assert.Equal(900, tb.Right, 1);
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
    public void PaletteGoesAwayFromSelection()
    {
        var sel = new RectangleF(100, 100, 800, 300);
        var screen = new RectangleF(0, 0, 1920, 1080);
        var tb = ToolbarLayout.Place(sel, screen, 1);
        var pal = PaletteLayout.Place(tb, sel, screen, 1);
        Assert.True(pal.Top >= tb.Bottom);
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
    static OverlayController Make() => new(new RectangleF(0, 0, 1920, 1080), new[] { new RectangleF(0, 0, 1920, 1080) }, 1);

    static OverlayController WithSelection()
    {
        var c = Make();
        c.PointerDown(new PointF(100, 100), PointerButton.Left);
        c.PointerMove(new PointF(700, 500));
        c.PointerUp(new PointF(700, 500));
        return c;
    }

    [Fact]
    public void DragMakesSelection()
    {
        var c = WithSelection();
        Assert.Equal(new RectangleF(100, 100, 600, 400), c.Selection);
        Assert.NotNull(c.ToolbarRect);
    }

    [Fact]
    public void TinyClickLeavesNoSelection()
    {
        var c = Make();
        c.PointerDown(new PointF(100, 100), PointerButton.Left);
        c.PointerUp(new PointF(101, 101));
        Assert.Null(c.Selection);
    }

    [Fact]
    public void DragInsideMovesSelection()
    {
        var c = WithSelection();
        c.PointerDown(new PointF(300, 300), PointerButton.Left);
        c.PointerMove(new PointF(350, 320));
        c.PointerUp(new PointF(350, 320));
        Assert.Equal(new RectangleF(150, 120, 600, 400), c.Selection);
    }

    [Fact]
    public void HandleResizes()
    {
        var c = WithSelection();
        c.PointerDown(new PointF(700, 500), PointerButton.Left);
        c.PointerMove(new PointF(800, 550));
        c.PointerUp(new PointF(800, 550));
        Assert.Equal(new RectangleF(100, 100, 700, 450), c.Selection);
    }

    [Fact]
    public void SelectionStaysOnScreen()
    {
        var c = WithSelection();
        c.PointerDown(new PointF(300, 300), PointerButton.Left);
        c.PointerMove(new PointF(-2000, -2000));
        c.PointerUp(new PointF(-2000, -2000));
        Assert.Equal(new RectangleF(0, 0, 600, 400), c.Selection);
    }

    [Fact]
    public void DrawsRectWithToolAndUndoes()
    {
        var c = WithSelection();
        Assert.True(c.Key(KeyCode.R, false, false));
        Assert.Equal(Tool.Rect, c.Tool);
        c.PointerDown(new PointF(200, 200), PointerButton.Left);
        c.PointerMove(new PointF(300, 260));
        c.PointerUp(new PointF(300, 260));
        Assert.Single(c.Doc.Shapes);
        Assert.Equal(new RectangleF(200, 200, 100, 60), c.Doc.Shapes[0].Bounds);
        c.Key(KeyCode.Z, true, false);
        Assert.Empty(c.Doc.Shapes);
        c.Key(KeyCode.Z, true, true);
        Assert.Single(c.Doc.Shapes);
    }

    [Fact]
    public void ClickWithToolDoesNotMakeDegenerateShape()
    {
        var c = WithSelection();
        c.SetTool(Tool.Arrow);
        c.PointerDown(new PointF(200, 200), PointerButton.Left);
        c.PointerUp(new PointF(200, 200));
        Assert.Empty(c.Doc.Shapes);
    }

    [Fact]
    public void ShiftSnapsLinesTo45Degrees()
    {
        var c = WithSelection();
        c.SetTool(Tool.Line);
        c.PointerDown(new PointF(200, 200), PointerButton.Left);
        c.PointerMove(new PointF(300, 290), shift: true);
        c.PointerUp(new PointF(300, 290), shift: true);
        var s = c.Doc.Shapes[0];
        Assert.Equal(s.End.X - s.Start.X, s.End.Y - s.Start.Y, 2);
    }

    [Fact]
    public void NumbersCountUp()
    {
        var c = WithSelection();
        c.SetTool(Tool.Number);
        c.PointerDown(new PointF(200, 200), PointerButton.Left);
        c.PointerUp(new PointF(200, 200));
        c.PointerDown(new PointF(250, 200), PointerButton.Left);
        c.PointerUp(new PointF(250, 200));
        Assert.Equal(new[] { 1, 2 }, c.Doc.Shapes.Select(s => s.Number));
    }

    [Fact]
    public void TextToolRequestsTextBoxAndCommits()
    {
        var c = WithSelection();
        PointF? at = null;
        c.TextRequested += (p, _) => at = p;
        c.SetTool(Tool.Text);
        c.PointerDown(new PointF(220, 230), PointerButton.Left);
        Assert.Equal(new PointF(220, 230), at);
        c.CommitText(at!.Value, "여기를 클릭!");
        Assert.Equal("여기를 클릭!", c.Doc.Shapes.Single().Text);
        c.CommitText(at.Value, "   ");
        Assert.Single(c.Doc.Shapes);
    }

    [Fact]
    public void SelectModeMovesAndDeletesShapes()
    {
        var c = WithSelection();
        c.SetTool(Tool.Line);
        c.PointerDown(new PointF(200, 200), PointerButton.Left);
        c.PointerMove(new PointF(400, 200));
        c.PointerUp(new PointF(400, 200));
        c.SetTool(Tool.None);
        c.PointerDown(new PointF(300, 201), PointerButton.Left);
        c.PointerMove(new PointF(300, 251));
        c.PointerUp(new PointF(300, 251));
        Assert.Equal(new PointF(200, 250), c.Doc.Shapes[0].Start);
        Assert.Equal(new RectangleF(100, 100, 600, 400), c.Selection); // selection did not move
        c.Key(KeyCode.Delete, false, false);
        Assert.Empty(c.Doc.Shapes);
        c.Key(KeyCode.Z, true, false);
        Assert.Single(c.Doc.Shapes);
        c.Key(KeyCode.Z, true, false);
        Assert.Equal(new PointF(200, 200), c.Doc.Shapes[0].Start);
    }

    [Fact]
    public void ClickOutsideStartsOver()
    {
        var c = WithSelection();
        c.SetTool(Tool.Rect);
        c.PointerDown(new PointF(200, 200), PointerButton.Left);
        c.PointerMove(new PointF(300, 300));
        c.PointerUp(new PointF(300, 300));
        c.SetTool(Tool.None);
        c.PointerDown(new PointF(1500, 900), PointerButton.Left);
        c.PointerUp(new PointF(1501, 901));
        Assert.Null(c.Selection);
        Assert.Empty(c.Doc.Shapes);
    }

    [Fact]
    public void ToolbarClickPicksTool()
    {
        var c = WithSelection();
        var tb = c.ToolbarRect!.Value;
        var (rects, _) = ToolbarLayout.Rects(1);
        var arrow = Array.FindIndex(ToolbarLayout.Items, i => i.Tool == Tool.Arrow);
        var r = rects[arrow];
        var p = new PointF(tb.X + r.X + r.Width / 2, tb.Y + r.Y + r.Height / 2);
        c.PointerDown(p, PointerButton.Left);
        c.PointerUp(p);
        Assert.Equal(Tool.Arrow, c.Tool);
        c.PointerDown(p, PointerButton.Left); // again → back to select mode
        Assert.Equal(Tool.None, c.Tool);
        Assert.Equal(new RectangleF(100, 100, 600, 400), c.Selection);
    }

    [Fact]
    public void PaletteChangesColorAndRestylesPickedShape()
    {
        var c = WithSelection();
        c.SetTool(Tool.Rect);
        c.PointerDown(new PointF(200, 200), PointerButton.Left);
        c.PointerMove(new PointF(300, 300));
        c.PointerUp(new PointF(300, 300));
        c.SetTool(Tool.None);
        c.PointerDown(new PointF(200, 250), PointerButton.Left); // pick the rect by its edge
        c.PointerUp(new PointF(200, 250));
        Assert.NotNull(c.Picked);
        c.SetPaletteOpen(true);
        var pal = c.PaletteRect!.Value;
        var (colors, _) = PaletteLayout.Rects(1);
        var blue = colors[4];
        c.PointerDown(new PointF(pal.X + blue.X + 5, pal.Y + blue.Y + 5), PointerButton.Left);
        Assert.Equal(4, c.ColorIndex);
        Assert.Equal(Palette.Default[4], c.Doc.Shapes[0].Color);
    }

    [Fact]
    public void ActionsFire()
    {
        var c = WithSelection();
        var got = new List<OverlayAction>();
        c.ActionRequested += got.Add;
        c.Key(KeyCode.C, true, false);
        c.Key(KeyCode.Enter, false, false);
        c.Key(KeyCode.S, true, false);
        c.Key(KeyCode.Escape, false, false);
        c.PointerDown(new PointF(5, 5), PointerButton.Right);
        Assert.Equal(new[] { OverlayAction.Copy, OverlayAction.Copy, OverlayAction.Save, OverlayAction.Close, OverlayAction.Close }, got);
    }

    [Fact]
    public void EscClosesPaletteFirst()
    {
        var c = WithSelection();
        var got = new List<OverlayAction>();
        c.ActionRequested += got.Add;
        c.SetPaletteOpen(true);
        c.Key(KeyCode.Escape, false, false);
        Assert.False(c.PaletteOpen);
        Assert.Empty(got);
    }

    [Fact]
    public void ArrowKeysNudgeSelection()
    {
        var c = WithSelection();
        c.Key(KeyCode.Right, false, false);
        c.Key(KeyCode.Down, false, true);
        Assert.Equal(new RectangleF(101, 110, 600, 400), c.Selection);
    }

    [Fact]
    public void CtrlASelectsMonitorUnderPointer()
    {
        var mons = new[] { new RectangleF(0, 0, 1920, 1080), new RectangleF(1920, 0, 2560, 1440) };
        var c = new OverlayController(new RectangleF(0, 0, 4480, 1440), mons, 1);
        c.PointerMove(new PointF(2500, 300));
        c.Key(KeyCode.A, true, false);
        Assert.Equal(mons[1], c.Selection);
    }

    [Fact]
    public void ToolbarOnSecondMonitorStaysThere()
    {
        var mons = new[] { new RectangleF(0, 0, 1920, 1080), new RectangleF(1920, 0, 2560, 1440) };
        var c = new OverlayController(new RectangleF(0, 0, 4480, 1440), mons, 1);
        c.SetSelection(new RectangleF(1930, 1000, 400, 430));
        var tb = c.ToolbarRect!.Value;
        Assert.True(mons[1].Contains(tb));
    }
}
