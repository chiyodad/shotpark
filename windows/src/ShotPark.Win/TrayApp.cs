using System.Diagnostics;
using System.Drawing.Imaging;
using System.Reflection;
using ShotPark.Core;

namespace ShotPark.Win;

/// Lives in the notification area: owns the hotkeys, the menu and the capture sessions.
sealed class TrayApp : ApplicationContext
{
    const int CaptureId = 0x5350, HistoryId = 0x5351;

    readonly AppSettings _settings;
    readonly NotifyIcon _tray;
    readonly HotKeyListener _hotKey = new();
    readonly ToolStripMenuItem _captureItem, _historyItem, _pinsItem, _updateItem, _autostartItem;
    readonly ClipboardHistory _history;
    readonly UpdateChecker _updates;
    OverlayForm? _overlay;
    SettingsForm? _settingsForm;
    ClipboardHistoryForm? _historyForm;

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
        Painter.InstallMetrics();
        _settings = AppSettings.Load(SettingsPath);
        _ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        if (showEvent != null)
            _showWait = ThreadPool.RegisterWaitForSingleObject(showEvent,
                (_, _) => _ui.Post(_ => ShowWelcome(alreadyRunning: true, conflict: null), null), null, Timeout.Infinite, false);

        _history = new ClipboardHistory(_settings);
        _updates = new UpdateChecker(_settings, _ui);

        _captureItem = new ToolStripMenuItem(L("영역 캡처", "Capture Region"), null, (_, _) => CaptureSoon()) { Font = new Font(SystemFonts.MenuFont!, FontStyle.Bold) };
        _historyItem = new ToolStripMenuItem(L("클립보드 이미지", "Clipboard Images"), null, (_, _) => ToggleHistory());
        _pinsItem = new ToolStripMenuItem("", null, (_, _) => PinForm.CloseAll()) { Visible = false };
        _updateItem = new ToolStripMenuItem("", null, (_, _) => UpdateChecker.OpenDownload()) { Visible = false, Font = new Font(SystemFonts.MenuFont!, FontStyle.Bold) };
        _autostartItem = new ToolStripMenuItem(L("로그인 시 자동 실행", "Start at Sign-in"), null, (_, _) => { AutoStart.Enabled = !AutoStart.Enabled; });
        var menu = new ContextMenuStrip();
        menu.Items.Add(_updateItem);
        menu.Items.Add(_captureItem);
        menu.Items.Add(_historyItem);
        menu.Items.Add(_pinsItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(L("설정…", "Settings…"), null, (_, _) => ShowSettings());
        menu.Items.Add(L("시작 안내", "Getting Started"), null, (_, _) => ShowWelcome(alreadyRunning: false, conflict: null));
        menu.Items.Add(L("저장 폴더 열기", "Open Save Folder"), null, (_, _) => OpenFolder(SaveFolder(_settings)));
        menu.Items.Add(_autostartItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(L("업데이트 확인…", "Check for Updates…"), null, (_, _) => _ = _updates.Check(userInitiated: true));
        menu.Items.Add(L("ShotPark 정보", "About ShotPark"), null, (_, _) => ShowAbout());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(L("ShotPark 종료", "Quit ShotPark"), null, (_, _) => Quit());
        menu.Opening += (_, _) => _autostartItem.Checked = AutoStart.Enabled;

        _tray = new NotifyIcon
        {
            Icon = AppIcon,
            Text = "ShotPark",
            ContextMenuStrip = menu,
            Visible = true,
        };
        _tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) CaptureSoon(); };

        PinForm.CountChanged += UpdatePinsItem;
        _updates.AvailabilityChanged += () =>
        {
            _updateItem.Visible = _updates.Available != null;
            _updateItem.Text = L($"⬆ ShotPark {_updates.Available} 업데이트 받기", $"⬆ Update to ShotPark {_updates.Available}");
        };

