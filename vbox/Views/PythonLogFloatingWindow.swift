//
//  PythonLogFloatingWindow.swift
//  vbox
//
//  开发用: PythonBridge 日志全局悬浮窗
//  独立 UIWindow(windowLevel 高), 所有页面之上, 可拖动
//  显示 PythonLogStore 收集的日志 + 支持导出
//

import SwiftUI
import UIKit

/// 全局 Python 日志悬浮窗管理器
@MainActor
final class PythonLogManager {
    static let shared = PythonLogManager()
    private var floatingWindow: PythonLogFloatingWindow?
    private init() {}

    func show() {
        guard floatingWindow == nil else { return }
        let window = PythonLogFloatingWindow()
        window.show()
        floatingWindow = window
    }

    func hide() {
        floatingWindow?.hide()
        floatingWindow = nil
    }

    var isShowing: Bool { floatingWindow != nil }
}

/// 悬浮窗 UIWindow (全局覆盖)
@MainActor
final class PythonLogFloatingWindow: UIWindow {
    private var panelVC: UIViewController?

    private static func currentWindowBounds() -> CGRect {
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
           let win = scene.windows.first {
            return win.bounds
        }
        return UIScreen.main.bounds
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    convenience init() {
        self.init(frame: Self.currentWindowBounds())
        self.windowLevel = UIWindow.Level.alert + 100
        self.backgroundColor = .clear
        let vc = PythonLogPanelViewController()
        self.rootViewController = vc
        self.panelVC = vc
    }

    // ★ 关键: 只拦截悬浮球/展开面板区域的触摸, 其余区域事件透传给下层 App
    // 否则全屏 UIWindow 会遮挡所有 UI 交互
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let rootVC = rootViewController else { return nil }
        // 检查触摸点是否落在 rootVC.view 的任何子视图上 (miniView 或 expandView)
        let hitView = rootVC.view.hitTest(point, with: event)
        if hitView != nil && hitView !== rootVC.view {
            // 点击在悬浮球或面板上, 返回该视图接收事件
            return hitView
        }
        // 点击在透明区域, 返回 nil 让事件穿透到下层
        return nil
    }

    func show() {
        // iOS 13+: UIWindow 必须关联到 UIWindowScene 才能显示
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) {
            self.windowScene = scene
        }
        self.isHidden = false
        self.makeKeyAndVisible()
    }

    func hide() {
        self.isHidden = true
        self.panelVC = nil
        self.rootViewController = nil
    }
}

/// 日志悬浮面板 (小窗可展开)
@MainActor
final class PythonLogPanelViewController: UIViewController {

    private var miniView: UIView!
    private var expandView: UIView!
    private var isExpanded = false
    private var textView: UITextView!
    private var countLabel: UILabel!
    private var autoScroll = true

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        setupMini()
        setupExpand()
        setupPan()

