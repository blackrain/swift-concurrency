// Book finishing: locate chapter pages, write pages.json, and (optionally) produce the final PDF
// with cover + running heads + folios.
// usage: finish <interior.pdf> <meta.json> <pages.json> [<cover.pdf> <out.pdf>]
import AppKit
import PDFKit

struct Entry: Decodable { let sid: String; let kind: String; let label: String; let title: String }

let args = CommandLine.arguments
let interior = PDFDocument(url: URL(fileURLWithPath: args[1]))!
let meta = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))

func norm(_ s: String) -> String {
    s.uppercased().components(separatedBy: .whitespacesAndNewlines).joined()
}

// 1. Find the page where each entry starts: the page whose text begins with its label.
var startPage: [String: Int] = [:]          // sid -> 0-based interior page index
var searchFrom = 0
for e in meta {
    let want = norm(e.label)
    var found = false
    for i in searchFrom..<interior.pageCount {
        let text = norm(interior.page(at: i)?.string ?? "")
        if text.hasPrefix(want) {
            startPage[e.sid] = i; searchFrom = i + 1; found = true; break
        }
    }
    if !found { FileHandle.standardError.write("NOT FOUND: \(e.label)\n".data(using: .utf8)!); exit(1) }
}
// printed page numbers: interior page index + 1 (the cover is unnumbered)
let pagesJSON = startPage.mapValues { $0 + 1 }
try JSONSerialization.data(withJSONObject: pagesJSON, options: [.sortedKeys, .prettyPrinted])
    .write(to: URL(fileURLWithPath: args[3]))
print("located \(startPage.count) entries in \(interior.pageCount) pages")

guard args.count >= 6 else { exit(0) }
let cover = PDFDocument(url: URL(fileURLWithPath: args[4]))!
let outURL = URL(fileURLWithPath: args[5])

// 2. Per-page context: which part/chapter each page belongs to, and what kind of page it is.
let firstBodyPage = startPage["ch-preface"]!               // title, copyright, TOC come before
let partPages = Set(meta.filter { $0.kind == "part" }.compactMap { startPage[$0.sid] })
let openerPages = Set(meta.filter { $0.kind == "chapter" }.compactMap { startPage[$0.sid] })
var chapterTitle = [String](repeating: "", count: interior.pageCount)
var partTitle = [String](repeating: "", count: interior.pageCount)
var currentChapter = "", currentPart = "Preface"
let byPage = Dictionary(grouping: meta, by: { startPage[$0.sid]! })
for i in 0..<interior.pageCount {
    for e in byPage[i] ?? [] {
        if e.kind == "part" { currentPart = e.label == "APPENDICES" ? "Appendices" : "Part \(e.label.split(separator: " ").last!) · \(e.title)" }
        else { currentChapter = e.title }
    }
    chapterTitle[i] = currentChapter; partTitle[i] = currentPart
}

// 3. Draw: cover first, then every interior page with running head + folio.
let mediaBox = interior.page(at: 0)!.bounds(for: .mediaBox)
var box = mediaBox
let ctx = CGContext(outURL as CFURL, mediaBox: &box, [kCGPDFContextTitle: "Mastering Swift Concurrency",
                                                      kCGPDFContextCreator: "Mastering Swift Concurrency build"] as CFDictionary)!

func drawPage(_ page: PDFPage) {
    var b = page.bounds(for: .mediaBox)
    ctx.beginPage(mediaBox: &b)
    page.draw(with: .mediaBox, to: ctx)
}

let headFont = NSFont(name: "AvenirNext-Medium", size: 7.2)!
let folioFont = NSFont(name: "AvenirNext-DemiBold", size: 8)!
let grey = NSColor(white: 0.35, alpha: 1)
let accent = NSColor(red: 0x8b/255, green: 0x1a/255, blue: 0x1a/255, alpha: 1)

func text(_ s: String, font: NSFont, color: NSColor, at p: CGPoint, alignRight: Bool = false, maxWidth: CGFloat = 300) {
    let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
    let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: 0.6, .paragraphStyle: para])
    let w = min(attr.size().width, maxWidth)
    let x = alignRight ? p.x - w : p.x
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    attr.draw(with: CGRect(x: x, y: p.y, width: w, height: font.pointSize * 1.6), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    NSGraphicsContext.restoreGraphicsState()
}

