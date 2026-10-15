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
    /// Clipboard image history (global). Win+V is Windows' own clipboard history.
    public static readonly HotKeySpec DefaultHistory = new(Mods.Ctrl | Mods.Shift, 0x56); // Ctrl+Shift+V
    /// In-capture shortcuts (only active while the overlay is open, so a single key is fine).
    public static readonly HotKeySpec DefaultMosaic = new(Mods.None, 0x42); // B
    public static readonly HotKeySpec DefaultOcr = new(Mods.Ctrl | Mods.Shift, 0x43); // Ctrl+Shift+C
    public static readonly HotKeySpec DefaultPin = new(Mods.Ctrl | Mods.Shift, 0x50); // Ctrl+Shift+P

    /// Needs Ctrl, Alt or Win (Shift alone would steal capital letters from every app),
    /// unless it is Print Screen or a function key.
    public bool IsValid => Key != 0 && !IsModifierKey(Key) &&
        ((Mods & (Mods.Ctrl | Mods.Alt | Mods.Win)) != 0 || Key == VkSnapshot || (Key >= 0x70 && Key <= 0x87));

    /// Valid as an in-capture shortcut: any non-modifier key, alone or with modifiers, that isn't
    /// Esc / Enter / Delete / an arrow key / a Ctrl shortcut the overlay already uses.
    public bool IsValidInCapture => Key != 0 && !IsModifierKey(Key) &&
        Key is not (0x1B or 0x0D or 0x2E or 0x08 or 0x25 or 0x26 or 0x27 or 0x28) &&
        !(Mods == Mods.Ctrl && Key is 0x43 or 0x53 or 0x5A or 0x59 or 0x41 or 0x56);

    public bool Matches(int vk, bool ctrl, bool shift, bool alt) =>
        vk == Key && ctrl == Mods.HasFlag(Mods.Ctrl) && shift == Mods.HasFlag(Mods.Shift) && alt == Mods.HasFlag(Mods.Alt) && !Mods.HasFlag(Mods.Win);

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

    public static HotKeySpec Parse(string? s, HotKeySpec fallback, bool inCapture = false)
    {
        if (string.IsNullOrWhiteSpace(s)) return fallback;
        var p = s.Split(':');
        if (p.Length == 2 && int.TryParse(p[0], out var m) && int.TryParse(p[1], out var k))
        {
            var spec = new HotKeySpec((Mods)m, k);
            return (inCapture ? spec.IsValidInCapture : spec.IsValid) ? spec : fallback;
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
    public static string ToHex(Color c) => $"#{c.R:X2}{c.G:X2}{c.B:X2}";

    public static Color? FromHex(string? s)
    {
        if (s is null) return null;
        s = s.Trim().TrimStart('#');
        return s.Length == 6 && int.TryParse(s, System.Globalization.NumberStyles.HexNumber, null, out var v)
            ? Color.FromArgb(255, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
            : null;
    }

    public static bool Close(Color a, Color b) =>
        Math.Abs(a.R - b.R) < 6 && Math.Abs(a.G - b.G) < 6 && Math.Abs(a.B - b.B) < 6;

    /// Same 10 colours as the Mac app's default palette.
    public static readonly Color[] Default =
    {
        Color.FromArgb(0xED, 0x38, 0x36), Color.FromArgb(0xFF, 0x94, 0x00), Color.FromArgb(0xFF, 0xD6, 0x0A),
        Color.FromArgb(0x4C, 0xAF, 0x50), Color.FromArgb(0x21, 0x96, 0xF3), Color.FromArgb(0x9C, 0x27, 0xB0),
        Color.FromArgb(0xE9, 0x1E, 0x63), Color.FromArgb(0xFF, 0xFF, 0xFF), Color.FromArgb(0x8C, 0x8C, 0x8C),
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

/// Win32 virtual-key codes the overlay reacts to.
public static class Vk
{
    public const int Back = 0x08, Enter = 0x0D, Escape = 0x1B, Space = 0x20, Left = 0x25, Up = 0x26, Right = 0x27, Down = 0x28, Delete = 0x2E;
    public const int D0 = 0x30, D1 = 0x31, D2 = 0x32, D3 = 0x33;
    public const int A = 0x41, B = 0x42, C = 0x43, E = 0x45, L = 0x4C, M = 0x4D, N = 0x4E, P = 0x50, R = 0x52, S = 0x53, T = 0x54, V = 0x56, X = 0x58, Y = 0x59, Z = 0x5A;
    public const int NumPad1 = 0x61, NumPad2 = 0x62, NumPad3 = 0x63, Add = 0x6B, Subtract = 0x6D;
    public const int OemPlus = 0xBB, OemMinus = 0xBD, OemOpenBracket = 0xDB, OemCloseBracket = 0xDD;
}

/// Version strings like "1.21.0" (an optional leading "v" is ignored).
public static class Versions
{
    public static bool IsNewer(string candidate, string current)
    {
        static int[] Parts(string v) => v.Trim().TrimStart('v', 'V').Split('.', '-', '+')
            .Select(p => int.TryParse(p, out var n) ? n : 0).Take(4).ToArray();
        var a = Parts(candidate);
        var b = Parts(current);
        for (var i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            var x = i < a.Length ? a[i] : 0;
            var y = i < b.Length ? b[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }
}
