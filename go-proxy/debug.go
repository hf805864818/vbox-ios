package quarkproxy

/*
#include <stdlib.h>
*/
import "C"

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

// ---- 诊断日志基础设施 ----

const maxLogEntries = 500

type logEntry struct {
	ts      time.Time
	message string
}

var (
	logMu      sync.Mutex
	logBuffer  []logEntry
	stats      segStats
	statsMu    sync.Mutex
)

// segStats 分片服务统计
type segStats struct {
	SegTotal       int   `json:"seg_total"`        // 总分片请求数
	SegPrefetchHit int   `json:"seg_prefetch_hit"` // 预取缓存命中
	SegDiskHit     int   `json:"seg_disk_hit"`     // 磁盘缓存命中
	SegUpstream    int   `json:"seg_upstream"`     // 上游拉取
	UpstreamMs     int64 `json:"upstream_ms"`      // 上游请求累计耗时(ms)
	UpstreamMaxMs  int64 `json:"upstream_max_ms"`  // 单次上游最大耗时(ms)
	UpstreamBytes  int64 `json:"upstream_bytes"`   // 上游拉取总字节
	PrefetchAttempts int `json:"prefetch_attempts"` // 预取尝试次数
	PrefetchSuccess  int `json:"prefetch_success"` // 预取成功次数
	PrefetchFail     int `json:"prefetch_fail"`    // 预取失败次数
}

// debugLog 记录调试日志（线程安全）
func debugLog(format string, args ...interface{}) {
	msg := fmt.Sprintf(format, args...)
	ts := time.Now()

	logMu.Lock()
	logBuffer = append(logBuffer, logEntry{ts: ts, message: msg})
	if len(logBuffer) > maxLogEntries {
		logBuffer = logBuffer[len(logBuffer)-maxLogEntries:]
	}
	logMu.Unlock()

	// 同时输出到 stderr（Xcode console 可见）
	fmt.Fprintf(os.Stderr, "[quarkproxy] %s %s\n", ts.Format("15:04:05.000"), msg)
}

// statInc 原子递增统计计数器
func statInc(field string, n int) {
	statsMu.Lock()
	defer statsMu.Unlock()
	switch field {
	case "seg_total":
		stats.SegTotal += n
	case "seg_prefetch_hit":
		stats.SegPrefetchHit += n
	case "seg_disk_hit":
		stats.SegDiskHit += n
	case "seg_upstream":
		stats.SegUpstream += n
	case "prefetch_attempts":
		stats.PrefetchAttempts += n
	case "prefetch_success":
		stats.PrefetchSuccess += n
	case "prefetch_fail":
		stats.PrefetchFail += n
	}
}

// statUpstream 记录上游请求耗时
func statUpstream(durMs int64, bytes int64) {
	statsMu.Lock()
	defer statsMu.Unlock()
	stats.UpstreamMs += durMs
	stats.UpstreamBytes += bytes
	if durMs > stats.UpstreamMaxMs {
		stats.UpstreamMaxMs = durMs
	}
}

// GetDebugLogs 返回最近的调试日志（JSON 格式），供 Swift 调用
//
//export GetDebugLogs
func GetDebugLogs() string {
	logMu.Lock()
	defer logMu.Unlock()

	var sb strings.Builder
	sb.WriteString("[")
	for i, e := range logBuffer {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(fmt.Sprintf(`{"ts":"%s","msg":%q}`,
			e.ts.Format("15:04:05.000"), e.message))
	}
	sb.WriteString("]")
	return sb.String()
}

// GetStats 返回统计信息（JSON 格式），供 Swift 调用
//
//export GetStats
func GetStats() string {
	statsMu.Lock()
	defer statsMu.Unlock()

	avgMs := int64(0)
	if stats.SegUpstream > 0 {
		avgMs = stats.UpstreamMs / int64(stats.SegUpstream)
	}
	avgMB := float64(0)
	if stats.UpstreamBytes > 0 {
		avgMB = float64(stats.UpstreamBytes) / 1024.0 / 1024.0
	}

	return fmt.Sprintf(`{"seg_total":%d,"seg_prefetch_hit":%d,"seg_disk_hit":%d,"seg_upstream":%d,"upstream_avg_ms":%d,"upstream_max_ms":%d,"upstream_total_mb":%.2f,"prefetch_attempts":%d,"prefetch_success":%d,"prefetch_fail":%d}`,
		stats.SegTotal, stats.SegPrefetchHit, stats.SegDiskHit, stats.SegUpstream,
		avgMs, stats.UpstreamMaxMs, avgMB,
		stats.PrefetchAttempts, stats.PrefetchSuccess, stats.PrefetchFail)
}

// ResetStats 重置统计计数器
//
//export ResetStats
func ResetStats() string {
	statsMu.Lock()
	stats = segStats{}
	statsMu.Unlock()

	logMu.Lock()
	logBuffer = nil
	logMu.Unlock()

	return "ok"
}
