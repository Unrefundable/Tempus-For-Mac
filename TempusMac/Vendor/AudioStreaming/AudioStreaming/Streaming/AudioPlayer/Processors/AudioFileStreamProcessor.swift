//
//  Created by Dimitrios Chatzieleftheriou on 16/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//
//  Inspired by Thong Nguyen's StreamingKit. All rights reserved.
//

import AVFoundation
import CoreAudio
import OSLog

enum AudioConvertStatus: Int32 {
    case done = 100
    case processed = 0
}

struct AudioConvertInfo {
    var done: Bool
    let numberOfPackets: UInt32
    var audioBuffer = AudioBuffer()
    let packDescription: UnsafeMutablePointer<AudioStreamPacketDescription>?
}

enum FileStreamProcessorEffect {
    case processSource
    case raiseError(AudioPlayerError)
}

/// An object that handles the processing of AudioFileStream, its packets etc.
final class AudioFileStreamProcessor {
    private let maxCompressedPacketForBitrate = 4096

    var fileStreamCallback: ((FileStreamProcessorEffect) -> Void)?

    private let playerContext: AudioPlayerContext
    private let rendererContext: AudioRendererContext
    private let outputAudioFormat: AudioStreamBasicDescription
    
    // Add Ogg Vorbis processor
    private lazy var oggVorbisProcessor = OggVorbisStreamProcessor(
        playerContext: playerContext,
        rendererContext: rendererContext,
        outputAudioFormat: outputAudioFormat
    )

    var audioFileStream: AudioFileStreamID?
    var audioConverter: AudioConverterRef?
    var discontinuous: Bool = false
    var inputFormat = AudioStreamBasicDescription()

    var currentFileFormat: String = ""
    let fileFormatsForDelayedConverterCreation: Set = ["fa4m", "f4pm"]
    
    // Track if we're processing Ogg Vorbis
    private var isProcessingOggVorbis: Bool = false

    // Tempus patch: accurate seeks (see AccurateSeek.swift).
    /// A FLAC seek still looking for the frame to play from, with the bytes read since its last jump.
    private var flacSeek: FlacSeekSearch?
    private var flacSeekBytes: [UInt8] = []
    private var flacSeekBytesStart: Int64 = 0
    /// The file offset of the next byte to parse, while the stream is read from its start.
    private var parsePosition: Int64?
    /// The stream's bytes from where its audio may start, kept until they've been checked for a Xing seek table.
    private var headBytes: [UInt8] = []
    private var headBytesStart: Int64 = 0
    /// While the tags before the audio are read, how many of their latest bytes `headBytes` keeps.
    private static let headBytesLimit = 256 * 1024
    /// A FLAC seek gives up looking for a frame header after this many bytes.
    private static let flacSeekBytesLimit = 1024 * 1024
    /// How far before the target a FLAC seek may land, in seconds; the gap is decoded and dropped.
    private static let flacSeekTolerance = 2.0

    var isFileStreamOpen: Bool {
        audioFileStream != nil || isProcessingOggVorbis
    }

    init(playerContext: AudioPlayerContext,
         rendererContext: AudioRendererContext,
         outputAudioFormat: AudioStreamBasicDescription)
    {
        self.playerContext = playerContext
        self.rendererContext = rendererContext
        self.outputAudioFormat = outputAudioFormat
        
        // Set up Ogg Vorbis processor callback
        oggVorbisProcessor.processorCallback = { [weak self] effect in
            self?.fileStreamCallback?(effect)
        }
    }

    /// Opens the `AudioFileStream`
    ///
    /// - parameter fileHint: An `AudioFileTypeID` value indicating the file type.
    ///
    /// - Returns: An `OSStatus` value indicating if an error occurred or not.

    func openFileStream(with fileHint: AudioFileTypeID) -> OSStatus {
        // Check if this is an Ogg Vorbis file
        if fileHint == kAudioFileOggType {
            isProcessingOggVorbis = true
            return noErr
        } else {
            isProcessingOggVorbis = false
            resetAccurateSeekState(parsingFromStart: true) // Tempus patch
            let data = UnsafeMutableRawPointer.from(object: self)
            return AudioFileStreamOpen(data, _propertyListenerProc, _propertyPacketsProc, fileHint, &audioFileStream)
        }
    }

    /// Closes the currently open `AudioFileStream` instance, if opened.
    func closeFileStreamIfNeeded() {
        if isProcessingOggVorbis {
            isProcessingOggVorbis = false
            oggVorbisProcessor.cleanup()
            return
        }
        
        guard let fileStream = audioFileStream else {
            Logger.debug("audio file stream not opened", category: .generic)
            return
        }
        AudioFileStreamClose(fileStream)
        audioFileStream = nil
        resetAccurateSeekState(parsingFromStart: false) // Tempus patch
    }

    /// Parses the given data using `AudioFileStreamParseBytes`
    ///
    /// - parameter data: A `Data` object containing the audio data to be parsed.
    ///
    /// - Returns: An `OSStatus` value indicating if an error occurred or not.
    func parseFileStreamBytes(data: Data) -> OSStatus {
        guard !data.isEmpty else { return 0 }
        
        // Check if we're processing Ogg Vorbis
        if isProcessingOggVorbis {
            return oggVorbisProcessor.parseOggVorbisData(data: data)
        }
        
        guard let stream = audioFileStream else { return 0 }
        // Tempus patch: a FLAC seek reads ahead for a frame header before anything is parsed.
        if flacSeek != nil {
            return continueFlacSeek(with: data, stream: stream)
        }
        recordHeadBytes(data)
        let status = parse(data, stream: stream)
        lookForXingSeekTable()
        return status
    }

