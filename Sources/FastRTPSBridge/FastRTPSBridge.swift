/////
////  FastRTPSBridge.swift
///   Copyright © 2019 Dmitriy Borovikov. All rights reserved.
//

import Foundation
import CDRCodable
#if SWIFT_PACKAGE
@_exported import FastRTPSWrapper
#endif

public protocol RTPSListenerDelegate {
    func RTPSNotification(reason: RTPSNotification, topic: String)
}

public protocol RTPSParticipantListenerDelegate {
    func participantNotification(reason: RTPSParticipantNotification, participant: String, unicastLocators: String, properties: [String:String])
    func readerWriterNotificaton(reason: RTPSReaderWriterNotification, topic: String, type: String, remoteLocators: String)
}

open class FastRTPSBridge {
    private var participant: UnsafeRawPointer
    fileprivate var listenerDelegate: RTPSListenerDelegate?
    fileprivate var participantListenerDelegate: RTPSParticipantListenerDelegate?
    
    public init() {
        participant = makeBridgedParticipant()
    }
    
    func setupBridgeContainer()
    {
        let container = BridgeContainer(
            decoderCallback: {
            (payloadDecoder, sequence, payloadSize, payload) in
            let payloadDecoder = Unmanaged<PayloadDecoderProxy>.fromOpaque(payloadDecoder).takeUnretainedValue()
            payloadDecoder.decode(sequence: sequence,
                                  payloadSize: Int(payloadSize),
                                  payload: payload)
        }, releaseCallback: {
            (payloadDecoder) in
            Unmanaged<PayloadDecoderProxy>.fromOpaque(payloadDecoder).release()
        }, readerWriterListenerCallback: {
            (listenerObject, reason, topicName) in
            let mySelf = Unmanaged<FastRTPSBridge>.fromOpaque(listenerObject).takeUnretainedValue()
            guard let delegate = mySelf.listenerDelegate else { return }
            let topic = String(cString: topicName)
            delegate.RTPSNotification(reason: reason, topic: topic)
        }, discoveryParticipantCallback: {
            (listenerObject, reason, participantName, unicastLocators, properties) in
            let mySelf = Unmanaged<FastRTPSBridge>.fromOpaque(listenerObject).takeUnretainedValue()
            guard let delegate = mySelf.participantListenerDelegate else { return }
            var locators = ""
            var propertiesDict: [String:String] = [:]
            if let unicastLocators = unicastLocators {
                locators = String(cString: unicastLocators)
            }
            if let properties = properties {
                var i = 0
                while properties[i] != nil {
                    let key = String(cString: properties[i]!)
                    let value = String(cString: properties[i+1]!)
                    propertiesDict[key] = value
                    i += 2
                }
            }
            delegate.participantNotification(reason: reason,
                                             participant: String(cString: participantName),
                                             unicastLocators: locators,
                                             properties: propertiesDict)
        }, discoveryReaderWriterCallback: {
            (listenerObject, reason, topicName, typeName, remoteLocators) in
            let mySelf = Unmanaged<FastRTPSBridge>.fromOpaque(listenerObject).takeUnretainedValue()
            guard let delegate = mySelf.participantListenerDelegate else { return }
            
            let topic = String(cString: topicName)
            let type = String(cString: typeName)
            var locators = ""
            if let remoteLocators = remoteLocators {
                locators = String(cString: remoteLocators)
            }
            delegate.readerWriterNotificaton(reason: reason, topic: topic, type: type, remoteLocators: locators)
        }, listnerObject: Unmanaged.passUnretained(self).toOpaque())
        
        setupRTPSBridgeContainer(participant, container)
    }

    // MARK: Public interface

    
    /// Create RTPS participant
    /// - Parameters:
    ///   - name: participant name
    ///   - domainID: participant domain ID
    ///   - localAddress: bind only to localAddress
    ///   - filerAddress: remote locators filter, eg "10.1.1.0/24"
    public func createParticipant(name: String, domainID: UInt32 = 0, localAddress: String? = nil, filterAddress: String? = nil) {
        setupBridgeContainer()
        createRTPSParticipantFiltered(participant,
                                      domainID,
                                      name.cString(using: .utf8)!,
                                      localAddress?.cString(using: .utf8),
                                      filterAddress?.cString(using: .utf8))
    }

    public func setRTPSListener(delegate: RTPSListenerDelegate?) {
        listenerDelegate = delegate
    }
    
    public func setRTPSParticipantListener(delegate: RTPSParticipantListenerDelegate?) {
        participantListenerDelegate = delegate
    }
    
    /// Set RTPS partition (default: "*")
    /// - Parameter name: partition name
    public func setPartition(name: String) {
        setRTPSPartition(participant, name.cString(using: .utf8)!)
    }
    
    /// Remove all readers/writers and then delete participant
    public func deleteParticipant() {
        removeRTPSParticipant(participant)
    }
    
