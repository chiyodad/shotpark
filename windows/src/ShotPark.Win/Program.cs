using ShotPark.Core;

namespace ShotPark.Win;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        ApplicationConfiguration.Initialize();

        if (args.Length >= 2 && args[0] == "--rendertest")
            return RenderTest.Run(args[1]);

        using var mutex = new Mutex(true, @"Local\ShotPark.SingleInstance", out var first);
        using var show = new EventWaitHandle(false, EventResetMode.AutoReset, TrayApp.ShowEventName);
        if (!first)
        {
            // Already running in the tray: let that copy show itself instead of exiting silently.
            show.Set();
            return 0;
        }

        Application.Run(new TrayApp(show));
        return 0;
    }
}

/// `ShotPark.exe --rendertest <dir>`: draws the overlay, toolbar, palette, result and settings window
/// for a synthetic screen into PNGs, without touching the real screen. Used by CI for visual review.
static class RenderTest
{
    public static int Run(string dir)
    {
        Directory.CreateDirectory(dir);
        Painter.InstallMetrics();
        var log = new List<string>();
        try
        {
            foreach (var korean in new[] { true, false })
            {
                Strings.Korean = korean;
                var tag = korean ? "ko" : "en";
                RenderOverlay(dir, tag, log);
                RenderSettings(Path.Combine(dir, $"settings-{tag}.png"));
            }
            log.Add("OK");
            File.WriteAllLines(Path.Combine(dir, "rendertest.log"), log);
            return 0;
        }
        catch (Exception ex)
        {
            log.Add("FAIL " + ex);
            File.WriteAllLines(Path.Combine(dir, "rendertest.log"), log);
            return 1;
        }
    }

