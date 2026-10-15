using System.Drawing;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ShotPark.Core;

/// User settings, stored as JSON (normally %APPDATA%\ShotPark\settings.json).
public sealed class AppSettings
{
    public string HotKey { get; set; } = HotKeySpec.Default.Serialize();
    public string HistoryHotKey { get; set; } = HotKeySpec.DefaultHistory.Serialize();
    public string MosaicKey { get; set; } = HotKeySpec.DefaultMosaic.Serialize();
    public string OcrKey { get; set; } = HotKeySpec.DefaultOcr.Serialize();
    public string PinKey { get; set; } = HotKeySpec.DefaultPin.Serialize();
    public string SaveFolder { get; set; } = "";
    public bool SaveDirectly { get; set; } = true;
    public bool SaveAlsoCopies { get; set; } = true;
    public bool CopyAlsoSaves { get; set; }
    public bool WelcomeShown { get; set; }

    /// The 10 palette colours (hex). Empty or malformed → the default palette.
    public List<string> Palette { get; set; } = new();
    public bool Beautify { get; set; }
    public bool BeautifyShadow { get; set; } = true;
    public bool BeautifyRounded { get; set; } = true;
    public bool ClipboardHistory { get; set; } = true;

    /// Last update check (Unix seconds) and the newest version seen.
    public long UpdateLastCheck { get; set; }
    public string UpdateLatest { get; set; } = "";

    /// The annotation tools' last-used settings (sizes in logical units; the overlay scales them).
    public AnnotationPrefs Annotation { get; set; } = new();

    // legacy (≤ 1.21): palette index and width preset
    public int ColorIndex { get; set; } = -1;
    public int WidthIndex { get; set; } = -1;

    [JsonIgnore] public string? FilePath { get; private set; }

    [JsonIgnore]
    public HotKeySpec CaptureHotKey
    {
        get => HotKeySpec.Parse(HotKey, HotKeySpec.Default);
        set => HotKey = value.Serialize();
    }

    [JsonIgnore]
    public HotKeySpec HistoryHotKeySpec
    {
        get => HotKeySpec.Parse(HistoryHotKey, HotKeySpec.DefaultHistory);
        set => HistoryHotKey = value.Serialize();
    }

    [JsonIgnore] public HotKeySpec MosaicKeySpec { get => HotKeySpec.Parse(MosaicKey, HotKeySpec.DefaultMosaic, true); set => MosaicKey = value.Serialize(); }
    [JsonIgnore] public HotKeySpec OcrKeySpec { get => HotKeySpec.Parse(OcrKey, HotKeySpec.DefaultOcr, true); set => OcrKey = value.Serialize(); }
    [JsonIgnore] public HotKeySpec PinKeySpec { get => HotKeySpec.Parse(PinKey, HotKeySpec.DefaultPin, true); set => PinKey = value.Serialize(); }

    [JsonIgnore]
    public Color[] Colors
    {
        get
        {
            var parsed = Palette.Select(ShotPark.Core.Palette.FromHex).ToList();
            return parsed.Count == ShotPark.Core.Palette.Default.Length && parsed.All(c => c != null)
                ? parsed.Select(c => c!.Value).ToArray()
                : (Color[])ShotPark.Core.Palette.Default.Clone();
        }
        set => Palette = value.Select(ShotPark.Core.Palette.ToHex).ToList();
    }

    /// The save folder, falling back to `fallback` (the Pictures folder) when unset or missing.
    public string ResolvedSaveFolder(string fallback) =>
        !string.IsNullOrWhiteSpace(SaveFolder) && Directory.Exists(SaveFolder) ? SaveFolder : fallback;

    static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    public static AppSettings Load(string path)
    {
        AppSettings s;
        try
        {
            s = File.Exists(path)
                ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path), Options) ?? new AppSettings()
                : new AppSettings();
        }
        catch (Exception)
        {
            s = new AppSettings(); // unreadable file: start over rather than crash
        }
        s.FilePath = path;
        s.Annotation ??= new AnnotationPrefs();
        // migrate the 1.21 colour index / width preset
        if (s.ColorIndex >= 0 && s.ColorIndex < ShotPark.Core.Palette.Default.Length)
            s.Annotation.Color = ShotPark.Core.Palette.ToHex(s.Colors[s.ColorIndex]);
        if (s.WidthIndex is >= 0 and <= 2) s.Annotation.Width = AnnotationPrefs.Widths[s.WidthIndex];
        s.ColorIndex = s.WidthIndex = -1;
        s.Annotation.Sanitize();
        return s;
    }

    public void Save()
    {
        if (FilePath is null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(this, Options));
            File.Move(tmp, FilePath, true);
        }
        catch (Exception)
        {
            // best effort; settings are not worth crashing over
        }
    }
}

/// Last-used annotation settings, shared by every capture (like the Mac app's Preferences).
public sealed class AnnotationPrefs
{
    public static readonly float[] Widths = { 2, 4, 7 };
    public static readonly float[] TextSizes = { 16, 24, 40 };
    public static readonly float[] EmojiSizes = { 28, 44, 72 };
    public static readonly string[] Emojis = { "👍", "❤️", "🔥", "✅", "❌", "⭐", "👀", "💡", "⚠️", "🎉", "😂", "🤔" };

    public string Color { get; set; } = ShotPark.Core.Palette.ToHex(ShotPark.Core.Palette.Default[0]);
    public float Width { get; set; } = 4;
    public bool Dashed { get; set; }
    public int Fill { get; set; }
    public float FillAlpha { get; set; } = 0.3f;
    public ArrowHead ArrowHead { get; set; }
    public float TextSize { get; set; } = 24;
    public TextStyles TextStyle { get; set; } = TextStyles.Shadow;
    public string BoxColor { get; set; } = "#FFFFFF";
    public float BoxAlpha { get; set; } = 0.85f;
    public MosaicStyle MosaicStyle { get; set; }
    public int MosaicLevel { get; set; } = 1;
    public string Emoji { get; set; } = "👍";
    public List<string> RecentEmojis { get; set; } = new();
    public float EmojiSize { get; set; } = 44;
    public string? StampImage { get; set; }

    public void Sanitize()
    {
        Width = Math.Clamp(Width, 1, 30);
        FillAlpha = Math.Clamp(FillAlpha, 0.1f, 1);
        TextSize = Math.Clamp(TextSize, 8, 200);
        BoxAlpha = Math.Clamp(BoxAlpha, 0.15f, 1);
        MosaicLevel = Math.Clamp(MosaicLevel, 0, 2);
        EmojiSize = Math.Clamp(EmojiSize, 12, 300);
        Fill = Math.Clamp(Fill, 0, 1);
        if (string.IsNullOrEmpty(Emoji)) Emoji = "👍";
        RecentEmojis ??= new();
        if (RecentEmojis.Count > 10) RecentEmojis = RecentEmojis.Take(10).ToList();
    }

    /// The 10 emoji slots: most recently used first, topped up with presets.
    public List<string> EmojiChoices()
    {
        var list = RecentEmojis.ToList();
        foreach (var e in Emojis) if (!list.Contains(e)) list.Add(e);
        return list.Take(10).ToList();
    }

    public void UseEmoji(string e)
    {
        Emoji = e;
        RecentEmojis.Remove(e);
        RecentEmojis.Insert(0, e);
        if (RecentEmojis.Count > 10) RecentEmojis.RemoveRange(10, RecentEmojis.Count - 10);
    }
}
