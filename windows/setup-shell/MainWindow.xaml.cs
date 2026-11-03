// ══════════════════════════════════════════════════════════════════════
//  vbox 安装程序 · UI 壳（路线 A）
//  ─────────────────────────────────────────────────────────────────────
//  职责：
//   1) 释放内嵌资源：静默安装内核 vbox-installer-core.exe + 定稿 HTML/素材 → 临时目录；
//   2) 用 WebView2 载入 installer.html（无边框窗口，标题栏由页面自绘）；
//   3) 与页面做 WebMessage 双向通信：选目录 / 开始安装 / 最小化 / 关闭；
//   4) 启动 core（/VERYSILENT）并轮询其进度文件，把「阶段 + 字节进度」回推页面；
//   5) 结束后上报 done/error，并在成功时启动 vbox.exe；
//   6) WebView2 Runtime 缺失时回退到 core 的原生向导（保证「装得上」优先）。
//
//  设计基线：docs/网盘登录11问题_对齐修复清单_v1.3.md 第 8 章（8.4.3 / 8.4.6）。
// ══════════════════════════════════════════════════════════════════════

using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;
using Microsoft.Win32;

namespace VboxSetupShell;

/// <summary>安装向导主窗口（无边框 + WebView2 宿主）。</summary>
public partial class MainWindow : Window
{
    /// <summary>内嵌资源逻辑名：静默安装内核。</summary>
    private const string CoreResourceName = "core/vbox-installer-core.exe";

    /// <summary>内嵌资源逻辑名：版本号文本（CI 注入）。</summary>
    private const string VersionResourceName = "version.txt";

    private string _tempDir = string.Empty;
    private string _corePath = string.Empty;
    private string _progFile = string.Empty;
    private string _logFile = string.Empty;
    private string _version = string.Empty;
    private string _installDir = string.Empty;

    private DispatcherTimer? _poller;
    private Process? _core;
    private bool _installing;

    /// <summary>构造：仅初始化窗口，实际工作在 <see cref="OnLoaded"/> 中完成。</summary>
    public MainWindow()
    {
        InitializeComponent();
    }

