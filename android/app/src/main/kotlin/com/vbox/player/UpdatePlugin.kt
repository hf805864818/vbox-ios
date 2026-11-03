package com.vbox.player

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 自更新安装平台通道（批次 K · K-01 Android 腿）。
 *
 * 对齐方案 §S.4（Android 自更新）与 iOS `UpdateManager.installIPA()` 的
 * 「分平台分派安装」语义：
 *
 * MethodChannel `com.vbox.system/update`：
 *  - `canInstall` → 当前是否已获「安装未知应用」授权（API 26+ 查
 *    `PackageManager.canRequestPackageInstalls()`；26 以下恒 true）。
 *  - `openInstallPermissionSettings` → 跳系统「安装未知应用」授权页
 *    （`Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES`）。
 *  - `installApk`（path）→ 经 [FileProvider] 生成 `content://` URI（免
 *    `FileUriExposedException`），`ACTION_VIEW` 拉起系统安装器；未授权时先跳授权页，
 *    回传 `{status: "needPermission"}`（否则 `{status: "started"}`）。
 *
 * 版本适配（§S.4）：API 26+ 需 `REQUEST_INSTALL_PACKAGES` + 用户手动授权；
 * 24~25 直接 `ACTION_VIEW`；安装包落 app 私有目录（`updates/`）免存储权限。
 */
class UpdatePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {

    private var activityBinding: ActivityPluginBinding? = null
    private var channel: MethodChannel? = null

    // ─────────────── FlutterPlugin ───────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val c = MethodChannel(binding.binaryMessenger, CHANNEL)
        c.setMethodCallHandler(this)
        channel = c
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    // ─────────────── ActivityAware ───────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
    }

    override fun onDetachedFromActivity() {
        activityBinding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding = null
    }

    // ─────────────── MethodChannel ───────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "canInstall" -> result.success(canInstall())
            "openInstallPermissionSettings" -> {
                openInstallPermissionSettings()
                result.success(null)
            }
            "installApk" -> installApk(call.argument<String>("path"), result)
            else -> result.notImplemented()
        }
    }

    /** API 26+ 查「安装未知应用」授权；26 以下无需授权恒 true。 */
    private fun canInstall(): Boolean {
        val ctx = activityBinding?.activity ?: return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return ctx.packageManager.canRequestPackageInstalls()
    }

    private fun openInstallPermissionSettings() {
        val activity = activityBinding?.activity ?: return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            activity.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                    .setData(Uri.parse("package:${activity.packageName}"))
            )
        } catch (e: Exception) {
            Log.w("vbox", "跳转安装授权页失败: ${e.message}")
        }
    }

    private fun installApk(path: String?, result: MethodChannel.Result) {
        val activity = activityBinding?.activity
        if (activity == null || path.isNullOrEmpty()) {
            result.success(mapOf("status" to "failed", "reason" to "参数无效或页面未附着"))
            return
        }
        val file = File(path)
        if (!file.exists()) {
            Log.w("vbox", "安装包不存在: $path")
            result.success(mapOf("status" to "failed", "reason" to "安装包不存在"))
            return
        }
        // 未授权「安装未知应用」→ 先跳授权页（对齐 §S.4 引导口径）。
        if (!canInstall()) {
            openInstallPermissionSettings()
            result.success(mapOf("status" to "needPermission"))
            return
        }
        try {
            val uri: Uri = FileProvider.getUriForFile(
                activity, activity.packageName + ".fileprovider", file
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
            result.success(mapOf("status" to "started"))
        } catch (e: Exception) {
            Log.w("vbox", "拉起安装器失败: ${e.message}")
            result.success(mapOf("status" to "failed", "reason" to e.message))
        }
    }

    companion object {
        const val CHANNEL = "com.vbox.system/update"
    }
}