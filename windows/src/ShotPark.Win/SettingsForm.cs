using Microsoft.Win32;
using ShotPark.Core;

namespace ShotPark.Win;

/// Settings window, same sections as the Mac app. Every change applies and saves immediately.
sealed class SettingsForm : Form
{
    readonly AppSettings _settings;
    readonly ClipboardHistory? _history;
    readonly Label _folder;
    readonly Button[] _swatches = new Button[Palette.Default.Length];

    static string L(string ko, string en) => Strings.L(ko, en);

    public SettingsForm(AppSettings settings, ClipboardHistory? history, Func<HotKeySpec, bool> applyHotKey, Func<HotKeySpec, bool> applyHistoryKey, Action<bool> suspendHotKeys)
    {
        _settings = settings;
        _history = history;

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
        var row = 0;

        Label Head(string t) => new()
        {
            Text = t, AutoSize = true, Anchor = AnchorStyles.Right | AnchorStyles.Top,
            Font = new Font(Font, FontStyle.Bold), Margin = new Padding(0, 9, 12, 0),
        };
        Label Hint(string t) => new()
        {
            Text = t, AutoSize = true, MaximumSize = new Size(470, 0), ForeColor = SystemColors.GrayText,
            Margin = new Padding(3, 0, 3, 10),
        };
        FlowLayoutPanel Row(params Control[] cs)
        {
            var f = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, 4, 0, 4) };
            f.Controls.AddRange(cs);
            return f;
        }
        void Add(string? head, Control c)
        {
            grid.Controls.Add(head != null ? Head(head) : new Label { AutoSize = true }, 0, row);
            grid.Controls.Add(c, 1, row);
            row++;
        }
        CheckBox Check(string text, bool value, Action<bool> set)
        {
            var c = new CheckBox { Text = text, Checked = value, AutoSize = true, Margin = new Padding(3, 3, 3, 3) };
            c.CheckedChanged += (_, _) => { set(c.Checked); _settings.Save(); };
            return c;
        }

        // ── hotkeys
        var capture = new HotKeyBox(settings.CaptureHotKey, HotKeySpec.Default, inCapture: false, suspendHotKeys, spec =>
        {
            var previous = settings.CaptureHotKey;
            settings.CaptureHotKey = spec;
            if (applyHotKey(spec)) { settings.Save(); return null; }
            settings.CaptureHotKey = previous;
            applyHotKey(previous);
            return L($"{spec.Display} 단축키는 다른 앱이 사용 중입니다.", $"{spec.Display} is already used by another app.");
        });
        Add(L("캡처 단축키", "Capture hotkey"), capture);
        Add(null, Hint(L("클릭한 뒤 원하는 키 조합을 누르세요. Ctrl / Alt / Win 중 하나가 포함되거나, PrtSc 또는 F 키여야 합니다. Windows 11에서 PrtSc를 쓰려면 설정 → 접근성 → 키보드에서 \"Print Screen 키를 사용하여 화면 캡처 열기\"를 끄세요.",
                         "Click, then press the combination you want. It must include Ctrl / Alt / Win, or be PrtSc or an F key. To use PrtSc on Windows 11, turn off \"Use the Print screen key to open screen capture\" in Settings → Accessibility → Keyboard.")));

        var historyKey = new HotKeyBox(settings.HistoryHotKeySpec, HotKeySpec.DefaultHistory, inCapture: false, suspendHotKeys, spec =>
        {
            var previous = settings.HistoryHotKeySpec;
            settings.HistoryHotKeySpec = spec;
            if (applyHistoryKey(spec)) { settings.Save(); return null; }
            settings.HistoryHotKeySpec = previous;
            applyHistoryKey(previous);
            return L($"{spec.Display} 단축키는 다른 앱이 사용 중입니다.", $"{spec.Display} is already used by another app.");
        }, L("어디서나", "anywhere"));
        Add(L("클립보드 이미지", "Clipboard images"), historyKey);

        HotKeyBox CaptureKey(Func<HotKeySpec> get, Action<HotKeySpec> set, HotKeySpec def) =>
            new(get(), def, inCapture: true, _ => { }, spec => { set(spec); settings.Save(); return null; }, L("캡처 중", "during a capture"));
        Add(L("모자이크", "Mosaic / blur"), CaptureKey(() => settings.MosaicKeySpec, s => settings.MosaicKeySpec = s, HotKeySpec.DefaultMosaic));
        Add(L("텍스트 추출", "Extract text"), CaptureKey(() => settings.OcrKeySpec, s => settings.OcrKeySpec = s, HotKeySpec.DefaultOcr));
        Add(L("화면에 고정", "Pin to screen"), CaptureKey(() => settings.PinKeySpec, s => settings.PinKeySpec = s, HotKeySpec.DefaultPin));
        Add(null, Hint(L("모자이크·텍스트 추출·화면에 고정은 캡처 중에만 쓰므로 B 같은 단일 키도 됩니다.", "Mosaic, Extract text and Pin only work during a capture, so a single key like B is fine.")));

        // ── save folder
        _folder = new Label { AutoSize = true, AutoEllipsis = true, MaximumSize = new Size(300, 0), Margin = new Padding(3, 8, 8, 3) };
        UpdateFolderLabel();
        var change = new Button { Text = L("변경…", "Change…"), AutoSize = true };
        change.Click += (_, _) => ChooseFolder();
        var open = new Button { Text = L("폴더 열기", "Open folder"), AutoSize = true };
        open.Click += (_, _) => TrayApp.OpenFolder(TrayApp.SaveFolder(_settings));
        Add(L("저장 폴더", "Save folder"), Row(_folder, change, open));

        var checks = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Margin = new Padding(0, 0, 0, 10) };
        checks.Controls.Add(Check(L("Ctrl+S 저장 시 확인 창 없이 지정 폴더에 바로 저장", "Ctrl+S saves straight to the folder, no dialog"), settings.SaveDirectly, v => settings.SaveDirectly = v));
        checks.Controls.Add(Check(L("Ctrl+S 저장할 때 클립보드에도 복사", "Ctrl+S also copies to the clipboard"), settings.SaveAlsoCopies, v => settings.SaveAlsoCopies = v));
        checks.Controls.Add(Check(L("Ctrl+C 복사할 때 저장 폴더에도 PNG 저장", "Ctrl+C also saves a PNG to the folder"), settings.CopyAlsoSaves, v => settings.CopyAlsoSaves = v));
        Add(null, checks);

        // ── palette
        var palette = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, 4, 0, 0) };
        for (var i = 0; i < _swatches.Length; i++)
        {
            var idx = i;
            var b = new Button { Size = new Size(26, 26), FlatStyle = FlatStyle.Flat, Margin = new Padding(2), Cursor = Cursors.Hand };
            b.FlatAppearance.BorderColor = Color.FromArgb(150, 150, 150);
            b.Click += (_, _) => PickColor(idx);
            _swatches[i] = b;
            palette.Controls.Add(b);
        }
        var paletteReset = new Button { Text = L("기본값", "Default"), AutoSize = true, Margin = new Padding(10, 2, 2, 2) };
        paletteReset.Click += (_, _) => { _settings.Palette = new(); _settings.Save(); UpdateSwatches(); };
        palette.Controls.Add(paletteReset);
        UpdateSwatches();
        Add(L("주석 색상", "Palette"), palette);
        Add(null, Hint(L("캡처 화면의 색상 팔레트에 보이는 10가지 색입니다. 클릭해서 원하는 색으로 바꾸면 바로 저장됩니다.", "The 10 colors shown in the capture palette. Click one to change it; it's saved immediately.")));

        // ── beautify
        Add(L("꾸미기", "Beautify"), Row(
            Check(L("그림자", "Shadow"), settings.BeautifyShadow, v => settings.BeautifyShadow = v),
            Check(L("둥근 모서리", "Rounded corners"), settings.BeautifyRounded, v => settings.BeautifyRounded = v)));
        Add(null, Hint(L("캡처 툴바의 꾸미기(마술봉) 버튼으로 켜고 끕니다. 켜면 복사·저장·공유하는 이미지에 10pt 여백과 그림자·둥근 모서리가 적용됩니다.",
                         "Turn it on or off with the Beautify (magic wand) button in the capture toolbar; copy, save and share then get a 10 pt margin with a shadow and rounded corners.")));

        // ── clipboard history
        var historyOn = new CheckBox { Text = L("복사한 이미지 기록 (최근 30개)", "Keep copied images (last 30)"), Checked = settings.ClipboardHistory, AutoSize = true, Margin = new Padding(3, 6, 12, 3) };
        historyOn.CheckedChanged += (_, _) => { if (_history != null) _history.SetEnabled(historyOn.Checked); else { settings.ClipboardHistory = historyOn.Checked; settings.Save(); } };
        var clear = new Button { Text = L("기록 지우기", "Clear"), AutoSize = true };
        clear.Click += (_, _) =>
        {
            _history?.Clear();
            Toast.Show(L("클립보드 이미지 기록을 지웠습니다", "Clipboard image history cleared"), null, null, 1400);
        };
        Add(L("클립보드", "Clipboard"), Row(historyOn, clear));
        Add(null, Hint(L("다른 앱에서 복사한 이미지도 포함되며, 이 PC에만 저장됩니다. 비밀번호 관리자처럼 기록 제외로 표시된 항목은 기록하지 않습니다.",
                         "Includes images copied in other apps; stored only on this PC. Items marked as excluded from history (e.g. by password managers) are skipped.")));

        // ── startup
        var autostart = new CheckBox { Text = L("Windows에 로그인하면 자동 실행", "Start when I sign in to Windows"), Checked = AutoStart.Enabled, AutoSize = true, Margin = new Padding(3, 8, 3, 3) };
        autostart.CheckedChanged += (_, _) => AutoStart.Enabled = autostart.Checked;
        Add(L("시작", "Startup"), autostart);

        var footer = new Label
        {
            Text = L("변경 사항은 즉시 적용됩니다. 화면 언어는 Windows 표시 언어를 따릅니다.", "Changes apply immediately. The language follows your Windows display language."),
            AutoSize = true, ForeColor = SystemColors.GrayText, Margin = new Padding(0, 16, 0, 0),
        };
        grid.Controls.Add(footer, 0, row);
        grid.SetColumnSpan(footer, 2);

        Controls.Add(grid);
        Shown += (_, _) => ActiveControl = null; // don't start in "recording" mode
    }

    void UpdateSwatches()
    {
        var colors = _settings.Colors;
        for (var i = 0; i < _swatches.Length; i++)
        {
            _swatches[i].BackColor = colors[i];
            _swatches[i].FlatAppearance.MouseOverBackColor = colors[i];
        }
    }

    void PickColor(int i)
    {
        var colors = _settings.Colors;
        using var dlg = new ColorDialog { Color = colors[i], FullOpen = true, AnyColor = true };
        if (dlg.ShowDialog(this) != DialogResult.OK) return;
        colors[i] = Color.FromArgb(255, dlg.Color);
        _settings.Colors = colors;
        _settings.Save();
        UpdateSwatches();
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
        _folder.Text = TrayApp.SaveFolder(_settings);
    }
}

