package quarkproxy

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	_ "golang.org/x/mobile/bind"
)

var (
	startMu   sync.Mutex
	isStarted bool
)

// StartProxy 启动本地 HTTP/2 代理服务器
//
//export StartProxy
func StartProxy(port int) string {
	startMu.Lock()
	defer startMu.Unlock()

	if isStarted {
		return fmt.Sprintf("ok:already running on port %d", proxyPort)
	}

	initClient()

	cacheDir := filepath.Join(os.TempDir(), "quarkproxy_cache")
	diskCache = NewDiskCache(cacheDir)

	if err := startServer(port); err != nil {
		return "error:" + err.Error()
	}

	go func() {
		ticker := time.NewTicker(10 * time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			if diskCache != nil {
				diskCache.Clean(3600)
			}
			streams.Range(func(key, value interface{}) bool {
				if e, ok := value.(*StreamEntry); ok {
					if time.Since(e.CreatedAt) > 2*time.Hour {
						streams.Delete(key)
					}
				}
				return true
			})
		}
	}()

	isStarted = true
	debugLog("StartProxy ok port=%d", port)
	return fmt.Sprintf("ok:%d", port)
}

// RegisterStream 注册上游 URL 和鉴权头，返回本地代理播放地址
//
//export RegisterStream
func RegisterStream(upstreamURL, headersJSON string) string {
	if !isStarted {
		return "error:proxy not started"
	}

	var headers map[string]string
	if headersJSON != "" {
		if err := json.Unmarshal([]byte(headersJSON), &headers); err != nil {
			return "error:invalid headers json: " + err.Error()
		}
	}
	if headers == nil {
		headers = make(map[string]string)
	}

	proxyURL := registerStream(upstreamURL, headers)
	return proxyURL
}

// StopProxy 停止代理服务器并清理资源
//
//export StopProxy
func StopProxy() string {
	startMu.Lock()
	defer startMu.Unlock()

	if !isStarted {
		return "ok:not running"
	}

	stopServer()

	if diskCache != nil {
		diskCache.Clear()
		diskCache = nil
	}

	isStarted = false
	return "ok:stopped"
}

// ProxyStatus 返回代理状态信息（含预取统计）
//
//export ProxyStatus
func ProxyStatus() string {
	if !isStarted {
		return "stopped"
	}

	var count int
	streams.Range(func(_, _ interface{}) bool {
		count++
		return true
	})

	cacheCount := 0
	if diskCache != nil {
		if entries, err := os.ReadDir(diskCache.dir); err == nil {
			cacheCount = len(entries)
		}
	}

	prefetchCount := 0
	prefetchCache.Range(func(_, _ interface{}) bool {
		prefetchCount++
		return true
	})

	statsJSON := GetStats()

	return fmt.Sprintf("running port=%d streams=%d cached_segments=%d prefetch=%d %s stats=%s",
		proxyPort, count, cacheCount, prefetchCount, roundTripperInfo(), statsJSON)
}

// ClearCache 清空磁盘缓存
//
//export ClearCache
func ClearCache() string {
	if diskCache != nil {
		diskCache.Clear()
		return "ok"
	}
	return "no cache"
}