        _hotKey.Pressed += id =>
        {
            if (id == CaptureId) Capture();
            else if (id == HistoryId) ToggleHistory();
        };
        var registered = RegisterHotKey(_settings.CaptureHotKey);
        RegisterHistoryHotKey(_settings.HistoryHotKeySpec);
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
        Exporter.CleanTemp(TimeSpan.FromMinutes(10));
        _ui.Post(_ => _updates.CheckDailyIfNeeded(), null);
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
                   L($"• {hotkey} 키를 누르거나 트레이 아이콘을 클릭하면 캡처합니다. 드래그로 영역을, 클릭으로 창을 고르세요.\n" +
                     $"• 복사한 이미지는 {_settings.HistoryHotKeySpec.Display}로 다시 꺼낼 수 있습니다.\n" +
                     "• 아이콘이 안 보이면 작업 표시줄 오른쪽 ^ 안에 있습니다. 끌어서 작업 표시줄에 두면 늘 보입니다.\n" +
                     "• 트레이 아이콘을 우클릭하면 설정과 종료 메뉴가 나옵니다.",
                     $"• Press {hotkey} or click the tray icon to capture. Drag for a region, click for a window.\n" +
                     $"• {_settings.HistoryHotKeySpec.Display} brings back images you copied.\n" +
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
        var ok = _hotKey.Register(CaptureId, spec);
        _captureItem.ShortcutKeyDisplayString = ok ? spec.Display : "";
        _tray.Text = ok ? L($"ShotPark — {spec.Display}로 영역 캡처", $"ShotPark — {spec.Display} to capture") : "ShotPark";
        return ok;
    }

    bool RegisterHistoryHotKey(HotKeySpec spec)
    {
        var ok = _hotKey.Register(HistoryId, spec);
        _historyItem.ShortcutKeyDisplayString = ok ? spec.Display : "";
        return ok;
    }

    void UpdatePinsItem()
    {
        _pinsItem.Visible = PinForm.Count > 0;
        _pinsItem.Text = L($"고정한 캡처 모두 닫기 ({PinForm.Count})", $"Close All Pinned Captures ({PinForm.Count})");
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
        List<Native.WindowInfo> windows;
        try
        {
            windows = Native.VisibleWindows();
            shot = ScreenGrab.Capture(virt);
        }
        catch (Exception ex)
        {
            Toast.Show(L("화면을 캡처하지 못했습니다", "Couldn't capture the screen"), subtitle: ex.Message);
            return;
        }
        var monitors = Screen.AllScreens
            .Select(s => new RectangleF(s.Bounds.X - virt.X, s.Bounds.Y - virt.Y, s.Bounds.Width, s.Bounds.Height))
            .ToList();

        var scale = Native.GetDpiForSystem() / 96f;
        var overlay = new OverlayForm(shot, virt, monitors, scale, _settings, windows);
        overlay.Finished += (action, image, extra) => Finish(overlay, action, image, extra);
        overlay.FormClosed += (_, _) =>
        {
            _settings.Save();
            if (_overlay == overlay) _overlay = null;
            overlay.Dispose();
        };
        _overlay = overlay;
        overlay.Show();
    }

