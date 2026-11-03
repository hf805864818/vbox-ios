// ══════════════════════════════════════════════════════════════════════
//  vbox 安装程序 · 应用入口
//  ─────────────────────────────────────────────────────────────────────
//  单实例保护：安装包启动慢（释放内嵌资源 + WebView2 冷启动），用户常在
//  窗口出现前重复双击；浏览器「下载完成后打开」与手动双击叠加也会产生两个
//  实例。第二个实例装完第一个的安装后弹出第二个向导（历史实测：装完后又
//  出现「选择安装位置」页），且再点「安装」会杀掉刚启动的 vbox 重装一遍。
//  此处在 Startup 阶段用命名 Mutex 拦截：已有实例时提示后退出，
//  StartupUri 指向的主窗口不会创建。
// ══════════════════════════════════════════════════════════════════════

using System.IO;
using System.Threading;
using System.Windows;
using System.Windows.Threading;

namespace VboxSetupShell;

/// <summary>应用入口（单实例保护）。</summary>
public partial class App : Application
{
    /// <summary>单实例互斥体。进程退出时由系统释放；保持引用防止 GC 提前释放。</summary>
    private static Mutex? _singleInstanceMutex;

    /// <summary>Startup 阶段检查单实例；重复启动时提示后退出。</summary>
    private void App_OnStartup(object sender, StartupEventArgs e)
    {
        // 全局兜底：UI 线程未处理异常（含 async void 在 UI 线程的续体）→
        // 落盘 + 弹窗，避免静默闪退后无日志可查。
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += OnAppDomainUnhandledException;

        // per-user 安装（PrivilegesRequired=lowest），Local 命名空间（按会话）足够：
        // 同会话内双开是真实场景；不同用户会话各自安装互不干扰。
        _singleInstanceMutex = new Mutex(true, @"Local\vbox-setup-shell", out bool createdNew);
        if (!createdNew)
        {
            MessageBox.Show(
                "vbox 安装程序已在运行，请使用已打开的安装窗口。",
                "vbox", MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown(0);
        }
    }

    /// <summary>UI 线程未处理异常：记录后弹窗并标记已处理，阻止进程退出、尽量保留现场。</summary>
    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        WriteCrashLog("DispatcherUnhandledException", e.Exception);
        MessageBox.Show(
            "安装程序遇到未处理的错误：\n" + e.Exception.Message + "\n\n详情已写入：" + CrashLogPath,
            "vbox", MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }

    /// <summary>后台线程 / ThreadPool 的 async void 异常：无法阻止进程退出，仅落盘留痕。</summary>
    private void OnAppDomainUnhandledException(object sender, UnhandledExceptionEventArgs e)
    {
        WriteCrashLog("AppDomainUnhandledException", e.ExceptionObject as Exception);
    }

    private static string CrashLogPath => Path.Combine(Path.GetTempPath(), "vbox-setup-crash.log");

    private static void WriteCrashLog(string source, Exception? ex)
    {
        try
        {
            File.AppendAllText(CrashLogPath,
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {source}\n{ex}\n\n");
        }
        catch
        {
            // 落盘失败不影响主流程
        }
    }
}
