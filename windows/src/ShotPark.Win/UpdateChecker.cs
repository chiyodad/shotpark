using System.Diagnostics;
using System.Net.Http;
using System.Text.Json;
using ShotPark.Core;

namespace ShotPark.Win;

/// A lightweight update check against GitHub Releases: at most once a day automatically,
/// or on demand from the tray menu. Updating means running the new installer.
sealed class UpdateChecker
{
    const string Api = "https://api.github.com/repos/chiyodad/shotpark/releases/latest";
    public const string SetupUrl = "https://github.com/chiyodad/shotpark/releases/latest/download/ShotPark-Windows-Setup.exe";
    public const string ReleasesUrl = "https://github.com/chiyodad/shotpark/releases/latest";

    readonly AppSettings _settings;
    readonly SynchronizationContext _ui;

    /// A newer version than the running one, or null.
    public string? Available { get; private set; }
    public event Action? AvailabilityChanged;

    static string L(string ko, string en) => Strings.L(ko, en);

    public UpdateChecker(AppSettings settings, SynchronizationContext ui)
    {
        _settings = settings;
        _ui = ui;
    }

    public void CheckDailyIfNeeded()
    {
        if (Versions.IsNewer(_settings.UpdateLatest, TrayApp.Version) && Available == null)
        {
            Available = _settings.UpdateLatest;
            AvailabilityChanged?.Invoke();
        }
        if (DateTimeOffset.UtcNow.ToUnixTimeSeconds() - _settings.UpdateLastCheck > 24 * 3600) _ = Check(userInitiated: false);
    }

    public async Task Check(bool userInitiated)
    {
        string? found = null;
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd($"ShotPark-Windows/{TrayApp.Version}");
            http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
            var json = await http.GetStringAsync(Api);
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.TryGetProperty("tag_name", out var tag)) found = tag.GetString()?.TrimStart('v');
        }
        catch (Exception) { }

        _ui.Post(_ =>
        {
            _settings.UpdateLastCheck = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            if (found != null)
            {
                _settings.UpdateLatest = found;
                Available = Versions.IsNewer(found, TrayApp.Version) ? found : null;
                AvailabilityChanged?.Invoke();
            }
            _settings.Save();
            if (!userInitiated) return;
            if (found != null && Available != null)
            {
                var get = new TaskDialogButton(L("설치 프로그램 받기", "Download installer"));
                var page = new TaskDialogPage
                {
                    Caption = "ShotPark",
                    Heading = L($"ShotPark {found} 업데이트가 있습니다", $"ShotPark {found} is available"),
                    Text = L($"현재 버전은 {TrayApp.Version}입니다. 새 설치 프로그램을 실행하면 설정은 그대로 두고 업데이트됩니다.",
                             $"You're on {TrayApp.Version}. Run the new installer to update; your settings are kept."),
                    Icon = new TaskDialogIcon(TrayApp.AppIcon),
                    Buttons = { get, new TaskDialogButton(L("나중에", "Later")) },
                };
                if (TaskDialog.ShowDialog(page) == get) OpenDownload();
            }
            else
            {
                TaskDialog.ShowDialog(new TaskDialogPage
                {
                    Caption = "ShotPark",
                    Heading = found != null ? L("최신 버전입니다", "You're up to date") : L("업데이트를 확인하지 못했습니다", "Couldn't check for updates"),
                    Text = found != null ? L($"ShotPark {TrayApp.Version}이 최신 버전입니다.", $"ShotPark {TrayApp.Version} is the latest version.")
                                         : L("인터넷 연결을 확인한 뒤 다시 시도해 주세요.", "Check your internet connection and try again."),
                    Icon = new TaskDialogIcon(TrayApp.AppIcon),
                    Buttons = { TaskDialogButton.OK },
                });
            }
        }, null);
    }

    public static void OpenDownload() => Process.Start(new ProcessStartInfo(SetupUrl) { UseShellExecute = true });
}
