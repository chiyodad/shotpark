using System.Drawing.Imaging;
using System.Security.Cryptography;
using ShotPark.Core;

namespace ShotPark.Win;

/// Keeps the most recent images copied to the clipboard (by ShotPark or any other app) as PNG files
/// in %LOCALAPPDATA%\ShotPark\Clipboard. Nothing leaves the PC. Items an app marks as excluded from
/// clipboard history (password managers) are skipped.
sealed class ClipboardHistory : NativeWindow, IDisposable
{
    readonly AppSettings _settings;
    ClipHistoryIndex _index;
    bool _listening;
    bool _ignoreNext;
    readonly Dictionary<string, Bitmap> _thumbs = new();

    public event Action? Changed;

    public ClipboardHistory(AppSettings settings)
    {
        _settings = settings;
        _index = ClipHistoryIndex.Load(File.Exists(IndexPath) ? SafeRead(IndexPath) : null, n => File.Exists(Path.Combine(Folder, n)));
        CreateHandle(new CreateParams());
        if (settings.ClipboardHistory) Start();
    }

    public static string Folder
    {
        get
        {
            var d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ShotPark", "Clipboard");
            Directory.CreateDirectory(d);
            return d;
        }
    }

    static string IndexPath => Path.Combine(Folder, "index.json");

    public IReadOnlyList<ClipEntry> Entries => _index.Entries;
    public bool Enabled => _settings.ClipboardHistory;

    public void SetEnabled(bool on)
    {
        _settings.ClipboardHistory = on;
        _settings.Save();
        if (on) Start(); else Stop();
        Changed?.Invoke();
    }

    void Start()
    {
        if (!_listening) _listening = Native.AddClipboardFormatListener(Handle);
    }

    void Stop()
    {
        if (_listening) Native.RemoveClipboardFormatListener(Handle);
        _listening = false;
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == Native.WM_CLIPBOARDUPDATE) OnClipboardChanged();
        base.WndProc(ref m);
    }

    void OnClipboardChanged()
    {
        if (_ignoreNext) { _ignoreNext = false; return; }
        if (!_settings.ClipboardHistory) return;
        try
        {
            var data = Clipboard.GetDataObject();
            if (data == null) return;
            var formats = data.GetFormats();
            // Password managers and the like mark secrets; never record those.
            if (formats.Contains("ExcludeClipboardContentFromMonitorProcessing") || formats.Contains("Clipboard Viewer Ignore")) return;
            if (formats.Contains("CanIncludeInClipboardHistory") && data.GetData("CanIncludeInClipboardHistory") is MemoryStream flag
                && flag.Length >= 4 && BitConverter.ToInt32(flag.ToArray(), 0) == 0) return;
            byte[]? png = null;
            if (data.GetData("PNG") is MemoryStream ms) png = ms.ToArray();
            else if (data.GetDataPresent(DataFormats.Bitmap) || data.GetDataPresent(DataFormats.Dib))
            {
                using var img = Clipboard.GetImage();
                if (img == null) return;
                using var outMs = new MemoryStream();
                img.Save(outMs, ImageFormat.Png);
                png = outMs.ToArray();
            }
            if (png != null && png.Length > 0) Add(png);
        }
        catch (Exception) { } // clipboard busy: skip this one
    }

    public void Add(byte[] png)
    {
        int w, h;
        try
        {
            using var ms = new MemoryStream(png);
            using var img = System.Drawing.Image.FromStream(ms);
            (w, h) = (img.Width, img.Height);
        }
        catch (Exception) { return; }
        var hash = Convert.ToHexString(SHA256.HashData(png));
        var (entry, isNew, evicted) = _index.Add(hash, Guid.NewGuid().ToString("N") + ".png", w, h, DateTime.Now);
        if (isNew)
        {
            try { File.WriteAllBytes(Path.Combine(Folder, entry.Name), png); }
            catch (Exception) { _index.Remove(entry.Name); return; }
        }
        foreach (var n in evicted) DeleteFile(n);
        Save();
    }

    public Bitmap? Load(ClipEntry e)
    {
        try
        {
            using var fs = File.OpenRead(Path.Combine(Folder, e.Name));
            using var img = System.Drawing.Image.FromStream(fs);
            return new Bitmap(img);
        }
        catch (Exception) { return null; }
    }

    public string PathOf(ClipEntry e) => Path.Combine(Folder, e.Name);

    public Bitmap? Thumbnail(ClipEntry e, int maxSide)
    {
        if (_thumbs.TryGetValue(e.Name, out var t)) return t;
        using var full = Load(e);
        if (full == null) return null;
        var s = Math.Min(1f, (float)maxSide / Math.Max(full.Width, full.Height));
        var thumb = new Bitmap(Math.Max(1, (int)(full.Width * s)), Math.Max(1, (int)(full.Height * s)));
        using (var g = Graphics.FromImage(thumb))
        {
            g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            g.DrawImage(full, 0, 0, thumb.Width, thumb.Height);
        }
        _thumbs[e.Name] = thumb;
        return thumb;
    }

    /// Puts an entry back on the clipboard (it moves to the front instead of being recorded twice).
    public bool CopyToClipboard(ClipEntry e)
    {
        using var img = Load(e);
        if (img == null) return false;
        _ignoreNext = true;
        var ok = Exporter.Copy(img);
        if (!ok) _ignoreNext = false;
        _index.Touch(e.Name, DateTime.Now);
        Save();
        return ok;
    }

    public void Remove(ClipEntry e)
    {
        _index.Remove(e.Name);
        DeleteFile(e.Name);
        Save();
    }

    public void Clear()
    {
        foreach (var n in _index.Clear()) DeleteFile(n);
        Save();
    }

    void DeleteFile(string name)
    {
        if (_thumbs.Remove(name, out var t)) t.Dispose();
        try { File.Delete(Path.Combine(Folder, name)); } catch (Exception) { }
    }

    void Save()
    {
        try { File.WriteAllText(IndexPath, _index.Serialize()); } catch (Exception) { }
        Changed?.Invoke();
    }

    static string? SafeRead(string path)
    {
        try { return File.ReadAllText(path); } catch (Exception) { return null; }
    }

    public void Dispose()
    {
        Stop();
        DestroyHandle();
    }
}
