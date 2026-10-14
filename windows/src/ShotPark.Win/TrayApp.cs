using System.Diagnostics;
using System.Drawing.Imaging;
using System.Reflection;
using ShotPark.Core;

namespace ShotPark.Win;

/// Lives in the notification area: owns the hotkey, the menu and the capture sessions.
sealed class TrayApp : ApplicationContext
{
    readonly AppSettings _settings;
    readonly NotifyIcon _tray;
    readonly HotKeyListener _hotKey = new();
    readonly ToolStripMenuItem _captureItem;
    OverlayForm? _overlay;
    SettingsForm? _settingsForm;

    static string L(string ko, string en) => Strings.L(ko, en);

    public static Icon AppIcon { get; } = LoadIcon();

    static Icon LoadIcon()
    {
        using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("ShotPark.ico");
        return s != null ? new Icon(s) : SystemIcons.Application;
    }

    public static string SettingsPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ShotPark", "settings.json");

    public static string SaveFolder(AppSettings s) =>
        s.ResolvedSaveFolder(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures));

    public static string Version =>
        Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "0";

    /// Signalled by a second launch (Start menu / desktop shortcut while already running).
    public const string ShowEventName = @"Local\ShotPark.Show";
    readonly SynchronizationContext _ui;
    RegisteredWaitHandle? _showWait;

    public TrayApp(EventWaitHandle? showEvent = null)
    {
        _settings = AppSettings.Load(SettingsPath);
        _ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        if (showEvent != null)
            _showWait = ThreadPool.RegisterWaitForSingleObject(showEvent,
                (_, _) => _ui.Post(_ => ShowWelcome(alreadyRunning: true, conflict: null), null), null, Timeout.Infinite, false);

        _captureItem = new ToolStripMenuItem(L("영역 캡처", "Capture Region"), null, (_, _) => CaptureSoon()) { Font = new Font(SystemFonts.MenuFont!, FontStyle.Bold) };
        var menu = new ContextMenuStrip();
        menu.Items.Add(_captureItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(L("설정…", "Settings…"), null, (_, _) => ShowSettings());
        menu.Items.Add(L("저장 폴더 열기", "Open Save Folder"), null, (_, _) => OpenFolder(SaveFolder(_settings)));
        menu.Items.Add(L("ShotPark 정보", "About ShotPark"), null, (_, _) => ShowAbout());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(L("ShotPark 종료", "Quit ShotPark"), null, (_, _) => Quit());

        _tray = new NotifyIcon
        {
            Icon = AppIcon,
            Text = "ShotPark",
            ContextMenuStrip = menu,
            Visible = true,
        };
        _tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) CaptureSoon(); };

        _hotKey.Pressed += Capture;
        var registered = RegisterHotKey(_settings.CaptureHotKey);
        var conflict = registered ? null
            : L($"다른 앱이 이미 {_settings.CaptureHotKey.Display} 단축키를 사용 중입니다. 설정에서 다른 조합으로 바꿔 주세요.",
                $"{_settings.CaptureHotKey.Display} is already used by another app. Choose another combination in Settings.");
        // A balloon is easy to miss (Focus Assist, hidden tray icon), so the first run — or a hotkey
        // conflict — gets a real window once the message loop is running.
        if (!_settings.WelcomeShown || conflict != null)
        {
            _ui.Post(_ => ShowWelcome(alreadyRunning: false, conflict), null);
            _settings.WelcomeShown = true;
            _settings.Save();
        }
    }

    void ShowWelcome(bool alreadyRunning, string? conflict)
    {
        var hotkey = _settings.CaptureHotKey.Display;
        var settingsButton = new TaskDialogButton(L("설정 열기", "Open Settings"));
        var page = new TaskDialogPage
        {
            Caption = "ShotPark",
            Heading = alreadyRunning ? L("ShotPark이 이미 실행 중입니다", "ShotPark is already running")
                                     : L("ShotPark이 트레이에서 실행 중입니다", "ShotPark is running in the tray"),
            Text = (conflict != null ? conflict + "\n\n" : "") +
                   L($"• {hotkey} 키를 누르거나 트레이 아이콘을 클릭하면 캡처합니다.\n" +
                     "• 아이콘이 안 보이면 작업 표시줄 오른쪽 ^ 안에 있습니다. 끌어서 작업 표시줄에 두면 늘 보입니다.\n" +
                     "• 트레이 아이콘을 우클릭하면 설정과 종료 메뉴가 나옵니다.",
                     $"• Press {hotkey} or click the tray icon to capture.\n" +
                     "• Can't see the icon? It's under the ^ at the right of the taskbar — drag it onto the taskbar to keep it visible.\n" +
                     "• Right-click the tray icon for Settings and Quit."),
            Icon = new TaskDialogIcon(AppIcon),
            Buttons = { settingsButton, TaskDialogButton.OK },
            DefaultButton = conflict != null ? settingsButton : TaskDialogButton.OK,
        };
        if (TaskDialog.ShowDialog(page) == settingsButton) ShowSettings();
    }

    bool RegisterHotKey(HotKeySpec spec)
    {
        var ok = _hotKey.Register(spec);
        _captureItem.ShortcutKeyDisplayString = ok ? spec.Display : "";
        return ok;
    }

    // ───────────────────────── capture ─────────────────────────

    /// From the tray menu / icon: wait for the menu to fade so it isn't in the screenshot.
    void CaptureSoon()
    {
        var t = new System.Windows.Forms.Timer { Interval = 250 };
        t.Tick += (_, _) => { t.Stop(); t.Dispose(); Capture(); };
        t.Start();
    }

    public void Capture()
    {
        if (_overlay != null)
        {
            _overlay.Activate();
            return;
        }
        var virt = SystemInformation.VirtualScreen;
        Bitmap shot;
        try
        {
            shot = ScreenGrab.Capture(virt);
        }
        catch (Exception ex)
        {
            Toast.Show(L("화면을 캡처하지 못했습니다: ", "Couldn't capture the screen: ") + ex.Message);
            return;
        }
        var monitors = Screen.AllScreens
            .Select(s => new RectangleF(s.Bounds.X - virt.X, s.Bounds.Y - virt.Y, s.Bounds.Width, s.Bounds.Height))
            .ToList();
        var scale = Native.GetDpiForSystem() / 96f;
        var overlay = new OverlayForm(shot, virt, monitors, scale, _settings);
        overlay.Finished += (action, image) => Finish(overlay, action, image);
        overlay.FormClosed += (_, _) =>
        {
            _settings.ColorIndex = overlay.Controller.ColorIndex;
            _settings.WidthIndex = overlay.Controller.WidthIndex;
            _settings.Save();
            if (_overlay == overlay) _overlay = null;
            overlay.Dispose();
        };
        _overlay = overlay;
        overlay.Show();
    }

    void Finish(OverlayForm overlay, OverlayAction action, Bitmap? image)
    {
        var area = Screen.FromPoint(Cursor.Position).WorkingArea;
        switch (action)
        {
            case OverlayAction.Close:
                overlay.Close();
                return;
            case OverlayAction.Copy when image != null:
                overlay.Close();
                CopyToClipboard(image);
                if (_settings.CopyAlsoSaves && SaveToFolder(image) is { } copied)
                    Toast.Show(L("복사됨 · 저장됨 · ", "Copied · Saved · ") + Path.GetFileName(copied), () => RevealFile(copied), area);
                else
                    Toast.Show(L("클립보드에 복사됨", "Copied to clipboard"), null, area);
                image.Dispose();
                return;
            case OverlayAction.Save when image != null:
                string? path;
                if (_settings.SaveDirectly)
                {
                    overlay.Close();
                    path = SaveToFolder(image);
                }
                else
                {
                    overlay.Hide();
                    path = AskWhereToSave(image);
                    if (path == null)
                    {
                        overlay.Show(); // cancelled: back to editing
                        image.Dispose();
                        return;
                    }
                    overlay.Close();
                }
                if (path != null)
                {
                    if (_settings.SaveAlsoCopies) CopyToClipboard(image);
                    Toast.Show(L("저장됨 · ", "Saved · ") + Path.GetFileName(path) + L("  · 클릭하면 폴더에서 보기", "  · click to show in folder"), () => RevealFile(path), area);
                }
                image.Dispose();
                return;
        }
    }

    static void CopyToClipboard(Bitmap image)
    {
        try
        {
            var data = new DataObject();
            data.SetData(DataFormats.Bitmap, true, image);
            var png = new MemoryStream();
            image.Save(png, ImageFormat.Png);
            data.SetData("PNG", false, png); // keeps quality in apps that read PNG (Office, browsers, Slack)
            Clipboard.SetDataObject(data, true, 5, 100);
        }
        catch (Exception ex)
        {
            Toast.Show(L("클립보드에 복사하지 못했습니다: ", "Couldn't copy: ") + ex.Message);
        }
    }

    string? SaveToFolder(Bitmap image)
    {
        try
        {
            var folder = SaveFolder(_settings);
            Directory.CreateDirectory(folder);
            var path = FileNames.Unique(folder, DateTime.Now, File.Exists);
            image.Save(path, ImageFormat.Png);
            return path;
        }
        catch (Exception ex)
        {
            Toast.Show(L("저장하지 못했습니다: ", "Couldn't save: ") + ex.Message);
            return null;
        }
    }

    string? AskWhereToSave(Bitmap image)
    {
        using var dlg = new SaveFileDialog
        {
            Filter = "PNG (*.png)|*.png",
            FileName = FileNames.ForCapture(DateTime.Now),
            InitialDirectory = SaveFolder(_settings),
            AddExtension = true,
        };
        if (dlg.ShowDialog() != DialogResult.OK) return null;
        try
        {
            image.Save(dlg.FileName, ImageFormat.Png);
            return dlg.FileName;
        }
        catch (Exception ex)
        {
            Toast.Show(L("저장하지 못했습니다: ", "Couldn't save: ") + ex.Message);
            return null;
        }
    }

    public static void RevealFile(string path) =>
        Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });

    public static void OpenFolder(string path)
    {
        Directory.CreateDirectory(path);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
    }

    // ───────────────────────── windows ─────────────────────────

    void ShowSettings()
    {
        if (_settingsForm is { IsDisposed: false })
        {
            _settingsForm.Activate();
            return;
        }
        _settingsForm = new SettingsForm(_settings, RegisterHotKey, suspend =>
        {
            if (suspend) _hotKey.Unregister();
            else RegisterHotKey(_settings.CaptureHotKey);
        });
        _settingsForm.FormClosed += (_, _) => _settingsForm = null;
        _settingsForm.Show();
        _settingsForm.Activate();
    }

    static void ShowAbout()
    {
        var site = new TaskDialogButton(L("웹사이트 열기", "Open website"));
        var page = new TaskDialogPage
        {
            Caption = L("ShotPark 정보", "About ShotPark"),
            Heading = $"ShotPark {Version}",
            Text = L("ShotPark을 사용해 주셔서 감사합니다!\n\n단축키 한 번으로 영역을 선택해 캡처하고, 바로 주석을 달아 복사·저장하는 무료 오픈소스 캡처 도구입니다.\n\nMIT 라이선스 · Copyright © chiyodad",
                     "Thanks for using ShotPark!\n\nA free, open-source capture tool: one hotkey to select a region, annotate it on the spot, then copy or save.\n\nMIT license · Copyright © chiyodad"),
            Icon = new TaskDialogIcon(AppIcon),
            Buttons = { site, TaskDialogButton.OK },
        };
        if (TaskDialog.ShowDialog(page) == site)
            Process.Start(new ProcessStartInfo("https://shotpark.site") { UseShellExecute = true });
    }

    void Quit()
    {
        _showWait?.Unregister(null);
        _overlay?.Close();
        _tray.Visible = false;
        _hotKey.Dispose();
        ExitThread();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _tray.Dispose();
            _hotKey.Dispose();
        }
        base.Dispose(disposing);
    }
}
