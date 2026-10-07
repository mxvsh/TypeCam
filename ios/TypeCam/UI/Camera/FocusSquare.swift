//
//  FocusSquare.swift
//  TypeCam
//

import SwiftUI

/// Yellow tap-to-focus square. Shrinks in, then fades after a moment unless focus is locked.
struct FocusSquare: View {
    let indicator: FocusIndicator
    let onExpire: (FocusIndicator) -> Void

    @State private var settled = false
    @State private var faded = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(Theme.paused, lineWidth: 1.5)
            .frame(width: 72, height: 72)
            .scaleEffect(settled ? 1 : 1.35)
            .opacity(faded ? 0.35 : 1)
            .position(indicator.location)
            .allowsHitTesting(false)
            .task(id: indicator.id) {
                settled = false
                faded = false
                withAnimation(.spring(duration: 0.3)) { settled = true }
                try? await Task.sleep(for: .seconds(1.2))
                if indicator.locked {
                    withAnimation(.easeOut(duration: 0.4)) { faded = true }
                } else {
                    onExpire(indicator)
                }
            }
    }
}
