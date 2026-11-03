package com.vbox.player

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 应用内浮窗平台通道（批次 D · D2 —— Android/TV 腿）。
 *
 * 对齐 iOS `PiPHelper.showFloatingWindow`（PlayerViewsV2.swift:328-509）：
 *  - 浮窗承载 Dart 传来的播放器截图（RepaintBoundary → PNG bytes），
 *    `update` 换图模拟播放（iOS 为 snapshotView 定时 5fps 刷新）；
 *  - 手势三件套：单击 → toggle 播放 / 双击 → 恢复全屏 / 拖动 → 自由移动 +
 *    松手吸附最近左右边缘（y 限制在屏内，对齐 handlePan:415-441）；
 *  - 右上关闭按钮（对齐 xmark.circle.fill closeBtn:377-381）。
 *
 * MethodChannel `com.vbox.player/floating`：
 *  - `isAvailable` → `Settings.canDrawOverlays`（未授权 → Dart 引导去系统授权页）；
 *  - `show`（bytes/width/height）→ WindowManager.addView
 *    （`TYPE_APPLICATION_OVERLAY`，API<26 回退 `TYPE_PHONE`）；
 *  - `update`（bytes）→ 换截图；`hide` / `dispose` → removeView；
 *    `setMedia` / `updateProgress` → 记录元数据（浮窗不消费，接口对齐）。
 *
 * EventChannel `com.vbox.player/floating/events`：`{type: tap|doubleTap|close}`
 * （Dart 侧 `PipController` 分派：tap→toggle、doubleTap→restore）。
 */
class FloatingWindowPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private var appContext: Context? = null
    private var channel: MethodChannel? = null
    private var sink: EventChannel.EventSink? = null

    private var windowManager: WindowManager? = null
    private var containerView: FrameLayout? = null
    private var snapshotView: ImageView? = null
    private var layoutParams: WindowManager.LayoutParams? = null

    private var windowWidthPx = 0
    private var windowHeightPx = 0

    // ─────────────── FlutterPlugin ───────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        val c = MethodChannel(binding.binaryMessenger, CHANNEL)
        c.setMethodCallHandler(this)
        channel = c
        val ec = EventChannel(binding.binaryMessenger, EVENTS_CHANNEL)
        ec.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        removeView()
        channel?.setMethodCallHandler(null)
        channel = null
        sink = null
    }

    // ─────────────── EventChannel ───────────────

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    // ─────────────── MethodChannel ───────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(isAvailable())
            "show" -> {
                val bytes = call.argument<ByteArray>("bytes")
                result.success(show(bytes, call))
            }
            "update" -> {
                update(call.argument<ByteArray>("bytes"))
                result.success(null)
            }
            "hide", "dispose" -> {
                removeView()
                result.success(null)
            }
            "setMedia", "updateProgress" -> result.success(null)
            else -> result.notImplemented()
        }
    }

    private fun isAvailable(): Boolean {
        val ctx = appContext ?: return false
        return Build.VERSION.SDK_INT >= 23 && Settings.canDrawOverlays(ctx)
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun show(bytes: ByteArray?, call: MethodCall): Boolean {
        val ctx = appContext ?: return false
        if (!isAvailable()) return false
        removeView()
        val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
            ?: return false

        val density = ctx.resources.displayMetrics.density
        val w = (call.argument<Double>("width")?.toFloat() ?: 200f) * density
        val h = (call.argument<Double>("height")?.toFloat() ?: 112f) * density
        windowWidthPx = w.toInt().coerceAtLeast(1)
        windowHeightPx = h.toInt().coerceAtLeast(1)

        // 容器：黑底圆角 12（对齐 iOS containerView cornerRadius 12 + 阴影）。
        val container = FrameLayout(ctx)
        val bg = GradientDrawable()
        bg.setColor(Color.BLACK)
        bg.cornerRadius = 12f * density
        container.background = bg
        container.clipToOutline = true

        // 截图承载（对齐 iOS snapshot tag 1001）。
        val snapshot = ImageView(ctx)
        snapshot.scaleType = ImageView.ScaleType.CENTER_CROP
        container.addView(
            snapshot,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        // 关闭按钮（右上，对齐 iOS xmark.circle.fill）。
        val close = ImageView(ctx)
        close.setImageResource(ctx.resources.getIdentifier(
            "ic_close_white", "drawable", ctx.packageName
        ).takeIf { it != 0 } ?: android.R.drawable.ic_menu_close_clear_cancel)
        close.setPadding((6 * density).toInt(), (6 * density).toInt(),
            (6 * density).toInt(), (6 * density).toInt())
        close.setOnClickListener { emit("close") }
        container.addView(
            close,
            FrameLayout.LayoutParams(
                (28 * density).toInt(),
                (28 * density).toInt(),
                Gravity.TOP or Gravity.END,
            ),
        )

        // 手势：单击/双击回传 Dart；拖动原生自处理 + 松手吸附（对齐 handlePan）。
        val gesture = GestureDetector(ctx, object : GestureDetector.SimpleOnGestureListener() {
            override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                emit("tap")
                return true
            }

            override fun onDoubleTap(e: MotionEvent): Boolean {
                emit("doubleTap")
                return true
            }
        })
        container.setOnTouchListener { v, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    lastRawX = event.rawX.toInt()
                    lastRawY = event.rawY.toInt()
                }
                MotionEvent.ACTION_MOVE -> moveBy(v, event)
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> snapToEdge(v)
            }
            gesture.onTouchEvent(event)
        }

        // 初始位置：屏幕右侧偏上（对齐 iOS (screenW-220, 80)）。
        val screenW = ctx.resources.displayMetrics.widthPixels
        val type = if (Build.VERSION.SDK_INT >= 26) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        val params = WindowManager.LayoutParams(
            windowWidthPx,
            windowHeightPx,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        )
        params.gravity = Gravity.TOP or Gravity.START
        params.x = screenW - windowWidthPx - (20 * density).toInt()
        params.y = (80 * density).toInt()

        if (bytes != null) applySnapshot(snapshot, bytes)

        try {
            wm.addView(container, params)
        } catch (e: Exception) {
            Log.w("vbox", "浮窗 addView 失败: ${e.message}")
            return false
        }

        windowManager = wm
        containerView = container
        snapshotView = snapshot
        layoutParams = params
        return true
    }

    private fun update(bytes: ByteArray?) {
        val v = snapshotView ?: return
        if (bytes != null) applySnapshot(v, bytes)
    }

    private fun applySnapshot(view: ImageView, bytes: ByteArray) {
        val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        if (bmp != null) view.setImageBitmap(bmp)
    }

    private fun moveBy(view: View, event: MotionEvent) {
        val params = layoutParams ?: return
        params.x += event.rawX.toInt() - lastRawX
        params.y += event.rawY.toInt() - lastRawY
        lastRawX = event.rawX.toInt()
        lastRawY = event.rawY.toInt()
        try {
            windowManager?.updateViewLayout(view, params)
        } catch (e: Exception) {
            // 视图已移除等竞态：忽略。
        }
    }

    private var lastRawX = 0
    private var lastRawY = 0

    // 拖动开始时重置参考点（ACTION_DOWN 未被上层消费，这里借 raw 首帧对齐）。
    private fun snapToEdge(view: View) {
        val ctx = appContext ?: return
        val params = layoutParams ?: return
        val screenW = ctx.resources.displayMetrics.widthPixels
        val screenH = ctx.resources.displayMetrics.heightPixels
        // 吸附最近左右边缘（对齐 iOS handlePan ended：x = w/2+8 或 screenW-w/2-8）。
        val centerX = params.x + windowWidthPx / 2
        params.x = if (centerX < screenW / 2) {
            (8 * ctx.resources.displayMetrics.density).toInt()
        } else {
            screenW - windowWidthPx - (8 * ctx.resources.displayMetrics.density).toInt()
        }
        // y 限制在屏内（对齐 iOS minY = h/2+50 / maxY = screenH-h/2-50）。
        val margin = (50 * ctx.resources.displayMetrics.density).toInt()
        params.y = params.y.coerceIn(margin, (screenH - windowHeightPx - margin).coerceAtLeast(margin))
        try {
            windowManager?.updateViewLayout(view, params)
        } catch (e: Exception) {
            // 忽略。
        }
    }

    private fun removeView() {
        val v = containerView ?: return
        try {
            windowManager?.removeView(v)
        } catch (e: Exception) {
            // 已移除：忽略。
        }
        containerView = null
        snapshotView = null
        layoutParams = null
    }

    private fun emit(type: String) {
        sink?.success(mapOf("type" to type))
    }

    companion object {
        private const val CHANNEL = "com.vbox.player/floating"
        private const val EVENTS_CHANNEL = "com.vbox.player/floating/events"

        /** 供 [MainActivity.configureFlutterEngine] 手动注册（非插件工程无 registrant）。 */
        @JvmStatic
        fun registerWith(engine: FlutterEngine) {
            engine.plugins.add(FloatingWindowPlugin())
        }
    }
}
