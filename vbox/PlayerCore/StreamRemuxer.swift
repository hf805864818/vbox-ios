import Foundation
import CoreMedia
import AVFoundation

// MARK: - 转封装结果

/// 转封装结果
struct RemuxResult {
    /// 初始化段（ftyp + moov），需在媒体段之前发送
    let initSegment: Data
    /// 媒体段列表（moof + mdat），每段可独立播放
    let mediaSegments: [Data]
    /// 视频编码器类型（用于 CMVideoFormatDescription）
    let videoCodecType: UInt32
    /// 视频 extradata（avcC / hvcC 等）
    let videoExtradata: Data?
    /// 视频分辨率
    let videoWidth: Int
    let videoHeight: Int
    /// 音频编码器类型
    let audioCodecType: UInt32
    /// 音频 extradata
    let audioExtradata: Data?

    /// 是否有效
    var isValid: Bool { !initSegment.isEmpty }
}

// MARK: - 流式转封装器

/// 纯 Swift 实现的流式容器转封装器。
///
/// 支持的转换：
/// - MKV (Matroska) → fMP4 (fragmented MP4)
/// - FLV → fMP4
///
/// 转封装 = 只换容器，不重新编码。数据本身原封不动，CPU 开销极低。
///
/// 使用方式：
/// 1. 调用 `processBytes(_:)` 持续喂入源数据
/// 2. 调用 `finalize()` 获取最终结果
/// 3. 通过 `onSegmentReady` 回调获取 fMP4 媒体段（流式输出）
///
/// 限制：
/// - 仅支持 H.264/H.265 视频 + AAC/MP3 音频
/// - 视频最大分辨率 4096x4096
/// - 不支持字幕轨道
final class StreamRemuxer {

    /// 源容器格式
    enum SourceFormat {
        case unknown
        case mkv
        case flv
        case mp4
        case webm
    }

    /// 每产生一个媒体段时回调（用于流式输出）
    var onSegmentReady: ((Data) -> Void)?

    /// 初始化段（ftyp + moov）就绪时回调（在解析完头部后触发一次）
    var onInitSegmentReady: ((Data) -> Void)?

    /// 源格式
    private(set) var sourceFormat: SourceFormat = .unknown
    /// 是否已完成
    private(set) var isComplete = false
    /// 视频尺寸
    private(set) var videoWidth: Int = 0
    private(set) var videoHeight: Int = 0

    // MARK: - 内部状态

    private var buffer = Data()
    private var parsedHeader = false
    private var initSegmentWritten = false

    // MKV 解析状态
    private var mkvTracks: [MKVTrack] = []
    private var mkvClusterTimecode: UInt64 = 0
    private var mkvSegmentBase: UInt64 = 0

    // fMP4 写入状态
    private var fmp4SequenceNumber: UInt32 = 1
    private var fmp4BaseMediaDecodeTime: UInt64 = 0
    private var fmp4VideoTrackID: UInt32 = 1
    private var fmp4AudioTrackID: UInt32 = 2
    private var fmp4VideoTimescale: UInt32 = 0
    private var fmp4AudioTimescale: UInt32 = 0
    private var fmp4DefaultSampleDuration: UInt32 = 0
    private var fmp4DefaultSampleSize: UInt32 = 0

    // 收集的媒体段
    private var mediaSegments: [Data] = []
    private var initSegment: Data = Data()

    // 视频/音频 extradata
    private var videoExtradata: Data?
    private var audioExtradata: Data?
    private var videoCodecType: UInt32 = 0
    private var audioCodecType: UInt32 = 0

    // MARK: - 公开方法

    /// 检测容器格式（从魔数）
    static func detectFormat(from data: Data) -> SourceFormat {
        guard data.count >= 4 else { return .unknown }

        // EBML 头 (MKV/WebM): 0x1A 0x45 0xDF 0xA3
        if data[0] == 0x1A && data[1] == 0x45 && data[2] == 0xDF && data[3] == 0xA3 {
            return .mkv
        }

        // FLV: "FLV" (0x46 0x4C 0x56)
        if data[0] == 0x46 && data[1] == 0x4C && data[2] == 0x56 {
            return .flv
        }

        // MP4: ftyp 在偏移 4 处
        if data.count >= 12 {
            let ftyp = data.subdata(in: 4..<8)
            if String(data: ftyp, encoding: .ascii) == "ftyp" {
                return .mp4
            }
        }

        return .unknown
    }