// Collect links from the interior (internal -> named destinations, external -> URLs).
enum LinkTarget { case dest(String), url(URL) }
var pageLinks = [[(CGRect, LinkTarget)]](repeating: [], count: interior.pageCount)
var destsOnPage = [[(String, CGPoint)]](repeating: [], count: interior.pageCount)
for i in 0..<interior.pageCount {
    for a in interior.page(at: i)!.annotations where a.type == "Link" {
        if let url = a.url ?? (a.action as? PDFActionURL)?.url { pageLinks[i].append((a.bounds, .url(url))); continue }
        guard let d = a.destination ?? (a.action as? PDFActionGoTo)?.destination, let tp = d.page else { continue }
        let ti = interior.index(for: tp)
        let name = "p\(ti)y\(Int(d.point.y))"
        pageLinks[i].append((a.bounds, .dest(name)))
        if !destsOnPage[ti].contains(where: { $0.0 == name }) { destsOnPage[ti].append((name, CGPoint(x: 0, y: d.point.y))) }
    }
}

drawPage(cover.page(at: 0)!)
ctx.endPage()

let W = mediaBox.width, H = mediaBox.height
let margin: CGFloat = 0.75 * 72
for i in 0..<interior.pageCount {
    let page = interior.page(at: i)!
    drawPage(page)
    let folio = "\(i + 1)"
    let even = (i + 1) % 2 == 0
    if i >= firstBodyPage && !partPages.contains(i) {
        if openerPages.contains(i) {
            // chapter opener: centered folio at the foot only
            text(folio, font: folioFont, color: grey, at: CGPoint(x: W / 2 + 6, y: 0.4 * 72), alignRight: true)
        } else {
            let y = H - 0.55 * 72
            let head = even ? partTitle[i].uppercased() : chapterTitle[i]
            if even {
                text(folio, font: folioFont, color: accent, at: CGPoint(x: margin, y: y))
                text(head, font: headFont, color: grey, at: CGPoint(x: margin + 26, y: y + 0.5), maxWidth: W - 2 * margin - 30)
            } else {
                text(folio, font: folioFont, color: accent, at: CGPoint(x: W - margin, y: y), alignRight: true)
                text(head, font: headFont, color: grey, at: CGPoint(x: W - margin - 26, y: y + 0.5), alignRight: true, maxWidth: W - 2 * margin - 30)
            }
            // hairline under the running head
            ctx.setStrokeColor(NSColor(white: 0.72, alpha: 1).cgColor); ctx.setLineWidth(0.4)
            ctx.move(to: CGPoint(x: margin, y: y - 4)); ctx.addLine(to: CGPoint(x: W - margin, y: y - 4)); ctx.strokePath()
        }
    }
    for (name, pt) in destsOnPage[i] { ctx.addDestination(name as CFString, at: pt) }
    for (rect, target) in pageLinks[i] {
        switch target {
        case .dest(let name): ctx.setDestination(name as CFString, for: rect)
        case .url(let url): ctx.setURL(url as CFURL, for: rect)
        }
    }
    ctx.endPage()
}
// Outline (bookmarks): one-indexed page numbers in the FINAL document (cover is page 1).
var top: [[String: Any]] = []
for e in meta {
    let pageNo = startPage[e.sid]! + 2
    let title = e.kind == "part" ? (e.label == "APPENDICES" ? "Appendices" : "Part \(e.label.split(separator: " ").last!): \(e.title)")
                                 : e.title.replacingOccurrences(of: "  ", with: " ")
    let node: [String: Any] = [kCGPDFOutlineTitle as String: title, kCGPDFOutlineDestination as String: pageNo]
    if e.kind == "part" || e.sid == "ch-preface" { top.append(node) }
    else {
        var last = top.removeLast()
        var kids = last[kCGPDFOutlineChildren as String] as? [[String: Any]] ?? []
        kids.append(node); last[kCGPDFOutlineChildren as String] = kids
        top.append(last)
    }
}
CGPDFContextSetOutline(ctx, [kCGPDFOutlineChildren as String: top] as CFDictionary)
ctx.closePDF()
print("wrote \(outURL.path) with \(pageLinks.map(\.count).reduce(0, +)) links")
