//
//  FocusIndicator.swift
//  TypeCam
//

import CoreGraphics
import Foundation

struct FocusIndicator: Equatable, Identifiable {
    let id = UUID()
    let location: CGPoint
    let locked: Bool
}