    static void RenderOverlay(string dir, string tag, List<string> log)
    {
        const float scale = 1.25f;
        using var screen = FakeScreen(1600, 1000, scale);
        using var dim = Painter.Dimmed(screen);
        using var mosaic = new MosaicSource(screen, scale);
        var full = new RectangleF(0, 0, screen.Width, screen.Height);
        var settings = new AppSettings();

        void Save(OverlayController c, string name)
        {
            using var bmp = new Bitmap(screen.Width, screen.Height);
            using (var g = Graphics.FromImage(bmp))
                Painter.PaintOverlay(g, c, screen, dim, mosaic, new Rectangle(0, 0, screen.Width, screen.Height));
            bmp.Save(Path.Combine(dir, $"{name}-{tag}.png"));
            log.Add($"{name}-{tag}: selection={c.Selection} toolbar={c.ToolbarRect} bars={string.Join(",", c.Bars.Select(b => b.Kind))} shapes={c.Doc.Shapes.Count}");
        }

        // 1. nothing selected yet: the hint, and the window under the pointer outlined
        var idle = new OverlayController(full, new[] { full }, scale, settings)
        {
            Windows = new[]
            {
                new WindowTarget(new RectangleF(1170, 170, 330, 380), Strings.L("가을 블렌드  ·  330 × 380", "Autumn blend  ·  330 × 380")),
                new WindowTarget(new RectangleF(40, 30, 1520, 910), Strings.L("온도 커피 - 브라우저  ·  1520 × 910", "Ondo Coffee - Browser  ·  1520 × 910")),
            },
        };
        idle.PointerMove(new PointF(800, 500));
        Save(idle, "overlay-idle");
        // window mode (Space): the window under the pointer is lit up
        idle.PointerMove(new PointF(1300, 400));
        idle.Key(Vk.Space, false, false);
        Save(idle, "overlay-window-mode");

        // 2. a marked-up selection, drawn through the same input path as the real window
        var c = new OverlayController(full, new[] { full }, scale, settings);
        Drag(c, new PointF(330, 150), new PointF(1150, 700));
        c.Key(Vk.R, false, false);
        Drag(c, new PointF(392, 548), new PointF(640, 628));
        c.Key(Vk.A, false, false);
        Drag(c, new PointF(900, 560), new PointF(660, 596));
        c.Key(Vk.T, false, false);
        PointF? textAt = null;
        c.TextRequested += (p, _) => textAt = p;
        Click(c, new PointF(690, 352));
        if (textAt is { } at) c.CommitText(at, Strings.L("여기를 클릭!", "Click here!"));
        c.Key(Vk.N, false, false);
        Click(c, new PointF(1090, 292));
        Click(c, new PointF(1090, 336));
        c.Key(Vk.B, false, false);
        Drag(c, new PointF(530, 410), new PointF(900, 486));
        c.Key(Vk.M, false, false);
        Drag(c, new PointF(392, 230), new PointF(700, 230));
        c.Key(Vk.S, false, false);
        Click(c, new PointF(1060, 640));
        Save(c, "overlay");

        // 3. option bars: stroke (arrow), text with a box, mosaic, emoji, palette; a tooltip
        c.Key(Vk.A, false, false);
        c.SetPaletteOpen(true);
        c.SetHover(2, true);
        Save(c, "bars-arrow");
        c.Key(Vk.Escape, false, false);
        c.Key(Vk.R, false, false);
        settings.Annotation.Fill = 1;
        Save(c, "bars-rect");
        c.Key(Vk.T, false, false);
        settings.Annotation.TextStyle = TextStyles.Shadow | TextStyles.Box;
        Save(c, "bars-text");
        c.Key(Vk.B, false, false);
        Save(c, "bars-mosaic");
        c.Key(Vk.S, false, false);
        Save(c, "bars-emoji");
        c.SetTool(Tool.None);

        // 4. a selected, rotated text with its rotate buttons
        var ti = c.Doc.Shapes.FindIndex(s => s.Tool == Tool.Text);
        if (ti >= 0)
        {
            c.Select(ti);
            c.Rotate(-1);
            c.Rotate(-1);
            Save(c, "rotate");
        }

        // 5. a window picked with a click keeps its own shape (rounded, transparent, shadow)
        using (var crop = screen.Clone(new Rectangle(1170, 170, 330, 380), System.Drawing.Imaging.PixelFormat.Format32bppArgb))
        using (var shaped = Painter.Beautify(crop, scale, shadow: true, rounded: true, radius: 8 * scale))
            shaped.Save(Path.Combine(dir, $"result-window-{tag}.png"));

        // 6. the exported image, plain and beautified
        using (var result = Painter.RenderResult(screen, mosaic, c.Selection!.Value, c.Doc.Shapes))
        {
            result.Save(Path.Combine(dir, $"result-{tag}.png"));
            using var pretty = Painter.Beautify(result, scale, true, true);
            pretty.Save(Path.Combine(dir, $"result-beautify-{tag}.png"));
        }

        // 7. toolbar close-up at 200 %
        var big = new OverlayController(new RectangleF(0, 0, 1700, 300), new[] { new RectangleF(0, 0, 1700, 300) }, 2f, settings);
        big.SetSelection(new RectangleF(20, 10, 1600, 120));
        big.SetTool(Tool.Arrow);
        big.SetHover(5, true);
        var tb = big.ToolbarRect!.Value;
        using (var bmp = new Bitmap((int)tb.Width + 40, (int)tb.Height + 110))
        {
            using (var g = Graphics.FromImage(bmp))
            {
                g.Clear(Color.FromArgb(120, 120, 128));
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                g.TranslateTransform(20 - tb.X, 90 - tb.Y);
                Painter.DrawToolbar(g, big, tb);
            }
            bmp.Save(Path.Combine(dir, $"toolbar-{tag}.png"));
        }
    }

    static void Drag(OverlayController c, PointF a, PointF b)
    {
        c.PointerDown(a, PointerButton.Left);
        c.PointerMove(new PointF((a.X + b.X) / 2, (a.Y + b.Y) / 2));
        c.PointerMove(b);
        c.PointerUp(b);
    }

    static void Click(OverlayController c, PointF p)
    {
        c.PointerDown(p, PointerButton.Left);
        c.PointerUp(p);
    }

    static void RenderSettings(string path)
    {
        var tmp = Path.Combine(Path.GetTempPath(), "shotpark-rendertest-settings.json");
        File.Delete(tmp);
        var settings = AppSettings.Load(tmp);
        using var form = new SettingsForm(settings, null, _ => true, _ => true, _ => { });
        form.StartPosition = FormStartPosition.Manual;
        form.Location = new Point(-5000, -5000);
        form.ShowInTaskbar = false;
        form.Show();
        Application.DoEvents();
        using var bmp = new Bitmap(form.Width, form.Height);
        form.DrawToBitmap(bmp, new Rectangle(0, 0, form.Width, form.Height));
        bmp.Save(path);
        form.Close();
    }