    private func parse(_ bytes: some ContiguousBytes, stream: AudioFileStreamID) -> OSStatus {
        let flags: AudioFileStreamParseFlags = discontinuous ? .discontinuity : .init()
        return bytes.withUnsafeBytes { buffer -> OSStatus in
            AudioFileStreamParseBytes(stream, UInt32(buffer.count), buffer.baseAddress, flags)
        }
    }
    
    /// Flushes any remaining packets from the AudioFileStream parser.
    ///
    /// This must be called at the end of a stream to ensure the final packet is delivered,
    /// particularly important for formats like FLAC that use sync words to determine packet boundaries.
    ///
    /// As documented in AudioFileStream.h:
    /// "At the end of the stream, this function must be called once with null data pointer
    /// and zero data byte size to flush any remaining packets out of the parser."
    ///
    /// - Returns: An `OSStatus` value indicating if an error occurred or not.
    func flushRemainingPackets() -> OSStatus {
        // Ogg Vorbis doesn't need flushing (handled internally)
        if isProcessingOggVorbis {
            return noErr
        }
        
        guard let stream = audioFileStream else { return noErr }
        
        // Call AudioFileStreamParseBytes with 0 bytes and nil data to flush the final packet
        let status = AudioFileStreamParseBytes(stream, 0, nil, [])
        
        if status != noErr {
            Logger.debug("Failed to flush AudioFileStream packets: \(status)", category: .generic)
        }
        
        return status
    }

    func processSeek() {
        guard let readingEntry = playerContext.audioReadingEntry else {
            return
        }
        
        // If processing Ogg Vorbis, use the Ogg Vorbis processor
        if isProcessingOggVorbis {
            oggVorbisProcessor.processSeek()
            return
        }
        
        guard let stream = audioFileStream else { return }

        guard readingEntry.calculatedBitrate() > 0.0 || (playerContext.audioPlayingEntry?.length ?? 0) > 0 else {
            return
        }

        let dataOffset = Double(readingEntry.audioStreamState.dataOffset)
        let dataLengthInBytes = Double(readingEntry.audioDataLengthBytes())
        let entryDuration = readingEntry.duration()
        let duration = entryDuration < readingEntry.progress && entryDuration > 0 ? readingEntry.progress : entryDuration
      
        guard duration > 0.0 else { return }

        // Tempus patch: FLAC frames carry their position, so the seek searches for the exact frame.
        if let search = flacSeekSearch(for: readingEntry, duration: duration) {
            beginFlacSeek(search, entry: readingEntry, stream: stream)
            return
        }

        var seekByteOffset = Int64(dataOffset + (readingEntry.seekRequest.time / duration) * dataLengthInBytes)
        // Tempus patch: a VBR MP3's seek table lands far closer than assuming a constant bitrate.
        if let tableOffset = xingSeekOffset(for: readingEntry, duration: duration) {
            seekByteOffset = tableOffset
        }

        if seekByteOffset > readingEntry.length - (2 * Int(readingEntry.processedPacketsState.bufferSize)) {
            seekByteOffset = Int64(readingEntry.length - (2 * Int(readingEntry.processedPacketsState.bufferSize)))
        }

        readingEntry.lock.lock()
        readingEntry.seekTime = readingEntry.seekRequest.time
        readingEntry.lock.unlock()

        let bitrate = readingEntry.calculatedBitrate()
        var isSeekExact = false // Tempus patch: whether decoding restarts at a known frame
        if readingEntry.packetDuration > 0, bitrate > 0 {
            var ioFlags = AudioFileStreamSeekFlags(rawValue: 0)
            var packetsAlignedByteOffset: Int64 = 0
            let seekPacket = Int64(floor(readingEntry.seekRequest.time / readingEntry.packetDuration))

            let seekStatus = AudioFileStreamSeek(stream, seekPacket, &packetsAlignedByteOffset, &ioFlags)
            let dataOffset = Int64(readingEntry.audioStreamState.dataOffset)
            if seekStatus == noErr, !ioFlags.contains(.offsetIsEstimated) {
                let delta = Double((seekByteOffset - dataOffset) - packetsAlignedByteOffset) / (bitrate * 8)
                readingEntry.lock.lock()
                readingEntry.seekTime -= delta
                readingEntry.lock.unlock()
                seekByteOffset = packetsAlignedByteOffset + dataOffset
                isSeekExact = true
            }
        }

        // Tempus patch: decoding restarts mid-stream, so count gapless trimming from the seek point.
        // When the position is only estimated (a VBR MP3 without a seek table), counting from it
        // could cut the end of the track, so trimming stops for this entry instead.
        readingEntry.lock.lock()
        if isSeekExact {
            readingEntry.gaplessTrim.restart(
                atSourceFrame: Int(readingEntry.seekTime * readingEntry.audioStreamFormat.mSampleRate)
            )
        } else {
            readingEntry.gaplessTrim.stopTrimming()
        }
        readingEntry.lock.unlock()
        restartReading(readingEntry, at: seekByteOffset)
    }

