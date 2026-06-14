//
//  Item.swift
//  JonesBlog
//
//  Created by Roger Nolan on 14/06/2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