    /// 喂入原始数据
    func processBytes(_ data: Data) {
        guard !isComplete, !data.isEmpty else { return }
        buffer.append(data)

        if !parsedHeader {
            guard buffer.count >= 4096 else { return }

            sourceFormat = Self.detectFormat(from: buffer)

            switch sourceFormat {
            case .mkv, .webm:
                parseMKVHeader()
            case .flv:
                parseFLVHeader()
            case .mp4:
                handleMP4Passthrough()
                return
            case .unknown:
                return
            }

            parsedHeader = true
        }

        switch sourceFormat {
        case .mkv:
            parseMKVClusters()
        case .flv:
            parseFLVTags()
        default:
            break
        }
    }

    /// 完成转封装
    func finalize() -> RemuxResult {
        isComplete = true

        return RemuxResult(
            initSegment: initSegment,
            mediaSegments: mediaSegments,
            videoCodecType: videoCodecType,
            videoExtradata: videoExtradata,
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            audioCodecType: audioCodecType,
            audioExtradata: audioExtradata
        )
    }

    // MARK: - MP4 透传

    private func handleMP4Passthrough() {
        initSegment = Data()
        isComplete = true
    }

    // MARK: - MKV 解析

    private func parseMKVHeader() {
        var offset = 0

        offset = skipEBMLElement(at: offset)
        guard offset < buffer.count else { return }

        let (segID, segSize) = readEBMLElementHeader(at: offset)
        guard segID == 0x18538067 else { return }
        offset += segSize.0

        let segmentEnd = offset + Int(segSize.1)

        while offset < segmentEnd && offset < buffer.count {
            let (elemID, elemSize) = readEBMLElementHeader(at: offset)
            let headerSize = elemSize.0
            let dataSize = Int(elemSize.1)
            offset += headerSize

            switch elemID {
            case 0x1549A966:
                offset += dataSize
            case 0x1654AE6B:
                parseMKVTracks(from: offset, length: dataSize)
                offset += dataSize
            case 0x1F43B675:
                offset -= headerSize
                return
            default:
                if dataSize < 0 || offset + dataSize > buffer.count { return }
                offset += dataSize
            }
        }
    }

    private func parseMKVTracks(from offset: Int, length: Int) {
        var pos = offset
        let end = offset + length

        while pos < end && pos < buffer.count {
            let (elemID, elemSize) = readEBMLElementHeader(at: pos)
            let headerSize = elemSize.0
            let dataSize = Int(elemSize.1)
            pos += headerSize

            if elemID == 0xAE {
                parseMKVTrackEntry(from: pos, length: dataSize)
            }

            pos += dataSize
        }

        if !mkvTracks.isEmpty {
            initSegment = buildFMP4InitSegment()
            initSegmentWritten = true
            onInitSegmentReady?(initSegment)
        }
    }

    private func parseMKVTrackEntry(from offset: Int, length: Int) {
        var pos = offset
        let end = offset + length
        var track = MKVTrack()

        while pos < end && pos < buffer.count {
            let (elemID, elemSize) = readEBMLElementHeader(at: pos)
            let headerSize = elemSize.0
            let dataSize = Int(elemSize.1)
            pos += headerSize

            let dataEnd = min(pos + dataSize, buffer.count)

            switch elemID {
            case 0xD7:
                track.trackNumber = readUInt(buffer, pos: pos, length: dataSize)
            case 0x83:
                if dataSize > 0 && pos < buffer.count { track.trackType = buffer[pos] }
            case 0x86:
                track.codecID = String(data: buffer.subdata(in: pos..<dataEnd), encoding: .utf8) ?? ""
            case 0x63A2:
                track.codecPrivate = buffer.subdata(in: pos..<dataEnd)
            case 0xE0:
                parseMKVVideo(from: pos, length: dataSize, track: &track)
            case 0xE1:
                parseMKVAudio(from: pos, length: dataSize, track: &track)
            case 0x258688:
                track.codecName = String(data: buffer.subdata(in: pos..<dataEnd), encoding: .utf8) ?? ""
            default:
                break
            }

            pos += dataSize
        }

        if track.trackType == 1 || track.trackType == 2 {
            mkvTracks.append(track)
        }
    }

