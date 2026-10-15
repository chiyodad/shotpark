using System.Text.Json;

namespace ShotPark.Core;

public sealed record ClipEntry(string Name, DateTime Date, string Hash, int Width, int Height);

/// The index of the clipboard image history: newest first, at most 30, no duplicates
/// (the same image again moves to the front). File handling is up to the caller.
public sealed class ClipHistoryIndex
{
    public const int MaxCount = 30;

    public List<ClipEntry> Entries { get; private set; } = new();

    /// Adds an image by hash. Returns the entry, whether its file still has to be written,
    /// and the names whose files should be deleted (pushed out of the history).
    public (ClipEntry Entry, bool IsNew, List<string> Evicted) Add(string hash, string newName, int width, int height, DateTime now)
    {
        var i = Entries.FindIndex(e => e.Hash == hash);
        if (i >= 0)
        {
            var moved = Entries[i] with { Date = now };
            Entries.RemoveAt(i);
            Entries.Insert(0, moved);
            return (moved, false, new List<string>());
        }
        var e = new ClipEntry(newName, now, hash, width, height);
        Entries.Insert(0, e);
        var evicted = new List<string>();
        while (Entries.Count > MaxCount)
        {
            evicted.Add(Entries[^1].Name);
            Entries.RemoveAt(Entries.Count - 1);
        }
        return (e, true, evicted);
    }

    /// Moves an entry to the front (it was copied again from the history).
    public void Touch(string name, DateTime now)
    {
        var i = Entries.FindIndex(e => e.Name == name);
        if (i < 0) return;
        var e = Entries[i] with { Date = now };
        Entries.RemoveAt(i);
        Entries.Insert(0, e);
    }

    public bool Remove(string name) => Entries.RemoveAll(e => e.Name == name) > 0;

    public List<string> Clear()
    {
        var names = Entries.Select(e => e.Name).ToList();
        Entries.Clear();
        return names;
    }

    public string Serialize() => JsonSerializer.Serialize(Entries);

    /// Loads an index, keeping only entries whose file exists.
    public static ClipHistoryIndex Load(string? json, Func<string, bool> fileExists)
    {
        var idx = new ClipHistoryIndex();
        try
        {
            if (!string.IsNullOrWhiteSpace(json))
                idx.Entries = (JsonSerializer.Deserialize<List<ClipEntry>>(json) ?? new())
                    .Where(e => e?.Name != null && fileExists(e.Name)).Take(MaxCount).ToList();
        }
        catch (Exception) { idx.Entries = new(); }
        return idx;
    }
}
