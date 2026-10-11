//
//  Bookmark.swift
//  nomad
//
//  Created by tarun on 11/10/26.
//

import Foundation

/// Represents a saved user bookmark.
struct Bookmark: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var url: String
    var createdAt: Date = Date()
}