    /// Decoding restarts at `byteOffset`, with nothing of the old position left in the buffers.
    private func restartReading(_ entry: AudioEntry, at byteOffset: Int64) {
        if let converted = audioConverter {
            AudioConverterReset(converted)
        }
        entry.reset()
        entry.seek(at: Int(byteOffset))
        rendererContext.waitingForDataAfterSeekFrameCount.write { $0 = 0 }
        playerContext.setInternalState(to: .waitingForDataAfterSeek)
        rendererContext.resetBuffers()
    }

    /// Creates an `AudioConverter` instance to be used for converting the remote audio data to the canonical audio format
    ///
    /// - parameter fromFormat: An `AudioStreamBasicDescription` indicating the format of the remote audio
    /// - parameter toFormat: An `AudioStreamBasicDescription` indicating the local format in which the fromFormat will be converted to.
    func createAudioConverter(from fromFormat: AudioStreamBasicDescription, to toFormat: AudioStreamBasicDescription) {
        var inputFormat = fromFormat
        if let converter = audioConverter {
            if memcmp(&inputFormat, &self.inputFormat, MemoryLayout<AudioStreamBasicDescription>.size) == 0 {
                AudioConverterReset(converter)
                return
            }
        }
        disposeAudioConverter()

        var classDesc = AudioClassDescription()
        var outputFormat = toFormat
        if getHardwareCodecClassDescription(formatId: inputFormat.mFormatID, classDesc: &classDesc) {
            AudioConverterNewSpecific(&inputFormat, &outputFormat, 1, &classDesc, &audioConverter)
        }

        if audioConverter == nil {
            let audioConverterStatus = AudioConverterNew(&inputFormat, &outputFormat, &audioConverter)
            guard audioConverterStatus == noErr else {
                let audioConverterError = AudioConverterError(osstatus: audioConverterStatus)
                fileStreamCallback?(.raiseError(.audioSystemError(.converterError(audioConverterError))))
                return
            }
        }
        self.inputFormat = inputFormat
        assignMagicCookieToConverterIfNeeded()
    }

