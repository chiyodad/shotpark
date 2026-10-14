using System.Drawing;
using System.Globalization;

namespace ShotPark.Core;

/// UI language follows Windows: Korean when the display language is Korean, English otherwise.
public static class Strings
{
    public static bool Korean { get; set; } =
        CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ko";

    public static string L(string ko, string en) => Korean ? ko : en;
}

/// Modifier flags, using the same values as Win32 RegisterHotKey (MOD_ALT/CONTROL/SHIFT/WIN).
[Flags]
public enum Mods { None = 0, Alt = 1, Ctrl = 2, Shift = 4, Win = 8 }

/// A global hotkey: modifiers plus a Win32 virtual-key code.
public readonly record struct HotKeySpec(Mods Mods, int Key)
{
    public const int VkSnapshot = 0x2C; // Print Screen

    public static readonly HotKeySpec Default = new(Mods.Ctrl | Mods.Shift, 0x39); // Ctrl+Shift+9

    /// Needs Ctrl, Alt or Win (Shift alone would steal capital letters from every app),
    /// unless it is Print Screen or a function key.
    public bool IsValid => Key != 0 && !IsModifierKey(Key) &&
        ((Mods & (Mods.Ctrl | Mods.Alt | Mods.Win)) != 0 || Key == VkSnapshot || (Key >= 0x70 && Key <= 0x87));

    public string Display
    {
        get
        {
            var parts = new List<string>();
            if (Mods.HasFlag(Mods.Ctrl)) parts.Add("Ctrl");
            if (Mods.HasFlag(Mods.Alt)) parts.Add("Alt");
            if (Mods.HasFlag(Mods.Shift)) parts.Add("Shift");
            if (Mods.HasFlag(Mods.Win)) parts.Add("Win");
            parts.Add(KeyName(Key));
            return string.Join("+", parts);
        }
    }

    public string Serialize() => $"{(int)Mods}:{Key}";

    public static HotKeySpec Parse(string? s, HotKeySpec fallback)
    {
        if (string.IsNullOrWhiteSpace(s)) return fallback;
        var p = s.Split(':');
        if (p.Length == 2 && int.TryParse(p[0], out var m) && int.TryParse(p[1], out var k))
        {
            var spec = new HotKeySpec((Mods)m, k);
            return spec.IsValid ? spec : fallback;
        }
        return fallback;
    }

    public static bool IsModifierKey(int vk) =>
        vk is 0x10 or 0x11 or 0x12 or 0x5B or 0x5C or 0xA0 or 0xA1 or 0xA2 or 0xA3 or 0xA4 or 0xA5;

    public static string KeyName(int vk) => vk switch
    {
        >= 0x30 and <= 0x39 => ((char)vk).ToString(),
        >= 0x41 and <= 0x5A => ((char)vk).ToString(),
        >= 0x70 and <= 0x87 => $"F{vk - 0x6F}",
        >= 0x60 and <= 0x69 => $"Num{vk - 0x60}",
        VkSnapshot => "PrtSc",
        0x20 => "Space",
        0x09 => "Tab",
        0x2D => "Insert",
        0x2E => "Delete",
        0x24 => "Home",
        0x23 => "End",
        0x21 => "PgUp",
        0x22 => "PgDn",
        0x13 => "Pause",
        0xBA => ";",
        0xBB => "=",
        0xBC => ",",
        0xBD => "-",
        0xBE => ".",
        0xBF => "/",
        0xC0 => "`",
        0xDB => "[",
        0xDC => "\\",
        0xDD => "]",
        0xDE => "'",
        _ => $"Key{vk:X2}",
    };
}

public static class Palette
{
    /// Same 10 colours as the Mac app's default palette.
    public static readonly Color[] Default =
    {
        Color.FromArgb(0xED, 0x38, 0x36), Color.FromArgb(0xFF, 0x94, 0x00), Color.FromArgb(0xFF, 0xD6, 0x0A),
        Color.FromArgb(0x4C, 0xAF, 0x50), Color.FromArgb(0x21, 0x96, 0xF3), Color.FromArgb(0x9C, 0x27, 0xB0),
        Color.FromArgb(0xE9, 0x1E, 0x63), Color.FromArgb(0xFF, 0xFF, 0xFF), Color.FromArgb(0x9E, 0x9E, 0x9E),
        Color.FromArgb(0x00, 0x00, 0x00),
    };
}

public static class FileNames
{
    public static string ForCapture(DateTime now) => $"shotpark-{now:yyyyMMdd-HHmmss}.png";

    /// `shotpark-…png`, or `shotpark-…-2.png` etc. when the name is taken.
    public static string Unique(string folder, DateTime now, Func<string, bool> exists)
    {
        var name = ForCapture(now);
        var path = Path.Combine(folder, name);
        for (var i = 2; exists(path); i++)
            path = Path.Combine(folder, $"{Path.GetFileNameWithoutExtension(name)}-{i}.png");
        return path;
    }
}
