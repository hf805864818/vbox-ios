//
//  NetworkLogger.swift
//  vbox
//
//  网络请求日志拦截器
//  - 通过 URLProtocol 全局拦截自定义 URLSession 的 HTTP/HTTPS 请求
//  - 记录请求耗时、状态码、错误信息
//  - 仅在 AppLogStore 开启时生效，不影响性能
//

import Foundation

/// 网络请求日志拦截器（URLProtocol 实现）
/// 注意：只能拦截使用自定义 URLSessionConfiguration 的请求，
///       URLSession.shared 的请求无法被 URLProtocol 拦截。
final class NetworkLoggerURLProtocol: URLProtocol {
    
    private static let requestHandledKey = "NetworkLoggerHandled"
    
    private var dataTask: URLSessionDataTask?
    private var receivedData = Data()
    private var startTime: Date?
    private var response: URLResponse?
    
    // MARK: - URLProtocol 方法
    
    override class func canInit(with request: URLRequest) -> Bool {
        // 避免重复处理
        if URLProtocol.property(forKey: requestHandledKey, in: request) as? Bool == true {
            return false
        }
        
        // 只处理 HTTP/HTTPS
        guard let scheme = request.url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        
        // 只有日志开启时才拦截
        let enabled = AppLogStore.shared.enabled
        guard enabled else { return false }
        
        // 只记录 info 级别以上时才拦截（verbose 级别的每条请求太频繁）
        // 这里始终拦截，内部根据级别判断是否记录
        return true
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    override class func requestIsCacheEquivalent(_ a: URLRequest, to b: URLRequest) -> Bool {
        return super.requestIsCacheEquivalent(a, to: b)
    }
    
    override func startLoading() {
        guard let mutableRequest = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "NetworkLogger", code: -1, userInfo: nil))
            return
        }
        
        // 标记已处理，避免递归
        URLProtocol.setProperty(true, forKey: Self.requestHandledKey, in: mutableRequest)
        
        startTime = Date()
        
        // 使用 default session 发请求
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        dataTask = session.dataTask(with: mutableRequest as URLRequest)
        dataTask?.resume()
    }
    
    override func stopLoading() {
        dataTask?.cancel()
        dataTask = nil
    }
}

// MARK: - URLSessionDataDelegate

extension NetworkLoggerURLProtocol: URLSessionDataDelegate {
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        receivedData = Data()
        
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
        client?.urlProtocol(self, didLoad: data)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let endTime = Date()
        let cost = startTime.map { Int(endTime.timeIntervalSince($0) * 1000) } ?? 0
        
        let url = task.originalRequest?.url?.absoluteString ?? "unknown"
        let method = task.originalRequest?.httpMethod ?? "GET"
        
        if let error = error {
            let nsError = error as NSError
            // 取消的请求不记录
            guard nsError.code != NSURLErrorCancelled else {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            
            AppLogStore.shared.log(.warn, .network,
                "\(method) \(url) 失败: \(error.localizedDescription) (code=\(nsError.code)), 耗时: \(cost)ms")
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            
            if statusCode >= 400 {
                AppLogStore.shared.log(.warn, .network,
                    "\(method) \(url) → \(statusCode), 耗时: \(cost)ms, 大小: \(receivedData.count) bytes")
            } else {
                // 成功的请求按 verbose 级别记录，默认不显示
                AppLogStore.shared.log(.verbose, .network,
                    "\(method) \(url) → \(statusCode), 耗时: \(cost)ms, 大小: \(receivedData.count) bytes")
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        
        // 完成后 invalidate session
        session.finishTasksAndInvalidate()
    }
}

// MARK: - 便捷管理

enum NetworkLogger {
    
    /// 是否已注册
    private(set) static var isRegistered = false
    
    /// 注册 URLProtocol 到默认 session 配置
    /// 注意：这只能拦截使用自定义 URLSessionConfiguration 的请求
    /// URLSession.shared 不受影响
    static func start() {
        guard !isRegistered else { return }
        URLProtocol.registerClass(NetworkLoggerURLProtocol.self)
        isRegistered = true
        AppLogStore.shared.info(.network, "网络请求日志拦截已启动")
    }
    
    /// 停止拦截
    static func stop() {
        guard isRegistered else { return }
        URLProtocol.unregisterClass(NetworkLoggerURLProtocol.self)
        isRegistered = false
    }
    
    /// 将拦截器注入 URLSessionConfiguration
    /// 自定义 URLSession 调用此方法后，其请求会被记录
    static func inject(into config: URLSessionConfiguration) {
        var protocolClasses = config.protocolClasses ?? []
        // 插入到最前面，优先处理
        if !protocolClasses.contains(where: { $0 == NetworkLoggerURLProtocol.self }) {
            protocolClasses.insert(NetworkLoggerURLProtocol.self, at: 0)
            config.protocolClasses = protocolClasses
        }
    }
}
