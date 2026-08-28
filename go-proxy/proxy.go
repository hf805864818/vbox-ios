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
	// 用于存放后台预取的分片，命中后直接回传，避免重复请求上游
	prefetchCache sync.Map

	// 预取去重：记录正在预取中的分片 URL，防止重复发起
	prefetching sync.Map // map[string]bool

	// 预取缓存上限（条数），超出后 LRU 式清理
	prefetchMaxEntries = 8
	prefetchEntryCount int
	prefetchCountMu    sync.Mutex
)

// prefetchedData 预取的分片数据
type prefetchedData struct {
	data       []byte
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
	segmentURLs []string         // m3u8 中的分片 URL 列表（按顺序）
	segMu       sync.RWMutex     // 保护 segmentURLs 读写
}

// startServer 启动本地 HTTP 代理服务器
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
	// 扩展路由：携带格式前缀的 URL，便于上层（PlayerViewsV2 / MDK）识别流类型
	mux.HandleFunc("/quark-m3u8/play", handlePlay)
	mux.HandleFunc("/quark-stream/play", handlePlay)
	mux.HandleFunc("/seg", handleSegment)

	server = &http.Server{
		Handler:      mux,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 0, // 流式传输不设写超时
	}

	go server.Serve(listener)

	// 启动预取缓存清理 goroutine
	go prefetchCleanupLoop()

	return nil
}

// stopServer 停止代理服务器
func stopServer() {
	if server != nil {
		server.Close()
		server = nil
	}
	if listener != nil {
		listener.Close()
		listener = nil
	}
	// 清理所有流注册
	streams.Range(func(key, value interface{}) bool {
		streams.Delete(key)
		return true
	})
	// 清理预取缓存
	prefetchCache.Range(func(key, value interface{}) bool {
		prefetchCache.Delete(key)
		return true
	})
	prefetching.Range(func(key, value interface{}) bool {
		prefetching.Delete(key)
		return true
	})
}

// registerStream 注册上游 URL 及鉴权头，返回本地代理播放地址
func registerStream(upstreamURL string, headers map[string]string) string {
	id := generateStreamID(upstreamURL)
	entry := &StreamEntry{
		URL:       upstreamURL,
		Headers:   headers,
		CreatedAt: time.Now(),
	}
	streams.Store(id, entry)

	// 清理超过 2 小时的旧条目
	streams.Range(func(key, value interface{}) bool {
		if e, ok := value.(*StreamEntry); ok {
			if time.Since(e.CreatedAt) > 2*time.Hour {
				streams.Delete(key)
			}
		}
		return true
	})

	return fmt.Sprintf("http://127.0.0.1:%d/play?id=%s", proxyPort, id)
}

// ---- 健康检查 ----

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

	// 构造上游请求
	upReq, err := http.NewRequestWithContext(r.Context(), "GET", entry.URL, nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	// 注入鉴权头
	for k, v := range entry.Headers {
		upReq.Header.Set(k, v)
	}
	// 删除 Accept-Encoding：让 Go HTTP 客户端自动处理 gzip 解压
	// 确保 m3u8 内容检测能在未压缩的 body 上正常工作
	upReq.Header.Del("Accept-Encoding")
	// 透传 Range 请求
	if rng := r.Header.Get("Range"); rng != "" {
		upReq.Header.Set("Range", rng)
	}

	resp, err := httpClient.Do(upReq)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	// 读取响应体（判断是否为 m3u8）
	bodyBytes := make([]byte, 0, 8192)
	buf := make([]byte, 4096)
	for {
		n, readErr := resp.Body.Read(buf)
		if n > 0 {
			bodyBytes = append(bodyBytes, buf[:n]...)
		}
		if readErr != nil {
			if readErr != io.EOF {
				// 读取错误
				http.Error(w, readErr.Error(), http.StatusBadGateway)
				return
			}
			break
		}
		// 读取到足够判断的数据
		if len(bodyBytes) > 256 {
			break
		}
	}

	// 检测是否为 m3u8 播放列表
	if isM3U8Content(resp.Header.Get("Content-Type"), bodyBytes) {
		// 读取完整内容
		rest, _ := io.ReadAll(resp.Body)
		fullContent := string(append(bodyBytes, rest...))

		// 提取并存储分片 URL 列表（用于预取）
		segURLs := extractSegmentURLs(fullContent, entry.URL)
		if len(segURLs) > 0 {
			entry.segMu.Lock()
			entry.segmentURLs = segURLs
			entry.segMu.Unlock()
		}

		// 重写 m3u8：将分片 URL 改写为本地代理地址
		rewritten := rewriteM3U8(fullContent, id, entry.URL)

		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		w.Header().Set("Cache-Control", "no-cache")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(rewritten))
		return
	}

	// 非 m3u8 内容：透传响应头和流式响应
	// 跳过压缩相关头：删除 Accept-Encoding 后 Go 客户端自动解压 gzip，
	// 此时 Content-Encoding/Content-Length 指向压缩前数据，透传会导致播放器解码失败
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

	// 如果之前读取了部分 body，需要先写回去
	w.WriteHeader(resp.StatusCode)
	if len(bodyBytes) > 0 {
		w.Write(bodyBytes)
	}
	io.Copy(w, resp.Body)
}

