using System.Text.Json;
using System.Text.Json.Serialization;

namespace ShotPark.Core;

/// User settings, stored as JSON (normally %APPDATA%\ShotPark\settings.json).
public sealed class AppSettings
{
    public string HotKey { get; set; } = HotKeySpec.Default.Serialize();
    public string SaveFolder { get; set; } = "";
    public bool SaveDirectly { get; set; } = true;
    public bool SaveAlsoCopies { get; set; } = true;
    public bool CopyAlsoSaves { get; set; }
    public int ColorIndex { get; set; }
    public int WidthIndex { get; set; } = 1;
    public bool WelcomeShown { get; set; }

    [JsonIgnore] public string? FilePath { get; private set; }

    [JsonIgnore]
    public HotKeySpec CaptureHotKey
    {
        get => HotKeySpec.Parse(HotKey, HotKeySpec.Default);
        set => HotKey = value.Serialize();
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
        s.ColorIndex = Math.Clamp(s.ColorIndex, 0, Palette.Default.Length - 1);
        s.WidthIndex = Math.Clamp(s.WidthIndex, 0, 2);
        return s;
    }

    public void Save()
    {
        if (FilePath is null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, Options));
        }
        catch (Exception)
        {
            // best effort; settings are not worth crashing over
        }
    }
}
