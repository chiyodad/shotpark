using System.Drawing.Imaging;

namespace ShotPark.Win;

/// The user's image stamps (signatures, logos…): the 3 most recent, as PNGs in
/// %APPDATA%\ShotPark\Stamps. Images pasted with Ctrl+V are kept in memory only.
static class ImageStamps
{
    public const int MaxCount = 3;
    static readonly Dictionary<string, Bitmap> Cache = new();
    static readonly Dictionary<string, Bitmap> Transient = new();

    public static string Folder
    {
        get
        {
            var d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ShotPark", "Stamps");
            Directory.CreateDirectory(d);
            return d;
        }
    }

    static IReadOnlyList<string>? _names;

    /// Newest first. Cached; adding or removing refreshes it.
    public static IReadOnlyList<string> Names
    {
        get
        {
            if (_names != null) return _names;
            try
            {
                _names = new DirectoryInfo(Folder).GetFiles("*.png")
                    .OrderByDescending(f => f.CreationTimeUtc).Take(MaxCount).Select(f => f.Name).ToList();
            }
            catch (Exception) { _names = Array.Empty<string>(); }
            return _names;
        }
    }

    public static Bitmap? Image(string name)
    {
        if (Transient.TryGetValue(name, out var t)) return t;
        if (Cache.TryGetValue(name, out var c)) return c;
        try
        {
            var path = Path.Combine(Folder, name);
            if (!File.Exists(path)) return null;
            using var fs = File.OpenRead(path);
            using var img = System.Drawing.Image.FromStream(fs);
            var bmp = new Bitmap(img);
            Cache[name] = bmp;
            return bmp;
        }
        catch (Exception) { return null; }
    }

    public static float? Aspect(string name) => Image(name) is { } b && b.Height > 0 ? (float)b.Width / b.Height : null;

    /// Adds an image file; the oldest beyond the limit is dropped. Returns the stored name.
    public static string? Add(string path)
    {
        try
        {
            using var src = System.Drawing.Image.FromFile(path);
            using var bmp = Fit(src, 1200);
            var name = $"stamp-{DateTime.Now:yyyyMMdd-HHmmss-fff}.png";
            bmp.Save(Path.Combine(Folder, name), ImageFormat.Png);
            File.SetCreationTimeUtc(Path.Combine(Folder, name), DateTime.UtcNow);
            foreach (var old in new DirectoryInfo(Folder).GetFiles("*.png").OrderByDescending(f => f.CreationTimeUtc).Skip(MaxCount))
                Remove(old.Name);
            _names = null;
            return name;
        }
        catch (Exception) { return null; }
    }

    /// A pasted image, used once and not saved to the stamp list.
    public static string AddTransient(Image img)
    {
        var name = $"paste-{Guid.NewGuid():N}";
        Transient[name] = Fit(img, 1600);
        return name;
    }

    public static void Remove(string name)
    {
        if (Cache.Remove(name, out var b)) b.Dispose();
        try { File.Delete(Path.Combine(Folder, name)); } catch (Exception) { }
        _names = null;
    }

    static Bitmap Fit(Image src, int max)
    {
        var s = Math.Min(1f, (float)max / Math.Max(src.Width, src.Height));
        var w = Math.Max(1, (int)(src.Width * s));
        var h = Math.Max(1, (int)(src.Height * s));
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);
        g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
        g.DrawImage(src, 0, 0, w, h);
        return bmp;
    }
}
