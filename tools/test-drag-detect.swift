// Harness for the drop panel's media-only drag classifier.
// Plants payloads on the DRAG pasteboard and runs the same logic
// DragMonitor.dragHasPayload uses. Run: swift tools/test-drag-detect.swift
import AppKit
import UniformTypeIdentifiers

let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "svg", "heic", "heif", "tiff", "bmp", "avif"]
let videoExts: Set<String> = ["mp4", "mov", "webm", "m4v", "mpg", "mpeg", "avi"]
let mediaExts = imageExts.union(videoExts)

func dragHasPayload(_ pb: NSPasteboard) -> Bool {
    let types = pb.types ?? []
    if types.contains(.fileURL),
       let urls = pb.readObjects(forClasses: [NSURL.self],
                                 options: [.urlReadingFileURLsOnly: true]) as? [URL] {
        if urls.contains(where: { mediaExts.contains($0.pathExtension.lowercased()) }) { return true }
        if !urls.isEmpty { return false }
    }
    if let promised = pb.string(forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")) {
        if let ut = UTType(promised), ut.conforms(to: .image) || ut.conforms(to: .movie) { return true }
        if mediaExts.contains(promised.lowercased()) { return true }
    }
    if let list = pb.propertyList(forType: NSPasteboard.PasteboardType("Apple files promise pasteboard type")) as? [String],
       list.contains(where: { mediaExts.contains($0.lowercased()) }) {
        return true
    }
    if types.contains(.URL),
       let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
       urls.contains(where: { $0.scheme?.hasPrefix("http") == true }) {
        return true
    }
    return false
}

let pb = NSPasteboard(name: .drag)
var pass = 0, fail = 0

func check(_ name: String, expect: Bool, plant: () -> Void) {
    pb.clearContents()
    plant()
    let got = dragHasPayload(pb)
    let ok = got == expect
    ok ? (pass += 1) : (fail += 1)
    print("\(ok ? "PASS" : "FAIL")  \(name): expected \(expect), got \(got)")
}

let jpg = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Pictures/Snag/files")
let jpgFile = (try? FileManager.default.contentsOfDirectory(at: jpg, includingPropertiesForKeys: nil))?
    .first { $0.pathExtension == "jpg" }

let tmpTxt = FileManager.default.temporaryDirectory.appendingPathComponent("snag-test.txt")
try? "hello".write(to: tmpTxt, atomically: true, encoding: .utf8)
let tmpPdf = FileManager.default.temporaryDirectory.appendingPathComponent("snag-test.pdf")
try? Data().write(to: tmpPdf)

if let jpgFile {
    check("jpg file drag", expect: true) { pb.writeObjects([jpgFile as NSURL]) }
}
check("txt file drag", expect: false) { pb.writeObjects([tmpTxt as NSURL]) }
check("pdf file drag", expect: false) { pb.writeObjects([tmpPdf as NSURL]) }
check("plain text drag", expect: false) { pb.setString("just some dragged text", forType: .string) }
check("web page URL drag (link/tab)", expect: true) { pb.writeObjects([URL(string: "https://theworkclub.co/pricing")! as NSURL]) }
check("web image URL drag", expect: true) { pb.writeObjects([URL(string: "https://i.pinimg.com/736x/ab/cd/ef.jpg")! as NSURL]) }
check("raw bitmap snapshot alone (text drag ghost)", expect: false) {
    let img = NSImage(size: NSSize(width: 4, height: 4))
    pb.writeObjects([img])
}
check("tiff snapshot + non-media file", expect: false) {
    pb.writeObjects([tmpPdf as NSURL])
    pb.setData(Data([0x4D, 0x4D, 0x00, 0x2A]), forType: .tiff)
}
check("browser promise drag (png)", expect: true) {
    pb.setString("public.png", forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"))
}
check("promise drag of pages doc", expect: false) {
    pb.setString("com.apple.iwork.pages.sffpages", forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"))
}

pb.clearContents()
print(fail == 0 ? "ALL \(pass) PASSED" : "\(fail) FAILED, \(pass) passed")
exit(fail == 0 ? 0 : 1)