    /// Register RTPS reader with raw data callback
    /// - Parameters:
    ///   - topic: DDSReaderTopic topic description
    ///   - ddsType: DDSType topic DDS data type
    ///   - completion: (sequence: UInt64, data: Data) -> Void
    ///      where data is topic ..................
    public func registerReaderRaw<D: DDSType, T: DDSReaderTopic>(topic: T, ddsType: D.Type, completion: @escaping (UInt64, Data)->Void) {
        let payloadDecoderProxy = Unmanaged.passRetained(PayloadDecoderProxy(completion: completion)).toOpaque()
        registerRTPSReader(participant,
                           topic.rawValue.cString(using: .utf8)!,
                           D.ddsTypeName.cString(using: .utf8)!,
                           D.isKeyed,
                           topic.transientLocal,
                           topic.reliable,
                           payloadDecoderProxy)
    }
    
    public func registerReader<D: DDSType, T: DDSReaderTopic>(topic: T, completion: @escaping (Result<D, Error>)->Void) {
        registerReaderRaw(topic: topic, ddsType: D.self) { (_, data) in
            let decoder = CDRDecoder()
            let result = Result.init { try decoder.decode(D.self, from: data) }
            completion(result)
        }
    }
    
    public func registerReader<D: DDSType, T: DDSReaderTopic>(topic: T, completion: @escaping (D)->Void) {
        registerReaderRaw(topic: topic, ddsType: D.self) { (_, data) in
            let decoder = CDRDecoder()
            do {
                let t = try decoder.decode(D.self, from: data)
                completion(t)
            } catch {
                print(topic.rawValue, error)
            }
        }
    }
    
    /// Remove RTPS reader
    /// - Parameter topic: topic descriptor
    public func removeReader<T: DDSReaderTopic>(topic: T) {
        removeRTPSReader(participant, topic.rawValue.cString(using: .utf8)!)
    }
    
    public func registerWriter<D: DDSType, T: DDSWriterTopic>(topic: T, ddsType: D.Type)  {
        registerRTPSWriter(participant,
                            topic.rawValue.cString(using: .utf8)!,
                            D.ddsTypeName.cString(using: .utf8)!,
                            D.isKeyed,
                            topic.transientLocal,
                            topic.reliable)
    }
    
    /// Remove RTPS writer
    /// - Parameter topic: topic descriptor
    public func removeWriter<T: DDSWriterTopic>(topic: T) {
        removeRTPSWriter(participant, topic.rawValue.cString(using: .utf8)!)
    }

    public func send<D: DDSType, T: DDSWriterTopic>(topic: T, ddsData: D) {
        let encoder = CDREncoder()
        do {
            var data = try encoder.encode(ddsData)
            if ddsData is DDSKeyed {
                var key = (ddsData as! DDSKeyed).key
                if key.isEmpty {
                    key = Data([0])
                }
                sendDataWithKey(participant,
                                topic.rawValue.cString(using: .utf8)!,
                                &data,
                                UInt32(data.count),
                                &key,
                                UInt32(key.count))
            } else {
                sendData(participant,
                         topic.rawValue.cString(using: .utf8)!,
                         &data,
                         UInt32(data.count))
            }
        } catch {
            fatalError(error.localizedDescription)
        }
    }
    
    /// Remove all readers and writers from participant
    public func resignAll() {
        resignRTPSAll(participant)
    }
    
    /// Method to shut down all RTPS participants, readers, writers, etc. It may be called at the end of the process to avoid memory leaks.
    public func stopAll() {
        stopRTPSAll(participant)
    }

    public func removeParticipant() {
        removeRTPSParticipant(participant)
    }

    public func setlogLevel(_ level: FastRTPSLogLevel) {
        setRTPSLoglevel(level)
    }
    
    /// Get IPV4 addresses of all network interfaces
    /// - Returns: String array with IPV4 addresses with dot notation x.x.x.x
    public class func getIP4Address() -> [String: String] {
        var localIP: [String: String] = [:]

        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0 else { return localIP }
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }

            let interface = ptr?.pointee
            let addrFamily = interface?.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name: String = String(cString: (interface!.ifa_name))
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface?.ifa_addr, socklen_t((interface?.ifa_addr.pointee.sa_len)!), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                let address = String(cString: hostname)
                localIP[name] = address
            }
        }
        freeifaddrs(ifaddr)

        return localIP
    }
    
    public class func getIP6Address() -> [String: String] {
        var localIP: [String: String] = [:]

        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0 else { return localIP }
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }

            let interface = ptr?.pointee
            let addrFamily = interface?.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET6) {
                let name: String = String(cString: (interface!.ifa_name))
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface?.ifa_addr, socklen_t((interface?.ifa_addr.pointee.sa_len)!), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                let address = String(cString: hostname)
                localIP[name] = address
            }
        }
        freeifaddrs(ifaddr)

        return localIP
    }
}
