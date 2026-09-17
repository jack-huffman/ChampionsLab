//  PixelSpriteView.swift
//  An animated pixel sprite, drawn as pixels.
//
//  SwiftUI's Image shows the first frame of a GIF and smooths it. An
//  NSImageView plays the frames, and with nearest-neighbour magnification a
//  ninety-six-pixel sprite stays crisp at whatever size the card gives it.

import SwiftUI
import AppKit

struct PixelSpriteView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.animates = true
        view.wantsLayer = true
        view.layer?.magnificationFilter = .nearest
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
        view.animates = true
    }
}