/// Click, then press a key combination. `apply` returns an error message, or null when it took.
sealed class HotKeyBox : FlowLayoutPanel
{
    readonly TextBox _box;
    readonly Label _status;
    readonly bool _inCapture;
    readonly Func<HotKeySpec, string?> _apply;
    readonly Action<bool> _suspend;
    HotKeySpec _spec;

    static string L(string ko, string en) => Strings.L(ko, en);

    public HotKeyBox(HotKeySpec current, HotKeySpec def, bool inCapture, Action<bool> suspend, Func<HotKeySpec, string?> apply, string? note = null)
    {
        _spec = current;
        _inCapture = inCapture;
        _apply = apply;
        _suspend = suspend;
        AutoSize = true;
        WrapContents = true;
        FlowDirection = FlowDirection.LeftToRight;
        MaximumSize = new Size(520, 0);
        Margin = new Padding(0, 4, 0, 2);

        _box = new TextBox
        {
            ReadOnly = true, Width = 170, TextAlign = HorizontalAlignment.Center, BackColor = SystemColors.Window,
            Text = current.Display, Cursor = Cursors.Hand, Margin = new Padding(3, 4, 8, 3),
        };
        _box.GotFocus += (_, _) => { _suspend(true); _box.Text = L("키 조합을 누르세요…", "Press a key combination…"); };
        _box.LostFocus += (_, _) => { _suspend(false); _box.Text = _spec.Display; };
        _box.PreviewKeyDown += (_, e) => e.IsInputKey = true;
        _box.KeyDown += OnBoxKey;
        _box.KeyUp += (_, e) => { if (e.KeyCode == Keys.PrintScreen) OnBoxKey(_box, e); }; // PrtSc only arrives as KeyUp
        var reset = new Button { Text = L("기본값", "Default") + $" ({def.Display})", AutoSize = true };
        reset.Click += (_, _) => Set(def);
        _status = new Label { AutoSize = true, ForeColor = Color.Firebrick, Margin = new Padding(3, 0, 3, 4), Visible = false };
        Controls.Add(_box);
        Controls.Add(reset);
        if (note != null) Controls.Add(new Label { Text = note, AutoSize = true, ForeColor = SystemColors.GrayText, Margin = new Padding(6, 9, 3, 3) });
        SetFlowBreak(Controls[^1], true);
        Controls.Add(_status);
    }