    private func assignMagicCookieToConverterIfNeeded() {
        // magic cookie info
        if let fileStream = audioFileStream {
            var cookieSize: UInt32 = 0
            guard AudioFileStreamGetPropertyInfo(fileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, nil) == noErr else {
                return
            }
            var cookie: [UInt8] = Array(repeating: 0, count: Int(cookieSize))
            guard AudioFileStreamGetProperty(fileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &cookie) == noErr else {
                return
            }
            guard let converter = audioConverter else {
                fileStreamCallback?(.raiseError(.audioSystemError(.fileStreamError(.unknownError))))
                return
            }
            guard AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, cookieSize, cookie) == noErr else {
                fileStreamCallback?(.raiseError(.audioSystemError(.fileStreamError(.unknownError))))
                return
            }
        }
    }

    /// Disposes the `AudioConverter` instance, if any.
    private func disposeAudioConverter() {
        guard let converter = audioConverter else { return }
        AudioConverterDispose(converter)
        audioConverter = nil
    }

    /// Parses any relevant properties as received by the opened `AudioFileStream`
    ///
    /// - parameter fileStream: An instance of `AudioFileStreamID` that is used to get information from.
    /// - parameter propertyId: A value of `AudioFileStreamPropertyID` indicating the file stream property.
    /// - parameter flags: A value of `UnsafeMutablePointer<AudioFileStreamPropertyFlags>`

    func propertyListenerProc(fileStream: AudioFileStreamID,
                              propertyId: AudioFileStreamPropertyID,
                              flags _: UnsafeMutablePointer<AudioFileStreamPropertyFlags>)
    {
        guard let entry = playerContext.audioReadingEntry else { return }
        switch propertyId {
        case kAudioFileStreamProperty_DataOffset:
            processDataOffset(entry: entry, fileStream: fileStream)
        case kAudioFileStreamProperty_FileFormat:
            processFileFormat(fileStream: fileStream)
        case kAudioFileStreamProperty_DataFormat:
            processDataFormat(entry: entry, fileStream: fileStream)
        case kAudioFileStreamProperty_AudioDataByteCount:
            processDataByteCount(entry: entry, fileStream: fileStream)
        case kAudioFileStreamProperty_AudioDataPacketCount:
            processAudioDataPacketCount(entry: entry, fileStream: fileStream)
        case kAudioFileStreamProperty_BitRate:
            processBitRate(entry: entry, fileStream: fileStream)
        case kAudioFileStreamProperty_ReadyToProducePackets:
            // check converter for discontinuous stream
            assignMagicCookieToConverterIfNeeded()
            processPacketUpperBoundAndMaxPacketSize(entry: entry, fileStream: fileStream)
            processReadyToProducePackets(entry: entry, fileStream: fileStream)
        case kAudioFileStreamProperty_FormatList:
            processFormatList(entry: entry, fileStream: fileStream)
        case kAudioFileStreamProperty_PacketTableInfo:
            processPacketTableInfo(entry: entry, fileStream: fileStream)
        default:
            break
        }
    }

    // MARK: AudioFileStream properties Processing

    private func processDataOffset(entry: AudioEntry, fileStream: AudioFileStreamID) {
        var offset: UInt64 = 0
        fileStreamGetProperty(value: &offset, fileStream: fileStream, propertyId: kAudioFileStreamProperty_DataOffset)
        entry.lock.lock(); defer { entry.lock.unlock() }
        entry.audioStreamState.processedDataFormat = true
        entry.audioStreamState.dataOffset = offset
    }

    private func processReadyToProducePackets(entry: AudioEntry, fileStream: AudioFileStreamID) {
        var packetCount: UInt64 = 0
        var packetCountSize = UInt32(MemoryLayout.size(ofValue: packetCount))
        AudioFileStreamGetProperty(fileStream, kAudioFileStreamProperty_AudioDataPacketCount, &packetCountSize, &packetCount)
        entry.lock.lock(); defer { entry.lock.unlock() }
        entry.audioStreamState.dataPacketCount = Double(packetCount)
        let entryFormatID = entry.audioStreamFormat.mFormatID
        let isFLAC = entryFormatID == kAudioFormatFLAC
        if entryFormatID != kAudioFormatLinearPCM && !isFLAC {
            discontinuous = true
        }
    }

    private func processFileFormat(fileStream: AudioFileStreamID) {
        var fileFormat: [UInt8] = Array(repeating: 0, count: 4)
        var size = UInt32(4)
        AudioFileStreamGetProperty(fileStream, kAudioFileStreamProperty_FileFormat, &size, &fileFormat)
        if let stringFileFormat = String(data: Data(fileFormat), encoding: .utf8) {
            currentFileFormat = stringFileFormat
        }
    }

    private func processDataFormat(entry: AudioEntry, fileStream: AudioFileStreamID) {
        var audioStreamFormat = AudioStreamBasicDescription()
        entry.lock.lock(); defer { entry.lock.unlock() }
        if !entry.audioStreamState.processedDataFormat {
            fileStreamGetProperty(value: &audioStreamFormat, fileStream: fileStream, propertyId: kAudioFileStreamProperty_DataFormat)

            if entry.audioStreamFormat.mFormatID == 0 {
                entry.audioStreamFormat = audioStreamFormat
            }

            entry.sampleRate = Float(audioStreamFormat.mSampleRate)
            entry.packetDuration = Double(audioStreamFormat.mFramesPerPacket) / Double(entry.sampleRate)

            var packetBufferSize: UInt32 = 0
            var status = fileStreamGetProperty(value: &packetBufferSize,
                                               fileStream: fileStream,
                                               propertyId: kAudioFileStreamProperty_PacketSizeUpperBound)
            if status != 0 || packetBufferSize == 0 {
                status = fileStreamGetProperty(value: &packetBufferSize,
                                               fileStream: fileStream,
                                               propertyId: kAudioFileStreamProperty_MaximumPacketSize)
                if status != 0 || packetBufferSize == 0 {
                    packetBufferSize = 2048 // default value
                }
            }

            entry.processedPacketsState.bufferSize = packetBufferSize

            if !fileFormatsForDelayedConverterCreation.contains(currentFileFormat) {
                createAudioConverter(from: entry.audioStreamFormat, to: outputAudioFormat)
            }
        }
    }

    private func processPacketUpperBoundAndMaxPacketSize(entry: AudioEntry, fileStream: AudioFileStreamID) {
        var packetBufferSize: UInt32 = 0
        var status = fileStreamGetProperty(value: &packetBufferSize,
                                           fileStream: fileStream,
                                           propertyId: kAudioFileStreamProperty_PacketSizeUpperBound)
        if status != 0 || packetBufferSize == 0 {
            status = fileStreamGetProperty(value: &packetBufferSize,
                                           fileStream: fileStream,
                                           propertyId: kAudioFileStreamProperty_MaximumPacketSize)
            if status != 0 || packetBufferSize == 0 {
                packetBufferSize = 2048 // default value
            }
        }
        entry.lock.withLock {
            entry.processedPacketsState.bufferSize = packetBufferSize
        }
    }

    private func processDataByteCount(entry: AudioEntry, fileStream: AudioFileStreamID) {
        var audioDataByteCount: UInt64 = 0
        fileStreamGetProperty(value: &audioDataByteCount, fileStream: fileStream, propertyId: kAudioFileStreamProperty_AudioDataByteCount)
        entry.lock.lock(); defer { entry.lock.unlock() }
        entry.audioStreamState.dataByteCount = audioDataByteCount
    }

    private func processAudioDataPacketCount(entry: AudioEntry, fileStream: AudioFileStreamID) {
        var audioDataPacketCount: UInt64 = 0
        fileStreamGetProperty(value: &audioDataPacketCount, fileStream: fileStream, propertyId: kAudioFileStreamProperty_AudioDataPacketCount)
        entry.lock.lock(); defer { entry.lock.unlock() }
        entry.audioStreamState.dataPacketOffset = audioDataPacketCount
    }

    private func processBitRate(entry: AudioEntry, fileStream: AudioFileStreamID) {
        var bitRate: UInt32 = 0
        let status = fileStreamGetProperty(value: &bitRate, fileStream: fileStream, propertyId: kAudioFileStreamProperty_BitRate)
        guard status == noErr else { return }
        entry.lock.lock(); defer { entry.lock.unlock() }
        entry.audioStreamState.bitRate = Double(bitRate)
    }

    private func processPacketTableInfo(entry: AudioEntry, fileStream: AudioFileStreamID) {
        var pti = AudioFilePacketTableInfo(mNumberValidFrames: 0,
                                           mPrimingFrames: 0,
                                           mRemainderFrames: 0)
        let status = fileStreamGetProperty(value: &pti, fileStream: fileStream, propertyId: kAudioFileStreamProperty_PacketTableInfo)
        guard status == noErr else { return }
        // Use valid frames to refine duration if present
        entry.lock.lock(); defer { entry.lock.unlock() }
        if pti.mNumberValidFrames > 0 {
            entry.audioStreamState.dataPacketCount = Double(pti.mNumberValidFrames) / Double(max(1, entry.audioStreamFormat.mFramesPerPacket))
        }
        // Tempus patch: remember the priming and padding so decoded output can drop them (gapless).
        entry.gaplessTrim.primingFrames = max(0, Int(pti.mPrimingFrames))
        entry.gaplessTrim.validFrames = pti.mNumberValidFrames > 0 ? Int(pti.mNumberValidFrames) : nil
    }

    private func processFormatList(entry: AudioEntry, fileStream: AudioFileStreamID) {
        let info = fileStreamGetPropertyInfo(fileStream: fileStream, propertyId: kAudioFileStreamProperty_FormatList)
        guard info.status == noErr, info.size > 0 else { return }

        let itemStride = MemoryLayout<AudioFormatListItem>.stride
        let itemCount = Int(info.size) / itemStride
        guard itemCount > 0 else { return }

        var list = [AudioFormatListItem](repeating: AudioFormatListItem(), count: itemCount)
        var size = UInt32(itemCount * itemStride)
        AudioFileStreamGetProperty(fileStream, kAudioFileStreamProperty_FormatList, &size, &list)

        var chosenASBD: AudioStreamBasicDescription?
        for i in 0..<itemCount {
            let asbd = list[i].mASBD
            let formatId = asbd.mFormatID
            if formatId == kAudioFormatMPEG4AAC_HE || formatId == kAudioFormatMPEG4AAC_HE_V2 {
                chosenASBD = asbd
                break
            }
            if chosenASBD == nil {
                chosenASBD = asbd
            }
        }

        if let asbd = chosenASBD {
            entry.lock.withLock { entry.audioStreamFormat = asbd }
            if fileFormatsForDelayedConverterCreation.contains(currentFileFormat) {
                createAudioConverter(from: asbd, to: outputAudioFormat)
            }
        }
    }

    // MARK: Packets Proc

    func propertyPacketsProc(
        inNumberBytes: UInt32,
        inNumberPackets: UInt32,
        inInputData: UnsafeRawPointer,
        inPacketDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        guard let entry = playerContext.audioReadingEntry else { return }
        guard entry.audioStreamState.processedDataFormat else { return }

        guard let converter = audioConverter else {
            Logger.error("Couldn't find audio converter", category: .audioRendering)
            return
        }

        if let playingEntry = playerContext.audioPlayingEntry,
           playingEntry.seekRequest.requested, playingEntry.calculatedBitrate() > 0
        {
            fileStreamCallback?(.processSource)
            if rendererContext.waiting.value {
                rendererContext.packetsSemaphore.signal()
            }
            return
        }

        // reset discontinuity
        discontinuous = false

        var convertInfo = AudioConvertInfo(
            done: false,
            numberOfPackets: inNumberPackets,
            packDescription: inPacketDescriptions
        )
        convertInfo.audioBuffer.mData = UnsafeMutableRawPointer(mutating: inInputData)
        convertInfo.audioBuffer.mDataByteSize = inNumberBytes
        if let playingAudioStreamFormat = playerContext.audioPlayingEntry?.audioStreamFormat {
            convertInfo.audioBuffer.mNumberChannels = playingAudioStreamFormat.mChannelsPerFrame
        }

        updateProcessedPackets(
            inPacketDescriptions: inPacketDescriptions,
            inNumberPackets: inNumberPackets
        )

        var status: OSStatus = noErr
        packetProcess: while status == noErr {
            rendererContext.lock.lock()
            let bufferContext = rendererContext.bufferContext
            var used = bufferContext.frameUsedCount
            var start = bufferContext.frameStartIndex
            var end = (bufferContext.frameStartIndex + bufferContext.frameUsedCount) % bufferContext.totalFrameCount

            var framesLeftInBuffer = bufferContext.totalFrameCount - used
            rendererContext.lock.unlock()

            if framesLeftInBuffer == 0 {
                while true {
                    rendererContext.lock.lock()
                    let bufferContext = rendererContext.bufferContext
                    used = bufferContext.frameUsedCount
                    start = bufferContext.frameStartIndex
                    end = (bufferContext.frameStartIndex + bufferContext.frameUsedCount) % bufferContext.totalFrameCount
                    framesLeftInBuffer = bufferContext.totalFrameCount - used
                    rendererContext.lock.unlock()
                    if framesLeftInBuffer > 0 {
                        break
                    }
                    if playerContext.internalState == .disposed
                        || playerContext.internalState == .pendingNext
                        || playerContext.internalState == .stopped
                    {
                        return
                    }

                    if let playingEntry = playerContext.audioPlayingEntry,
                       playingEntry.seekRequest.requested, playingEntry.calculatedBitrate() > 0
                    {
                        fileStreamCallback?(.processSource)
                        if rendererContext.waiting.value {
                            rendererContext.packetsSemaphore.signal()
                        }
                        return
                    }

                    rendererContext.waiting.write { $0 = true }
                    rendererContext.packetsSemaphore.wait()
                    rendererContext.waiting.write { $0 = false }
                }
            }

            let localBufferList = AudioBufferList.allocate(maximumBuffers: 1)
            defer { localBufferList.unsafeMutablePointer.deallocate() }

            if end >= start {
                var framesAdded: UInt32 = 0
                var framesToDecode: UInt32 = rendererContext.bufferContext.totalFrameCount - end

                let offset = Int(end * rendererContext.bufferContext.sizeInBytes)
                prefillLocalBufferList(
                    bufferList: localBufferList,
                    dataOffset: offset,
                    framesToDecode: framesToDecode
                )

                status = AudioConverterFillComplexBuffer(
                    converter,
                    _converterCallback,
                    &convertInfo,
                    &framesToDecode,
                    localBufferList.unsafeMutablePointer,
                    nil
                )

                framesAdded = trimDecodedChunk(entry: entry, atFrame: end, count: framesToDecode)

                if status == AudioConvertStatus.done.rawValue {
                    fillUsedFrames(framesCount: framesAdded)
                    return
                } else if status != 0 {
                    fileStreamCallback?(.raiseError(.codecError))
                    return
                }

                // Tempus patch: a trimmed chunk no longer reaches the end of the buffer, so writing
                // the wrap-around part at index 0 would leave a hole. Recompute the free space instead.
                if framesAdded < framesToDecode {
                    fillUsedFrames(framesCount: framesAdded)
                    continue packetProcess
                }

                framesToDecode = start
                if framesToDecode == 0 {
                    fillUsedFrames(framesCount: framesAdded)
                    continue packetProcess
                }
                prefillLocalBufferList(
                    bufferList: localBufferList,
                    dataOffset: 0,
                    framesToDecode: framesToDecode
                )

                status = AudioConverterFillComplexBuffer(
                    converter,
                    _converterCallback,
                    &convertInfo,
                    &framesToDecode,
                    localBufferList.unsafeMutablePointer,
                    nil
                )

                framesAdded += trimDecodedChunk(entry: entry, atFrame: 0, count: framesToDecode)

                if status == AudioConvertStatus.done.rawValue {
                    fillUsedFrames(framesCount: framesAdded)
                    return
                } else if status == AudioConvertStatus.processed.rawValue {
                    fillUsedFrames(framesCount: framesAdded)
                    continue packetProcess
                } else if status != 0 {
                    fileStreamCallback?(.raiseError(.codecError))
                    return
                }
            } else {
                var framesAdded: UInt32 = 0
                var framesToDecode: UInt32 = start - end

                let offset = Int(end * rendererContext.bufferContext.sizeInBytes)
                prefillLocalBufferList(
                    bufferList: localBufferList,
                    dataOffset: offset,
                    framesToDecode: framesToDecode
                )

                status = AudioConverterFillComplexBuffer(
                    converter,
                    _converterCallback,
                    &convertInfo,
                    &framesToDecode,
                    localBufferList.unsafeMutablePointer,
                    nil
                )

                framesAdded = trimDecodedChunk(entry: entry, atFrame: end, count: framesToDecode)
                if status == AudioConvertStatus.done.rawValue {
                    fillUsedFrames(framesCount: framesAdded)
                    return
                } else if status == AudioConvertStatus.processed.rawValue {
                    fillUsedFrames(framesCount: framesAdded)
                    continue packetProcess
                } else if status != 0 {
                    fileStreamCallback?(.raiseError(.codecError))
                    return
                }
            }
        }
    }

    /// Fills the `AudioBuffer` with data as required
    ///
    /// - parameter list: An `UnsafeMutableAudioBufferListPointer` object representing the buffer list be filled with data
    /// - parameter dataOffset: An `Int` value indicating any offset to be applied to the buffer data
    /// - parameter framesToDecode: An `UInt32` value indicating the frames to be decoded, used in calculating the data size of the buffer.
    @inline(__always)
    private func prefillLocalBufferList(
        bufferList: UnsafeMutableAudioBufferListPointer,
        dataOffset: Int,
        framesToDecode: UInt32
    ) {
        if let mData = rendererContext.audioBuffer.mData {
            bufferList[0].mData = dataOffset > 0 ? mData + dataOffset : mData
        }
        bufferList[0].mDataByteSize = framesToDecode * rendererContext.bufferContext.sizeInBytes
        bufferList[0].mNumberChannels = rendererContext.audioBuffer.mNumberChannels
    }

    /// Tempus patch: drops encoder priming and padding from a chunk just decoded into the ring buffer.
    ///
    /// - parameter entry: The entry being decoded.
    /// - parameter frame: The ring-buffer frame index where the chunk starts.
    /// - parameter count: The number of frames the converter wrote there.
    /// - returns: The number of frames to keep. They are moved to the start of the chunk.
    @inline(__always)
    private func trimDecodedChunk(entry: AudioEntry, atFrame frame: UInt32, count: UInt32) -> UInt32 {
        let ratio = inputFormat.mSampleRate > 0 ? outputAudioFormat.mSampleRate / inputFormat.mSampleRate : 0
        entry.lock.lock()
        let (drop, keep) = entry.gaplessTrim.trim(chunkOf: Int(count), outputRatio: ratio)
        entry.lock.unlock()
        if drop > 0, keep > 0, let base = rendererContext.audioBuffer.mData {
            let frameSize = Int(rendererContext.bufferContext.sizeInBytes)
            let chunk = base + Int(frame) * frameSize
            memmove(chunk, chunk + drop * frameSize, keep * frameSize)
        }
        return UInt32(keep)
    }

    /// Advances the processed frames for buffer and reading entry
    ///
    /// - parameter frameCount: An `UInt32` value to be added to the used count of the buffers.
    @inline(__always)
    private func fillUsedFrames(framesCount: UInt32) {
        rendererContext.lock.lock()
        rendererContext.bufferContext.frameUsedCount += framesCount
        rendererContext.lock.unlock()

        playerContext.audioReadingEntry?.lock.lock()
        playerContext.audioReadingEntry?.framesState.queued += Int(framesCount)
        playerContext.audioReadingEntry?.lock.unlock()
    }

    @inline(__always)
    private func updateProcessedPackets(
        inPacketDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?,
        inNumberPackets: UInt32
    ) {
        guard let inPacketDescriptions = inPacketDescriptions else { return }
        guard let readingEntry = playerContext.audioReadingEntry else { return }
        let processedPackCount = readingEntry.processedPacketsState.count
        if processedPackCount < maxCompressedPacketForBitrate {
            let count = min(Int(inNumberPackets), maxCompressedPacketForBitrate - Int(processedPackCount))
            for i in 0 ..< count {
                let packet = inPacketDescriptions[i]
                let packetSize: UInt32 = packet.mDataByteSize
                readingEntry.lock.lock()
                readingEntry.processedPacketsState.sizeTotal += packetSize
                readingEntry.processedPacketsState.count += 1
                readingEntry.lock.unlock()
            }
        }
    }
}

