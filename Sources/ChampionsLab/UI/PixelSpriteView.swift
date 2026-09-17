//  PixelSpriteView.swift
//  An animated pixel sprite, drawn as pixels, by SwiftUI.
//
//  The frames of the GIF are decoded once, off the main thread, and this
//  shows whichever one the clock calls for, unsmoothed. It was an NSImageView
//  playing the file itself, which SwiftUI cannot carry through a lunge
//  cheaply: every frame of a move meant a new frame for the AppKit view, and
//  that read as a stutter. An Image is just a picture.

import SwiftUI

struct PixelSpriteView: View {
    let frames: PixelSprites.Frames

    var body: some View {
        if frames.images.count > 1 {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { slice in
                picture(frames.frame(at: slice.date.timeIntervalSinceReferenceDate))
            }
        } else if let only = frames.images.first {
            picture(only)
        }
    }

    private func picture(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.none)
            .aspectRatio(contentMode: .fit)
    }
}
