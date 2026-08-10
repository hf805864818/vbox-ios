//
//  PythonBridge.m
//  vbox
//
//  ObjC 桥接层 —— 连接 Swift 和 CPython 解释器
//  负责 Python 解释器的生命周期管理和 Spider 脚本调用
//

#import "PythonBridge.h"
#import <Python/Python.h>   // iOS framework 标准 include (对应 Python.framework/Headers/Python.h)
#include <pthread.h>

static pthread_mutex_t _pyMutex = PTHREAD_MUTEX_INITIALIZER;
static BOOL _pyInitialized = NO;
static NSString *_pyHome = nil;

@implementation PythonSpiderBridge

#pragma mark - Lifecycle

+ (void)initializePythonIfNeeded {
    pthread_mutex_lock(&_pyMutex);
    
    if (_pyInitialized) {
        pthread_mutex_unlock(&_pyMutex);
        return;
    }
    
    // 1. 定位 Python 标准库目录（在 App bundle Resources 中）
    NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
    _pyHome = [resourcePath stringByAppendingPathComponent:@"python-stdlib"];
    
    // 2. 设置 Python 环境变量
    setenv("PYTHONHOME", [_pyHome UTF8String], 1);
    setenv("PYTHONPATH", [_pyHome UTF8String], 1);
    setenv("PYTHONDONTWRITEBYTECODE", "1", 1);  // 不生成 .pyc（节省磁盘写入）
    
    // 3. 初始化 CPython 解释器
    Py_Initialize();
    
    if (!Py_IsInitialized()) {
        NSLog(@"[PythonBridge] ❌ Py_Initialize 失败");
        pthread_mutex_unlock(&_pyMutex);
        return;
    }
    
    // 4. 注入 sys.path — 让脚本能 import requests/bs4/urllib3 等
    NSString *sitePackages = [_pyHome stringByAppendingPathComponent:@"site-packages"];
    NSString *initCmd = [NSString stringWithFormat:
        @"import sys\n"
        @"sys.path.insert(0, '%@')\n"
        @"sys.path.insert(0, '%@')\n"
        @"sys.dont_write_bytecode = True\n"
        @"import builtins\n"
        @"if not hasattr(builtins, 'load_module'):\n"
        @"    builtins.load_module = lambda m: __import__(m)\n",
        sitePackages, _pyHome];
    
    if (PyRun_SimpleString([initCmd UTF8String]) != 0) {
        PyErr_Print();
        NSLog(@"[PythonBridge] ❌ sys.path 注入失败");
        pthread_mutex_unlock(&_pyMutex);
        return;
    }
    
    _pyInitialized = YES;
    NSLog(@"[PythonBridge] ✅ Python 解释器初始化完成 (home: %@)", _pyHome);
    
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
        NSLog(@"[PythonBridge] 🔚 Python 解释器已销毁");
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
    
    NSString *result = nil;
    PyObject *mainModule = NULL;
    PyObject *globals = NULL;
    PyObject *spider = NULL;
    FILE *fp = NULL;
    
    @try {
        // === Phase 1: 加载脚本文件 ===
        fp = fopen([scriptPath UTF8String], "r");
        if (!fp) {
            NSLog(@"[PythonBridge] ❌ 无法打开脚本: %@", scriptPath);
            goto cleanup;
        }
        
        mainModule = PyImport_AddModule("__main__");
        if (!mainModule) goto cleanup;
        globals = PyModule_GetDict(mainModule);
        if (!globals) goto cleanup;
        
        // 注入脚本路径信息
        NSString *injectPath = [NSString stringWithFormat:
            @"import sys; sys.path.insert(0, '%@')",
            [[scriptPath stringByDeletingLastPathComponent] stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"]];
        PyRun_SimpleString([injectPath UTF8String]);
        
        // 执行脚本（创建 Spider 类定义）
        PyObject *runRet = PyRun_File(fp, [[scriptPath lastPathComponent] UTF8String],
                                       Py_file_input, globals, globals);
        if (!runRet) {
            PyErr_Print();
            NSLog(@"[PythonBridge] ❌ 脚本执行失败: %@", [scriptPath lastPathComponent]);
            goto cleanup;
        }
        Py_DECREF(runRet);
        fclose(fp); fp = NULL;
        
        // === Phase 2: 实例化 Spider 类 ===
        PyObject *spiderClass = PyDict_GetItemString(globals, "Spider");
        if (!spiderClass || !PyCallable_Check(spiderClass)) {
            NSLog(@"[PythonBridge] ❌ 未找到 Spider 类: %@", [scriptPath lastPathComponent]);
            goto cleanup;
        }
        
        spider = PyObject_CallObject(spiderClass, NULL);
        if (!spider) {
            PyErr_Print();
            NSLog(@"[PythonBridge] ❌ Spider 实例化失败");
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
        
        // === Phase 3: 调用目标方法 ===
        PyObject *method = PyObject_GetAttrString(spider, [functionName UTF8String]);
        if (!method || !PyCallable_Check(method)) {
            NSLog(@"[PythonBridge] ❌ 未找到方法: %@.%@", [scriptPath lastPathComponent], functionName);
            Py_XDECREF(method);
            goto cleanup;
        }
        
        // 构造参数 — 根据方法签名传不同格式
        PyObject *pyArgs = [self buildArgsForFunction:functionName jsonArgs:argsJSON];
        PyObject *callRet = PyObject_Call(method, pyArgs, NULL);
        
        if (callRet) {
            // 转为 JSON 字符串
            PyObject *str = PyObject_Str(callRet);
            if (str) {
                const char *cstr = PyUnicode_AsUTF8(str);
                if (cstr) {
                    result = [NSString stringWithUTF8String:cstr];
                }
                Py_DECREF(str);
            }
            Py_DECREF(callRet);
        } else {
            PyErr_Print();
            NSLog(@"[PythonBridge] ❌ %@.%@ 调用失败", [scriptPath lastPathComponent], functionName);
        }
        
        Py_DECREF(method);
        Py_XDECREF(pyArgs);
        
    } @catch (NSException *exception) {
        NSLog(@"[PythonBridge] ❌ 异常: %@", exception.reason);
    }
    
cleanup:
    if (fp) fclose(fp);
    Py_XDECREF(spider);
    // 注意：不要释放 mainModule/globals（PyImport_AddModule 借出的引用）
    
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
        if (jsonArgs) {
            NSData *data = [jsonArgs dataUsingEncoding:NSUTF8StringEncoding];
            NSError *err;
            NSDictionary *d = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
            if (!err && d) {
                NSString *tid = d[@"tid"] ?: @"";
                NSString *pg = d[@"pg"] ?: @"1";
                return PyTuple_Pack(4,
                    PyUnicode_FromString([tid UTF8String]),
                    PyUnicode_FromString([pg UTF8String]),
                    PyDict_New(),
                    PyDict_New()
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
