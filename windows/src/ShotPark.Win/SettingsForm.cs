using Microsoft.Win32;
using ShotPark.Core;

namespace ShotPark.Win;

/// Settings window. Every change applies and saves immediately.
sealed class SettingsForm : Form
{
    readonly AppSettings _settings;
    readonly Func<HotKeySpec, bool> _applyHotKey;
    readonly Action<bool> _suspendHotKey;
    readonly TextBox _hotKey;
    readonly Label _hotKeyStatus;
    readonly Label _folder;

    static string L(string ko, string en) => Strings.L(ko, en);

    public SettingsForm(AppSettings settings, Func<HotKeySpec, bool> applyHotKey, Action<bool> suspendHotKey)
    {
        _settings = settings;
        _applyHotKey = applyHotKey;
        _suspendHotKey = suspendHotKey;

        Text = L("ShotPark 설정", "ShotPark Settings");
        Font = new Font(Strings.Korean ? "Malgun Gothic" : "Segoe UI", 9.5f);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(18, 16, 18, 14);
        BackColor = SystemColors.Window;
        Icon = TrayApp.AppIcon;

        var grid = new TableLayoutPanel
        {
            ColumnCount = 2,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Dock = DockStyle.Fill,
        };
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        Label Head(string t) => new()
        {
            Text = t, AutoSize = true, Anchor = AnchorStyles.Right | AnchorStyles.Top,
            Font = new Font(Font, FontStyle.Bold), Margin = new Padding(0, 9, 12, 0),
        };
        Label Hint(string t) => new()
        {
            Text = t, AutoSize = true, MaximumSize = new Size(420, 0), ForeColor = SystemColors.GrayText,
            Margin = new Padding(3, 0, 3, 10),
        };
        FlowLayoutPanel Row(params Control[] cs)
        {
            var f = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, 4, 0, 4) };
            f.Controls.AddRange(cs);
            return f;
        }

        // capture hotkey
        _hotKey = new TextBox
        {
            ReadOnly = true, Width = 190, TextAlign = HorizontalAlignment.Center, BackColor = SystemColors.Window,
            Text = settings.CaptureHotKey.Display, Cursor = Cursors.Hand, Margin = new Padding(3, 4, 8, 3),
        };
        _hotKey.GotFocus += (_, _) => { _suspendHotKey(true); _hotKey.Text = L("키 조합을 누르세요…", "Press a key combination…"); };
        _hotKey.LostFocus += (_, _) => { _suspendHotKey(false); _hotKey.Text = _settings.CaptureHotKey.Display; };
        _hotKey.PreviewKeyDown += (_, e) => e.IsInputKey = true;
        _hotKey.KeyDown += HotKeyDown;
        _hotKey.KeyUp += (_, e) => { if (e.KeyCode == Keys.PrintScreen) HotKeyDown(_hotKey, e); }; // PrtSc only arrives as KeyUp
        var reset = new Button { Text = L("기본값", "Default") + $" ({HotKeySpec.Default.Display})", AutoSize = true };
        reset.Click += (_, _) => SetHotKey(HotKeySpec.Default);
        _hotKeyStatus = new Label { AutoSize = true, ForeColor = Color.Firebrick, Margin = new Padding(3, 0, 3, 4) };

        grid.Controls.Add(Head(L("캡처 단축키", "Capture hotkey")), 0, 0);
        grid.Controls.Add(Row(_hotKey, reset), 1, 0);
        grid.Controls.Add(new Label(), 0, 1);
        var hotHints = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Margin = Padding.Empty };
        hotHints.Controls.Add(_hotKeyStatus);
        hotHints.Controls.Add(Hint(L("클릭한 뒤 원하는 키 조합을 누르세요. Ctrl / Alt / Win 중 하나가 포함되거나, PrtSc 또는 F 키여야 합니다.",
                                     "Click, then press the combination you want. It must include Ctrl / Alt / Win, or be PrtSc or an F key.")));
        grid.Controls.Add(hotHints, 1, 1);

        // save folder
        _folder = new Label { AutoSize = true, AutoEllipsis = true, MaximumSize = new Size(260, 0), Margin = new Padding(3, 8, 8, 3) };
        UpdateFolderLabel();
        var change = new Button { Text = L("변경…", "Change…"), AutoSize = true };
        change.Click += (_, _) => ChooseFolder();
        var open = new Button { Text = L("폴더 열기", "Open folder"), AutoSize = true };
        open.Click += (_, _) => TrayApp.OpenFolder(TrayApp.SaveFolder(_settings));
        grid.Controls.Add(Head(L("저장 폴더", "Save folder")), 0, 2);
        grid.Controls.Add(Row(_folder, change, open), 1, 2);

        CheckBox Check(string text, bool value, Action<bool> set)
        {
            var c = new CheckBox { Text = text, Checked = value, AutoSize = true, Margin = new Padding(3, 3, 3, 3) };
            c.CheckedChanged += (_, _) => { set(c.Checked); _settings.Save(); };
            return c;
        }
        var checks = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Margin = new Padding(0, 0, 0, 10) };
        checks.Controls.Add(Check(L("Ctrl+S 저장 시 확인 창 없이 지정 폴더에 바로 저장", "Ctrl+S saves straight to the folder, no dialog"), settings.SaveDirectly, v => settings.SaveDirectly = v));
        checks.Controls.Add(Check(L("Ctrl+S 저장할 때 클립보드에도 복사", "Ctrl+S also copies to the clipboard"), settings.SaveAlsoCopies, v => settings.SaveAlsoCopies = v));
        checks.Controls.Add(Check(L("Ctrl+C 복사할 때 저장 폴더에도 PNG 저장", "Ctrl+C also saves a PNG to the folder"), settings.CopyAlsoSaves, v => settings.CopyAlsoSaves = v));
        grid.Controls.Add(new Label(), 0, 3);
        grid.Controls.Add(checks, 1, 3);

        // startup
        grid.Controls.Add(Head(L("시작", "Startup")), 0, 4);
        var autostart = new CheckBox { Text = L("Windows에 로그인하면 자동 실행", "Start when I sign in to Windows"), Checked = AutoStart.Enabled, AutoSize = true, Margin = new Padding(3, 8, 3, 3) };
        autostart.CheckedChanged += (_, _) => AutoStart.Enabled = autostart.Checked;
        grid.Controls.Add(autostart, 1, 4);

        var footer = new Label
        {
            Text = L("변경 사항은 즉시 적용됩니다. 화면 언어는 Windows 표시 언어를 따릅니다.", "Changes apply immediately. The language follows your Windows display language."),
            AutoSize = true, ForeColor = SystemColors.GrayText, Margin = new Padding(0, 16, 0, 0),
        };
        grid.Controls.Add(footer, 0, 5);
        grid.SetColumnSpan(footer, 2);

        Controls.Add(grid);
        Shown += (_, _) => ActiveControl = null; // don't start in "recording" mode
    }

    void HotKeyDown(object? sender, KeyEventArgs e)
    {
        e.SuppressKeyPress = true;
        e.Handled = true;
        if (e.KeyCode == Keys.Escape) { ActiveControl = null; return; }
        var mods = Mods.None;
        if (e.Control) mods |= Mods.Ctrl;
        if (e.Alt) mods |= Mods.Alt;
        if (e.Shift) mods |= Mods.Shift;
        if (Native.IsKeyDown(0x5B) || Native.IsKeyDown(0x5C)) mods |= Mods.Win;
        var spec = new HotKeySpec(mods, (int)e.KeyCode);
        if (HotKeySpec.IsModifierKey((int)e.KeyCode)) { _hotKey.Text = spec.Display.Replace("+" + HotKeySpec.KeyName((int)e.KeyCode), "+…"); return; }
        if (!spec.IsValid)
        {
            _hotKeyStatus.Text = L("Ctrl / Alt / Win을 함께 누르거나 PrtSc·F 키를 쓰세요.", "Hold Ctrl / Alt / Win, or use PrtSc or an F key.");
            return;
        }
        SetHotKey(spec);
        ActiveControl = null;
    }

    void SetHotKey(HotKeySpec spec)
    {
        var previous = _settings.CaptureHotKey;
        _settings.CaptureHotKey = spec;
        if (_applyHotKey(spec))
        {
            _hotKeyStatus.Text = "";
            _settings.Save();
        }
        else
        {
            _settings.CaptureHotKey = previous;
            _applyHotKey(previous);
            _hotKeyStatus.Text = L($"{spec.Display}은(는) 다른 앱이 사용 중입니다.", $"{spec.Display} is already used by another app.");
        }
        _hotKey.Text = _settings.CaptureHotKey.Display;
    }

    void ChooseFolder()
    {
        using var dlg = new FolderBrowserDialog { SelectedPath = TrayApp.SaveFolder(_settings), ShowNewFolderButton = true };
        if (dlg.ShowDialog(this) != DialogResult.OK) return;
        _settings.SaveFolder = dlg.SelectedPath;
        _settings.Save();
        UpdateFolderLabel();
    }

    void UpdateFolderLabel()
    {
        var path = TrayApp.SaveFolder(_settings);
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        _folder.Text = path.StartsWith(home, StringComparison.OrdinalIgnoreCase) ? "~" + path[home.Length..] : path;
    }
}

/// "Start when I sign in": the per-user Run key.
static class AutoStart
{
    const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string Name = "ShotPark";

    public static bool Enabled
    {
        get
        {
            using var k = Registry.CurrentUser.OpenSubKey(Key);
            return k?.GetValue(Name) is string;
        }
        set
        {
            using var k = Registry.CurrentUser.CreateSubKey(Key);
            if (value) k.SetValue(Name, $"\"{Environment.ProcessPath}\"");
            else k.DeleteValue(Name, false);
        }
    }
}