// MARK: - AudioFileStream proc method

private func _propertyListenerProc(
    clientData: UnsafeMutableRawPointer,
    fileStream: AudioFileStreamID,
    propertyId: AudioFileStreamPropertyID,
    flags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>
) {
    let processor = clientData.to(type: AudioFileStreamProcessor.self)
    processor.propertyListenerProc(fileStream: fileStream,
                                   propertyId: propertyId,
                                   flags: flags)
}

private func _propertyPacketsProc(
    clientData: UnsafeMutableRawPointer,
    inNumberBytes: UInt32,
    inNumberPackets: UInt32,
    inInputData: UnsafeRawPointer,
    inPacketDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
) {
    let processor = clientData.to(type: AudioFileStreamProcessor.self)
    processor.propertyPacketsProc(inNumberBytes: inNumberBytes,
                                  inNumberPackets: inNumberPackets,
                                  inInputData: inInputData,
                                  inPacketDescriptions: inPacketDescriptions)
}

// MARK: - AudioConverterFillComplexBuffer callback method

private func _converterCallback(
    inAudioConverter _: AudioConverterRef,
    ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    ioData: UnsafeMutablePointer<AudioBufferList>,
    outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let convertInfo = inUserData?.assumingMemoryBound(to: AudioConvertInfo.self) else { return 0 }

    // we need to tell the converter to stop converting after it should stop converting
    if convertInfo.pointee.done {
        ioNumberDataPackets.pointee = 0
        return AudioConvertStatus.done.rawValue
    }
    // calculate the input buffer
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers = convertInfo.pointee.audioBuffer

    // output the packet descriptions
    if outDataPacketDescription != nil {
        outDataPacketDescription?.pointee = convertInfo.pointee.packDescription
    }

    ioNumberDataPackets.pointee = convertInfo.pointee.numberOfPackets
    convertInfo.pointee.done = true

    return AudioConvertStatus.processed.rawValue
}