        // 监听日志更新通知 + 定时刷新
        NotificationCenter.default.addObserver(self, selector: #selector(onLogUpdate), name: .init("PythonLogStoreDidUpdateNotification"), object: nil)
        Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshLogs() }
        }
        refreshLogs()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupMini() {
        let mini = UIView(frame: CGRect(x: UIScreen.main.bounds.width - 70, y: 150, width: 54, height: 54))
        mini.layer.cornerRadius = 27
        mini.backgroundColor = UIColor.systemIndigo.withAlphaComponent(0.9)
        mini.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(miniTapped)))
        view.addSubview(mini)
        miniView = mini

        let img = UIImageView()
        img.image = UIImage(systemName: "ladybug.fill")
        img.tintColor = .white
        img.contentMode = .scaleAspectFit
        img.frame = mini.bounds.insetBy(dx: 12, dy: 12)
        mini.addSubview(img)
    }

    private func setupExpand() {
        let x: CGFloat = 8
        let w: CGFloat = UIScreen.main.bounds.width - 16
        let h: CGFloat = UIScreen.main.bounds.height * 0.5
        let panel = UIView(frame: CGRect(x: x, y: 60, width: w, height: h))
        panel.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        panel.layer.cornerRadius = 12
        panel.isHidden = true
        view.addSubview(panel)
        expandView = panel

        // 标题栏
        let titleBar = UIView(frame: CGRect(x: 0, y: 0, width: w, height: 36))
        titleBar.backgroundColor = UIColor.darkGray.withAlphaComponent(0.5)
        panel.addSubview(titleBar)
        let title = UILabel(frame: CGRect(x: 10, y: 0, width: w - 120, height: 36))
        title.text = "🐍 Python 开发日志"
        title.textColor = .white
        title.font = .systemFont(ofSize: 15, weight: .bold)
        titleBar.addSubview(title)

        countLabel = UILabel(frame: CGRect(x: w - 90, y: 0, width: 80, height: 36))
        countLabel.textColor = .lightGray
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.text = "0 条"
        countLabel.textAlignment = .right
        titleBar.addSubview(countLabel)

        // 操作栏
        let barY: CGFloat = 36
        let actH: CGFloat = 36
        let actW: CGFloat = (w - 20 - 8 * 3) / 4
        let actions: [(String, Selector)] = [("清空", #selector(clearLogs)), ("暂停", #selector(togglePause)), ("导出", #selector(exportLogs)), ("收起", #selector(collapse))]
        for (i, item) in actions.enumerated() {
            let b = UIButton(type: .system)
            b.frame = CGRect(x: 10 + CGFloat(i) * (actW + 8), y: barY, width: actW, height: actH)
            b.setTitle(item.0, for: .normal)
            b.setTitleColor(.systemBlue, for: .normal)
            b.backgroundColor = UIColor.white.withAlphaComponent(0.15)
            b.layer.cornerRadius = 6
            b.addTarget(self, action: item.1, for: .touchUpInside)
            panel.addSubview(b)
        }

        textView = UITextView(frame: CGRect(x: 6, y: barY + actH + 6, width: w - 12, height: h - barY - actH - 16))
        textView.backgroundColor = .clear
        textView.textColor = .white
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isEditable = false
        panel.addSubview(textView)
    }

    private func setupPan() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        miniView.addGestureRecognizer(pan)
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: view)
        var center = miniView.center
        center.x += t.x; center.y += t.y
        let margin: CGFloat = 30
        center.x = max(min(center.x, view.bounds.width - margin), margin)
        center.y = max(min(center.y, view.bounds.height - margin), margin)
        miniView.center = center
        g.setTranslation(.zero, in: view)
    }

    @objc private func onLogUpdate() {
        Task { @MainActor [weak self] in self?.refreshLogs() }
    }

    @objc private func miniTapped() {
        isExpanded = true
        miniView.isHidden = true
        expandView.isHidden = false
        refreshLogs()
    }

    @objc private func collapse() {
        isExpanded = false
        expandView.isHidden = true
        miniView.isHidden = false
    }

    @objc private func clearLogs() {
        PythonLogStore.shared().clearLogs()
        refreshLogs()
    }

    @objc private func togglePause() {
        autoScroll.toggle()
    }

    @objc private func exportLogs() {
        // 检查是否有日志
        if PythonLogStore.shared().count == 0 {
            showAlertOnMainWindow(title: "提示", message: "没有日志可导出")
            return
        }

        // ★ 调用 exportToZip 压缩所有日志为 zip
        guard let zipPath = PythonLogStore.shared().exportToZip() else {
            showAlertOnMainWindow(title: "导出失败", message: "创建 zip 文件失败")
            return
        }

        // ★ 使用 UIDocumentPickerViewController 让用户保存到 "文件" App
        // forExporting + asCopy: true → 将 zip 复制到用户选择的目标位置
        let fileURL = URL(fileURLWithPath: zipPath)
        let documentPicker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        documentPicker.delegate = self
        present(documentPicker, animated: true)
    }

    /// ★ 在主 App 窗口上弹 Alert
    /// 关键: 悬浮窗 windowLevel = alert + 100, 高于 UIAlertController 的 alert 级别
    /// 如果不临时降低悬浮窗 windowLevel, alert 会被悬浮窗完全遮挡, 按钮无法点击
    private func showAlertOnMainWindow(title: String, message: String) {
        // 获取悬浮窗引用, 暂存原始 windowLevel
        let floatingWindow = self.view.window as? PythonLogFloatingWindow
        let savedLevel = floatingWindow?.windowLevel
        // 临时降到 normal 以下, 确保 alert 在最上层
        floatingWindow?.windowLevel = .normal - 1

        // alert 关闭后恢复悬浮窗 windowLevel
        let restoreWindow: () -> Void = {
            floatingWindow?.windowLevel = savedLevel ?? (UIWindow.Level.alert + 100)
        }

        let presentAlert: (UIViewController) -> Void = { presenter in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in
                restoreWindow()
            })
            presenter.present(alert, animated: true)
        }

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }),
              let rootVC = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            // 回退: 直接在悬浮窗 present
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in restoreWindow() })
            present(alert, animated: true)
            return
        }

        // 如果 rootVC 正在 present 其他控制器, 先 dismiss 再 present alert
        if let presented = rootVC.presentedViewController, !presented.isBeingDismissed {
            presented.dismiss(animated: true) {
                presentAlert(rootVC)
            }
        } else {
            presentAlert(rootVC)
        }
    }

    private func refreshLogs() {
        let logs = PythonLogStore.shared().recentLogs(300)
        countLabel?.text = "\(PythonLogStore.shared().count) 条"
        guard isExpanded else { return }
        let text = logs.joined(separator: "\n")
        if text != textView.text {
            textView.text = text
            if autoScroll && !text.isEmpty {
                textView.scrollRangeToVisible(NSRange(location: text.count - 1, length: 1))
            }
        }
    }
}

// MARK: - UIDocumentPickerDelegate
@MainActor
extension PythonLogPanelViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        // ★ 延迟 0.3s 等 documentPicker 完全 dismiss 后再弹 alert
        // 否则 rootVC 可能仍在处理 dismiss 动画, present 会失败
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.showAlertOnMainWindow(title: "导出成功", message: "日志已保存到文件")
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // 用户取消, 无需处理
    }
}
