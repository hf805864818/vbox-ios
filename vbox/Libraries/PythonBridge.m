//
//  PythonBridge.m
//  vbox
//
//  ObjC 桥接层 —— 连接 Swift 和 CPython 解释器
//  负责 Python 解释器的生命周期管理和 Spider 脚本调用
//

#import "PythonBridge.h"
#import "PythonLogStore.h"
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
static PyObject *_cachedMainModule = NULL;   // 缓存 __main__ 模块，避免每次 PyImport_AddModule 崩溃
static PyObject *_cachedGlobals = NULL;      // 缓存的 globals 字典

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
    
    if (!scriptPath || !functionName) return nil;
    
    // 确保解释器已初始化
    [self initializePythonIfNeeded];
    if (!_pyInitialized) return nil;
    
    pthread_mutex_lock(&_pyMutex);
    
    // ★ 关键: 获取 GIL — 后台线程调用 Python C API 必须持有 GIL
    // Py_Initialize 在主线程执行并持有 GIL，初始化后已通过 PyEval_SaveThread 释放
    // 此处通过 PyGILState_Ensure 在当前线程重新获取 GIL
    PyGILState_STATE gilState = PyGILState_Ensure();
    
    NSString *result = nil;
    PyObject *globals = NULL;
    PyObject *spider = NULL;
    FILE *fp = NULL;
    
    @try {
        // === Phase 1: 获取/复用 __main__ globals (避免每次 PyImport_AddModule 崩溃) ===
        // 复用缓存的 globals; 若为空则创建 __main__
        if (_cachedGlobals == NULL) {
            PyObject *mainModule = PyImport_AddModule("__main__");
            if (!mainModule) goto cleanup;
            _cachedMainModule = mainModule;
            _cachedGlobals = PyModule_GetDict(mainModule);  // 借出引用, 不 DECREF
        }
        globals = _cachedGlobals;
        if (!globals) goto cleanup;
        
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
            PyObject *initArgs = PyTuple_Pack(1, PyUnicode_FromString(""));
            PyObject *initRet = PyObject_Call(initMethod, initArgs, NULL);
            if (initRet) Py_DECREF(initRet);
            else { PyErr_Clear(); }
            Py_DECREF(initArgs);
        }
        Py_XDECREF(initMethod);
        
        // === Phase 4: 调用目标方法 ===
        PyObject *method = PyObject_GetAttrString(spider, [functionName UTF8String]);
        if (!method || !PyCallable_Check(method)) {
            PYBridgeLog([NSString stringWithFormat:@"[PythonBridge] ❌ 未找到方法: %@.%@", [scriptPath lastPathComponent], functionName]);
            Py_XDECREF(method);
            goto cleanup;
        }
        
        // 构造参数 — 根据方法签名传不同格式
        PyObject *pyArgs = [self buildArgsForFunction:functionName jsonArgs:argsJSON];
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
    // 注意：不要释放 _cachedGlobals/_cachedMainModule (长期持有)
    
    // ★ 释放 GIL
    PyGILState_Release(gilState);
    
    pthread_mutex_unlock(&_pyMutex);
    return result;
}

#pragma mark - Argument Building

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

@end
