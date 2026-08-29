package quarkproxy

import (
	"bufio"
	"encoding/base64"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// 全局变量
var (
	server    *http.Server
	listener  net.Listener
	proxyPort int
	streams   sync.Map // map[string]*StreamEntry
	diskCache *DiskCache

	// 内存预取缓存：key=segURL, value=*prefetchedData
	prefetchCache sync.Map

	// 预取去重
	prefetching sync.Map

	prefetchMaxEntries   = 16
	prefetchEntryCount   int
	prefetchCountMu      sync.Mutex
	prefetchAhead        = 3 // 预取后续分片数（从 1 增加到 3，减少缓冲）
)

// prefetchedData 预取的分片数据
type prefetchedData struct {
	data        []byte
	contentType string
	statusCode  int
	headers     http.Header
	fetchedAt   time.Time
}

// StreamEntry 注册的流条目
type StreamEntry struct {
	URL         string            `json:"url"`
	Headers     map[string]string `json:"headers"`
	CreatedAt   time.Time         `json:"created_at"`
	segmentURLs []string
	segMu       sync.RWMutex
}

func startServer(port int) error {
	var err error
	listener, err = net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		return err
	}
	proxyPort = port

	mux := http.NewServeMux()
	mux.HandleFunc("/proxy", handleHealth)
	mux.HandleFunc("/play", handlePlay)
	mux.HandleFunc("/quark-m3u8/play", handlePlay)
	mux.HandleFunc("/quark-stream/play", handlePlay)
	mux.HandleFunc("/seg", handleSegment)

	server = &http.Server{
		Handler:      mux,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 0,
	}

	go server.Serve(listener)
	go prefetchCleanupLoop()

	debugLog("server started on port %d", port)
	return nil
}

func stopServer() {
	if server != nil {
		server.Close()
		server = nil
	}
	if listener != nil {
		listener.Close()
		listener = nil
	}
	streams.Range(func(key, value interface{}) bool {
		streams.Delete(key)
		return true
	})
	prefetchCache.Range(func(key, value interface{}) bool {
		prefetchCache.Delete(key)
		return true
	})
	prefetching.Range(func(key, value interface{}) bool {
		prefetching.Delete(key)
		return true
	})
	debugLog("server stopped")
}

func registerStream(upstreamURL string, headers map[string]string) string {
	id := generateStreamID(upstreamURL)
	entry := &StreamEntry{
		URL:       upstreamURL,
		Headers:   headers,
		CreatedAt: time.Now(),
	}
	streams.Store(id, entry)

	streams.Range(func(key, value interface{}) bool {
		if e, ok := value.(*StreamEntry); ok {
			if time.Since(e.CreatedAt) > 2*time.Hour {
				streams.Delete(key)
			}
		}
		return true
	})

	debugLog("registerStream id=%s url=%s headers=%d", id, upstreamURL[:min(80, len(upstreamURL))], len(headers))
	return fmt.Sprintf("http://127.0.0.1:%d/play?id=%s", proxyPort, id)
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	w.Write([]byte("hello"))
}

// ---- 播放入口（m3u8 或直链） ----