    void Finish(OverlayForm overlay, OverlayAction action, Bitmap? image, object? extra)
    {
        var area = Screen.FromPoint(Cursor.Position).WorkingArea;
        switch (action)
        {
            case OverlayAction.Close:
                overlay.Close();
                return;
            case OverlayAction.Copy when image != null:
                overlay.Close();
                if (Exporter.Copy(image))
                {
                    if (_settings.CopyAlsoSaves && SaveToFolder(image) is { } copied)
                        Toast.Show(L("복사됨 · 저장됨", "Copied · Saved"), () => RevealFile(copied), area, 2200, Path.GetFileName(copied) + L("  · 클릭하면 폴더에서 보기", "  · click to show in folder"));
                    else
                        Toast.Show(L("클립보드에 복사됨", "Copied to clipboard"), null, area);
                }
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
                    if (_settings.SaveAlsoCopies) Exporter.Copy(image);
                    Toast.Show(L("저장됨", "Saved"), () => RevealFile(path), area, 2200, Path.GetFileName(path) + L("  · 클릭하면 폴더에서 보기", "  · click to show in folder"));
                }
                image.Dispose();
                return;
            case OverlayAction.Share when image != null:
                if (extra is ShareTarget target)
                {
                    Exporter.Copy(image);
                    target.Open(); // while the overlay (ours) is still in front, so the app may take the focus
                    overlay.Close();
                    Toast.Show(L($"{target.Name}에서 Ctrl+V로 붙여넣으세요", $"Paste into {target.Name} with Ctrl+V"), null, area, 2600,
                        L("이미지가 클립보드에 복사되어 있습니다", "The image is on the clipboard"));
                }
                else
                {
                    overlay.Close();
                    if (Exporter.WriteTempPng(image) is { } tmp) Exporter.ShowShareSheet(tmp);
                }
                image.Dispose();
                return;
            case OverlayAction.Pin when image != null && extra is Rectangle r:
                overlay.Close();
                PinForm.Pin(image, r);
                return;
            case OverlayAction.Ocr when image != null:
                overlay.Close();
                _ = ExtractText(image, area);
                return;
        }
        image?.Dispose();
    }

    async Task ExtractText(Bitmap image, Rectangle area)
    {
        try
        {
            var codes = await Task.Run(() => TextRecognizer.Barcodes(image));
            if (codes.Count > 0)
            {
                // A QR code wins: its content is usually what you wanted.
                var payload = string.Join("\n", codes);
                Exporter.CopyText(payload);
                var url = Uri.TryCreate(codes[0], UriKind.Absolute, out var u) && (u.Scheme == "http" || u.Scheme == "https") ? u : null;
                Toast.Show(url != null ? L("QR 링크 복사됨 · 클릭하면 열기", "QR link copied · click to open") : L("QR 코드 내용 복사됨", "QR code content copied"),
                    url != null ? () => Process.Start(new ProcessStartInfo(url.ToString()) { UseShellExecute = true }) : null, area, 2600, codes[0]);
                return;
            }
            var text = await TextRecognizer.RecognizeAsync(image);
            if (text.Length == 0)
            {
                System.Media.SystemSounds.Beep.Play();
                Toast.Show(L("글자를 찾지 못했습니다", "No text found"), null, area, 1600,
                    L("Windows 설정 → 시간 및 언어에서 해당 언어 팩(광학 문자 인식)을 설치하면 인식할 수 있습니다", "Install the language (with optical character recognition) in Windows Settings → Time & language"));
                return;
            }
            Exporter.CopyText(text);
            var first = text.Split('\n')[0];
            Toast.Show(L($"텍스트 {text.Length}자 복사됨", $"Copied {text.Length} characters"), null, area, 2000, first);
        }
        catch (Exception ex)
        {
            Toast.Show(L("텍스트를 추출하지 못했습니다", "Couldn't extract text"), null, area, 2000, ex.Message);
        }
        finally { image.Dispose(); }
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
            Toast.Show(L("저장하지 못했습니다", "Couldn't save"), subtitle: ex.Message);
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
            Toast.Show(L("저장하지 못했습니다", "Couldn't save"), subtitle: ex.Message);
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

    void ToggleHistory()
    {
        if (_historyForm is { IsDisposed: false } f)
        {
            if (f.Visible && Form.ActiveForm == f) { f.Close(); return; }
            f.ShowCentered();
            return;
        }
        _historyForm = new ClipboardHistoryForm(_history);
        _historyForm.FormClosed += (_, _) => _historyForm = null;
        _historyForm.ShowCentered();
    }

    void ShowSettings()
    {
        if (_settingsForm is { IsDisposed: false })
        {
            _settingsForm.Activate();
            return;
        }
        _settingsForm = new SettingsForm(_settings, _history, RegisterHotKey, RegisterHistoryHotKey, suspend =>
        {
            if (suspend) { _hotKey.Unregister(CaptureId); _hotKey.Unregister(HistoryId); }
            else { RegisterHotKey(_settings.CaptureHotKey); RegisterHistoryHotKey(_settings.HistoryHotKeySpec); }
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
            Text = L("ShotPark을 사용해 주셔서 감사합니다!\n\n단축키 한 번으로 영역을 선택해 캡처하고, 바로 주석을 달아 복사·저장·공유하는 무료 오픈소스 캡처 도구입니다.\n\nMIT 라이선스 · Copyright © chiyodad",
                     "Thanks for using ShotPark!\n\nA free, open-source capture tool: one hotkey to select a region, annotate it on the spot, then copy, save or share.\n\nMIT license · Copyright © chiyodad"),
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
        PinForm.CloseAll();
        _tray.Visible = false;
        _hotKey.Dispose();
        _history.Dispose();
        _settings.Save();
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
