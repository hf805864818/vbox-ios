//
//  PythonBridge.m
//  vbox
//
//  ObjC 桥接层 —— 连接 Swift 和 CPython 解释器
//  负责 Python 解释器的生命周期管理和 Spider 脚本调用
//

#import "PythonBridge.h"
#import "PythonLogStore.h"
#import "PythonWebViewBridge.h"
#import <Python/Python.h>   // iOS framework 标准 include (对应 Python.framework/Headers/Python.h)
#include <pthread.h>

// 便捷函数: 同时打 NSLog + 写入 PythonLogStore(开启时)
static inline void PYBridgeLog(NSString *msg) {
    NSLog(@"%@", msg);
    [PythonLogStore appendLog:msg];
}

static pthread_mutex_t _pyMutex = PTHREAD_MUTEX_INITIALIZER;
static BOOL _pyInitialized = NO;
static NSString *_pyHome = nil;
// _cachedMainModule/_cachedGlobals 已移除: 每次调用创建独立 globals，支持并发

@implementation PythonSpiderBridge

#pragma mark - Lifecycle

+ (void)initializePythonIfNeeded {
    // 锁: 保护 _pyInitialized 检查
    pthread_mutex_lock(&_pyMutex);
    BOOL alreadyInit = _pyInitialized;
    pthread_mutex_unlock(&_pyMutex);
    if (alreadyInit) return;
    
    // 定位标准库目录
    NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
    _pyHome = [resourcePath stringByAppendingPathComponent:@"python-stdlib"];
    setenv("PYTHONHOME", [_pyHome UTF8String], 1);
    setenv("PYTHONPATH", [_pyHome UTF8String], 1);
    setenv("PYTHONDONTWRITEBYTECODE", "1", 1);
    
    // Py_Initialize 必须在主线程首次调用
    void (^initBlock)(void) = ^{
        [self performMainThreadPythonInit];
    };
    if ([NSThread isMainThread]) {
        initBlock();
    } else {
        // 先释放锁再派发主线程, 避免持锁 dispatch_sync 死锁
        dispatch_sync(dispatch_get_main_queue(), initBlock);
    }
}

+ (void)performMainThreadPythonInit {
    // 已在主线程
    pthread_mutex_lock(&_pyMutex);
    if (_pyInitialized) {
        pthread_mutex_unlock(&_pyMutex);
        return;
    }
    @try {
        Py_Initialize();
        if (!Py_IsInitialized()) {
            PYBridgeLog(@"[PythonBridge] ❌ Py_Initialize 失败");
            pthread_mutex_unlock(&_pyMutex);
            return;
        }
        
        // 注入 sys.path
        NSString *sitePackages = [_pyHome stringByAppendingPathComponent:@"site-packages"];
        NSString *initCmd = [NSString stringWithFormat:
            @"import sys\n"
            @"sys.path.insert(0, '%@')\n"
            @"sys.path.insert(0, '%@')\n"
            @"sys.path.insert(0, '%@/lib/python3.14')\n"
            @"sys.dont_write_bytecode = True\n",
            sitePackages, _pyHome, _pyHome];
        if (PyRun_SimpleString([initCmd UTF8String]) != 0) {
            PyErr_Print();
            PYBridgeLog(@"[PythonBridge] ❌ sys.path 注入失败");
            pthread_mutex_unlock(&_pyMutex);
            return;
        }
        
        _pyInitialized = YES;
        PYBridgeLog([NSString stringWithFormat:@"[PythonBridge] ✅ Python 解释器初始化完成 (home: %@)", _pyHome]);
        
        // 注册 webview_fetch 全局函数 (WKWebView 桥接)
        // 让 Python 脚本可以调用 WKWebView 绕过反爬验证 (如 TAC 验证码)
        [PythonWebViewBridgeOC registerWebViewFetch];
        
        // ★ 关键: 释放 GIL，允许后台线程通过 PyGILState_Ensure() 获取
        // Py_Initialize 后主线程持有 GIL，不释放的话后台线程无法安全调用 Python C API
        PyEval_SaveThread();
    } @catch (NSException *exception) {
        PYBridgeLog([NSString stringWithFormat:@"[PythonBridge] ❌ 初始化异常: %@", exception.reason]);
    }
    pthread_mutex_unlock(&_pyMutex);
}

