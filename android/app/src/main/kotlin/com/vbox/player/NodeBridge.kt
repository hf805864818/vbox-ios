package com.vbox.player

import android.util.Log

/**
 * Node 引擎 JNI 桥（批次 I · ND-01-native —— Android 侧 nodejs-mobile 接入）。
 *
 * 严格对齐 iOS `Libraries/NodeMobile/NodeRunner`：
 *   iOS     NodeRunner（ObjC++）── `node_start(argc, argv)` ── NodeMobile.framework
 *   Android NodeBridge（Kotlin）── `node::Start(argc, argv)` ── libnode.so
 *
 * 官方约束（与 iOS 一致）：运行时**单实例**且**不可重启**；[start] 会**阻塞**至引擎退出，
 * 故调用方（[NodePlugin]）须置于独立后台线程。
 *
 * 加载链：`System.loadLibrary("node_bridge")`（本工程 node_bridge.cpp）→
 * `System.loadLibrary("node")`（libnode.so，SONAME 解析同目录依赖）。
 * 未集成预编译库时静态块抛 `UnsatisfiedLinkError`，由 [NodePlugin] 捕获后回
 * `E_NODE_UNAVAILABLE` 降级（Node 站点暂不可用，不 crash、不影响其余功能）。
 */
object NodeBridge {

    private const val TAG = "vbox"

    /** 引擎是否已启动（单实例语义，启动后不可重启）。 */
    @Volatile
    var isStarted: Boolean = false
        private set

    init {
        System.loadLibrary("node_bridge")
        System.loadLibrary("node")
    }

    /**
     * 预加载原生库（供调用方在**启动前同步**捕获缺包，避免仅在线程内失败）。
     * 首次访问对象即触发 [init] 的 `System.loadLibrary`。
     */
    fun ensureLoaded() {
        // 空实现：访问对象本身即触发类初始化（loadLibrary）
    }

    /**
     * 启动 Node 引擎（**阻塞**至引擎退出，须在独立后台线程调用）。
     *
     * @param scriptPath 入口脚本（main.js）绝对路径
     */
    fun start(scriptPath: String) {
        if (isStarted) {
            Log.w(TAG, "[NodeBridge] ⚠️ Node 引擎已启动，忽略重复启动请求")
            return
        }
        isStarted = true
        Log.i(TAG, "[NodeBridge] 🚀 node::Start 启动（入口=$scriptPath）")
        nativeStartNodeWithArguments(arrayOf("node", scriptPath))
        Log.i(TAG, "[NodeBridge] 🔚 node::Start 返回（引擎已退出）")
    }

    /** JNI 实现见 `src/main/jni/node_bridge.cpp`。 */
    private external fun nativeStartNodeWithArguments(arguments: Array<String>): Int
}