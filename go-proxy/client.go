package quarkproxy

import (
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"time"
)

// httpClient 是全局 HTTP/2 客户端，连接池复用
var httpClient *http.Client

// initClient 初始化 HTTP/2 客户端，支持多路复用和连接池
func initClient() {
	transport := &http.Transport{
		// 强制尝试 HTTP/2（对 HTTPS 自动协商 ALPN h2）
		ForceAttemptHTTP2: true,
		// 全局最大空闲连接
		MaxIdleConns: 100,
		// 每个 Host 最大空闲连接（连接池核心参数）
		MaxIdleConnsPerHost: 10,
		// 每个 Host 最大连接数（0=不限制，允许多路复用）
		MaxConnsPerHost: 0,
		// 空闲连接超时
		IdleConnTimeout: 90 * time.Second,
		// TLS 握手超时
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 15 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		// TLS 配置：允许 HTTP/2
		TLSClientConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
		},
		// 拨号配置
		DialContext: (&net.Dialer{
			Timeout:   10 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
	}

	httpClient = &http.Client{
		Transport: transport,
		// 不设总超时，因为流式传输需要长时间
		Timeout: 0,
	}
}

// roundTripperInfo 返回当前传输层信息（调试用）
func roundTripperInfo() string {
	if httpClient == nil {
		return "client not initialized"
	}
	if t, ok := httpClient.Transport.(*http.Transport); ok {
		return fmt.Sprintf(
			"HTTP/2=%v MaxIdleConnsPerHost=%d IdleConnTimeout=%v",
			t.ForceAttemptHTTP2, t.MaxIdleConnsPerHost, t.IdleConnTimeout,
		)
	}
	return "unknown transport"
}
