#!/usr/bin/env swift
// Boots a dedicated simulator and adds a fictional OCR fixture. Never reads personal photos.
import AppKit
import Foundation

guard CommandLine.arguments.count == 2, UUID(uuidString: CommandLine.arguments[1]) != nil else {
    fputs("Usage: swift scripts/prepare_photo_fixture.swift SIMULATOR_UUID\n", stderr)
    exit(2)
}
let device = CommandLine.arguments[1]
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shike-photo-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let path = directory.appendingPathComponent("reading-club.png")
let image = NSImage(size: NSSize(width: 1200, height: 800))
image.lockFocus()
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: 1200, height: 800).fill()
("READING CLUB\nTomorrow 7 PM - 8 PM\nLibrary Room 2\nBring your notebook" as NSString).draw(
    in: NSRect(x: 70, y: 100, width: 1080, height: 600),
    withAttributes: [.font: NSFont.systemFont(ofSize: 65), .foregroundColor: NSColor.black])
image.unlockFocus()
guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot render fixture") }
try data.write(to: path)
func simctl(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl"] + arguments
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
}
try simctl(["bootstatus", device, "-b"])
try simctl(["addmedia", device, path.path])
try simctl(["privacy", device, "grant", "photos", "com.chandler.shike"])
print("Added fictional reading-club photo and granted Photos access on simulator \(device).")