    private func parseMKVVideo(from offset: Int, length: Int, track: inout MKVTrack) {
        var pos = offset
        let end = offset + length

        while pos < end && pos < buffer.count {
            let (elemID, elemSize) = readEBMLElementHeader(at: pos)
            let headerSize = elemSize.0
            let dataSize = Int(elemSize.1)
            pos += headerSize

            switch elemID {
            case 0xB0: track.videoWidth = Int(readUInt(buffer, pos: pos, length: dataSize))
            case 0xBA: track.videoHeight = Int(readUInt(buffer, pos: pos, length: dataSize))
            default: break
            }

            pos += dataSize
        }
    }

    private func parseMKVAudio(from offset: Int, length: Int, track: inout MKVTrack) {
        var pos = offset
        let end = offset + length

        while pos < end && pos < buffer.count {
            let (elemID, elemSize) = readEBMLElementHeader(at: pos)
            let headerSize = elemSize.0
            let dataSize = Int(elemSize.1)
            pos += headerSize

            switch elemID {
            case 0xB5: track.audioSampleRate = Float64(readFloat(buffer, pos: pos, length: dataSize))
            case 0x9F: if dataSize > 0 && pos < buffer.count { track.audioChannels = Int(buffer[pos]) }
            default: break
            }

            pos += dataSize
        }
    }

    // MARK: - MKV Cluster 解析

    private func parseMKVClusters() {
        var offset = findNextClusterOffset()
        guard offset < buffer.count else { return }

        while offset < buffer.count {
            let (elemID, elemSize) = readEBMLElementHeader(at: offset)
            let headerSize = elemSize.0
            let dataSize = Int(elemSize.1)

            guard elemID == 0x1F43B675 else { break }

            offset += headerSize
            let clusterDataStart = offset
            let clusterDataEnd = min(offset + dataSize, buffer.count)

            var clusterTimecode: UInt64 = 0
            var simpleBlocks: [MKVSimpleBlock] = []
            var pos = offset

            while pos < clusterDataEnd {
                let (subID, subSize) = readEBMLElementHeader(at: pos)
                let subHeaderSize = subSize.0
                let subDataSize = Int(subSize.1)
                pos += subHeaderSize

                switch subID {
                case 0xE7:
                    clusterTimecode = readUInt(buffer, pos: pos, length: subDataSize)
                case 0xA3:
                    if let block = parseSimpleBlock(from: pos, length: subDataSize) {
                        simpleBlocks.append(block)
                    }
                case 0xA0:
                    parseBlockGroup(from: pos, length: subDataSize, into: &simpleBlocks)
                default:
                    break
                }

                pos += subDataSize
            }

            if !simpleBlocks.isEmpty {
                let segment = buildFMP4MediaSegment(
                    simpleBlocks: simpleBlocks,
                    clusterTimecode: clusterTimecode
                )
                if !segment.isEmpty {
                    mediaSegments.append(segment)
                    onSegmentReady?(segment)

                    let keepOffset = max(0, clusterDataStart - 65536)
                    if keepOffset > 0 {
                        buffer.removeSubrange(0..<keepOffset)
                    }
                }
            }

            offset = clusterDataEnd
        }
    }

    private func parseSimpleBlock(from offset: Int, length: Int) -> MKVSimpleBlock? {
        guard offset + 4 <= buffer.count else { return nil }

        var block = MKVSimpleBlock()
        var pos = offset

        let (trackNum, trackBytes) = readVINT(buffer, pos: pos)
        block.trackNumber = trackNum
        pos += trackBytes

        guard pos + 2 <= buffer.count else { return nil }
        block.timecode = Int16(buffer[pos]) << 8 | Int16(buffer[pos + 1])
        pos += 2

        guard pos < buffer.count else { return nil }
        block.flags = buffer[pos]
        pos += 1

        block.data = buffer.subdata(in: pos..<min(pos + (length - (pos - offset)), buffer.count))

        return block
    }

    private func parseBlockGroup(from offset: Int, length: Int, into blocks: inout [MKVSimpleBlock]) {
        var pos = offset
        let end = offset + length

        while pos < end && pos < buffer.count {
            let (elemID, elemSize) = readEBMLElementHeader(at: pos)
            let headerSize = elemSize.0
            let dataSize = Int(elemSize.1)
            pos += headerSize

            if elemID == 0xA1 {
                if let block = parseBlock(from: pos, length: dataSize) {
                    blocks.append(block)
                }
            }

            pos += dataSize
        }
    }