func handlePlay(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	val, ok := streams.Load(id)
	if !ok {
		http.Error(w, "stream not found", http.StatusNotFound)
		return
	}
	entry := val.(*StreamEntry)

	playStart := time.Now()

	upReq, err := http.NewRequestWithContext(r.Context(), "GET", entry.URL, nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	for k, v := range entry.Headers {
		upReq.Header.Set(k, v)
	}
	upReq.Header.Del("Accept-Encoding")
	if rng := r.Header.Get("Range"); rng != "" {
		upReq.Header.Set("Range", rng)
	}

	resp, err := httpClient.Do(upReq)
	if err != nil {
		debugLog("handlePlay upstream error id=%s err=%v", id, err)
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	bodyBytes := make([]byte, 0, 8192)
	buf := make([]byte, 4096)
	for {
		n, readErr := resp.Body.Read(buf)
		if n > 0 {
			bodyBytes = append(bodyBytes, buf[:n]...)
		}
		if readErr != nil {
			if readErr != io.EOF {
				http.Error(w, readErr.Error(), http.StatusBadGateway)
				return
			}
			break
		}
		if len(bodyBytes) > 256 {
			break
		}
	}

	if isM3U8Content(resp.Header.Get("Content-Type"), bodyBytes) {
		rest, _ := io.ReadAll(resp.Body)
		fullContent := string(append(bodyBytes, rest...))

		segURLs := extractSegmentURLs(fullContent, entry.URL)
		if len(segURLs) > 0 {
			entry.segMu.Lock()
			entry.segmentURLs = segURLs
			entry.segMu.Unlock()
		}

		rewritten := rewriteM3U8(fullContent, id, entry.URL)

		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		w.Header().Set("Cache-Control", "no-cache")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(rewritten))

		debugLog("handlePlay m3u8 id=%s segments=%d upstream_ms=%d rewrite_ms=%d",
			id, len(segURLs), time.Since(playStart).Milliseconds(), 0)
		return
	}

	ce := resp.Header.Get("Content-Encoding")
	isCompressed := ce != "" && !strings.EqualFold(ce, "identity")
	for k, vs := range resp.Header {
		if isCompressed && (strings.EqualFold(k, "Content-Encoding") || strings.EqualFold(k, "Content-Length")) {
			continue
		}
		for _, v := range vs {
			w.Header().Add(k, v)
		}
	}

	w.WriteHeader(resp.StatusCode)
	if len(bodyBytes) > 0 {
		w.Write(bodyBytes)
	}
	io.Copy(w, resp.Body)

	debugLog("handlePlay direct id=%s status=%d upstream_ms=%d",
		id, resp.StatusCode, time.Since(playStart).Milliseconds())
}

// ---- 分片代理（ts/媒体分片） ----

func handleSegment(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	encURL := r.URL.Query().Get("u")

	urlBytes, err := base64.URLEncoding.DecodeString(encURL)
	if err != nil {
		http.Error(w, "invalid url", http.StatusBadRequest)
		return
	}
	segURL := string(urlBytes)

	segStart := time.Now()
	statInc("seg_total", 1)

	// 截取 URL 最后 30 字符用于日志（避免过长）
	segShort := shortURL(segURL)

	// 1. 内存预取缓存
	if cachedVal, ok := prefetchCache.Load(segURL); ok {
		pd := cachedVal.(*prefetchedData)
		prefetchCache.Delete(segURL)

		for k, vs := range pd.headers {
			if strings.EqualFold(k, "Content-Encoding") || strings.EqualFold(k, "Content-Length") {
				continue
			}
			for _, v := range vs {
				w.Header().Add(k, v)
			}
		}
		w.WriteHeader(pd.statusCode)
		w.Write(pd.data)

		statInc("seg_prefetch_hit", 1)
		debugLog("seg HIT(prefetch) %s bytes=%d ms=%d",
			segShort, len(pd.data), time.Since(segStart).Milliseconds())

		go prefetchNextSegment(id, segURL)
		return
	}

	// 2. 磁盘缓存
	if diskCache != nil && diskCache.Exists(segURL) {
		cachedFile, cacheErr := diskCache.Get(segURL)
		if cacheErr == nil {
			defer cachedFile.Close()
			w.Header().Set("Content-Type", "video/MP2T")
			w.Header().Set("Cache-Control", "public, max-age=3600")
			w.WriteHeader(http.StatusOK)
			bufWriter := bufio.NewWriterSize(w, 128*1024)
			io.Copy(bufWriter, cachedFile)
			bufWriter.Flush()

			statInc("seg_disk_hit", 1)
			debugLog("seg HIT(disk) %s ms=%d",
				segShort, time.Since(segStart).Milliseconds())

			go prefetchNextSegment(id, segURL)
			return
		}
	}

	// 3. 上游拉取
	var headers map[string]string
	var entry *StreamEntry
	if val, ok := streams.Load(id); ok {
		entry = val.(*StreamEntry)
		headers = entry.Headers
	}

	upReq, err := http.NewRequestWithContext(r.Context(), "GET", segURL, nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	for k, v := range headers {
		upReq.Header.Set(k, v)
	}
	upReq.Header.Del("Accept-Encoding")
	if rng := r.Header.Get("Range"); rng != "" {
		upReq.Header.Set("Range", rng)
	}

	upStart := time.Now()
	resp, err := httpClient.Do(upReq)
	upMs := time.Since(upStart).Milliseconds()

	if err != nil {
		statInc("seg_upstream", 1)
		statUpstream(upMs, 0)
		debugLog("seg UPSTREAM_ERR %s ms=%d err=%v", segShort, upMs, err)
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	statInc("seg_upstream", 1)
	contentLen := resp.ContentLength
	debugLog("seg UPSTREAM %s status=%d cl=%d upstream_ms=%d",
		segShort, resp.StatusCode, contentLen, upMs)

	ce := resp.Header.Get("Content-Encoding")
	isCompressed := ce != "" && !strings.EqualFold(ce, "identity")
	for k, vs := range resp.Header {
		if isCompressed && (strings.EqualFold(k, "Content-Encoding") || strings.EqualFold(k, "Content-Length")) {
			continue
		}
		for _, v := range vs {
			w.Header().Add(k, v)
		}
	}
	w.WriteHeader(resp.StatusCode)

	var bytesWritten int64
	if diskCache != nil && resp.StatusCode == http.StatusOK {
		bufWriter := bufio.NewWriterSize(w, 128*1024)
		bytesWritten, _ = diskCache.StreamAndCache(segURL, bufWriter, resp.Body)
		bufWriter.Flush()
	} else {
		bufWriter := bufio.NewWriterSize(w, 128*1024)
		bytesWritten, _ = io.Copy(bufWriter, resp.Body)
		bufWriter.Flush()
	}

	statUpstream(upMs, bytesWritten)
	debugLog("seg DONE %s bytes=%d total_ms=%d",
		segShort, bytesWritten, time.Since(segStart).Milliseconds())

	go prefetchNextSegment(id, segURL)
}

// ---- 分片预取 ----

func prefetchNextSegment(streamID string, currentSegURL string) {
	if _, loading := prefetching.LoadOrStore(currentSegURL, true); loading {
		return
	}
	defer prefetching.Delete(currentSegURL)

	val, ok := streams.Load(streamID)
	if !ok {
		return
	}
	entry := val.(*StreamEntry)

	entry.segMu.RLock()
	segURLs := entry.segmentURLs
	entry.segMu.RUnlock()

	currentIdx := -1
	for i, u := range segURLs {
		if u == currentSegURL {
			currentIdx = i
			break
		}
	}

	if currentIdx < 0 {
		return
	}

	// 预取后续 prefetchAhead 个分片（并发）
	for ahead := 1; ahead <= prefetchAhead; ahead++ {
		if currentIdx+ahead >= len(segURLs) {
			break
		}
		nextURL := segURLs[currentIdx+ahead]

		if _, cached := prefetchCache.Load(nextURL); cached {
			continue
		}
		if diskCache != nil && diskCache.Exists(nextURL) {
			continue
		}

		debugLog("prefetch NEXT idx=%d/%d ahead=%d %s",
			currentIdx+ahead, len(segURLs), ahead, shortURL(nextURL))

		go prefetchSegment(nextURL, entry.Headers)
	}
}

func prefetchSegment(segURL string, headers map[string]string) {
	statInc("prefetch_attempts", 1)
	pfStart := time.Now()

	upReq, err := http.NewRequest(http.MethodGet, segURL, nil)
	if err != nil {
		statInc("prefetch_fail", 1)
		debugLog("prefetch FAIL(create_req) %s err=%v", shortURL(segURL), err)
		return
	}
	for k, v := range headers {
		upReq.Header.Set(k, v)
	}
	upReq.Header.Del("Accept-Encoding")

	resp, err := httpClient.Do(upReq)
	if err != nil {
		statInc("prefetch_fail", 1)
		debugLog("prefetch FAIL(fetch) %s ms=%d err=%v",
			shortURL(segURL), time.Since(pfStart).Milliseconds(), err)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		statInc("prefetch_fail", 1)
		debugLog("prefetch FAIL(status=%d) %s ms=%d",
			resp.StatusCode, shortURL(segURL), time.Since(pfStart).Milliseconds())
		return
	}

	data, err := io.ReadAll(resp.Body)
	if err != nil {
		statInc("prefetch_fail", 1)
		debugLog("prefetch FAIL(read) %s ms=%d err=%v",
			shortURL(segURL), time.Since(pfStart).Milliseconds(), err)
		return
	}

	prefetchCountMu.Lock()
	if prefetchEntryCount >= prefetchMaxEntries {
		var oldestKey string
		var oldestTime time.Time
		prefetchCache.Range(func(key, value interface{}) bool {
			pd := value.(*prefetchedData)
			if oldestKey == "" || pd.fetchedAt.Before(oldestTime) {
				oldestKey = key.(string)
				oldestTime = pd.fetchedAt
			}
			return true
		})
		if oldestKey != "" {
			prefetchCache.Delete(oldestKey)
			prefetchEntryCount--
		}
	}
	prefetchEntryCount++
	prefetchCountMu.Unlock()

	prefetchCache.Store(segURL, &prefetchedData{
		data:        data,
		contentType: resp.Header.Get("Content-Type"),
		statusCode:  resp.StatusCode,
		headers:     resp.Header.Clone(),
		fetchedAt:   time.Now(),
	})

	statInc("prefetch_success", 1)
	debugLog("prefetch OK %s bytes=%d ms=%d",
		shortURL(segURL), len(data), time.Since(pfStart).Milliseconds())
}

func prefetchCleanupLoop() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		now := time.Now()
		prefetchCache.Range(func(key, value interface{}) bool {
			pd := value.(*prefetchedData)
			if now.Sub(pd.fetchedAt) > 2*time.Minute {
				prefetchCache.Delete(key)
				prefetchCountMu.Lock()
				prefetchEntryCount--
				prefetchCountMu.Unlock()
			}
			return true
		})
	}
}

// ---- 工具函数 ----

func generateStreamID(url string) string {
	return fmt.Sprintf("%x", []byte(fmt.Sprintf("%d%s", time.Now().UnixNano(), url)))[:16]
}

// shortURL 截取 URL 最后 40 字符用于日志（含文件名和参数）
func shortURL(u string) string {
	if len(u) <= 40 {
		return u
	}
	return "..." + u[len(u)-37:]
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