    /// <summary>窗口载入：释放资源 → 初始化 WebView2 → 载入定稿页面。</summary>
    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            PrepareTempWorkspace();
            ExtractEmbeddedAssets();
        }
        catch (Exception ex)
        {
            MessageBox.Show("安装程序初始化失败：\n" + ex.Message, "vbox",
                MessageBoxButton.OK, MessageBoxImage.Error);
            Application.Current.Shutdown(1);
            return;
        }

        try
        {
            var userData = Path.Combine(_tempDir, "webview2");
            var env = await CoreWebView2Environment.CreateAsync(null, userData);
            await Web.EnsureCoreWebView2Async(env);

            var core = Web.CoreWebView2;
            // 精简宿主：关闭右键菜单 / 开发工具 / 状态栏，屏蔽外链与新窗口跳转。
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.IsStatusBarEnabled = false;
            core.Settings.IsZoomControlEnabled = false;
            core.Settings.AreHostObjectsAllowed = false;
            core.NewWindowRequested += (_, args) => args.Handled = true;
            core.NavigationStarting += (_, args) =>
            {
                if (!args.Uri.StartsWith("file://", StringComparison.OrdinalIgnoreCase))
                    args.Cancel = true;
            };
            core.WebMessageReceived += OnWebMessageReceived;

            var html = Path.Combine(_tempDir, "installer.html");
            core.Navigate(new Uri(html).AbsoluteUri);
        }
        catch (Exception ex)
        {
            // WebView2 Runtime 缺失 / 初始化失败 → 回退到 core 的原生向导（8.4.6）。
            FallbackToNativeWizard(ex);
        }
    }

    /// <summary>安装日志目录：<c>%LOCALAPPDATA%\vbox-setup-logs</c>（保留最近 10 份）。</summary>
    private static string BuildPersistentLogPath()
    {
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "vbox-setup-logs");
        Directory.CreateDirectory(dir);

        try
        {
            var stale = Directory.GetFiles(dir, "vbox-setup-*.log");
            if (stale.Length >= 10)
            {
                Array.Sort(stale, StringComparer.OrdinalIgnoreCase);
                for (var i = 0; i <= stale.Length - 10; i++)
                {
                    try { File.Delete(stale[i]); } catch { /* 占用则留到下次清理 */ }
                }
            }
        }
        catch { /* 清理失败不影响安装 */ }

        return Path.Combine(dir, $"vbox-setup-{DateTime.Now:yyyyMMdd-HHmmss}.log");
    }
    /// <summary>建立本次运行的临时工作目录。</summary>
    private void PrepareTempWorkspace()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "vbox-setup-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_tempDir);
        _corePath = Path.Combine(_tempDir, "vbox-installer-core.exe");
        _progFile = Path.Combine(_tempDir, "vbox-setup-progress.json");
        // 安装日志落到 LocalAppData 而不是临时工作目录：临时目录在窗口关闭时
        // 会被 CleanupTemp 整体删除，用户装失败后拿不到任何证据（3.1888 线上
        // 故障现场就是这样丢的）。这里固定保留最近 10 份。
        _logFile = BuildPersistentLogPath();
    }

    /// <summary>
    /// 释放全部内嵌资源：core → <c>_corePath</c>；version.txt → 字段；
    /// 其余（installer.html / brand / splash）按逻辑名原样落盘（保留相对目录结构）。
    /// </summary>
    private void ExtractEmbeddedAssets()
    {
        var asm = Assembly.GetExecutingAssembly();
        foreach (var name in asm.GetManifestResourceNames())
        {
            if (name == VersionResourceName)
            {
                using var reader = new StreamReader(asm.GetManifestResourceStream(name)!);
                _version = reader.ReadToEnd().Trim();
                continue;
            }

            var target = name == CoreResourceName
                ? _corePath
                : Path.Combine(_tempDir, name.Replace('/', Path.DirectorySeparatorChar));

            var dir = Path.GetDirectoryName(target);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

            using var src = asm.GetManifestResourceStream(name)!;
            using var dst = File.Create(target);
            src.CopyTo(dst);
        }

        if (!File.Exists(_corePath))
            throw new FileNotFoundException("安装内核缺失（构建时未注入 vbox-installer-core.exe）。");
    }

    // ─────────────────────────── 页面 → 宿主 ───────────────────────────

    /// <summary>接收页面消息（选目录 / 开始安装 / 窗口控制）。</summary>
    private void OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        string cmd;
        string dir = string.Empty;
        try
        {
            using var doc = JsonDocument.Parse(e.WebMessageAsJson);
            var root = doc.RootElement;
            cmd = root.TryGetProperty("cmd", out var c) ? (c.GetString() ?? string.Empty) : string.Empty;
            if (root.TryGetProperty("dir", out var d)) dir = d.GetString() ?? string.Empty;
        }
        catch (JsonException)
        {
            return;
        }

        switch (cmd)
        {
            case "ready":
                // 页面就绪：下发默认安装位置与版本号。
                _installDir = DefaultInstallDir();
                SendInit(_installDir);
                break;

            case "browseDir":
                PickFolder();
                break;

            case "install":
                if (!string.IsNullOrWhiteSpace(dir)) _installDir = dir;
                StartCore(_installDir);
                break;

            case "minimize":
                WindowState = WindowState.Minimized;
                break;

            case "close":
                RequestClose();
                break;
        }
    }

    /// <summary>原生「选择文件夹」对话框（.NET 8 的 WPF <see cref="OpenFolderDialog"/>）。</summary>
    private void PickFolder()
    {
        var dlg = new OpenFolderDialog
        {
            Title = "选择 vbox 安装位置",
            InitialDirectory = Directory.Exists(_installDir) ? _installDir : string.Empty,
            Multiselect = false,
        };
        if (dlg.ShowDialog(this) == true && !string.IsNullOrWhiteSpace(dlg.FolderName))
        {
            _installDir = dlg.FolderName;
            SendJson(new { type = "dir", path = _installDir });
        }
    }

    /// <summary>默认安装位置：<c>%LOCALAPPDATA%\Programs\vbox</c>
    /// （对齐 core 的 <c>PrivilegesRequired=lowest</c> 下 <c>{autopf}</c> 展开结果）。</summary>
    private static string DefaultInstallDir() => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Programs", "vbox");

    /// <summary>下发初始值（默认目录 + 版本号）。</summary>
    private void SendInit(string dir) =>
        SendJson(new { type = "init", dir, version = string.IsNullOrEmpty(_version) ? "vbox" : _version });

    // ─────────────────────────── 安装执行 ───────────────────────────

    /// <summary>以静默模式启动 core，并开始轮询进度文件。</summary>
    private void StartCore(string dir)
    {
        if (_installing) return;
        _installing = true;

        try { if (File.Exists(_progFile)) File.Delete(_progFile); } catch { /* 忽略 */ }

        var psi = new ProcessStartInfo
        {
            FileName = _corePath,
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = _tempDir,
        };
        // ArgumentList 会按需自动加引号，等价于 /DIR="C:\Program Files\vbox"。
        psi.ArgumentList.Add("/VERYSILENT");
        psi.ArgumentList.Add("/SUPPRESSMSGBOXES");
        psi.ArgumentList.Add("/NORESTART");
        psi.ArgumentList.Add("/NOCANCEL");
        psi.ArgumentList.Add("/SP-");
        psi.ArgumentList.Add($"/DIR={dir}");
        psi.ArgumentList.Add($"/VBOXPROG={_progFile}");
        psi.ArgumentList.Add($"/LOG={_logFile}");

        try
        {
            _core = Process.Start(psi);
        }
        catch (Exception ex)
        {
            _installing = false;
            SendError("无法启动安装内核：" + ex.Message);
            return;
        }

        if (_core is null)
        {
            _installing = false;
            SendError("无法启动安装内核（进程创建失败）。");
            return;
        }

        _core.EnableRaisingEvents = true;
        _core.Exited += OnCoreExited;

        _poller = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
        _poller.Tick += OnPollTick;
        _poller.Start();
    }

    /// <summary>轮询 core 写入的进度文件并回推页面（缺文件/半写状态静默跳过）。</summary>
    private void OnPollTick(object? sender, EventArgs e)
    {
        if (!File.Exists(_progFile)) return;

        string raw;
        try
        {
            raw = File.ReadAllText(_progFile);
            if (string.IsNullOrWhiteSpace(raw)) return;
        }
        catch (IOException)
        {
            return; // core 正在覆写，本次跳过
        }

        try
        {
            using var doc = JsonDocument.Parse(raw);
            var root = doc.RootElement;
            var stage = root.TryGetProperty("stage", out var s) ? (s.GetString() ?? string.Empty) : string.Empty;
            int cur = root.TryGetProperty("cur", out var c) ? c.GetInt32() : -1;
            int max = root.TryGetProperty("max", out var m) ? m.GetInt32() : -1;
            // core 只写 {stage,cur,max}，由壳补上 type 供页面分发。
            SendJson(new { type = "progress", stage, cur, max });
        }
        catch (JsonException)
        {
            // 跳过本次损坏快照
        }
    }

    /// <summary>core 结束：封送回 UI 线程后处理（停轮询 → 成功(exit 0)上报 done 并启动 vbox → 否则上报错误）。</summary>
    private void OnCoreExited(object? sender, EventArgs e)
    {
        // Process.Exited 在 .NET 中由 ThreadPool 线程触发，并非 UI 线程；而下面
        // 所有动作（停 DispatcherTimer、经 WebView2 推消息、Close 窗口）都要求
        // UI 线程。若直接在事件回调里执行，跨线程访问会抛 InvalidOperationException，
        // 且 async void 没有异常出口 → 安装收尾时窗口静默闪退（安装本身其实已成功）。
        // 故统一封送回 UI 线程后再处理。
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(() => OnCoreExitedOnUI(sender, e));
            return;
        }
        OnCoreExitedOnUI(sender, e);
    }

    private async void OnCoreExitedOnUI(object? sender, EventArgs e)
    {
        _poller?.Stop();
        OnPollTick(null, EventArgs.Empty); // 收尾读一次最终状态

        var exitCode = -1;
        try { exitCode = _core?.ExitCode ?? -1; } catch { /* 忽略 */ }
        _installing = false;

        if (exitCode == 0)
        {
            // 收尾竞态兜底：内核在进程退出前一刻才落盘 done 快照，最后一次
            // 轮询可能只读到上一阶段快照（实测停在 62%）；且 done 消息的页面
            // 渲染窗口只有 0.9s，vbox.exe 启动抢占 CPU 时页面来不及画 100%，
            // 表现为「62% → 窗口直接关闭」（安装本身已完整成功）。
            // 此处无论最后读到什么，都强制补发 done 阶段，并加长停留时间，
            // 保证「安装完成 100%」必然渲染后再关窗。
            SendJson(new { type = "progress", stage = "done", cur = -1, max = -1 });
            SendJson(new { type = "done" });

            await Task.Delay(1200);
            await LaunchVboxAsync(_installDir);
            await Task.Delay(900);
            Close();
        }
        else
        {
            SendError(BuildFailureMessage(exitCode));
        }
    }

    /// <summary>安装成功后启动 <c>{dir}\vbox.exe</c>（core 的 [Run] 使用 skipifsilent，
    /// 静默模式下不会自启，故由壳代劳）。vbox.exe 由内核收尾阶段落盘，个别环境
    /// （杀软扫描 / 索引器占用）会有短暂延迟，最多重试 3 次 × 600ms。</summary>
    private static async Task LaunchVboxAsync(string dir)
    {
        var exe = Path.Combine(dir, "vbox.exe");
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                if (File.Exists(exe))
                {
                    Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true });
                    return;
                }
            }
            catch { /* 启动失败不影响安装结果 */ }
            await Task.Delay(600);
        }
    }

    /// <summary>从 core 的 /LOG 尾部截取可读信息，构造失败文案。</summary>
    private string BuildFailureMessage(int exitCode)
    {
        var tail = string.Empty;
        try
        {
            if (File.Exists(_logFile))
            {
                var text = File.ReadAllText(_logFile);
                const int keep = 600;
                tail = text.Length > keep ? text[^keep..] : text;
                tail = tail.Trim();
            }
        }
        catch { /* 忽略 */ }

        return string.IsNullOrEmpty(tail)
            ? $"安装未完成（内核退出码 {exitCode}）。请关闭正在运行的 vbox / Node 进程后重试。"
            : $"安装未完成（内核退出码 {exitCode}）。\n\n日志尾部：\n{tail}";
    }

    // ─────────────────────────── 窗口控制 ───────────────────────────

    /// <summary>安装进行中禁止关闭窗口（避免 core 成为孤儿进程）。</summary>
    private void RequestClose()
    {
        if (_installing)
        {
            MessageBox.Show(this, "正在安装，请等待完成后再关闭。", "vbox",
                MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        Close();
    }

    /// <summary>窗口关闭拦截：安装未结束时取消关闭。</summary>
    private void OnClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (_installing)
        {
            e.Cancel = true;
            return;
        }
        _poller?.Stop();
        _poller = null;
        CleanupTemp();
    }

    /// <summary>清理临时目录（core 已被查杀/退出，文件可删；失败则留给系统清理）。</summary>
    private void CleanupTemp()
    {
        try
        {
            if (!string.IsNullOrEmpty(_tempDir) && Directory.Exists(_tempDir))
                Directory.Delete(_tempDir, recursive: true);
        }
        catch { /* 忽略：文件仍被占用时不影响交付 */ }
    }

    // ─────────────────────────── WebView2 缺失兜底 ───────────────────────────

    /// <summary>WebView2 不可用 → 切换到 core 的原生向导，保证「装得上」优先。</summary>
    private async void FallbackToNativeWizard(Exception ex)
    {
        Web.Visibility = Visibility.Collapsed;
        FallbackPane.Visibility = Visibility.Visible;
        FallbackText.Text = "未检测到 WebView2 组件，已切换到原生安装向导…";
        Debug.WriteLine("WebView2 init failed: " + ex);

        await Task.Delay(400);

        try
        {
            // 不带 /VERYSILENT：core 走自己的原生向导（含目录页 / 完成页）。
            Process.Start(new ProcessStartInfo(_corePath) { UseShellExecute = true });
        }
        catch { /* 忽略 */ }

        Application.Current.Shutdown(0);
    }

    // ─────────────────────────── 工具 ───────────────────────────

    /// <summary>按需把对象序列化为 JSON 后推给页面。</summary>
    private void SendJson(object payload)
    {
        var json = JsonSerializer.Serialize(payload);
        Web.CoreWebView2?.PostWebMessageAsJson(json);
    }

    /// <summary>上报安装错误（页面以红色横幅展示）。</summary>
    private void SendError(string message) => SendJson(new { type = "error", message });
}