    private func parseBlock(from offset: Int, length: Int) -> MKVSimpleBlock? {
        return parseSimpleBlock(from: offset, length: length)
    }

    // MARK: - FLV 解析

    private func parseFLVHeader() {
        guard buffer.count >= 13 else { return }

        let flags = buffer[4]
        let hasVideo = (flags & 0x01) != 0
        let hasAudio = (flags & 0x04) != 0

        if hasVideo {
            var track = MKVTrack()
            track.trackNumber = 1
            track.trackType = 1
            track.codecID = "V_MPEG4/ISO/AVC"
            mkvTracks.append(track)
        }

        if hasAudio {
            var track = MKVTrack()
            track.trackNumber = 2
            track.trackType = 2
            track.codecID = "A_AAC"
            mkvTracks.append(track)
        }

        if !mkvTracks.isEmpty {
            initSegment = buildFMP4InitSegment()
            initSegmentWritten = true
            onInitSegmentReady?(initSegment)
        }
    }

    private func parseFLVTags() {
        var offset = 13

        while offset + 15 <= buffer.count {
            offset += 4

            guard offset + 11 <= buffer.count else { break }

            let tagType = buffer[offset]
            let dataSize = Int(buffer[offset + 1]) << 16 | Int(buffer[offset + 2]) << 8 | Int(buffer[offset + 3])
            let timestamp = (Int(buffer[offset + 4]) << 16 | Int(buffer[offset + 5]) << 8 | Int(buffer[offset + 6])) |
                            (Int(buffer[offset + 7]) << 24)

            offset += 11

            guard offset + dataSize <= buffer.count else { break }

            var block = MKVSimpleBlock()
            block.timecode = Int16(timestamp & 0xFFFF)

            if tagType == 9 {
                block.trackNumber = 1
                if dataSize > 1 {
                    let frameType = (buffer[offset] >> 4) & 0x0F
                    block.flags = (frameType == 1) ? 0x80 : 0x00
                    block.data = buffer.subdata(in: (offset + 1)..<(offset + dataSize))
                }
            } else if tagType == 8 {
                block.trackNumber = 2
                block.flags = 0x80
                if dataSize > 1 {
                    block.data = buffer.subdata(in: (offset + 1)..<(offset + dataSize))
                }
            } else {
                offset += dataSize
                continue
            }

            if !block.data.isEmpty {
                let segment = buildFMP4MediaSegment(
                    simpleBlocks: [block],
                    clusterTimecode: UInt64(timestamp)
                )
                if !segment.isEmpty {
                    mediaSegments.append(segment)
                    onSegmentReady?(segment)
                }
            }

            offset += dataSize
        }
    }

    // MARK: - fMP4 构建

