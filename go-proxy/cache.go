package quarkproxy

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// DiskCache 是基于磁盘的 HLS 分片缓存
type DiskCache struct {
	dir string
	mu  sync.Mutex // 仅保护元数据操作（目录创建/清理），不锁流式传输

	// 正在写入的文件去重：防止同一分片并发写入冲突
	writingMu sync.Map // map[string]bool — key=cacheKey
}

// NewDiskCache 创建磁盘缓存，dir 为缓存目录
func NewDiskCache(dir string) *DiskCache {
	os.MkdirAll(dir, 0755)
	return &DiskCache{dir: dir}
}

// cachePath 根据原始 URL 生成缓存文件路径
func (c *DiskCache) cachePath(key string) string {
	h := sha256.Sum256([]byte(key))
	name := hex.EncodeToString(h[:16]) + ".seg"
	return filepath.Join(c.dir, name)
}

// Exists 检查分片是否已缓存
func (c *DiskCache) Exists(key string) bool {
	_, err := os.Stat(c.cachePath(key))
	return err == nil
}

// Get 打开缓存文件用于读取
func (c *DiskCache) Get(key string) (io.ReadCloser, error) {
	return os.Open(c.cachePath(key))
}

// Set 从 reader 读取数据，同时写入文件和 writer（流式缓存）
// 返回写入的字节数和错误
// 注意：此函数不加全局锁，允许多个分片并发缓存
func (c *DiskCache) StreamAndCache(key string, dest io.Writer, src io.Reader) (int64, error) {
	// 检查是否已有其他 goroutine 在写同一分片
	if _, loading := c.writingMu.LoadOrStore(key, true); loading {
		// 已有写入在进行，直接转发不缓存
		return io.Copy(dest, src)
	}
	defer c.writingMu.Delete(key)

	path := c.cachePath(key)
	tmpPath := path + ".tmp"

	tmpFile, err := os.Create(tmpPath)
	if err != nil {
		// 缓存写入失败，不影响播放，直接转发
		return io.Copy(dest, src)
	}

	// 同时写入客户端和临时文件（无锁，不阻塞其他分片）
	multi := io.MultiWriter(dest, tmpFile)
	n, err := io.Copy(multi, src)
	tmpFile.Close()

	if err == nil {
		// 原子重命名
		os.Rename(tmpPath, path)
	} else {
		os.Remove(tmpPath)
	}

	return n, nil
}

// Clean 清理超过 maxAge 的缓存文件
func (c *DiskCache) Clean(maxAgeSec int64) {
	c.mu.Lock()
	defer c.mu.Unlock()

	entries, err := os.ReadDir(c.dir)
	if err != nil {
		return
	}

	now := time.Now()
	for _, entry := range entries {
		info, err := entry.Info()
		if err != nil {
			continue
		}
		if now.Sub(info.ModTime()).Seconds() > float64(maxAgeSec) {
			os.Remove(filepath.Join(c.dir, entry.Name()))
		}
	}
}

// Clear 清空所有缓存
func (c *DiskCache) Clear() {
	c.mu.Lock()
	defer c.mu.Unlock()
	os.RemoveAll(c.dir)
	os.MkdirAll(c.dir, 0755)
}
