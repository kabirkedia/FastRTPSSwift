/////
////  DDSTopic.swift
///   Copyright © 2020 Dmitriy Borovikov. All rights reserved.
//


import Foundation


public protocol DDSTopic: RawRepresentable where RawValue == String {
    var transientLocal: Bool { get set}
    var reliable: Bool { get set }
    
    init(name: String, reliable: Bool, transientLocal: Bool)
}

public protocol DDSReaderTopic: DDSTopic {}

public protocol DDSWriterTopic: DDSTopic {}