    private func buildFMP4InitSegment() -> Data {
        var data = Data()

        var videoTrack: MKVTrack?
        var audioTrack: MKVTrack?
        var videoTrackID: UInt32 = 1
        var audioTrackID: UInt32 = 2

        for track in mkvTracks {
            if track.trackType == 1, videoTrack == nil {
                videoTrack = track
                videoTrackID = UInt32(track.trackNumber)
            } else if track.trackType == 2, audioTrack == nil {
                audioTrack = track
                audioTrackID = UInt32(track.trackNumber)
            }
        }

        videoCodecType = codecTypeFromMKVCodecID(videoTrack?.codecID ?? "")
        videoExtradata = videoTrack?.codecPrivate
        videoWidth = videoTrack?.videoWidth ?? 0
        videoHeight = videoTrack?.videoHeight ?? 0
        audioCodecType = codecTypeFromMKVCodecID(audioTrack?.codecID ?? "")
        audioExtradata = audioTrack?.codecPrivate

        fmp4VideoTimescale = 1000
        fmp4AudioTimescale = UInt32(audioTrack?.audioSampleRate ?? 44100)
        fmp4VideoTrackID = videoTrackID
        fmp4AudioTrackID = audioTrackID

        if videoCodecType == kCMVideoCodecType_H264 {
            fmp4DefaultSampleDuration = 40
            fmp4DefaultSampleSize = 0
        } else if videoCodecType == kCMVideoCodecType_HEVC {
            fmp4DefaultSampleDuration = 40
            fmp4DefaultSampleSize = 0
        }

        // ftyp
        data.append(box("ftyp") {
            var d = Data()
            d.append("isom".data(using: .ascii)!)
            d.append(writeUInt32(0x200))
            d.append("isom".data(using: .ascii)!)
            d.append("iso2".data(using: .ascii)!)
            d.append("avc1".data(using: .ascii)!)
            d.append("mp41".data(using: .ascii)!)
            return d
        })

        // moov
        data.append(box("moov") {
            var moov = Data()

            // mvhd
            moov.append(fullBox("mvhd", version: 0, flags: 0) {
                var d = Data()
                d.append(writeUInt32(0))
                d.append(writeUInt32(0))
                d.append(writeUInt32(1000))
                d.append(writeUInt32(0))
                d.append(writeUInt32(0x00010000))
                d.append(writeUInt16(0x0100))
                d.append(writeUInt16(0))
                d.append(writeUInt32(0))
                d.append(writeUInt32(0))
                d.append(writeUInt32(0x00010000))
                d.append(writeUInt32(0))
                d.append(writeUInt32(0))
                d.append(writeUInt32(0))
                d.append(writeUInt32(0x00010000))
                d.append(writeUInt32(0))
                d.append(writeUInt32(0))
                d.append(writeUInt32(0))
                d.append(writeUInt32(0x40000000))
                for _ in 0..<6 { d.append(writeUInt32(0)) }
                d.append(writeUInt32(2))
                return d
            })

            if let vt = videoTrack {
                moov.append(buildTrakBox(track: vt, trackID: videoTrackID, timescale: fmp4VideoTimescale, isVideo: true))
            }
            if let at = audioTrack {
                moov.append(buildTrakBox(track: at, trackID: audioTrackID, timescale: fmp4AudioTimescale, isVideo: false))
            }

            return moov
        })

        return data
    }

