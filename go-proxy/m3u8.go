package quarkproxy

import (
	"encoding/base64"
	"fmt"
	"net/url"
	"strings"
)

// isM3U8Content 检测响应是否为 m3u8 播放列表
func isM3U8Content(contentType string, body []byte) bool {
	// 通过 Content-Type 检测
	ct := strings.ToLower(contentType)
	if strings.Contains(ct, "mpegurl") || strings.Contains(ct, "m3u8") {
		return true
	}
	// 通过内容前缀检测
	if len(body) > 7 && strings.HasPrefix(string(body), "#EXTM3U") {
		return true
	}
	return false
}

// rewriteM3U8 解析 m3u8 播放列表，将每个分片 URL 重写为本地代理地址
// entryID 是注册的流 ID，baseURL 是 m3u8 的来源 URL（用于解析相对路径）
func rewriteM3U8(content string, entryID string, baseURL string) string {
	lines := strings.Split(content, "\n")
	var result []string

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			result = append(result, line)
			continue
		}

		// HLS 标签行（#EXT 开头）
		if strings.HasPrefix(trimmed, "#") {
			// 处理 #EXT-X-KEY 中的 URI 属性
			rewritten := rewriteKeyURI(line, entryID, baseURL)
			result = append(result, rewritten)
			continue
		}

		// 媒体分片 URL 行 —— 重写为本地代理地址
		absoluteURL := resolveURL(trimmed, baseURL)
		encoded := base64.URLEncoding.EncodeToString([]byte(absoluteURL))
		rewritten := fmt.Sprintf("http://127.0.0.1:%d/seg?id=%s&u=%s",
			proxyPort, entryID, encoded)
		result = append(result, rewritten)
	}

	return strings.Join(result, "\n")
}

// rewriteKeyURI 重写 #EXT-X-KEY 标签中的 URI 属性
func rewriteKeyURI(line string, entryID string, baseURL string) string {
	// 仅处理包含 URI="..." 的标签
	uriIdx := strings.Index(line, `URI="`)
	if uriIdx < 0 {
		return line // 无 URI 属性，原样返回
	}

	start := uriIdx + 5 // len('URI="') = 5
	end := strings.Index(line[start:], `"`)
	if end < 0 {
		return line
	}
	end = end + start

	originalURI := line[start:end]
	absoluteURL := resolveURL(originalURI, baseURL)
	encoded := base64.URLEncoding.EncodeToString([]byte(absoluteURL))
	rewrittenURI := fmt.Sprintf("http://127.0.0.1:%d/seg?id=%s&u=%s",
		proxyPort, entryID, encoded)

	return line[:start] + rewrittenURI + line[end:]
}

// resolveURL 将可能的相对 URL 解析为绝对 URL
func resolveURL(raw string, baseURL string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return raw
	}
	if u.IsAbs() {
		return raw // 已是绝对 URL
	}
	base, err := url.Parse(baseURL)
	if err != nil {
		return raw
	}
	return base.ResolveReference(u).String()
}

// extractSegmentURLs 从 m3u8 内容中提取所有分片的绝对 URL（按顺序）
func extractSegmentURLs(content string, baseURL string) []string {
	lines := strings.Split(content, "\n")
	var urls []string
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		absoluteURL := resolveURL(trimmed, baseURL)
		urls = append(urls, absoluteURL)
	}
	return urls
}
