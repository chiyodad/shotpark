using System.Diagnostics;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using ShotPark.Core;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Streams;

namespace ShotPark.Win;

/// An app the Share menu can send the capture to: the image goes on the clipboard and the app comes
/// to the front (Windows apps don't take a dropped file reliably, so you paste with Ctrl+V).
sealed class ShareTarget
{
    public required string Name { get; init; }
    public string[] Exes { get; init; } = Array.Empty<string>();
    public string[] Processes { get; init; } = Array.Empty<string>();
    /// Microsoft Store package family-name prefixes.
    public string[] Packages { get; init; } = Array.Empty<string>();
    public string? Web { get; init; }

    public string? ExePath => Exes.Select(Environment.ExpandEnvironmentVariables).FirstOrDefault(File.Exists);

    public string? PackageFamily
    {
        get
        {
            if (Packages.Length == 0) return null;
            try
            {
                var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Packages");
                return Directory.Exists(root)
                    ? Directory.EnumerateDirectories(root).Select(Path.GetFileName)
                        .FirstOrDefault(d => d != null && Packages.Any(p => d.StartsWith(p, StringComparison.OrdinalIgnoreCase)))
                    : null;
            }
            catch (Exception) { return null; }
        }
    }

    Process? Running => Processes.SelectMany(p => { try { return Process.GetProcessesByName(p); } catch { return Array.Empty<Process>(); } })
        .FirstOrDefault(p => p.MainWindowHandle != IntPtr.Zero);

    public bool Installed => ExePath != null || PackageFamily != null || Running != null;

    Image? _icon;
    public Image? Icon
    {
        get
        {
            if (_icon != null) return _icon;
            try
            {
                var path = ExePath ?? Running?.MainModule?.FileName;
                if (path != null && System.Drawing.Icon.ExtractAssociatedIcon(path) is { } ic)
                {
                    using (ic) _icon = new Bitmap(ic.ToBitmap(), 16, 16);
                }
            }
            catch (Exception) { }
            return _icon;
        }
    }

    /// Brings the app to the front (or starts it, or opens the web app).
    public void Open()
    {
        try
        {
            if (Running is { } p)
            {
                var h = p.MainWindowHandle;
                if (Native.IsIconic(h)) Native.ShowWindow(h, 9 /* SW_RESTORE */);
                Native.SetForegroundWindow(h);
                return;
            }
            if (ExePath is { } exe) { Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true }); return; }
            if (PackageFamily is { } pfn && LaunchPackage(pfn)) return;
            if (Web != null) Process.Start(new ProcessStartInfo(Web) { UseShellExecute = true });
        }
        catch (Exception) { }
    }

    static bool LaunchPackage(string familyDir)
    {
        try
        {
            var pm = new Windows.Management.Deployment.PackageManager();
            var pkg = pm.FindPackagesForUser(string.Empty).FirstOrDefault(p => p.Id.FamilyName.Equals(familyDir, StringComparison.OrdinalIgnoreCase));
            var entry = pkg?.GetAppListEntriesAsync().AsTask().GetAwaiter().GetResult().FirstOrDefault();
            if (entry == null) return false;
            _ = entry.LaunchAsync();
            return true;
        }
        catch (Exception) { return false; }
    }
}

static class ShareTargets
{
    public static readonly ShareTarget[] All =
    {
        new() { Name = "Claude", Exes = new[] { @"%LOCALAPPDATA%\AnthropicClaude\claude.exe", @"%LOCALAPPDATA%\Programs\Claude\Claude.exe" },
                Processes = new[] { "claude" }, Packages = new[] { "Claude_", "Anthropic" } },
        new() { Name = "ChatGPT", Processes = new[] { "ChatGPT" }, Packages = new[] { "OpenAI.ChatGPT" }, Web = "https://chatgpt.com/" },
        new() { Name = "Gemini", Web = "https://gemini.google.com/app" },
        new() { Name = "Slack", Exes = new[] { @"%LOCALAPPDATA%\slack\slack.exe", @"%ProgramFiles%\Slack\slack.exe" },
                Processes = new[] { "slack" }, Packages = new[] { "91750D7E.Slack" } },
        new() { Name = Strings.L("카카오톡", "KakaoTalk"), Exes = new[] { @"%ProgramFiles(x86)%\Kakao\KakaoTalk\KakaoTalk.exe", @"%ProgramFiles%\Kakao\KakaoTalk\KakaoTalk.exe" },
                Processes = new[] { "KakaoTalk" } },
    };

    /// Installed apps plus the ones with a web app (ChatGPT, Gemini).
    public static IEnumerable<ShareTarget> Available() => All.Where(t => t.Installed || t.Web != null);
}

