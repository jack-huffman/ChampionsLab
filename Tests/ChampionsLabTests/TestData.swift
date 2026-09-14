//  TestData.swift
//  Where the tests find the dataset: beside Package.swift, wherever the
//  package has been checked out.

import Foundation

enum TestData {
    static func url(_ name: String) -> URL {
        var here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = here.appendingPathComponent("data/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            here.deleteLastPathComponent()
        }
        preconditionFailure("data/\(name) not found above \(#filePath)")
    }
}
