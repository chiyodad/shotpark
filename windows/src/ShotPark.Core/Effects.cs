namespace ShotPark.Core;

/// Mosaic / blur on raw 32-bit pixels (0xAARRGGBB, row-major). Kept toolkit-free so it can be tested.
public static class Effects
{
    /// Block size / blur radius in logical pixels for strength 0 (light) … 2 (strong). Same as the Mac app.
    public static float Amount(MosaicStyle style, int level)
    {
        var l = Math.Clamp(level, 0, 2);
        return style == MosaicStyle.Pixelate ? new[] { 7f, 12f, 20f }[l] : new[] { 5f, 10f, 18f }[l];
    }

    /// Pixelates in place with square blocks aligned to (originX, originY) in image coordinates.
    public static void Pixelate(int[] px, int w, int h, int block, int originX = 0, int originY = 0)
    {
        block = Math.Max(2, block);
        var ox = ((originX % block) + block) % block;
        var oy = ((originY % block) + block) % block;
        for (var by = -oy; by < h; by += block)
        for (var bx = -ox; bx < w; bx += block)
        {
            int x0 = Math.Max(0, bx), y0 = Math.Max(0, by), x1 = Math.Min(w, bx + block), y1 = Math.Min(h, by + block);
            if (x0 >= x1 || y0 >= y1) continue;
            long r = 0, g = 0, b = 0, n = 0;
            for (var y = y0; y < y1; y++)
            for (var x = x0; x < x1; x++)
            {
                var c = px[y * w + x];
                r += (c >> 16) & 0xFF; g += (c >> 8) & 0xFF; b += c & 0xFF; n++;
            }
            var avg = unchecked((int)0xFF000000) | (int)(r / n) << 16 | (int)(g / n) << 8 | (int)(b / n);
            for (var y = y0; y < y1; y++)
                Array.Fill(px, avg, y * w + x0, x1 - x0);
        }
    }

    /// Approximates a Gaussian blur of the given radius with three box blurs (in place).
    public static void Blur(int[] px, int w, int h, float radius)
    {
        if (radius < 1 || w < 2 || h < 2) return;
        // box sizes for 3 passes (Ivan Kutskir's approximation)
        var sigma = radius / 2f;
        var wIdeal = MathF.Sqrt(12 * sigma * sigma / 3 + 1);
        var wl = (int)MathF.Floor(wIdeal);
        if (wl % 2 == 0) wl--;
        var wu = wl + 2;
        var m = (int)MathF.Round((12 * sigma * sigma - 3 * wl * wl - 4 * 3 * wl - 3 * 3) / (-4 * wl - 4));
        var tmp = new int[px.Length];
        for (var i = 0; i < 3; i++)
        {
            var r = ((i < m ? wl : wu) - 1) / 2;
            if (r < 1) continue;
            BoxH(px, tmp, w, h, r);
            BoxV(tmp, px, w, h, r);
        }
    }

    static void BoxH(int[] src, int[] dst, int w, int h, int r)
    {
        var div = 2 * r + 1;
        for (var y = 0; y < h; y++)
        {
            var row = y * w;
            int sr = 0, sg = 0, sb = 0;
            for (var k = -r; k <= r; k++)
            {
                var c = src[row + Math.Clamp(k, 0, w - 1)];
                sr += (c >> 16) & 0xFF; sg += (c >> 8) & 0xFF; sb += c & 0xFF;
            }
            for (var x = 0; x < w; x++)
            {
                dst[row + x] = unchecked((int)0xFF000000) | (sr / div) << 16 | (sg / div) << 8 | (sb / div);
                var add = src[row + Math.Min(x + r + 1, w - 1)];
                var sub = src[row + Math.Max(x - r, 0)];
                sr += ((add >> 16) & 0xFF) - ((sub >> 16) & 0xFF);
                sg += ((add >> 8) & 0xFF) - ((sub >> 8) & 0xFF);
                sb += (add & 0xFF) - (sub & 0xFF);
            }
        }
    }

    static void BoxV(int[] src, int[] dst, int w, int h, int r)
    {
        var div = 2 * r + 1;
        for (var x = 0; x < w; x++)
        {
            int sr = 0, sg = 0, sb = 0;
            for (var k = -r; k <= r; k++)
            {
                var c = src[Math.Clamp(k, 0, h - 1) * w + x];
                sr += (c >> 16) & 0xFF; sg += (c >> 8) & 0xFF; sb += c & 0xFF;
            }
            for (var y = 0; y < h; y++)
            {
                dst[y * w + x] = unchecked((int)0xFF000000) | (sr / div) << 16 | (sg / div) << 8 | (sb / div);
                var add = src[Math.Min(y + r + 1, h - 1) * w + x];
                var sub = src[Math.Max(y - r, 0) * w + x];
                sr += ((add >> 16) & 0xFF) - ((sub >> 16) & 0xFF);
                sg += ((add >> 8) & 0xFF) - ((sub >> 8) & 0xFF);
                sb += (add & 0xFF) - (sub & 0xFF);
            }
        }
    }
}
