package com.vbox.player

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/**
 * 直播本地文件导入/导出/分享平台通道（批次 E · E-04 Android 腿）。
 *
 * 对齐 iOS `LiveTVView` 的 `DocumentPickerView`（`UIDocumentPickerViewController`
 * `forOpeningContentTypes: [.item], asCopy: true`）与 `ActivityShareSheet`
 * （`UIActivityViewController`）：
 *
 * MethodChannel `com.vbox.live/file`：
 *  - `pickTextFile` → 打开系统文件选择器（`ACTION_OPEN_DOCUMENT`，MIME `*`/`*` + openable），
 *    读取文本内容（UTF-8 → ASCII 兜底，对齐 iOS `String(contentsOf:encoding:)` 失败
 *    走 ASCII 解码的语义），回传 `{name, content, path}`；取消/失败回传 null。
 *  - `shareFile`（path）→ 经 `FileProvider` 生成 `content://` URI（内部缓存目录，
 *    解决 API 24+ `FileUriExposedException`），走 `ACTION_SEND` 系统分享。
 *
 * 活动结果经 [PluginRegistry.ActivityResultListener] 回传（`startActivityForResult`
 * 回调路径），Activity 切换/重配置时释放监听，避免泄漏。
 */
class LiveFilePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {

    private var activityBinding: ActivityPluginBinding? = null
    private var channel: MethodChannel? = null

    /** 挂起中的文件选择回调（单次选择，选择结束即清空）。 */
    private var pendingPickResult: MethodChannel.Result? = null

    private val pickListener = PluginRegistry.ActivityResultListener {
            requestCode, resultCode, data ->
        if (requestCode != REQUEST_PICK) return@ActivityResultListener false
        val result = pendingPickResult
        pendingPickResult = null
        if (result == null) return@ActivityResultListener true
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null) // 用户取消
            return@ActivityResultListener true
        }
        result.success(readTextFile(uri))
        true
    }

    // ─────────────── FlutterPlugin ───────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val c = MethodChannel(binding.binaryMessenger, CHANNEL)
        c.setMethodCallHandler(this)
        channel = c
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        pendingPickResult = null
    }

    // ─────────────── ActivityAware ───────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(pickListener)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(pickListener)
        activityBinding = null
        pendingPickResult = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity()
    }

    // ─────────────── MethodChannel ───────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickTextFile" -> pickTextFile(result)
            "shareFile" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.success(null)
                } else {
                    shareFile(path, result)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun pickTextFile(result: MethodChannel.Result) {
        val activity = activityBinding?.activity
        if (activity == null) {
            result.success(null)
            return
        }
        pendingPickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            // 任意文档类型（对齐 iOS `.item`，含 m3u8/m3u/txt 无标准 MIME 的文件）。
            type = "*/*"
        }
        try {
            activity.startActivityForResult(intent, REQUEST_PICK)
        } catch (e: Exception) {
            Log.w("vbox", "打开文件选择器失败: ${e.message}")
            pendingPickResult = null
            result.success(null)
        }
    }

    /** 读取所选文本内容并回传快照；失败返回 null。 */
    private fun readTextFile(uri: Uri): Map<String, Any?>? {
        val ctx = activityBinding?.activity ?: return null
        return try {
            val bytes = ctx.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                ?: return null
            val name = queryDisplayName(ctx, uri)?.substringBeforeLast('.')?.ifBlank { null }
                ?: "imported"
            mapOf(
                "name" to name,
                "content" to decodeText(bytes),
                "path" to uri.toString()
            )
        } catch (e: Exception) {
            Log.w("vbox", "读取直播源文件失败: ${e.message}")
            null
        }
    }

    /** 查询文件展示名（`OpenableColumns.DISPLAY_NAME`），失败返回 null。 */
    private fun queryDisplayName(ctx: Context, uri: Uri): String? {
        return try {
            ctx.contentResolver.query(
                uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null
            )?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        } catch (e: Exception) {
            null
        }
    }

    /** UTF-8 解码，非法编码回退 ASCII（对齐 iOS `String(contentsOf:encoding:)` 语义）。 */
    private fun decodeText(bytes: ByteArray): String {
        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return try {
            decoder.decode(ByteBuffer.wrap(bytes)).toString()
        } catch (e: Exception) {
            String(bytes, Charsets.US_ASCII)
        }
    }

    private fun shareFile(path: String, result: MethodChannel.Result) {
        val activity = activityBinding?.activity
        if (activity == null) {
            result.success(null)
            return
        }
        try {
            val file = File(path)
            if (!file.exists()) {
                Log.w("vbox", "分享文件不存在: $path")
                result.success(null)
                return
            }
            val uri: Uri = FileProvider.getUriForFile(
                activity, activity.packageName + ".fileprovider", file
            )
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "*/*"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(Intent.createChooser(send, "分享直播源"))
            result.success(null)
        } catch (e: Exception) {
            Log.w("vbox", "分享直播源失败: ${e.message}")
            result.success(null)
        }
    }

    companion object {
        const val CHANNEL = "com.vbox.live/file"
        private const val REQUEST_PICK = 0x6c66
    }
}