// MARK: HardwareCodedClass method

private func getHardwareCodecClassDescription(formatId: UInt32, classDesc: UnsafeMutablePointer<AudioClassDescription>) -> Bool {
    #if os(iOS)
        var size: UInt32 = 0
        let formatIdSize = UInt32(MemoryLayout.size(ofValue: formatId))
        var id = formatId
        if AudioFormatGetPropertyInfo(kAudioFormatProperty_Decoders, formatIdSize, &id, &size) != noErr {
            return false
        }
        let count = Int(size) / MemoryLayout<AudioClassDescription>.size
        var encoderDescriptions = Array(repeating: AudioClassDescription(), count: count)
        if AudioFormatGetProperty(kAudioFormatProperty_Decoders, formatIdSize, &id, &size, &encoderDescriptions) != noErr {
            return false
        }

        for item in encoderDescriptions where item.mManufacturer == kAppleHardwareAudioCodecManufacturer {
            classDesc.pointee = item
            return true
        }
    #endif
    return false
}

// MARK: - Tempus patch: accurate seeks

extension AudioFileStreamProcessor {
    fileprivate func resetAccurateSeekState(parsingFromStart: Bool) {
        flacSeek = nil
        flacSeekBytes = []
        flacSeekBytesStart = 0
        parsePosition = parsingFromStart ? 0 : nil
        headBytes = []
        headBytesStart = 0
    }