// ---- 分片代理（ts/媒体分片） ----

func handleSegment(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	encURL := r.URL.Query().Get("u")

	// 解码原始分片 URL
	urlBytes, err := base64.URLEncoding.DecodeString(encURL)
	if err != nil {
		http.Error(w, "invalid url", http.StatusBadRequest)
		return
	}
	segURL := string(urlBytes)

	// 1. 检查内存预取缓存（最高优先级）
	if cachedVal, ok := prefetchCache.Load(segURL); ok {
		pd := cachedVal.(*prefetchedData)
		// 命中预取缓存，直接回传，零等待
		prefetchCache.Delete(segURL) // 用后即删，防止内存膨胀

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

		// 异步预取下一个分片
		go prefetchNextSegment(id, segURL)
		return
	}

	// 2. 检查磁盘缓存
	if diskCache != nil && diskCache.Exists(segURL) {
		cachedFile, cacheErr := diskCache.Get(segURL)
		if cacheErr == nil {
			defer cachedFile.Close()
			w.Header().Set("Content-Type", "video/MP2T")
			w.Header().Set("Cache-Control", "public, max-age=3600")
			w.WriteHeader(http.StatusOK)
			// 使用带缓冲的 writer 提高回传效率
			bufWriter := bufio.NewWriterSize(w, 128*1024)
			io.Copy(bufWriter, cachedFile)
			bufWriter.Flush()

			// 异步预取下一个分片
			go prefetchNextSegment(id, segURL)
			return
		}
	}

	// 3. 从上游拉取
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

	resp, err := httpClient.Do(upReq)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	// 复制响应头（跳过压缩相关头）
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

	// 流式回传 + 磁盘缓存（使用 bufio 提升写入吞吐）
	if diskCache != nil && resp.StatusCode == http.StatusOK {
		bufWriter := bufio.NewWriterSize(w, 128*1024)
		diskCache.StreamAndCache(segURL, bufWriter, resp.Body)
		bufWriter.Flush()
	} else {
		bufWriter := bufio.NewWriterSize(w, 128*1024)
		io.Copy(bufWriter, resp.Body)
		bufWriter.Flush()
	}

	// 异步预取下一个分片
	go prefetchNextSegment(id, segURL)
}

// ---- 分片预取 ----

// prefetchNextSegment 预取当前分片的下一个分片（仅预取一个，控制内存）
func prefetchNextSegment(streamID string, currentSegURL string) {
	// 防止重复预取
	if _, loading := prefetching.LoadOrStore(currentSegURL, true); loading {
		return
	}
	defer prefetching.Delete(currentSegURL)

	// 获取流条目
	val, ok := streams.Load(streamID)
	if !ok {
		return
	}
	entry := val.(*StreamEntry)

	// 查找当前分片在列表中的索引
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

	// 预取下一个分片（如果存在）
	if currentIdx < 0 || currentIdx+1 >= len(segURLs) {
		return
	}
	nextURL := segURLs[currentIdx+1]

	// 如果已在缓存中，跳过
	if _, cached := prefetchCache.Load(nextURL); cached {
		return
	}
	if diskCache != nil && diskCache.Exists(nextURL) {
		return
	}

	prefetchSegment(nextURL, entry.Headers)
}

// prefetchSegment 后台预取一个分片并存入内存缓存
func prefetchSegment(segURL string, headers map[string]string) {
	// 独立 context，不受播放请求生命周期影响
	upReq, err := http.NewRequest(http.MethodGet, segURL, nil)
	if err != nil {
		return
	}
	for k, v := range headers {
		upReq.Header.Set(k, v)
	}
	upReq.Header.Del("Accept-Encoding")

	resp, err := httpClient.Do(upReq)
	if err != nil {
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return
	}

	// 读取完整分片到内存（ts 分片通常 1-5MB）
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return
	}

	// 控制缓存大小
	prefetchCountMu.Lock()
	if prefetchEntryCount >= prefetchMaxEntries {
		// 清理最早的缓存条目
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
		data:       data,
		contentType: resp.Header.Get("Content-Type"),
		statusCode:  resp.StatusCode,
		headers:     resp.Header.Clone(),
		fetchedAt:   time.Now(),
	})
}

// prefetchCleanupLoop 定期清理过期的预取缓存
func prefetchCleanupLoop() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		now := time.Now()
		prefetchCache.Range(func(key, value interface{}) bool {
			pd := value.(*prefetchedData)
			// 超过 2 分钟的预取缓存视为过期
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

// generateStreamID 根据上游 URL 生成短 ID
func generateStreamID(url string) string {
	// 使用时间戳 + URL 哈希，保证唯一且可追溯
	return fmt.Sprintf("%x", []byte(fmt.Sprintf("%d%s", time.Now().UnixNano(), url)))[:16]
}
