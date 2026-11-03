//
//  node_bridge.cpp
//  vbox
//
//  Android 侧 Node 引擎 JNI 桥 —— 对齐 iOS `Libraries/NodeMobile/NodeRunner.mm`。
//
//  iOS：ObjC++ `node_start(argc, argv)`（NodeMobile.framework）
//  Android：JNI `node::Start(argc, argv)`（libnode.so，nodejs-mobile 官方 Android 入口）
//
//  官方要求：argv 各元素须位于**连续内存**（libuv 约束），且引擎须在独立后台线程运行、
//  单实例不可重启（与 iOS 语义一致）。
//

#include <jni.h>

#include <cstdlib>
#include <cstring>

#include "node.h"

extern "C" JNIEXPORT jint JNICALL
Java_com_vbox_player_NodeBridge_nativeStartNodeWithArguments(
    JNIEnv *env,
    jobject /* this */,
    jobjectArray arguments) {
  const jsize argumentCount = env->GetArrayLength(arguments);

  // 1) 计算连续内存所需字节数（每个参数含结尾 '\0'）
  int totalSize = 0;
  for (jsize i = 0; i < argumentCount; i++) {
    jstring element = static_cast<jstring>(env->GetObjectArrayElement(arguments, i));
    const char *arg = env->GetStringUTFChars(element, nullptr);
    totalSize += static_cast<int>(strlen(arg)) + 1;
    env->ReleaseStringUTFChars(element, arg);
    env->DeleteLocalRef(element);
  }

  // 2) 参数写入连续内存 + 组装 argv
  char *buffer = static_cast<char *>(calloc(totalSize > 0 ? totalSize : 1, sizeof(char)));
  char **argv = static_cast<char **>(calloc(argumentCount > 0 ? argumentCount : 1, sizeof(char *)));
  // 分配失败必须提前返回：node::Start 收到 nullptr argv 会 SIGSEGV 杀进程
  // （native 崩溃 Kotlin catch(Throwable) 接不住）。
  if (buffer == nullptr || argv == nullptr) {
    free(argv);
    free(buffer);
    return -1;
  }
  char *cursor = buffer;
  for (jsize i = 0; i < argumentCount; i++) {
    jstring element = static_cast<jstring>(env->GetObjectArrayElement(arguments, i));
    const char *arg = env->GetStringUTFChars(element, nullptr);
    const size_t len = strlen(arg);
    memcpy(cursor, arg, len);
    cursor[len] = '\0';  // 显式结尾，不依赖 calloc 清零（防御性）
    argv[i] = cursor;
    cursor += len + 1;
    env->ReleaseStringUTFChars(element, arg);
    env->DeleteLocalRef(element);
  }

  // 3) 启动引擎（阻塞至引擎退出；单实例不可重启，调用方须置于独立后台线程）
  const int result = node::Start(static_cast<int>(argumentCount), argv);

  free(argv);
  free(buffer);
  return static_cast<jint>(result);
}