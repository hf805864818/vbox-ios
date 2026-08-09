//
//  VTDecoderSession.swift
//  vbox
//
//  VideoToolbox 硬解码会话封装，专用于 PiP 场景。
//  输入：H.264/H.265 原始编码数据（NAL 单元）
//  输出：CVPixelBuffer（硬件解码，零拷贝）
//
//  注意：此文件仅用于画中画（PiP）解码，不影响主播放链路。
//

import Foundation
import VideoToolbox
import CoreMedia
import AVFoundation

protocol VTDecoderSessionDelegate: AnyObject {
    /// 解码出一帧时回调
    func decoderSession(_ session: VTDecoderSession, didOutputFrame pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime)
    
    /// 解码出错时回调
    func decoderSession(_ session: VTDecoderSession, didFailWithError error: Error)
}

final class VTDecoderSession {
    
    // MARK: - Properties
    
    weak var delegate: VTDecoderSessionDelegate?
    
    private(set) var isReady = false
    private(set) var codecType: CMVideoCodecType = 0
    private(set) var width: Int = 0
    private(set) var height: Int = 0
    
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var serialQueue = DispatchQueue(label: "com.vbox.vtdecoder")
    
    /// 帧序号，用于生成 pts（如果输入没带时间戳）
    private var frameCount: Int64 = 0
    /// 默认每帧时长（1/30 秒，估算用）
    private let defaultFrameDuration = CMTime(value: 1, timescale: 30)
    
    // MARK: - Init / Deinit
    
    deinit {
        invalidate()
    }
    
    // MARK: - Setup
    
    /// 设置解码会话
    /// - Parameters:
    ///   - codecType: 视频编码类型（kCMVideoCodecType_H264 / kCMVideoCodecType_HEVC）
    ///   - extradata: 编码器私有数据（H.264: avcC 或 Annex-B SPS/PPS；H.265: hvcC 或 VPS+SPS+PPS）
    ///   - width: 视频宽度
    ///   - height: 视频高度
    func setup(codecType: CMVideoCodecType, extradata: Data?, width: Int, height: Int) throws {
        invalidate()
        
        self.codecType = codecType
        self.width = width
        self.height = height
        
        guard codecType == kCMVideoCodecType_H264 || codecType == kCMVideoCodecType_HEVC else {
            throw VTError.unsupportedCodec
        }
        
        // 创建 CMVideoFormatDescription
        let formatDesc = try createFormatDescription(
            codecType: codecType,
            extradata: extradata,
            width: width,
            height: height
        )
        self.formatDescription = formatDesc
        
        // 创建 VTDecompressionSession
        let decoderSpecification: [CFString: Any] = [
            kVTDecompressionPropertyKey_RealTime: true,
            kVTDecompressionPropertyKey_OnlyTheseFrames: kVTDecompressionProperty_OnlyTheseFrames_AllFrames
        ]
        
        let imageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferOpenGLESCompatibilityKey: true
        ]
        
        var outputCallback = VTDecompressionOutputCallbackRecord()
        outputCallback.decompressionOutputCallback = { (
            decompressionOutputRefCon: UnsafeMutableRawPointer?,
            sourceFrameRefCon: UnsafeMutableRawPointer?,
            status: OSStatus,
            infoFlags: VTDecodeInfoFlags,
            imageBuffer: CVImageBuffer?,
            presentationTimeStamp: CMTime,
            presentationDuration: CMTime
        ) in
            guard let refCon = decompressionOutputRefCon else { return }
            let session = Unmanaged<VTDecoderSession>.fromOpaque(refCon).takeUnretainedValue()
            session.handleDecodedFrame(
                status: status,
                imageBuffer: imageBuffer,
                presentationTimeStamp: presentationTimeStamp,
                userData: sourceFrameRefCon
            )
        }
        