    void OnBoxKey(object? sender, KeyEventArgs e)
    {
        e.SuppressKeyPress = true;
        e.Handled = true;
        if (e.KeyCode == Keys.Escape && e.Modifiers == Keys.None) { FindForm()!.ActiveControl = null; return; }
        var mods = Mods.None;
        if (e.Control) mods |= Mods.Ctrl;
        if (e.Alt) mods |= Mods.Alt;
        if (e.Shift) mods |= Mods.Shift;
        if (Native.IsKeyDown(0x5B) || Native.IsKeyDown(0x5C)) mods |= Mods.Win;
        var spec = new HotKeySpec(mods, (int)e.KeyCode);
        if (HotKeySpec.IsModifierKey((int)e.KeyCode)) { _box.Text = spec.Display.Replace("+" + HotKeySpec.KeyName((int)e.KeyCode), "+…"); return; }
        if (_inCapture ? !spec.IsValidInCapture : !spec.IsValid)
        {
            ShowStatus(_inCapture ? L("다른 키를 고르세요 (Esc·Enter·방향키·Ctrl+C/S/Z/A/V는 캡처 화면에서 이미 씁니다).", "Choose another key (Esc, Enter, arrows and Ctrl+C/S/Z/A/V are already used in the capture).")
                            : L("Ctrl / Alt / Win을 함께 누르거나 PrtSc·F 키를 쓰세요.", "Hold Ctrl / Alt / Win, or use PrtSc or an F key."));
            return;
        }
        Set(spec);
        FindForm()!.ActiveControl = null;
    }

    void Set(HotKeySpec spec)
    {
        var error = _apply(spec);
        if (error == null) _spec = spec;
        ShowStatus(error ?? "");
        _box.Text = _spec.Display;
    }

    void ShowStatus(string message)
    {
        _status.Text = message;
        _status.Visible = message.Length > 0;
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