    // MARK: VBR MP3

    /// Keeps the stream's start while it may still hold a Xing seek table.
    fileprivate func recordHeadBytes(_ data: Data) {
        guard let position = parsePosition else { return }
        parsePosition = position + Int64(data.count)
        guard let entry = playerContext.audioReadingEntry,
              !entry.lock.withLock(body: { entry.hasLookedForXingSeekTable })
        else { return }
        if headBytes.isEmpty {
            headBytesStart = position
        }
        headBytes.append(contentsOf: data)
    }

    /// Once Core Audio knows where the audio starts, reads the seek table from the first frame.
    fileprivate func lookForXingSeekTable() {
        guard parsePosition != nil, let entry = playerContext.audioReadingEntry,
              !entry.lock.withLock(body: { entry.hasLookedForXingSeekTable })
        else { return }
        guard entry.audioStreamState.processedDataFormat else {
            // Still in the tags before the audio: the header can only be in the latest bytes.
            dropHeadBytes(before: headBytesStart + Int64(headBytes.count) - Int64(Self.headBytesLimit))
            return
        }
        let dataOffset = Int64(entry.audioStreamState.dataOffset)
        let headBytesEnd = headBytesStart + Int64(headBytes.count)
        let isMP3 = entry.audioStreamFormat.mFormatID == kAudioFormatMPEGLayer3
        // The header is in the first frame, within a few kilobytes of the data offset.
        guard !isMP3 || headBytesEnd >= dataOffset + 4096 else {
            dropHeadBytes(before: dataOffset - 4096)
            return
        }
        let table = isMP3 ? XingSeekTable(bytes: headBytes, bytesStart: headBytesStart, dataOffset: dataOffset) : nil
        entry.lock.withLock {
            entry.xingSeekTable = table
            entry.hasLookedForXingSeekTable = true
        }
        headBytes = []
    }