        let selfRef = Unmanaged.passUnretained(self).toOpaque()
        
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: &outputCallback,
            decompressionSessionOut: &session
        )
        
        guard status == noErr, let decompSession = session else {
            throw VTError.decoderCreateFailed(status: status)
        }
        
        self.decompressionSession = decompSession
        self.isReady = true
    }
    
    /// 销毁解码会话
    func invalidate() {
        serialQueue.sync {
            if let session = decompressionSession {
                VTDecompressionSessionInvalidate(session)
                decompressionSession = nil
            }
            formatDescription = nil
            isReady = false
            frameCount = 0
        }
    }
    
    // MARK: - Decode
    
    /// 解码一帧
    /// - Parameters:
    ///   - data: 编码数据（一个完整的帧，可能包含多个 NAL）
    ///   - presentationTimeStamp: 显示时间戳
    ///   - isKeyframe: 是否关键帧
    ///   - userData: 用户数据，会在回调中原样返回
    func decodeFrame(
        _ data: Data,
        presentationTimeStamp: CMTime? = nil,
        isKeyframe: Bool = false,
        userData: UnsafeMutableRawPointer? = nil
    ) {
        guard isReady, let session = decompressionSession, let formatDesc = formatDescription else {
            delegate?.decoderSession(self, didFailWithError: VTError.notReady)
            return
        }
        
        let pts = presentationTimeStamp ?? CMTime(value: frameCount, timescale: 30)
        frameCount += 1
        
        serialQueue.async { [weak self] in
            guard let self else { return }
            
            // 创建 CMSampleBuffer
            var sampleBuffer: CMSampleBuffer?
            
            // 创建 blockBuffer
            var blockBuffer: CMBlockBuffer?
            let dataSize = data.count
            let status1 = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: dataSize,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataSize,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            
            guard status1 == noErr, let blockBuf = blockBuffer else {
                DispatchQueue.main.async {
                    self.delegate?.decoderSession(self, didFailWithError: VTError.blockBufferCreateFailed)
                }
                return
            }
            
            // 填充数据
            let copyStatus = data.withUnsafeBytes { ptr in
                CMBlockBufferReplaceDataBytes(
                    with: ptr.baseAddress!,
                    blockBuffer: blockBuf,
                    offsetIntoDestination: 0,
                    dataLength: dataSize
                )
            }
            
            guard copyStatus == noErr else {
                DispatchQueue.main.async {
                    self.delegate?.decoderSession(self, didFailWithError: VTError.blockBufferCopyFailed)
                }
                return
            }
            
            // 创建 sample timing info
            var timingInfo = CMSampleTimingInfo(
                duration: self.defaultFrameDuration,
                presentationTimeStamp: pts,
                decodeTimeStamp: .invalid
            )
            
            // 创建 sampleBuffer
            let status2 = CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuf,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDesc,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timingInfo,
                sampleSizeEntryCount: 1,
                sampleSizeArray: [dataSize],
                sampleBufferOut: &sampleBuffer
            )
            
            guard status2 == noErr, let sampleBuf = sampleBuffer else {
                DispatchQueue.main.async {
                    self.delegate?.decoderSession(self, didFailWithError: VTError.sampleBufferCreateFailed)
                }
                return
            }
            
            // 设置关键帧标记
            if isKeyframe {
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuf, createIfNecessary: true)
                if let arr = attachments as? [[CFString: Any]], var dict = arr.first {
                    dict[kCMSampleAttachmentKey_DependsOnOthers] = false
                    dict[kCMSampleAttachmentKey_NotSync] = false
                }
            }
            
            // 解码
            let selfRef = Unmanaged.passUnretained(self).toOpaque()
            
            var infoFlags = VTDecodeInfoFlags()
            let decodeStatus = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuf,
                flags: [._EnableAsynchronousDecompression],
                frameRefcon: userData,
                infoFlagsOut: &infoFlags
            )
            
            if decodeStatus != noErr {
                DispatchQueue.main.async {
                    self.delegate?.decoderSession(
                        self,
                        didFailWithError: VTError.decodeFailed(status: decodeStatus)
                    )
                }
            }
        }
    }
    
    /// 解码完成，刷新所有待解码帧
    func finishDecoding() {
        guard let session = decompressionSession else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }
    
    // MARK: - Private
    
    private func handleDecodedFrame(
        status: OSStatus,
        imageBuffer: CVImageBuffer?,
        presentationTimeStamp: CMTime,
        userData: UnsafeMutableRawPointer?
    ) {
        if status != noErr {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.decoderSession(
                    self,
                    didFailWithError: VTError.decodeFailed(status: status)
                )
            }
            return
        }
        
        guard let pixelBuffer = imageBuffer else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.decoderSession(
                self,
                didOutputFrame: pixelBuffer,
                presentationTimeStamp: presentationTimeStamp
            )
        }
    }
    
    /// 根据 extradata 创建 CMVideoFormatDescription
    private func createFormatDescription(
        codecType: CMVideoCodecType,
        extradata: Data?,
        width: Int,
        height: Int
    ) throws -> CMVideoFormatDescription {
        
        // 如果有 extradata，尝试解析参数集
        if let extradata = extradata, !extradata.isEmpty {
            if codecType == kCMVideoCodecType_H264 {
                // H.264: 尝试从 avcC 或 Annex-B 中提取 SPS/PPS
                if let formatDesc = createH264FormatDescription(
                    extradata: extradata,
                    width: width,
                    height: height
                ) {
                    return formatDesc
                }
            } else if codecType == kCMVideoCodecType_HEVC {
                // H.265: 尝试从 hvcC 或 Annex-B 中提取 VPS/SPS/PPS
                if let formatDesc = createHEVCFormatDescription(
                    extradata: extradata,
                    width: width,
                    height: height
                ) {
                    return formatDesc
                }
            }
        }
        
        // 没有 extradata 或解析失败，先创建一个空的 format description
        // 等第一个关键帧到来时再重建
        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: Int32(width),
            height: Int32(height),
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        
        guard status == noErr, let desc = formatDesc else {
            throw VTError.formatDescriptionCreateFailed(status: status)
        }
        
        return desc
    }
    
    /// 从 H.264 extradata 中创建 format description
    private func createH264FormatDescription(
        extradata: Data,
        width: Int,
        height: Int
    ) -> CMVideoFormatDescription? {
        
        // 先尝试 avcC 格式（MP4 风格）
        // avcC 结构：configurationVersion(1) + profile(1) + profileCompat(1) + level(1) + reserved+lengthSize(1) + reserved+numSPS(1) + SPS... + numPPS(1) + PPS...
        if extradata.count > 6 {
            var spsData: Data?
            var ppsData: Data?
            
            // 检查是否看起来像 avcC（第一个字节是 1，且 profile 合理）
            let configVersion = extradata[0]
            if configVersion == 1 {
                // avcC 格式
                let numSPS = Int(extradata[5] & 0x1F)
                var offset = 6
                
                for i in 0..<numSPS {
                    guard offset + 2 <= extradata.count else { break }
                    let spsLen = Int(extradata[offset]) << 8 | Int(extradata[offset + 1])
                    offset += 2
                    guard offset + spsLen <= extradata.count else { break }
                    if i == 0 {
                        spsData = extradata.subdata(in: offset..<(offset + spsLen))
                    }
                    offset += spsLen
                }
                
                guard offset + 1 <= extradata.count else { return nil }
                let numPPS = Int(extradata[offset])
                offset += 1
                
                for i in 0..<numPPS {
                    guard offset + 2 <= extradata.count else { break }
                    let ppsLen = Int(extradata[offset]) << 8 | Int(extradata[offset + 1])
                    offset += 2
                    guard offset + ppsLen <= extradata.count else { break }
                    if i == 0 {
                        ppsData = extradata.subdata(in: offset..<(offset + ppsLen))
                    }
                    offset += ppsLen
                }
            }
            
            // 再尝试 Annex-B 格式（以 00 00 00 01 开头）
            if spsData == nil {
                let nalUnits = splitAnnexBNALs(extradata)
                for nal in nalUnits {
                    guard !nal.isEmpty else { continue }
                    let nalType = nal[0] & 0x1F
                    if nalType == 7 { spsData = nal }
                    else if nalType == 8 { ppsData = nal }
                }
            }
            
            if let sps = spsData, let pps = ppsData {
                var formatDesc: CMVideoFormatDescription?
                let status = sps.withUnsafeBytes { spsPtr in
                    pps.withUnsafeBytes { ppsPtr in
                        let spsPointer = spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        let ppsPointer = ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: [spsPointer, ppsPointer],
                            parameterSetSizes: [sps.count, pps.count],
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &formatDesc
                        )
                    }
                }
                if status == noErr, let desc = formatDesc {
                    return desc
                }
            }
        }
        
        return nil
    }
    
    /// 从 H.265 extradata 中创建 format description
    private func createHEVCFormatDescription(
        extradata: Data,
        width: Int,
        height: Int
    ) -> CMVideoFormatDescription? {
        
        var vpsData: Data?
        var spsData: Data?
        var ppsData: Data?
        
        // 尝试 Annex-B 格式
        let nalUnits = splitAnnexBNALs(extradata)
        for nal in nalUnits {
            guard !nal.isEmpty else { continue }
            let nalType = (nal[0] >> 1) & 0x3F
            if nalType == 32 { vpsData = nal }
            else if nalType == 33 { spsData = nal }
            else if nalType == 34 { ppsData = nal }
        }
        
        // 尝试 hvcC 格式
        if spsData == nil && extradata.count > 20 {
            // hvcC 解析较复杂，这里简化处理
            // 如果第一个字节是 1，可能是 hvcC
            if extradata[0] == 1 {
                // 简单解析 hvcC：找参数集
                // 实际应用中应该完整解析 hvcC 结构
                // 这里先跳过，依赖关键帧重建
            }
        }
        
        guard let vps = vpsData, let sps = spsData, let pps = ppsData else {
            return nil
        }
        
        var formatDesc: CMVideoFormatDescription?
        let status = vps.withUnsafeBytes { vpsPtr in
            sps.withUnsafeBytes { spsPtr in
                pps.withUnsafeBytes { ppsPtr in
                    let vpsPointer = vpsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let spsPointer = spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let ppsPointer = ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: [vpsPointer, spsPointer, ppsPointer],
                        parameterSetSizes: [vps.count, sps.count, pps.count],
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &formatDesc
                    )
                }
            }
        }
        
        if status == noErr, let desc = formatDesc {
            return desc
        }
        
        return nil
    }
    
    /// 分割 Annex-B 格式的 NAL 单元
    private func splitAnnexBNALs(_ data: Data) -> [Data] {
        var nalUnits: [Data] = []
        var i = 0
        let count = data.count
        
        while i < count {
            // 找起始码 00 00 00 01 或 00 00 01
            var startCodeLen = 0
            if i + 4 <= count && data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1 {
                startCodeLen = 4
            } else if i + 3 <= count && data[i] == 0 && data[i+1] == 0 && data[i+2] == 1 {
                startCodeLen = 3
            } else {
                i += 1
                continue
            }
            
            let nalStart = i + startCodeLen
            // 找下一个起始码
            var j = nalStart
            while j < count {
                if j + 4 <= count && data[j] == 0 && data[j+1] == 0 && data[j+2] == 0 && data[j+3] == 1 {
                    break
                }
                if j + 3 <= count && data[j] == 0 && data[j+1] == 0 && data[j+2] == 1 {
                    break
                }
                j += 1
            }
            
            if nalStart < j {
                nalUnits.append(data.subdata(in: nalStart..<j))
            }
            i = j
        }
        
        return nalUnits
    }
}

// MARK: - Error

enum VTError: Error {
    case notReady
    case unsupportedCodec
    case decoderCreateFailed(status: OSStatus)
    case formatDescriptionCreateFailed(status: OSStatus)
    case blockBufferCreateFailed
    case blockBufferCopyFailed
    case sampleBufferCreateFailed
    case decodeFailed(status: OSStatus)
    
    var localizedDescription: String {
        switch self {
        case .notReady:
            return "VTDecoderSession 尚未初始化"
        case .unsupportedCodec:
            return "不支持的视频编码格式"
        case .decoderCreateFailed(let status):
            return "VTDecompressionSession 创建失败 (status: \(status))"
        case .formatDescriptionCreateFailed(let status):
            return "CMVideoFormatDescription 创建失败 (status: \(status))"
        case .blockBufferCreateFailed:
            return "CMBlockBuffer 创建失败"
        case .blockBufferCopyFailed:
            return "CMBlockBuffer 数据拷贝失败"
        case .sampleBufferCreateFailed:
            return "CMSampleBuffer 创建失败"
        case .decodeFailed(let status):
            return "解码失败 (status: \(status))"
        }
    }
}
