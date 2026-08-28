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
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          200,
		MaxIdleConnsPerHost:   30,
		MaxConnsPerHost:       0,
		IdleConnTimeout:       120 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 20 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		TLSClientConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
		},
		DialContext: (&net.Dialer{
			Timeout:   10 * time.Second,
			KeepAlive:  60 * time.Second,
		}).DialContext,
		WriteBufferSize: 256 * 1024, // 256KB 写缓冲，减少 syscall
		ReadBufferSize:  256 * 1024, // 256KB 读缓冲
	}

	httpClient = &http.Client{
		Transport: transport,
		Timeout:   0,
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