    /// A made-up online store page (no real brand), standing in for a real screen.
    static Bitmap FakeScreen(int w, int h, float s)
    {
        var bmp = new Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        using (var bg = new System.Drawing.Drawing2D.LinearGradientBrush(new Rectangle(0, 0, w, h), Color.FromArgb(59, 74, 107), Color.FromArgb(201, 138, 122), 35f))
            g.FillRectangle(bg, 0, 0, w, h);
        // browser window
        var win = new Rectangle(40, 30, w - 80, h - 90);
        using (var p = Painter.RoundRect(win, 10)) using (var b = new SolidBrush(Color.FromArgb(246, 244, 241))) g.FillPath(b, p);
        using (var b = new SolidBrush(Color.FromArgb(233, 230, 226))) g.FillRectangle(b, win.X, win.Y + 10, win.Width, 34);
        using (var b = new SolidBrush(Color.White)) g.FillRectangle(b, win.X, win.Y + 44, win.Width, 64);
        // taskbar
        using (var b = new SolidBrush(Color.FromArgb(235, 32, 32, 36))) g.FillRectangle(b, 0, h - 48, w, 48);

        Font F(float px, bool bold = false) => new(Strings.Korean ? "Malgun Gothic" : "Segoe UI", px, bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Pixel);
        void T(string text, float x, float y, float px, Color col, bool bold = false)
        {
            using var f = F(px, bold);
            using var b = new SolidBrush(col);
            g.DrawString(text, f, b, x, y);
        }
        var dark = Color.FromArgb(34, 34, 34);
        var grey = Color.FromArgb(136, 136, 136);
        var brown = Color.FromArgb(91, 59, 38);
        T(Strings.L("온도 커피", "Ondo Coffee"), 80, 92, 26, brown, true);
        T("ondo-coffee.example/orders", w / 2 - 100, 48, 14, grey);
        // card
        var card = new Rectangle(350, 170, 780, 510);
        using (var p = Painter.RoundRect(card, 14)) using (var b = new SolidBrush(Color.White)) g.FillPath(b, p);
        T(Strings.L("주문번호 20261013-0427", "Order 20261013-0427"), 390, 200, 15, Color.FromArgb(164, 112, 76), true);
        T(Strings.L("주문이 접수되었습니다", "Your order is confirmed"), 390, 224, 30, dark, true);
        T(Strings.L("에티오피아 예가체프 200g × 2", "Ethiopia Yirgacheffe 200g × 2"), 390, 282, 19, dark);
        T("32,000", 980, 282, 19, dark);
        T(Strings.L("드립백 10개입 세트 × 1", "Drip bag set (10) × 1"), 390, 326, 19, dark);
        T("14,500", 980, 326, 19, dark);
        using (var pen = new Pen(Color.FromArgb(238, 238, 238))) g.DrawLine(pen, 390, 372, 1090, 372);
        T(Strings.L("받는 분", "Name"), 390, 384, 17, grey); T(Strings.L("김민지", "Minji Kim"), 530, 384, 17, dark);
        T(Strings.L("연락처", "Phone"), 390, 420, 17, grey); T("010-1234-5678", 530, 420, 17, dark);
        T(Strings.L("이메일", "Email"), 390, 456, 17, grey); T("minji.kim@example.com", 530, 456, 17, dark);
        using (var p = Painter.RoundRect(new RectangleF(400, 556, 232, 60), 10)) using (var b = new SolidBrush(brown)) g.FillPath(b, p);
        T(Strings.L("배송 조회하기", "Track delivery"), 448, 571, 20, Color.White, true);
        T("46,500", 980, 570, 26, dark, true);
        // side panel
        using (var p = Painter.RoundRect(new RectangleF(1170, 170, 330, 380), 14))
        using (var b = new System.Drawing.Drawing2D.LinearGradientBrush(new Rectangle(1170, 170, 330, 380), brown, Color.FromArgb(164, 112, 76), 70f))
            g.FillPath(b, p);
        T(Strings.L("가을 블렌드 출시", "Autumn blend is here"), 1200, 200, 24, Color.White, true);
        return bmp;
    }
}
