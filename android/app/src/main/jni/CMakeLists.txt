# 批次 Q · Q-02：Android JSC 集成（NDK 编译 jsc/wrapper.c → libvbox_jsc.so）。
#
# 结构：
#   libvbox_jsc.so ──DT_NEEDED──▶ libjsc.so（预编译，React Native 生态
#   `jsc-android` r250231 产物，由 scripts/fetch-jsc-android.sh 就位到
#   src/main/jniLibs/<abi>/，AGP 自动随 APK 打入 lib/<abi>/）
#
# 加载链（运行时）：MainActivity.onCreate → System.loadLibrary("vbox_jsc")
#   （linker 按 SONAME 自动解析同目录 libjsc.so）→ Dart FFI
#   `DynamicLibrary.open("libvbox_jsc.so")` 命中已加载实例。
# 加载失败（非四 ABI 设备等）不 crash：Dart 侧 isAvailable=false，
# 工厂按 D6 自动降级 QuickJS（降级可观测，见 spider_engine_factory.dart）。
#
# ABI 形状：与 quickjs/wrapper.c 的 vq_* 完全对齐（Q-05 三端同一 ABI）；
# 符号可见性 hidden + wrapper.h 的 VJ_EXPORT（default）→ 仅导出 vj_*。
cmake_minimum_required(VERSION 3.22)
# 批次 I · ND-01-native：node_bridge（C++，node::Start）与 JSC wrapper（C）同工程编译，故启用 CXX。
project(vbox_jsc LANGUAGES C CXX)

set(CMAKE_C_STANDARD 99)

# 项目根（android/app/src/main/jni 上溯 5 层）
get_filename_component(VBOX_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)

# JSC 预编译库（IMPORTED，按当前 ABI 分派）
set(JSC_PREBUILT "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libjsc.so")
if(NOT EXISTS "${JSC_PREBUILT}")
    message(FATAL_ERROR
        "libjsc.so(${ANDROID_ABI}) 缺失：请先运行 scripts/fetch-jsc-android.sh"
        "（原生二进制不入 git，见同脚本头注释）")
endif()

add_library(jsc SHARED IMPORTED)
set_target_properties(jsc PROPERTIES IMPORTED_LOCATION "${JSC_PREBUILT}")

add_library(vbox_jsc SHARED "${VBOX_ROOT}/jsc/wrapper.c")

target_include_directories(vbox_jsc PRIVATE "${VBOX_ROOT}/jsc/include")

set_target_properties(vbox_jsc PROPERTIES
    C_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN TRUE)

target_link_libraries(vbox_jsc PRIVATE jsc)

# ─────────────────────────────────────────────────────────────────────────────
# G-03-B-Android · QuickJS 引擎兜底（D6 降级链闭环，对齐 iOS QJSSpiderEngine 语义）
#
#   libvbox_quickjs.so（quickjs/wrapper.c + quickjs 核心五文件，纯 C99 零外部依赖）
#
#   背景：jsc-android r250231 预编译 libjsc.so 为 4KB 页对齐（2018 年 RN 生态
#   产物，已停更），Android 15+ 16KB 页设备加载失败 → D6 降级 QuickJS 时
#   此前安卓无构建目标（libvbox_quickjs.so 缺失）→ 报「QuickJS 原生库未打包」。
#   本 target 用 NDK 现场编译 QuickJS（16KB 对齐），兜底链两端补齐。
#
#   加载链：Dart FFI `DynamicLibrary.open("libvbox_quickjs.so")` 直接命中
#   APK lib/<abi>/（无 JNI 预加载需求）。
#
#   16KB 页对齐：显式 `-Wl,-z,max-page-size=16384`（NDK r27 起默认，
#   显式声明对旧 NDK 兜底，与 AGP `useLegacyPackaging` 无关）。
#
#   不编 quickjs-libc.c：stdio/open 等宿主 API 不进 App（wrapper.c 未用，
#   蜘蛛脚本的 console/print 由 wrapper 注册 no-op，见 wrapper.c）。
# ─────────────────────────────────────────────────────────────────────────────
set(QJS_DIR "${VBOX_ROOT}/quickjs/quickjs-2024-01-13")
file(READ "${QJS_DIR}/VERSION" QJS_VERSION)
string(STRIP "${QJS_VERSION}" QJS_VERSION)

