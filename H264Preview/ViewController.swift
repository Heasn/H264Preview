//
//  ViewController.swift
//  H264Preview
//
//  Created by 陈柏宇 on 2021/12/23.
//
//

import Cocoa
import AVFoundation
import CocoaAsyncSocket
import VideoToolbox

class ViewController: NSViewController {
    var videoLayer: AVSampleBufferDisplayLayer?

    var spsSize: Int = 0
    var ppsSize: Int = 0

    var sps: Array<UInt8>?
    var pps: Array<UInt8>?

    var formatDesc: CMVideoFormatDescription?

    var cacheData: NSMutableData = NSMutableData()

    var socket: GCDAsyncSocket?

    var decompressionSession: VTDecompressionSession?

    var hasInitializedSPSAndPPS = false

    let networkQueue: DispatchQueue = DispatchQueue.init(label: "network.dispatch")
    let avQueue: DispatchQueue = DispatchQueue.init(label: "av.dispatch")

    override func viewDidLoad() {
        super.viewDidLoad()

        socket = GCDAsyncSocket(delegate: self, delegateQueue: networkQueue)
        do {
            try socket!.connect(toHost: "127.0.0.1", onPort: 18999)
        } catch {
            print("socket connect failed")
            exit(1)
        }

        videoLayer = AVSampleBufferDisplayLayer()

        if let layer = videoLayer {
            layer.frame = view.bounds
            layer.bounds = view.bounds
            layer.videoGravity = AVLayerVideoGravity.resizeAspect
            layer.isOpaque = true
            layer.backgroundColor = .black

            let _CMTimebasePointer = UnsafeMutablePointer<CMTimebase?>.allocate(capacity: 1)
            let status = CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                    sourceClock: CMClockGetHostTimeClock(),
                    timebaseOut: _CMTimebasePointer)

            if status != noErr {
                print("CMTimebaseCreateWithSourceClock failed(\(status))")
            }

            layer.controlTimebase = _CMTimebasePointer.pointee
            CMTimebaseSetTime(layer.controlTimebase!, time: CMTime.zero);
            CMTimebaseSetRate(layer.controlTimebase!, rate: 1.0);

            view.layer = layer
        }
    }

    func decodeVideoPacket(videoPacket: Array<UInt8>) {

        let bufferPointer = UnsafeMutablePointer<UInt8>(mutating: videoPacket)

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                memoryBlock: bufferPointer,
                blockLength: videoPacket.count,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: videoPacket.count,
                flags: 0,
                blockBufferOut: &blockBuffer)

        if status != kCMBlockBufferNoErr {
            print("CMBlockBufferCreateWithMemoryBlock failed(\(status))")
            return
        }

        var sampleBuffer: CMSampleBuffer?
        let sampleSizeArray = [videoPacket.count]

        if formatDesc == nil {
            print("formatDesc is nil")
            return
        }
        
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDesc,
                sampleCount: 1,
                sampleTimingEntryCount: 0,
                sampleTimingArray: nil,
                sampleSizeEntryCount: 1,
                sampleSizeArray: sampleSizeArray,
                sampleBufferOut: &sampleBuffer)

        if let buffer = sampleBuffer, let session = decompressionSession, status == kCMBlockBufferNoErr {

            var flagOut = VTDecodeInfoFlags.asynchronous
            var outputBuffer = UnsafeMutablePointer<CVPixelBuffer>.allocate(capacity: 1)

            status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: buffer,
                    flags: [._EnableAsynchronousDecompression],
                    frameRefcon: &outputBuffer, infoFlagsOut: &flagOut)

            if (status == kVTInvalidSessionErr) {
                print("VT: Invalid session, reset decoder session");
            } else if (status == kVTVideoDecoderBadDataErr) {
                print("VT: decode failed status=\(status)(Bad data)");
            } else if (status != noErr) {
                print("VT: decode failed status=\(status)");
            }
        } else {
            print("CMSampleBufferCreateReady status \(status)")
        }
    }

    func createDecompSession() -> Bool {
        if let spsData = sps, let ppsData = pps {
            let pointerSPS = UnsafePointer<UInt8>(spsData)
            let pointerPPS = UnsafePointer<UInt8>(ppsData)

            // make pointers array
            let dataParamArray = [pointerSPS, pointerPPS]
            let parameterSetPointers = UnsafePointer<UnsafePointer<UInt8>>(dataParamArray)

            // make parameter sizes array
            let sizeParamArray = [spsData.count, ppsData.count]
            let parameterSetSizes = UnsafePointer<Int>(sizeParamArray)

            let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: parameterSetPointers,
                    parameterSetSizes: parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc)

            if status != noErr {
                print("prepare formatdesc failed(\(status))")
            }

            if let desc = formatDesc, status == noErr {

                if let session = self.decompressionSession {
                    VTDecompressionSessionInvalidate(session)
                    decompressionSession = nil
                }

                var videoSessionM: VTDecompressionSession?


                let destinationPixelBufferAttributes = NSMutableDictionary()
                destinationPixelBufferAttributes.setValue(NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange as UInt32), forKey: kCVPixelBufferPixelFormatTypeKey as String)

                var outputCallback = VTDecompressionOutputCallbackRecord()
                outputCallback.decompressionOutputCallback = decompressionSessionDecodeFrameCallback
                outputCallback.decompressionOutputRefCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

                var status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                        formatDescription: desc,
                        decoderSpecification: nil,
                        imageBufferAttributes: destinationPixelBufferAttributes,
                        outputCallback: &outputCallback,
                        decompressionSessionOut: &videoSessionM)
                if (status != noErr) {
                    print("\t\t VTD ERROR type: \(status)")
                    return false
                }

                if !VTDecompressionSessionCanAcceptFormatDescription(videoSessionM!, formatDescription: desc) {
                    print("can't accept format desc")
                }

                status = VTSessionSetProperty(videoSessionM!,
                        key: kVTDecompressionPropertyKey_RealTime,
                        value: kCFBooleanTrue)

                if status != noErr {
                    print("VTSessionSetProperty failed: kVTCompressionPropertyKey_RealTime => kCFBooleanTrue")
                    return false
                }


                self.decompressionSession = videoSessionM
            
            } else {
                print("VT: reset decoder session failed status=\(status)")
            }
        }

        return true
    }

}