    private func buildTrakBox(track: MKVTrack, trackID: UInt32, timescale: UInt32, isVideo: Bool) -> Data {
        return box("trak") {
            var trak = Data()

            trak.append(fullBox("tkhd", version: 0, flags: isVideo ? 0x0F : 0x00) {
                var d = Data()
                d.append(writeUInt32(0))
                d.append(writeUInt32(0))
                d.append(writeUInt32(trackID))
                d.append(writeUInt32(0))
                d.append(writeUInt32(0))
                d.append(writeUInt32(0))
                d.append(writeUInt32(0))
                d.append(writeUInt16(0))
                d.append(writeUInt16(0))
                d.append(writeUInt16(0x0100))
                d.append(writeUInt16(0))
                d.append(writeUInt32(0x00010000)); d.append(writeUInt32(0)); d.append(writeUInt32(0))
                d.append(writeUInt32(0)); d.append(writeUInt32(0x00010000)); d.append(writeUInt32(0))
                d.append(writeUInt32(0)); d.append(writeUInt32(0)); d.append(writeUInt32(0x40000000))
                d.append(writeUInt32(UInt32(track.videoWidth) << 16))
                d.append(writeUInt32(UInt32(track.videoHeight) << 16))
                return d
            })

            trak.append(box("mdia") {
                var mdia = Data()

                mdia.append(fullBox("mdhd", version: 0, flags: 0) {
                    var d = Data()
                    d.append(writeUInt32(0))
                    d.append(writeUInt32(0))
                    d.append(writeUInt32(timescale))
                    d.append(writeUInt32(0))
                    d.append(writeUInt16(0x55C4))
                    d.append(writeUInt16(0))
                    return d
                })

                mdia.append(fullBox("hdlr", version: 0, flags: 0) {
                    var d = Data()
                    d.append(writeUInt32(0))
                    d.append(isVideo ? "vide".data(using: .ascii)! : "soun".data(using: .ascii)!)
                    d.append(writeUInt32(0))
                    d.append(writeUInt32(0))
                    d.append(writeUInt32(0))
                    d.append("vBox".data(using: .ascii)!)
                    d.append(0x00)
                    return d
                })

                mdia.append(box("minf") {
                    var minf = Data()

                    if isVideo {
                        minf.append(fullBox("vmhd", version: 0, flags: 1) {
                            var d = Data()
                            d.append(writeUInt16(0))
                            d.append(writeUInt16(0))
                            d.append(writeUInt16(0))
                            d.append(writeUInt16(0))
                            return d
                        })
                    } else {
                        minf.append(fullBox("smhd", version: 0, flags: 0) {
                            var d = Data()
                            d.append(writeUInt16(0))
                            d.append(writeUInt16(0))
                            return d
                        })
                    }

                    minf.append(box("dinf") {
                        fullBox("dref", version: 0, flags: 0) {
                            var d = Data()
                            d.append(writeUInt32(1))
                            d.append(writeUInt32(0))
                            d.append(writeUInt32(0))
                            d.append(writeUInt32(0))
                            return d
                        }
                    })

                    minf.append(box("stbl") {
                        var stbl = Data()

                        stbl.append(fullBox("stsd", version: 0, flags: 0) {
                            var d = Data()
                            d.append(writeUInt32(1))

                            if isVideo {
                                let codecFourCC = fourCCForCodecType(track.codecID)
                                d.append(box(String(data: codecFourCC, encoding: .ascii) ?? "avc1") {
                                    var sd = Data()
                                    sd.append(writeUInt32(0))
                                    sd.append(writeUInt16(0))
                                    sd.append(writeUInt16(1))
                                    sd.append(writeUInt16(0))
                                    sd.append(writeUInt16(0))
                                    sd.append(writeUInt32(0))
                                    sd.append(writeUInt32(0))
                                    sd.append(writeUInt32(0))
                                    sd.append(writeUInt16(UInt16(track.videoWidth)))
                                    sd.append(writeUInt16(UInt16(track.videoHeight)))
                                    sd.append(writeUInt32(0x00480000))
                                    sd.append(writeUInt32(0x00480000))
                                    sd.append(writeUInt32(0))
                                    sd.append(writeUInt16(1))
                                    sd.append("                                ".data(using: .ascii)!.prefix(32))
                                    sd.append(writeUInt16(0x0018))
                                    sd.append(writeInt16(-1))
                                    if let extradata = track.codecPrivate {
                                        sd.append(box("avcC") { extradata })
                                    }
                                    return sd
                                })
                            } else {
                                d.append(box("mp4a") {
                                    var sd = Data()
                                    sd.append(writeUInt32(0))
                                    sd.append(writeUInt16(0))
                                    sd.append(writeUInt16(1))
                                    sd.append(writeUInt16(0))
                                    sd.append(writeUInt32(0))
                                    sd.append(writeUInt16(2))
                                    sd.append(writeUInt16(16))
                                    sd.append(writeUInt16(0))
                                    sd.append(writeUInt16(0))
                                    sd.append(writeUInt32(UInt32(track.audioSampleRate > 0 ? track.audioSampleRate : 44100) << 16))
                                    if let extradata = track.codecPrivate {
                                        sd.append(box("esds") {
                                            var esds = Data()
                                            esds.append(writeUInt32(0))
                                            esds.append(0x03)
                                            esds.append(0x19)
                                            esds.append(writeUInt16(0))
                                            esds.append(0x00)
                                            esds.append(0x04)
                                            esds.append(0x11)
                                            esds.append(0x40)
                                            esds.append(0x15)
                                            esds.append(writeUInt24(0))
                                            esds.append(writeUInt32(0))
                                            esds.append(writeUInt32(0))
                                            esds.append(0x05)
                                            esds.append(UInt8(extradata.count))
                                            esds.append(extradata)
                                            esds.append(0x06)
                                            esds.append(0x01)
                                            esds.append(0x02)
                                            return esds
                                        })
                                    }
                                    return sd
                                })
                            }

                            return d
                        })

                        return stbl
                    })

                    return minf
                })

                return mdia
            })

            return trak
        }
    }

