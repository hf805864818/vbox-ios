package quarkproxy

import (
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
)

// StreamEntry 注册的流条目
type StreamEntry struct {
	URL       string            `json:"url"`
	Headers   map[string]string `json:"headers"`
	CreatedAt time.Time         `json:"created_at"`
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

	// 检查磁盘缓存
	if diskCache != nil && diskCache.Exists(segURL) {
		cachedFile, cacheErr := diskCache.Get(segURL)
		if cacheErr == nil {
			defer cachedFile.Close()
			w.Header().Set("Content-Type", "video/MP2T")
			w.Header().Set("Cache-Control", "public, max-age=3600")
			w.WriteHeader(http.StatusOK)
			io.Copy(w, cachedFile)
			return
		}
	}

	// 从流条目获取鉴权头
	var headers map[string]string
	if val, ok := streams.Load(id); ok {
		headers = val.(*StreamEntry).Headers
	}

	// 构造上游请求
	upReq, err := http.NewRequestWithContext(r.Context(), "GET", segURL, nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	for k, v := range headers {
		upReq.Header.Set(k, v)
	}
	// 删除 Accept-Encoding：让 Go HTTP 客户端自动处理 gzip 解压
	upReq.Header.Del("Accept-Encoding")
	// 透传 Range
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

	// 流式回传，同时缓存到磁盘（仅 200 状态且启用了缓存）
	if diskCache != nil && resp.StatusCode == http.StatusOK {
		diskCache.StreamAndCache(segURL, w, resp.Body)
	} else {
		io.Copy(w, resp.Body)
	}
}

// ---- 工具函数 ----

// generateStreamID 根据上游 URL 生成短 ID
func generateStreamID(url string) string {
	// 使用时间戳 + URL 哈希，保证唯一且可追溯
	return fmt.Sprintf("%x", []byte(fmt.Sprintf("%d%s", time.Now().UnixNano(), url)))[:16]
}
