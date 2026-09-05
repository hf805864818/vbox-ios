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
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			// 诊断日志：记录每次重定向
			fromURL := "unknown"
			if len(via) > 0 {
				fromURL = via[len(via)-1].URL.String()
			}
			debugLog("DIAG REDIRECT_REQ %s -> %s", shortURL(fromURL), shortURL(req.URL.String()))
			// 将原始请求的鉴权头转发到重定向目标（夸克 CDN 跨域可能需要）
			for _, v := range via {
				if v.Header.Get("Cookie") != "" && req.Header.Get("Cookie") == "" {
					req.Header.Set("Cookie", v.Header.Get("Cookie"))
				}
				if v.Header.Get("User-Agent") != "" && req.Header.Get("User-Agent") == "" {
					req.Header.Set("User-Agent", v.Header.Get("User-Agent"))
				}
			}
			if len(via) >= 10 {
				return fmt.Errorf("stopped after 10 redirects")
			}
			return nil
		},
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