add_library(vbox_quickjs SHARED
    "${VBOX_ROOT}/quickjs/wrapper.c"
    "${QJS_DIR}/quickjs.c"
    "${QJS_DIR}/cutils.c"
    "${QJS_DIR}/libbf.c"
    "${QJS_DIR}/libregexp.c"
    "${QJS_DIR}/libunicode.c")

target_include_directories(vbox_quickjs PRIVATE "${QJS_DIR}")

# 与 quickjs Makefile 一致的必要宏（build_quickjs_wrapper.sh 同口径）
target_compile_definitions(vbox_quickjs PRIVATE
    CONFIG_VERSION="${QJS_VERSION}"
    # 官方 Makefile 口径（CONFIG_BIGNUM=y）：启用 bignum/十进制大数（USE_FFT_MUL
    # / USE_BF_DEC），缺失会导致 libbf.c 内 bfdec_* undefined reference 与
    # JS_ToFloat64 大数行为偏差；_GNU_SOURCE 显式声明（NDK 默认开启，显式兜底）。
    CONFIG_BIGNUM
    _GNU_SOURCE)

# 16KB 页对齐（Android 15+ 设备强制要求，见上方说明）
target_link_options(vbox_quickjs PRIVATE "-Wl,-z,max-page-size=16384")

target_link_libraries(vbox_quickjs PRIVATE m)

# ─────────────────────────────────────────────────────────────────────────────
# 批次 I · ND-01-native：Node 引擎 JNI 桥（对齐 iOS NodeRunner.mm + NodeMobile.xcframework）
#
#   头文件：src/main/jni/libnode/include/node/node.h（node::Start 入口）
#   预编译：../jniLibs/${ANDROID_ABI}/libnode.so（AGP 随 APK 打入 lib/<abi>/）
#   产物：libnode_bridge.so（加载链 NodeBridge → loadLibrary("node_bridge") + ("node")）
#   STL：libnode 以 libc++_shared 构建 → gradle 传 -DANDROID_STL=c++_shared 匹配 ABI
#
# 前置：scripts/fetch-nodejs-mobile-android.sh（同 iOS build-ipa.yml 的 NodeMobile 下载步骤）。
#
# 开关 VBOX_NODE_BRIDGE（缺省 ON）：App 构建（AGP）须编译 JNI 桥；而 build-jsc.yml 的
# JSC 独立构建只需 vbox_jsc（且遍历含 x86 的四 ABI，nodejs-mobile 仅提供三 ABI），
# 故该工作流转 -DVBOX_NODE_BRIDGE=OFF，避免因缺 libnode.so 触发下方 FATAL_ERROR。
# ─────────────────────────────────────────────────────────────────────────────
option(VBOX_NODE_BRIDGE "编译 Node 引擎 JNI 桥（需 libnode.so；JSC 独立构建可关闭）" ON)

if(VBOX_NODE_BRIDGE)
    set(NODE_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/libnode/include/node")
    set(NODE_PREBUILT "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libnode.so")
    if(NOT EXISTS "${NODE_PREBUILT}")
        message(FATAL_ERROR
            "libnode.so(${ANDROID_ABI}) 缺失：请先运行 scripts/fetch-nodejs-mobile-android.sh"
            "（原生二进制不入 git，见同脚本头注释）")
    endif()

    add_library(libnode SHARED IMPORTED)
    set_target_properties(libnode PROPERTIES IMPORTED_LOCATION "${NODE_PREBUILT}")

    add_library(node_bridge SHARED "${CMAKE_CURRENT_SOURCE_DIR}/node_bridge.cpp")

    target_include_directories(node_bridge PRIVATE "${NODE_INCLUDE_DIR}")

    target_link_libraries(node_bridge PRIVATE libnode)

    find_library(log-lib log)
    target_link_libraries(node_bridge PRIVATE ${log-lib})
endif()