    private func dropHeadBytes(before offset: Int64) {
        let count = min(headBytes.count, Int(max(0, offset - headBytesStart)))
        guard count > 0 else { return }
        headBytes.removeFirst(count)
        headBytesStart += Int64(count)
    }

    fileprivate func xingSeekOffset(for entry: AudioEntry, duration: Double) -> Int64? {
        guard let table = entry.lock.withLock(body: { entry.xingSeekTable }) else { return nil }
        return table.byteOffset(
            for: entry.seekRequest.time,
            frameDuration: entry.packetDuration,
            duration: duration,
            fileLength: Int64(entry.length)
        )
    }

    // MARK: FLAC

    fileprivate func flacSeekSearch(for entry: AudioEntry, duration: Double) -> FlacSeekSearch? {
        let format = entry.audioStreamFormat
        guard format.mFormatID == kAudioFormatFLAC, format.mSampleRate > 0, format.mFramesPerPacket > 0 else {
            return nil
        }
        let dataOffset = Int64(entry.audioStreamState.dataOffset)
        let dataEnd = dataOffset + Int64(entry.audioDataLengthBytes())
        guard dataEnd > dataOffset else { return nil }
        let rate = format.mSampleRate
        return FlacSeekSearch(
            target: Int64(entry.seekRequest.time * rate),
            tolerance: Int64(Self.flacSeekTolerance * rate),
            lower: .init(byte: dataOffset, sample: 0),
            upper: .init(byte: dataEnd, sample: Int64(duration * rate))
        )
    }

    fileprivate func beginFlacSeek(_ search: FlacSeekSearch, entry: AudioEntry, stream: AudioFileStreamID) {
        // Resets the parser for data from a new place; the offset it estimates isn't used.
        var ioFlags = AudioFileStreamSeekFlags(rawValue: 0)
        var ignoredOffset: Int64 = 0
        let packet = entry.packetDuration > 0 ? Int64(entry.seekRequest.time / entry.packetDuration) : 0
        AudioFileStreamSeek(stream, packet, &ignoredOffset, &ioFlags)

        entry.lock.withLock { entry.seekTime = entry.seekRequest.time }
        parsePosition = nil
        flacSeek = search
        flacSeekBytes = []
        flacSeekBytesStart = search.firstJump
        restartReading(entry, at: search.firstJump)
    }

    /// Reads ahead from the last jump until a frame header says where it landed, then plays from
    /// that frame or jumps again.
    fileprivate func continueFlacSeek(with data: Data, stream: AudioFileStreamID) -> OSStatus {
        guard var search = flacSeek, let entry = playerContext.audioReadingEntry else {
            flacSeek = nil
            return parse(data, stream: stream)
        }
        flacSeekBytes.append(contentsOf: data)
        let format = entry.audioStreamFormat
        guard let header = FlacFrameHeader.find(
            in: flacSeekBytes,
            nominalBlockSize: Int64(format.mFramesPerPacket),
            sampleRate: format.mSampleRate
        ) else {
            guard flacSeekBytes.count > Self.flacSeekBytesLimit else { return noErr }
            // No frame where there should be one: play from here, as an estimated seek would.
            Logger.error("FLAC seek found no frame header; playing from an estimated position", category: .generic)
            entry.lock.withLock { entry.gaplessTrim.stopTrimming() }
            return finishFlacSeek(playing: flacSeekBytes[...], stream: stream)
        }

        let landing = FlacSeekSearch.Anchor(byte: flacSeekBytesStart + Int64(header.index), sample: header.sample)
        switch search.landed(at: landing) {
        case let .jump(to: byte):
            flacSeek = search
            flacSeekBytes = []
            flacSeekBytesStart = byte
            entry.seek(at: Int(byte))
            return noErr
        case .accept:
            entry.lock.withLock {
                entry.gaplessTrim.restart(atSourceFrame: Int(landing.sample), keepingFrom: Int(search.target))
            }
            return finishFlacSeek(playing: flacSeekBytes[header.index...], stream: stream)
        }
    }

    private func finishFlacSeek(playing bytes: ArraySlice<UInt8>, stream: AudioFileStreamID) -> OSStatus {
        flacSeek = nil
        flacSeekBytes = []
        return parse(Array(bytes), stream: stream)
    }
}