/// Clipboard, files and the Windows share sheet.
static class Exporter
{
    static string L(string ko, string en) => Strings.L(ko, en);

    /// PNG (keeps transparency, read by browsers, Office, Slack…) plus a bitmap flattened on white
    /// for apps that only read CF_BITMAP. Returns false (after a toast) when the clipboard is busy.
    public static bool Copy(Bitmap image)
    {
        try
        {
            var data = new System.Windows.Forms.DataObject();
            using var flat = new Bitmap(image.Width, image.Height, PixelFormat.Format24bppRgb);
            using (var g = Graphics.FromImage(flat))
            {
                g.Clear(Color.White);
                g.DrawImageUnscaled(image, 0, 0);
            }
            data.SetData(DataFormats.Bitmap, true, new Bitmap(flat));
            var png = new MemoryStream();
            image.Save(png, ImageFormat.Png);
            data.SetData("PNG", false, png);
            System.Windows.Forms.Clipboard.SetDataObject(data, true, 5, 100);
            return true;
        }
        catch (Exception ex)
        {
            Toast.Show(L("클립보드에 복사하지 못했습니다", "Couldn't copy to the clipboard"), subtitle: ex.Message);
            return false;
        }
    }

    public static void CopyText(string text)
    {
        try { System.Windows.Forms.Clipboard.SetText(text); } catch (Exception) { }
    }

    public static string TempDir => Path.Combine(Path.GetTempPath(), "ShotPark");

    /// Screen content handed to other apps lives here briefly; CleanTemp removes leftovers.
    public static string? WriteTempPng(Bitmap image)
    {
        try
        {
            Directory.CreateDirectory(TempDir);
            var path = FileNames.Unique(TempDir, DateTime.Now, File.Exists);
            image.Save(path, ImageFormat.Png);
            return path;
        }
        catch (Exception) { return null; }
    }

    public static void CleanTemp(TimeSpan olderThan)
    {
        try
        {
            if (!Directory.Exists(TempDir)) return;
            foreach (var f in new DirectoryInfo(TempDir).GetFiles())
                if (DateTime.Now - f.LastWriteTime > olderThan) f.Delete();
        }
        catch (Exception) { }
    }

    // ───────────────────────── Windows share sheet ─────────────────────────

    [ComImport, Guid("3A3DCD6C-3EAB-43DC-BCDE-45671CE800C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDataTransferManagerInterop
    {
        IntPtr GetForWindow(IntPtr appWindow, ref Guid riid);
        void ShowShareUIForWindow(IntPtr appWindow);
    }

    static Guid _dtmIid = new("a5caee9b-8708-49d1-8d36-67d25a8da00c");

    /// Shows the Windows share sheet (Mail, Nearby sharing, Phone Link…) for a PNG file.
    public static void ShowShareSheet(string path)
    {
        // The sheet needs a real window to belong to: a tiny invisible one at the pointer.
        var host = new Form
        {
            FormBorderStyle = FormBorderStyle.None, ShowInTaskbar = false, StartPosition = FormStartPosition.Manual,
            Bounds = new Rectangle(Cursor.Position, new Size(1, 1)), Opacity = 0.01, TopMost = true,
        };
        host.Show();
        try
        {
            var interop = DataTransferManager.As<IDataTransferManagerInterop>();
            var ptr = interop.GetForWindow(host.Handle, ref _dtmIid);
            var dtm = WinRT.MarshalInterface<DataTransferManager>.FromAbi(ptr);
            dtm.DataRequested += async (_, e) =>
            {
                var deferral = e.Request.GetDeferral();
                try
                {
                    var file = await StorageFile.GetFileFromPathAsync(path);
                    e.Request.Data.Properties.Title = "ShotPark";
                    e.Request.Data.Properties.Description = Path.GetFileName(path);
                    e.Request.Data.SetStorageItems(new IStorageItem[] { file });
                    e.Request.Data.SetBitmap(RandomAccessStreamReference.CreateFromFile(file));
                }
                finally { deferral.Complete(); }
            };
            interop.ShowShareUIForWindow(host.Handle);
        }
        catch (Exception ex)
        {
            Toast.Show(L("Windows 공유를 열지 못했습니다", "Couldn't open Windows sharing"), subtitle: ex.Message);
        }
        // the sheet keeps its own reference; the host only has to outlive the request
        var t = new System.Windows.Forms.Timer { Interval = 120_000 };
        t.Tick += (_, _) => { t.Dispose(); host.Close(); host.Dispose(); };
        t.Start();
    }
}
