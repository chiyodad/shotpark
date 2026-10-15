using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using D2D = Vortice.Direct2D1;
using DW = Vortice.DirectWrite;

namespace ShotPark.Win;

/// Colour emoji. GDI+ only draws the monochrome outline of an emoji glyph, so emoji are drawn with
/// Direct2D (which renders the colour layers of Segoe UI Emoji) into a bitmap, cached per emoji and size.
static class EmojiRenderer
{
    static readonly Dictionary<(string, int), Bitmap> Cache = new();
    static D2D.ID2D1Factory? _d2d;
    static DW.IDWriteFactory? _dw;
    static bool _failed;

    /// Box an emoji occupies at a font size (pixels). Matches what Render draws into.
    public static SizeF Measure(string emoji, float px) => new(px * 1.25f, px * 1.25f);

    /// The emoji drawn centred in a square of Measure(px) (premultiplied ARGB). Never null.
    public static Bitmap Render(string emoji, float px)
    {
        var key = (emoji, (int)MathF.Round(px * 2));
        if (Cache.TryGetValue(key, out var hit)) return hit;
        if (Cache.Count > 200)
        {
            foreach (var b in Cache.Values) b.Dispose();
            Cache.Clear();
        }
        var side = Math.Max(4, (int)MathF.Ceiling(px * 1.25f));
        var bmp = (_failed ? null : TryDirect2D(emoji, px, side)) ?? Gdi(emoji, px, side);
        Cache[key] = bmp;
        return bmp;
    }

    static Bitmap Gdi(string emoji, float px, int side)
    {
        var bmp = new Bitmap(side, side, PixelFormat.Format32bppPArgb);
        using var g = Graphics.FromImage(bmp);
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        using var font = new Font("Segoe UI Emoji", px, GraphicsUnit.Pixel);
        using var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
        g.DrawString(emoji, font, Brushes.Black, new RectangleF(0, 0, side, side), fmt);
        return bmp;
    }

    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);

    [StructLayout(LayoutKind.Sequential)]
    struct BITMAPINFOHEADER
    {
        public int biSize, biWidth, biHeight;
        public short biPlanes, biBitCount;
        public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant;
    }

    static Bitmap? TryDirect2D(string emoji, float px, int side)
    {
        IntPtr dc = IntPtr.Zero, dib = IntPtr.Zero, old = IntPtr.Zero;
        try
        {
            _d2d ??= D2D.D2D1.D2D1CreateFactory<D2D.ID2D1Factory>(D2D.FactoryType.SingleThreaded);
            _dw ??= DW.DWrite.DWriteCreateFactory<DW.IDWriteFactory>(DW.FactoryType.Shared);

            var bi = new BITMAPINFOHEADER { biSize = Marshal.SizeOf<BITMAPINFOHEADER>(), biWidth = side, biHeight = -side, biPlanes = 1, biBitCount = 32 };
            dc = CreateCompatibleDC(IntPtr.Zero);
            dib = CreateDIBSection(dc, ref bi, 0, out var bits, IntPtr.Zero, 0);
            if (dib == IntPtr.Zero) return null;
            old = SelectObject(dc, dib);

            var props = new D2D.RenderTargetProperties
            {
                Type = D2D.RenderTargetType.Default,
                PixelFormat = new Vortice.DCommon.PixelFormat(Vortice.DXGI.Format.B8G8R8A8_UNorm, Vortice.DCommon.AlphaMode.Premultiplied),
                DpiX = 96,
                DpiY = 96,
            };
            using var rt = _d2d.CreateDCRenderTarget(props);
            rt.BindDC(dc, new Vortice.RawRect(0, 0, side, side));
            using var format = _dw.CreateTextFormat("Segoe UI Emoji", DW.FontWeight.Normal, DW.FontStyle.Normal, DW.FontStretch.Normal, px);
            format.TextAlignment = DW.TextAlignment.Center;
            format.ParagraphAlignment = DW.ParagraphAlignment.Center;
            using var brush = rt.CreateSolidColorBrush(new Vortice.Mathematics.Color4(0, 0, 0, 1));
            rt.BeginDraw();
            rt.Clear(new Vortice.Mathematics.Color4(0, 0, 0, 0));
            rt.DrawText(emoji, format, new Vortice.Mathematics.Rect(0, 0, side, side), brush, D2D.DrawTextOptions.EnableColorFont);
            rt.EndDraw();

            var px32 = new int[side * side];
            Marshal.Copy(bits, px32, 0, px32.Length);
            var bmp = new Bitmap(side, side, PixelFormat.Format32bppPArgb);
            var data = bmp.LockBits(new Rectangle(0, 0, side, side), ImageLockMode.WriteOnly, PixelFormat.Format32bppPArgb);
            for (var y = 0; y < side; y++) Marshal.Copy(px32, y * side, data.Scan0 + y * data.Stride, side);
            bmp.UnlockBits(data);
            return bmp;
        }
        catch (Exception)
        {
            _failed = true; // no Direct2D (e.g. a remote session without it): monochrome fallback
            return null;
        }
        finally
        {
            if (old != IntPtr.Zero) SelectObject(dc, old);
            if (dib != IntPtr.Zero) DeleteObject(dib);
            if (dc != IntPtr.Zero) DeleteDC(dc);
        }
    }
}