    private func buildFMP4MediaSegment(simpleBlocks: [MKVSimpleBlock], clusterTimecode: UInt64) -> Data {
        guard !simpleBlocks.isEmpty else { return Data() }

        var data = Data()

        var videoBlocks: [MKVSimpleBlock] = []
        var audioBlocks: [MKVSimpleBlock] = []

        for block in simpleBlocks {
            if block.trackNumber == fmp4VideoTrackID {
                videoBlocks.append(block)
            } else if block.trackNumber == fmp4AudioTrackID {
                audioBlocks.append(block)
            }
        }

        if mkvSegmentBase == 0 && clusterTimecode > 0 {
            mkvSegmentBase = clusterTimecode
        }
        let relativeTimecode = clusterTimecode > mkvSegmentBase ? clusterTimecode - mkvSegmentBase : 0
        fmp4BaseMediaDecodeTime = relativeTimecode

        // styp
        data.append(box("styp") {
            var d = Data()
            d.append("msdh".data(using: .ascii)!)
            d.append(writeUInt32(0))
            d.append("msdh".data(using: .ascii)!)
            d.append("msix".data(using: .ascii)!)
            return d
        })

        // moof
        data.append(box("moof") {
            var moof = Data()

            moof.append(fullBox("mfhd", version: 0, flags: 0) {
                writeUInt32(fmp4SequenceNumber)
            })
            fmp4SequenceNumber += 1

            if !videoBlocks.isEmpty {
                moof.append(buildTrafBox(
                    trackID: fmp4VideoTrackID,
                    blocks: videoBlocks,
                    baseTime: fmp4BaseMediaDecodeTime,
                    timescale: fmp4VideoTimescale,
                    defaultDuration: fmp4DefaultSampleDuration,
                    defaultSize: fmp4DefaultSampleSize,
                    isVideo: true
                ))
            }

            if !audioBlocks.isEmpty {
                moof.append(buildTrafBox(
                    trackID: fmp4AudioTrackID,
                    blocks: audioBlocks,
                    baseTime: fmp4BaseMediaDecodeTime,
                    timescale: fmp4AudioTimescale,
                    defaultDuration: 1024,
                    defaultSize: 0,
                    isVideo: false
                ))
            }

            return moof
        })

        // mdat
        data.append(box("mdat") {
            var mdat = Data()
            for block in simpleBlocks {
                mdat.append(block.data)
            }
            return mdat
        })

        return data
    }

    private func buildTrafBox(trackID: UInt32, blocks: [MKVSimpleBlock], baseTime: UInt64, timescale: UInt32, defaultDuration: UInt32, defaultSize: UInt32, isVideo: Bool) -> Data {
        return box("traf") {
            var traf = Data()

            var tfhdFlags: UInt32 = 0x020000
            if defaultDuration > 0 { tfhdFlags |= 0x000008 }
            if defaultSize > 0 { tfhdFlags |= 0x000010 }
            traf.append(fullBox("tfhd", version: 0, flags: tfhdFlags) {
                var d = Data()
                d.append(writeUInt32(trackID))
                if defaultDuration > 0 { d.append(writeUInt32(defaultDuration)) }
                if defaultSize > 0 { d.append(writeUInt32(defaultSize)) }
                return d
            })

            traf.append(fullBox("tfdt", version: 1, flags: 0) {
                writeUInt64(baseTime)
            })

            var trunFlags: UInt32 = 0x000001 | 0x000100 | 0x000200
            if isVideo { trunFlags |= 0x000004 }
            traf.append(fullBox("trun", version: 0, flags: trunFlags) {
                var d = Data()
                d.append(writeUInt32(UInt32(blocks.count)))
                d.append(writeUInt32(8 + 16 + 20 + 8 + 8 + 4))
                for block in blocks {
                    d.append(writeUInt32(UInt32(block.data.count)))
                    if isVideo { d.append(writeUInt32(0)) }
                    if isVideo { d.append(writeUInt32(block.isKeyframe ? 0x02000000 : 0x01010000)) }
                }
                return d
            })

            return traf
        }
    }

    // MARK: - EBML 解析辅助

    private func readEBMLElementHeader(at offset: Int) -> (id: UInt64, size: (Int, UInt64)) {
        let (id, idBytes) = readVINT(buffer, pos: offset)
        let (size, sizeBytes) = readVINT(buffer, pos: offset + idBytes)
        return (id, (idBytes + sizeBytes, size))
    }

    private func skipEBMLElement(at offset: Int) -> Int {
        let (_, size) = readEBMLElementHeader(at: offset)
        return offset + size.0 + Int(size.1)
    }

