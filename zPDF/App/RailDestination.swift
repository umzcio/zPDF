//
//  RailDestination.swift
//  zPDF
//
//  Purpose: Home/document screen state. Navigation is through the title-bar
//  Home button and document tabs; there is no app rail.
//  Phase: 1 — REAL. No TODOs.
//

import Foundation

enum RailDestination: String, CaseIterable, Identifiable {
    case home
    case document

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .document: "Document"
        }
    }

    var symbolName: String {
        switch self {
        case .home: "house"
        case .document: "doc.richtext"
        }
    }
}