+ (BOOL)isPythonInitialized {
    return _pyInitialized;
}

+ (void)finalizePython {
    pthread_mutex_lock(&_pyMutex);
    if (_pyInitialized && Py_IsInitialized()) {
        // 释放 Python 资源
        Py_FinalizeEx();
        _pyInitialized = NO;
        PYBridgeLog(@"[PythonBridge] 🔚 Python 解释器已销毁");
    }
    pthread_mutex_unlock(&_pyMutex);
}

#pragma mark - Spider Invocation

+ (NSString *)callSpider:(NSString *)scriptPath
                function:(NSString *)functionName
                    args:(NSString *)argsJSON {
    return [self callSpider:scriptPath injectDict:nil function:functionName args:argsJSON];
}

+ (NSString *)callSpider:(NSString *)scriptPath
              injectDict:(NSDictionary *)injectDict
                function:(NSString *)functionName
                    args:(NSString *)argsJSON {
    
    if (!scriptPath || !functionName) return nil;

    // 确保解释器已初始化
    [self initializePythonIfNeeded];
    if (!_pyInitialized) return nil;

    // ★ 不再使用 pthread_mutex 锁住整个 callSpider
    // GIL (PyGILState_Ensure/Release) 保证 Python C API 线程安全
    // I/O 期间 GIL 自动释放，多线程可并发执行网络请求

    // ★ 关键: 获取 GIL — 后台线程调用 Python C API 必须持有 GIL
    // Py_Initialize 在主线程执行并持有 GIL，初始化后已通过 PyEval_SaveThread 释放
    // 此处通过 PyGILState_Ensure 在当前线程重新获取 GIL
    PyGILState_STATE gilState = PyGILState_Ensure();

    NSString *result = nil;
    PyObject *globals = NULL;
    PyObject *spider = NULL;
    FILE *fp = NULL;

    @try {
        // === Phase 1: 为每次调用创建独立的全局字典 ===
        // 不再共享 __main__ globals，避免并发 callSpider 时 Spider 类互相覆盖
        // 新字典包含 __builtins__，脚本可正常使用内置函数
        globals = PyDict_New();
        if (!globals) goto cleanup;
        PyObject *builtins = PyEval_GetBuiltins();
        if (builtins) {
            PyDict_SetItemString(globals, "__builtins__", builtins);
        }

        // === Phase 1.5: 注入外部上下文（福利域名/代理等）===
        // injectDict 中的键值对被写入 globals，脚本的 base.spider.Spider
        // 在 __init__ 时可读取这些值实现自适应。
        // 支持的类型：NSString → PyUnicode, NSNumber → PyLong/PyFloat/PyBool,
        //            NSArray → PyList (元素递归转换), NSNull → Py_None
        if (injectDict != nil && injectDict.count > 0) {
            for (NSString *key in injectDict) {
                id value = injectDict[key];
                PyObject *pyValue = [self pyObjectFromObjC:value];
                if (pyValue) {
                    PyDict_SetItemString(globals, [key UTF8String], pyValue);
                    Py_DECREF(pyValue);
                }
            }
        }
        
        // === Phase 2: 加载脚本文件 ===
        fp = fopen([scriptPath UTF8String], "r");
        if (!fp) {
            PYBridgeLog([NSString stringWithFormat:@"[PythonBridge] ❌ 无法打开脚本: %@", scriptPath]);
            goto cleanup;
        }
        
        // 注入脚本路径信息
        NSString *injectPath = [NSString stringWithFormat:
            @"import sys; sys.path.insert(0, '%@')",
            [[scriptPath stringByDeletingLastPathComponent] stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"]];
        PyRun_SimpleString([injectPath UTF8String]);
        
        // 执行脚本（每次重新定义 Spider 类）
        PyObject *runRet = PyRun_File(fp, [[scriptPath lastPathComponent] UTF8String],
                                       Py_file_input, globals, globals);
        if (!runRet) {
            PyErr_Print();
            PYBridgeLog([NSString stringWithFormat:@"[PythonBridge] ❌ 脚本执行失败: %@", [scriptPath lastPathComponent]]);
            goto cleanup;
        }
        Py_DECREF(runRet);
        fclose(fp); fp = NULL;
        
        // === Phase 3: 实例化 Spider 类 ===
        PyObject *spiderClass = PyDict_GetItemString(globals, "Spider");
        if (!spiderClass || !PyCallable_Check(spiderClass)) {
            PYBridgeLog([NSString stringWithFormat:@"[PythonBridge] ❌ 未找到 Spider 类: %@", [scriptPath lastPathComponent]]);
            goto cleanup;
        }
        
        spider = PyObject_CallObject(spiderClass, NULL);
        if (!spider) {
            PyErr_Print();
            PYBridgeLog(@"[PythonBridge] ❌ Spider 实例化失败");
            goto cleanup;
        }
        
        // 调 init(extend="")
        PyObject *initMethod = PyObject_GetAttrString(spider, "init");
        if (initMethod && PyCallable_Check(initMethod)) {
            PyObject *initStandardArgs = PyTuple_Pack(1, PyUnicode_FromString(""));
            PyObject *initArgs = [self adaptArgs:initStandardArgs
                                     forCallable:initMethod
                                    functionName:@"init"
                                      scriptName:[scriptPath lastPathComponent]];
            Py_XDECREF(initStandardArgs);
            PyObject *initRet = initArgs ? PyObject_Call(initMethod, initArgs, NULL) : NULL;
            if (initRet) Py_DECREF(initRet);
            else { PyErr_Clear(); }
            Py_XDECREF(initArgs);
        }
        Py_XDECREF(initMethod);

        // === Phase 3.5: 实例属性注入（福利专区域名/代理自适应）===
        // 将 injectDict 中的键值对设为 Spider 实例的属性（实例级隔离）。
        // base.spider.Spider 的 _apply_injected_hosts / _proxy_enabled /
        // _proxy_url_template 通过 getattr(self, ...) 优先读取实例属性。
        // 每个实例独立持有注入值，100+ 平台并发也不会串域名。
        // 普通资源（injectDict=nil）跳过此段，行为不变。
        if (injectDict != nil && injectDict.count > 0) {
            for (NSString *key in injectDict) {
                id value = injectDict[key];
                PyObject *pyValue = [self pyObjectFromObjC:value];
                if (pyValue) {
                    PyObject_SetAttrString(spider, [key UTF8String], pyValue);
                    Py_DECREF(pyValue);
                }
            }
            // 重新应用域名：__init__ 时实例属性尚未注入，
            // 此刻补上，让 self.host / _backup_hosts 立即生效。
            PyObject *applyMethod = PyObject_GetAttrString(spider, "_apply_injected_hosts");
            if (applyMethod) {
                PyObject *applyRet = PyObject_CallObject(applyMethod, NULL);
                Py_XDECREF(applyRet);
                Py_DECREF(applyMethod);
            } else {
                PyErr_Clear();
            }
        }

        // === Phase 4: 调用目标方法 ===
        PyObject *method = PyObject_GetAttrString(spider, [functionName UTF8String]);
        if (!method || !PyCallable_Check(method)) {
            PYBridgeLog([NSString stringWithFormat:@"[PythonBridge] ❌ 未找到方法: %@.%@", [scriptPath lastPathComponent], functionName]);
            Py_XDECREF(method);
            goto cleanup;
        }
        
        // 构造标准参数，再由兼容层根据脚本真实签名裁剪参数。
        PyObject *standardArgs = [self buildArgsForFunction:functionName jsonArgs:argsJSON];
        PyObject *pyArgs = [self adaptArgs:standardArgs
                               forCallable:method
                              functionName:functionName
                                scriptName:[scriptPath lastPathComponent]];
        Py_XDECREF(standardArgs);
        if (!pyArgs) {
            PyErr_Clear();
            PYBridgeLog([NSString stringWithFormat:@"[PythonBridge] ❌ %@.%@ 参数构建失败", [scriptPath lastPathComponent], functionName]);
            Py_DECREF(method);
            goto cleanup;
        }
        PyObject *callRet = PyObject_Call(method, pyArgs, NULL);
        
        if (callRet) {
            // ★ 使用 json.dumps() 序列化返回值为标准 JSON
            // 失败则记录 repr 到日志 (不作为返回值, 因为 repr 不是合法 JSON)
            PyObject *jsonModule = PyImport_ImportModule("json");
            if (jsonModule) {
                PyObject *dumpsFunc = PyObject_GetAttrString(jsonModule, "dumps");
                if (dumpsFunc && PyCallable_Check(dumpsFunc)) {
                    PyObject *dumpsArgs = PyTuple_Pack(1, callRet);
                    PyObject *jsonStr = PyObject_Call(dumpsFunc, dumpsArgs, NULL);
                    Py_DECREF(dumpsArgs);
                    if (jsonStr) {
                        const char *cstr = PyUnicode_AsUTF8(jsonStr);
                        if (cstr) {
                            result = [NSString stringWithUTF8String:cstr];
                        }
                        Py_DECREF(jsonStr);
                    } else {
                        // json.dumps 失败 → 记录 repr 用于调试, 返回 nil
                        PyErr_Clear();
                        PyObject *repr = PyObject_Repr(callRet);
                        if (repr) {
                            const char *rstr = PyUnicode_AsUTF8(repr);
                            if (rstr) {
                                PYBridgeLog([NSString stringWithFormat:
                                    @"[PythonBridge] ⚠️ %@.%@ 返回值无法 JSON 序列化, repr: %s",
                                    [scriptPath lastPathComponent], functionName, rstr]);
                            }
                            Py_DECREF(repr);
                        }
                    }
                    Py_XDECREF(dumpsFunc);
                }
                Py_DECREF(jsonModule);
            }
            Py_DECREF(callRet);
        } else {
            PyErr_Print();
            PYBridgeLog([NSString stringWithFormat:@"[PythonBridge] ❌ %@.%@ 调用失败", [scriptPath lastPathComponent], functionName]);
        }
        
        Py_DECREF(method);
        Py_XDECREF(pyArgs);
        
    } @catch (NSException *exception) {
        PYBridgeLog([NSString stringWithFormat:@"[PythonBridge] ❌ 异常: %@", exception.reason]);
    }
    
cleanup:
    if (fp) fclose(fp);
    Py_XDECREF(spider);
    Py_XDECREF(globals);   // ★ 每次调用创建的独立 globals，用完释放

    // ★ 释放 GIL — 允许其他线程获取 GIL 执行 Python 代码
    PyGILState_Release(gilState);

    return result;
}

#pragma mark - Local Proxy (binary return)

/// 调用 Spider 的 localProxy 方法
/// localProxy 返回 [statusCode, contentType, body] 其中 body 是 bytes
/// 不能用 json.dumps 序列化，需手动提取
+ (NSDictionary *)callLocalProxy:(NSString *)scriptPath
                     injectDict:(NSDictionary *)injectDict
                           args:(NSString *)argsJSON {

    if (!scriptPath) return nil;

    [self initializePythonIfNeeded];
    if (!_pyInitialized) return nil;

    PyGILState_STATE gilState = PyGILState_Ensure();

    NSDictionary *result = nil;
    PyObject *globals = NULL;
    PyObject *spider = NULL;
    FILE *fp = NULL;

    @try {
        // Phase 1: 创建独立 globals
        globals = PyDict_New();
        if (!globals) goto proxyCleanup;
        PyObject *builtins = PyEval_GetBuiltins();
        if (builtins) {
            PyDict_SetItemString(globals, "__builtins__", builtins);
        }

        // Phase 1.5: 注入上下文
        if (injectDict != nil && injectDict.count > 0) {
            for (NSString *key in injectDict) {
                id value = injectDict[key];
                PyObject *pyValue = [self pyObjectFromObjC:value];
                if (pyValue) {
                    PyDict_SetItemString(globals, [key UTF8String], pyValue);
                    Py_DECREF(pyValue);
                }
            }
        }

        // Phase 2: 加载脚本
        fp = fopen([scriptPath UTF8String], "r");
        if (!fp) {
            PYBridgeLog([NSString stringWithFormat:@"[PythonBridge] ❌ localProxy: 无法打开脚本: %@", scriptPath]);
            goto proxyCleanup;
        }

        NSString *injectPath = [NSString stringWithFormat:
            @"import sys; sys.path.insert(0, '%@')",
            [[scriptPath stringByDeletingLastPathComponent] stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"]];
        PyRun_SimpleString([injectPath UTF8String]);

        PyObject *runRet = PyRun_File(fp, [[scriptPath lastPathComponent] UTF8String],
                                       Py_file_input, globals, globals);
        if (!runRet) {
            PyErr_Print();
            goto proxyCleanup;
        }
        Py_DECREF(runRet);
        fclose(fp); fp = NULL;

        // Phase 3: 实例化 Spider
        PyObject *spiderClass = PyDict_GetItemString(globals, "Spider");
        if (!spiderClass || !PyCallable_Check(spiderClass)) goto proxyCleanup;

        spider = PyObject_CallObject(spiderClass, NULL);
        if (!spider) { PyErr_Clear(); goto proxyCleanup; }

        // 调 init(extend="")
        PyObject *initMethod = PyObject_GetAttrString(spider, "init");
        if (initMethod && PyCallable_Check(initMethod)) {
            PyObject *initStandardArgs = PyTuple_Pack(1, PyUnicode_FromString(""));
            PyObject *initArgs = [self adaptArgs:initStandardArgs
                                     forCallable:initMethod
                                    functionName:@"init"
                                      scriptName:[scriptPath lastPathComponent]];
            Py_XDECREF(initStandardArgs);
            PyObject *initRet = initArgs ? PyObject_Call(initMethod, initArgs, NULL) : NULL;
            Py_XDECREF(initRet);
            Py_XDECREF(initArgs);
        }
        Py_XDECREF(initMethod);

        // Phase 3.5: 实例属性注入
        if (injectDict != nil && injectDict.count > 0) {
            for (NSString *key in injectDict) {
                id value = injectDict[key];
                PyObject *pyValue = [self pyObjectFromObjC:value];
                if (pyValue) {
                    PyObject_SetAttrString(spider, [key UTF8String], pyValue);
                    Py_DECREF(pyValue);
                }
            }
            PyObject *applyMethod = PyObject_GetAttrString(spider, "_apply_injected_hosts");
            if (applyMethod) {
                PyObject *applyRet = PyObject_CallObject(applyMethod, NULL);
                Py_XDECREF(applyRet);
                Py_DECREF(applyMethod);
            } else {
                PyErr_Clear();
            }
        }

        // Phase 4: 调用 localProxy(params_dict)
        PyObject *method = PyObject_GetAttrString(spider, "localProxy");
        if (!method || !PyCallable_Check(method)) {
            Py_XDECREF(method);
            PyErr_Clear();
            goto proxyCleanup;
        }

        // 构造 params dict
        PyObject *paramsDict = PyDict_New();
        if (argsJSON) {
            NSData *jsonData = [argsJSON dataUsingEncoding:NSUTF8StringEncoding];
            NSError *err;
            NSDictionary *d = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&err];
            if (!err && d) {
                for (NSString *k in d) {
                    id v = d[k];
                    PyDict_SetItemString(paramsDict, [k UTF8String],
                        PyUnicode_FromString([[v description] UTF8String]));
                }
            }
        }

        PyObject *pyArgs = PyTuple_Pack(1, paramsDict);
        Py_DECREF(paramsDict);
        PyObject *callRet = PyObject_Call(method, pyArgs, NULL);
        Py_DECREF(pyArgs);
        Py_DECREF(method);

        if (!callRet) {
            PyErr_Print();
            goto proxyCleanup;
        }

        // Phase 5: 提取 [statusCode, contentType, body]
        // callRet 应该是一个 list/tuple: [int, str, bytes]
        if (PyList_Check(callRet) || PyTuple_Check(callRet)) {
            Py_ssize_t len = PySequence_Size(callRet);
            if (len >= 3) {
                PyObject *pyStatus = PySequence_GetItem(callRet, 0);
                PyObject *pyContentType = PySequence_GetItem(callRet, 1);
                PyObject *pyBody = PySequence_GetItem(callRet, 2);

                int status = 200;
                if (pyStatus) {
                    status = (int)PyLong_AsLong(pyStatus);
                    if (status == 0) status = 200;
                    Py_DECREF(pyStatus);
                }

                NSString *contentType = @"application/octet-stream";
                if (pyContentType) {
                    const char *cs = PyUnicode_AsUTF8(pyContentType);
                    if (cs) contentType = [NSString stringWithUTF8String:cs];
                    Py_DECREF(pyContentType);
                }

                NSData *bodyData = [NSData data];
                if (pyBody) {
                    if (PyBytes_Check(pyBody)) {
                        char *buf;
                        Py_ssize_t bufLen;
                        PyBytes_AsStringAndSize(pyBody, &buf, &bufLen);
                        if (bufLen > 0) {
                            bodyData = [NSData dataWithBytes:buf length:bufLen];
                        }
                    } else if (PyByteArray_Check(pyBody)) {
                        char *buf = PyByteArray_AsString(pyBody);
                        Py_ssize_t bufLen = PyByteArray_Size(pyBody);
                        if (bufLen > 0) {
                            bodyData = [NSData dataWithBytes:buf length:bufLen];
                        }
                    }
                    Py_DECREF(pyBody);
                }

                result = @{
                    @"status": @(status),
                    @"contentType": contentType,
                    @"data": bodyData
                };
            }
        }
        Py_DECREF(callRet);

    } @catch (NSException *exception) {
        PYBridgeLog([NSString stringWithFormat:@"[PythonBridge] ❌ localProxy 异常: %@", exception.reason]);
    }

proxyCleanup:
    if (fp) fclose(fp);
    Py_XDECREF(spider);
    Py_XDECREF(globals);
    PyGILState_Release(gilState);

    return result;
}

#pragma mark - Argument Building

/// 根据 Python bound method 的真实签名裁剪标准参数。
/// 只改变参数数量，不改变参数含义；无法读取签名时保持标准参数，交给 Python 报原始错误。
+ (PyObject *)adaptArgs:(PyObject *)standardArgs
            forCallable:(PyObject *)callable
           functionName:(NSString *)functionName
             scriptName:(NSString *)scriptName {
    if (!standardArgs || !PyTuple_Check(standardArgs) || !callable) {
        Py_XINCREF(standardArgs);
        return standardArgs;
    }

    Py_ssize_t standardCount = PyTuple_Size(standardArgs);
    if (standardCount <= 0) {
        Py_INCREF(standardArgs);
        return standardArgs;
    }

    PyObject *inspectModule = PyImport_ImportModule("inspect");
    if (!inspectModule) {
        PyErr_Clear();
        Py_INCREF(standardArgs);
        return standardArgs;
    }

    PyObject *signatureFunc = PyObject_GetAttrString(inspectModule, "signature");
    if (!signatureFunc || !PyCallable_Check(signatureFunc)) {
        Py_XDECREF(signatureFunc);
        Py_DECREF(inspectModule);
        Py_INCREF(standardArgs);
        return standardArgs;
    }

    PyObject *signature = PyObject_CallFunctionObjArgs(signatureFunc, callable, NULL);
    Py_DECREF(signatureFunc);
    Py_DECREF(inspectModule);

    if (!signature) {
        PyErr_Clear();
        Py_INCREF(standardArgs);
        return standardArgs;
    }

    PyObject *parameters = PyObject_GetAttrString(signature, "parameters");
    Py_DECREF(signature);
    if (!parameters) {
        PyErr_Clear();
        Py_INCREF(standardArgs);
        return standardArgs;
    }

    PyObject *items = PyMapping_Items(parameters);
    Py_DECREF(parameters);
    if (!items) {
        PyErr_Clear();
        Py_INCREF(standardArgs);
        return standardArgs;
    }

    Py_ssize_t positionalCount = 0;
    BOOL hasVarArgs = NO;
    Py_ssize_t itemCount = PyList_Size(items);
    for (Py_ssize_t i = 0; i < itemCount; i++) {
        PyObject *item = PyList_GetItem(items, i);  // borrowed
        if (!item || !PyTuple_Check(item) || PyTuple_Size(item) < 2) continue;

        PyObject *param = PyTuple_GetItem(item, 1); // borrowed
        PyObject *kindObj = PyObject_GetAttrString(param, "kind");
        if (!kindObj) {
            PyErr_Clear();
            continue;
        }

        long kind = PyLong_AsLong(kindObj);
        Py_DECREF(kindObj);
        if (PyErr_Occurred()) {
            PyErr_Clear();
            continue;
        }

        // inspect.Parameter: POSITIONAL_ONLY=0, POSITIONAL_OR_KEYWORD=1, VAR_POSITIONAL=2
        if (kind == 0 || kind == 1) {
            positionalCount++;
        } else if (kind == 2) {
            hasVarArgs = YES;
        }
    }
    Py_DECREF(items);

    if (hasVarArgs || positionalCount >= standardCount) {
        Py_INCREF(standardArgs);
        return standardArgs;
    }

    if (positionalCount >= 0 && positionalCount < standardCount) {
        PYBridgeLog([NSString stringWithFormat:
            @"[PythonBridge] ℹ️ 方法参数适配: %@.%@ 标准%zd个 → 实际%zd个",
            scriptName, functionName, standardCount, positionalCount]);
        return PyTuple_GetSlice(standardArgs, 0, positionalCount);
    }

    Py_INCREF(standardArgs);
    return standardArgs;
}

/// 根据 Spider 方法签名构建 Python 参数
+ (PyObject *)buildArgsForFunction:(NSString *)functionName jsonArgs:(NSString *)jsonArgs {
    
    if ([functionName isEqualToString:@"homeContent"]) {
        // homeContent(filter) → 传入 {} 或空 dict
        if (jsonArgs) {
            // 尝试解析 JSON
            NSData *data = [jsonArgs dataUsingEncoding:NSUTF8StringEncoding];
            NSError *err;
            NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
            if (!err && dict) {
                PyObject *pyDict = PyDict_New();
                for (NSString *key in dict) {
                    id val = dict[key];
                    PyDict_SetItemString(pyDict, [key UTF8String],
                        PyUnicode_FromString([[val description] UTF8String]));
                }
                return PyTuple_Pack(1, pyDict);
            }
        }
        return PyTuple_Pack(1, PyDict_New());
    }
    
    if ([functionName isEqualToString:@"homeVideoContent"]) {
        return PyTuple_Pack(0);  // 无参数
    }
    
    if ([functionName isEqualToString:@"categoryContent"]) {
        // categoryContent(tid, pg, filter, extend) — Spider 标准签名
        // ★ 修复: 之前 extend 参数始终传空 dict, 导致筛选器不生效
        if (jsonArgs) {
            NSData *data = [jsonArgs dataUsingEncoding:NSUTF8StringEncoding];
            NSError *err;
            NSDictionary *d = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
            if (!err && d) {
                NSString *tid = d[@"tid"] ?: @"";
                NSString *pg = d[@"pg"] ?: @"1";

                // ★ 从 JSON 中提取 extend 参数, 转为 Python dict
                PyObject *extendDict = PyDict_New();
                NSString *extendStr = d[@"extend"];
                if (extendStr && extendStr.length > 0 && ![extendStr isEqualToString:@"{}"]) {
                    // extend 是 JSON 字符串, 解析后转为 Python dict
                    NSData *extendData = [extendStr dataUsingEncoding:NSUTF8StringEncoding];
                    NSDictionary *extendObj = [NSJSONSerialization JSONObjectWithData:extendData options:0 error:nil];
                    if (extendObj) {
                        for (NSString *k in extendObj) {
                            id v = extendObj[k];
                            PyDict_SetItemString(extendDict, [k UTF8String],
                                PyUnicode_FromString([[v description] UTF8String]));
                        }
                    }
                }

                return PyTuple_Pack(4,
                    PyUnicode_FromString([tid UTF8String]),
                    PyUnicode_FromString([pg UTF8String]),
                    PyDict_New(),
                    extendDict
                );
            }
        }
        return PyTuple_Pack(4,
            PyUnicode_FromString(""),
            PyUnicode_FromString("1"),
            PyDict_New(),
            PyDict_New()
        );
    }
    
    if ([functionName isEqualToString:@"detailContent"]) {
        // detailContent(array) → array 是 vod_id 列表
        if (jsonArgs) {
            NSData *data = [jsonArgs dataUsingEncoding:NSUTF8StringEncoding];
            NSError *err;
            NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
            if (!err && arr) {
                PyObject *pyList = PyList_New((Py_ssize_t)arr.count);
                for (NSUInteger i = 0; i < arr.count; i++) {
                    PyList_SetItem(pyList, i,
                        PyUnicode_FromString([[arr[i] description] UTF8String]));
                }
                return PyTuple_Pack(1, pyList);
            }
        }
        return PyTuple_Pack(1, PyList_New(0));
    }
    
    if ([functionName isEqualToString:@"searchContent"]) {
        // searchContent(key, quick, pg)
        if (jsonArgs) {
            NSData *data = [jsonArgs dataUsingEncoding:NSUTF8StringEncoding];
            NSError *err;
            NSDictionary *d = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
            if (!err && d) {
                NSString *key = d[@"key"] ?: @"";
                NSString *pg = d[@"pg"] ?: @"1";
                return PyTuple_Pack(3,
                    PyUnicode_FromString([key UTF8String]),
                    PyUnicode_FromString("false"),
                    PyUnicode_FromString([pg UTF8String])
                );
            }
        }
        return PyTuple_Pack(3,
            PyUnicode_FromString(""),
            PyUnicode_FromString("false"),
            PyUnicode_FromString("1")
        );
    }
    
    if ([functionName isEqualToString:@"playerContent"]) {
        // playerContent(flag, id, vipFlags)
        if (jsonArgs) {
            NSData *data = [jsonArgs dataUsingEncoding:NSUTF8StringEncoding];
            NSError *err;
            NSDictionary *d = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
            if (!err && d) {
                NSString *flag = d[@"flag"] ?: @"";
                NSString *vid = d[@"id"] ?: @"";
                return PyTuple_Pack(3,
                    PyUnicode_FromString([flag UTF8String]),
                    PyUnicode_FromString([vid UTF8String]),
                    PyDict_New()
                );
            }
        }
        return PyTuple_Pack(3,
            PyUnicode_FromString(""),
            PyUnicode_FromString(""),
            PyDict_New()
        );
    }
    
    // 默认：传 JSON 字符串
    if (jsonArgs) {
        return PyTuple_Pack(1, PyUnicode_FromString([jsonArgs UTF8String]));
    }
    return PyTuple_Pack(0);
}

#pragma mark - ObjC → Python 类型转换

/// 将基础 ObjC 类型转换为对应的 Python 对象。
/// 支持：NSString → PyUnicode, NSNumber(bool) → PyBool,
///       NSNumber(int) → PyLong, NSNumber(double) → PyFloat,
///       NSArray → PyList (递归), NSDictionary → PyDict (递归),
///       NSNull → Py_None。
/// 不支持的类型返回 nil。
+ (PyObject *)pyObjectFromObjC:(id)value {
    if (value == nil || value == [NSNull null]) {
        Py_RETURN_NONE;
    }
    if ([value isKindOfClass:[NSString class]]) {
        return PyUnicode_FromString([(NSString *)value UTF8String]);
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        NSNumber *num = (NSNumber *)value;
        const char *type = [num objCType];
        if (strcmp(type, @encode(BOOL)) == 0) {
            return PyBool_FromLong([num boolValue] ? 1 : 0);
        }
        if (strcmp(type, @encode(int)) == 0 ||
            strcmp(type, @encode(long)) == 0 ||
            strcmp(type, @encode(long long)) == 0 ||
            strcmp(type, @encode(short)) == 0 ||
            strcmp(type, @encode(char)) == 0 ||
            strcmp(type, @encode(unsigned int)) == 0 ||
            strcmp(type, @encode(unsigned long)) == 0 ||
            strcmp(type, @encode(unsigned long long)) == 0) {
            return PyLong_FromLongLong([num longLongValue]);
        }
        // float / double / CGFloat
        return PyFloat_FromDouble([num doubleValue]);
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSArray *arr = (NSArray *)value;
        PyObject *list = PyList_New((Py_ssize_t)arr.count);
        for (NSUInteger i = 0; i < arr.count; i++) {
            PyObject *item = [self pyObjectFromObjC:arr[i]];
            if (item) {
                PyList_SetItem(list, i, item);  // steals reference
            } else {
                Py_INCREF(Py_None);
                PyList_SetItem(list, i, Py_None);
            }
        }
        return list;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)value;
        PyObject *pyDict = PyDict_New();
        for (id key in dict) {
            if (![key isKindOfClass:[NSString class]]) continue;
            PyObject *pyValue = [self pyObjectFromObjC:dict[key]];
            if (pyValue) {
                PyDict_SetItemString(pyDict, [(NSString *)key UTF8String], pyValue);
                Py_DECREF(pyValue);
            }
        }
        return pyDict;
    }
    // 不支持的类型：返回 nil，调用方应跳过
    return nil;
}

@end