extension ViewController: GCDAsyncSocketDelegate {
    func socket(_ sock: GCDAsyncSocket, didConnectToHost host: String, port: UInt16) -> Void {
        print("Socket 连接服务器成功 \(host):\(port)")
        sock.readData(toLength: 4, withTimeout: -1, tag: 0)
    }

    /**
     * 连接服务器 失败
     **/
    func socketDidDisconnect(_ sock: GCDAsyncSocket, withError err: Swift.Error?) -> Void {
        print("断开连接: \(err?.localizedDescription)")
    }

    /**
     * 处理服务器发来的消息
     **/


    func socket(_ sock: GCDAsyncSocket, didRead data: Data, withTag tag: Int) -> Void {
        switch tag {
        case 0:
            var lengthHeader: UInt = 0
            (data as NSData).getBytes(&lengthHeader, length: 4)
            sock.readData(toLength: lengthHeader, withTimeout: -1, tag: 1)
            break
        case 1:
            let nalType = data[0] & 0x1F

            switch nalType {
            case 0x05:
//                print("Nal type is IDR frame")
                var lengthHeader = CFSwapInt32HostToBig(UInt32(data.count))
                let packet = NSMutableData.init(bytes: &lengthHeader, length: 4)
                packet.append(data)
                avQueue.sync {
                    self.decodeVideoPacket(videoPacket: Array(packet))
                }

            case 0x07:
                spsSize = data.count
                sps = Array(data) // [SPS]
//                print("Nal type is SPS, length:\(spsSize)")
            case 0x08:
                ppsSize = data.count
                pps = Array(data)
//                print("Nal type is PPS, length:\(ppsSize)")// 00 00 00 01 [PPS]

                print("create decompsession \(createDecompSession())")
            default:
//                print("Nal type is B/P frame")
                var lengthHeader = CFSwapInt32HostToBig(UInt32(data.count))
                let packet = NSMutableData.init(bytes: &lengthHeader, length: 4)
//                print("\(packet.count)")
                packet.append(data)
//                print("\(packet.count)")
                avQueue.sync {
                    self.decodeVideoPacket(videoPacket: Array(packet))
                }
                break;
            }

            sock.readData(toLength: 4, withTimeout: -1, tag: 0)
        default:
            break
        }
    }
}

private func decompressionSessionDecodeFrameCallback(_ decompressionOutputRefCon: UnsafeMutableRawPointer?, _ sourceFrameRefCon: UnsafeMutableRawPointer?, _ status: OSStatus, _ infoFlags: VTDecodeInfoFlags, _ imageBuffer: CVImageBuffer?, _ presentationTimeStamp: CMTime, _ presentationDuration: CMTime) -> Void {

    let streamManager: ViewController = unsafeBitCast(decompressionOutputRefCon, to: ViewController.self)

    if status != noErr {
        print("decompressionSessionDecodeFrameCallback failed(\(status))")
        return
    }

    var timing = CMSampleTimingInfo.init(duration: CMTime.invalid, presentationTimeStamp: CMTime.invalid, decodeTimeStamp: CMTime.invalid)

    var sampleBuffer: CMSampleBuffer?
    var pixelFormat:CMVideoFormatDescription?
    
    if CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: imageBuffer!,
        formatDescriptionOut: &pixelFormat) != noErr{
        print("CMVideoFormatDescriptionCreateForImageBuffer failed")
    }
    
    let status2 = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer!,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: pixelFormat!,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer)

    if status2 != noErr {
        print("CMSampleBufferCreateForImageBuffer failed (\(status2))")
        return
    }

    let attachments: CFArray? = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer!, createIfNecessary: true)
    if let attachmentArray = attachments {
        let dic = unsafeBitCast(CFArrayGetValueAtIndex(attachmentArray, 0), to: CFMutableDictionary.self)

        CFDictionarySetValue(dic,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    streamManager.videoLayer?.enqueue(sampleBuffer!)
}

