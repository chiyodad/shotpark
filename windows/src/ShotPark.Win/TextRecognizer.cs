using System.Drawing.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;
using ZXing;

namespace ShotPark.Win;

/// "Extract text": QR codes first (ZXing.Net), otherwise Windows' built-in on-device OCR
/// (Windows.Media.Ocr — nothing is uploaded). Korean, English, Japanese and Chinese, as far as
/// the matching Windows language features are installed.
static class TextRecognizer
{
    public static List<string> Barcodes(Bitmap bmp)
    {
        try
        {
            var w = bmp.Width;
            var h = bmp.Height;
            var bytes = new byte[w * h * 4];
            var data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                for (var y = 0; y < h; y++)
                    System.Runtime.InteropServices.Marshal.Copy(data.Scan0 + y * data.Stride, bytes, y * w * 4, w * 4);
            }
            finally { bmp.UnlockBits(data); }
            var source = new RGBLuminanceSource(bytes, w, h, RGBLuminanceSource.BitmapFormat.BGRA32);
            var reader = new BarcodeReaderGeneric { AutoRotate = true };
            reader.Options.TryHarder = true;
            reader.Options.PossibleFormats = new List<BarcodeFormat> { BarcodeFormat.QR_CODE };
            var results = reader.DecodeMultiple(source);
            return results?.Select(r => r.Text).Where(t => !string.IsNullOrEmpty(t)).Distinct().ToList() ?? new List<string>();
        }
        catch (Exception) { return new List<string>(); }
    }

    static readonly string[] Preferred = { "ko", "en-US", "ja", "zh-Hans", "zh-Hant" };

    public static async Task<string> RecognizeAsync(Bitmap bmp)
    {
        // Small captures recognise much better scaled up.
        using var src = Upscale(bmp);
        using var stream = new InMemoryRandomAccessStream();
        using (var ms = new MemoryStream())
        {
            src.Save(ms, ImageFormat.Png);
            await stream.WriteAsync(ms.ToArray().AsBuffer());
        }
        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream);
        using var soft = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);

        // The user's languages first, then the others Windows can read; keep the longest result.
        var engines = new List<OcrEngine>();
        if (OcrEngine.TryCreateFromUserProfileLanguages() is { } user) engines.Add(user);
        foreach (var tag in Preferred)
        {
            try
            {
                var lang = new Language(tag);
                if (!OcrEngine.IsLanguageSupported(lang)) continue;
                if (engines.Any(e => e.RecognizerLanguage.LanguageTag.StartsWith(tag.Split('-')[0], StringComparison.OrdinalIgnoreCase))) continue;
                if (OcrEngine.TryCreateFromLanguage(lang) is { } e) engines.Add(e);
            }
            catch (Exception) { }
        }
        var best = "";
        foreach (var engine in engines)
        {
            var result = await engine.RecognizeAsync(soft);
            var text = Join(result);
            if (Score(text) > Score(best)) best = text;
            if (best.Length > 0 && engine == engines[0] && Score(best) >= best.Length * 0.6) break; // the user's language read it well
        }
        return best.Trim();
    }

    static Bitmap Upscale(Bitmap bmp)
    {
        var f = Math.Min(bmp.Width, bmp.Height) < 120 ? 3 : Math.Min(bmp.Width, bmp.Height) < 300 ? 2 : 1;
        f = Math.Min(f, Math.Max(1, 9000 / Math.Max(bmp.Width, bmp.Height)));
        var outBmp = new Bitmap(bmp.Width * f, bmp.Height * f, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(outBmp);
        g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
        g.DrawImage(bmp, 0, 0, outBmp.Width, outBmp.Height);
        return outBmp;
    }

    /// Lines joined with newlines; Windows puts spaces between CJK "words" (characters), so those go.
    static string Join(OcrResult result)
    {
        var sb = new StringBuilder();
        foreach (var line in result.Lines)
        {
            var t = line.Text;
            var clean = new StringBuilder();
            for (var i = 0; i < t.Length; i++)
            {
                if (t[i] == ' ' && i > 0 && i < t.Length - 1 && IsCjk(t[i - 1]) && IsCjk(t[i + 1])) continue;
                clean.Append(t[i]);
            }
            sb.Append(clean).Append('\n');
        }
        return sb.ToString();
    }

    static bool IsCjk(char c) => c is >= '぀' and <= 'ヿ' or >= '一' and <= '鿿' or >= '＀' and <= '￯' or >= '　' and <= '〿';

    /// Letters and digits recognised (higher = better).
    static int Score(string s) => s.Count(char.IsLetterOrDigit);
}