    private func findNextClusterOffset() -> Int {
        let clusterID: [UInt8] = [0x1F, 0x43, 0xB6, 0x75]
        var offset = 0
        while offset + 4 <= buffer.count {
            if buffer[offset] == clusterID[0],
               buffer[offset + 1] == clusterID[1],
               buffer[offset + 2] == clusterID[2],
               buffer[offset + 3] == clusterID[3] {
                return offset
            }
            offset += 1
        }
        return buffer.count
    }

    // MARK: - Codec 映射

    private func codecTypeFromMKVCodecID(_ codecID: String) -> UInt32 {
        switch codecID {
        case "V_MPEG4/ISO/AVC": return kCMVideoCodecType_H264
        case "V_MPEGH/ISO/HEVC": return kCMVideoCodecType_HEVC
        case "A_AAC", "A_AAC/MPEG2/LC", "A_AAC/MPEG4/LC": return kAudioFormatMPEG4AAC
        case "A_MPEG/L3": return kAudioFormatMPEGLayer3
        case "A_OPUS": return kAudioFormatOpus
        default: return 0
        }
    }

    private func fourCCForCodecType(_ codecID: String) -> Data {
        switch codecID {
        case "V_MPEG4/ISO/AVC": return "avc1".data(using: .ascii)!
        case "V_MPEGH/ISO/HEVC": return "hvc1".data(using: .ascii)!
        default: return "avc1".data(using: .ascii)!
        }
    }

    // MARK: - 二进制工具

    private func readVINT(_ data: Data, pos: Int) -> (UInt64, Int) {
        guard pos < data.count else { return (0, 0) }
        let first = data[pos]
        var length: Int = 0
        var mask: UInt8 = 0x80
        for i in 0..<8 {
            if (first & mask) != 0 { length = i + 1; break }
            mask >>= 1
        }
        guard length > 0, pos + length <= data.count else { return (0, 0) }
        var value: UInt64 = UInt64(first & (mask - 1))
        for i in 1..<length {
            value = (value << 8) | UInt64(data[pos + i])
        }
        return (value, length)
    }

    private func readUInt(_ data: Data, pos: Int, length: Int) -> UInt64 {
        guard pos + length <= data.count else { return 0 }
        var value: UInt64 = 0
        for i in 0..<length { value = (value << 8) | UInt64(data[pos + i]) }
        return value
    }

    private func readFloat(_ data: Data, pos: Int, length: Int) -> Float64 {
        let raw = readUInt(data, pos: pos, length: length)
        if length == 4 { return Float64(Float(bitPattern: UInt32(raw))) }
        else if length == 8 { return Float64(bitPattern: raw) }
        return Float64(raw)
    }

    // MARK: - MP4 Box 工具

    private func box(_ type: String, _ body: () -> Data) -> Data {
        let bodyData = body()
        let totalSize = UInt32(8 + bodyData.count)
        var data = Data()
        data.append(writeUInt32(totalSize))
        data.append(type.data(using: .ascii)!)
        data.append(bodyData)
        return data
    }

    private func fullBox(_ type: String, version: UInt8, flags: UInt32, _ body: () -> Data) -> Data {
        let bodyData = body()
        let totalSize = UInt32(12 + bodyData.count)
        var data = Data()
        data.append(writeUInt32(totalSize))
        data.append(type.data(using: .ascii)!)
        data.append(version)
        data.append(writeUInt24(flags))
        data.append(bodyData)
        return data
    }

    private func writeUInt32(_ value: UInt32) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 4)
    }

    private func writeUInt64(_ value: UInt64) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 8)
    }

    private func writeUInt24(_ value: UInt32) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 4).subdata(in: 1..<4)
    }

    private func writeUInt16(_ value: UInt16) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 2)
    }

    private func writeInt16(_ value: Int16) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 2)
    }
}

// MARK: - MKV 数据结构

private struct MKVTrack {
    var trackNumber: UInt64 = 0
    var trackType: UInt8 = 0
    var codecID: String = ""
    var codecName: String = ""
    var codecPrivate: Data?
    var videoWidth: Int = 0
    var videoHeight: Int = 0
    var audioSampleRate: Float64 = 0
    var audioChannels: Int = 0
}

private struct MKVSimpleBlock {
    var trackNumber: UInt64 = 0
    var timecode: Int16 = 0
    var flags: UInt8 = 0
    var data: Data = Data()

    var isKeyframe: Bool { (flags & 0x80) != 0 }
}