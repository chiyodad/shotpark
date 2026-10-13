import AppKit
import Vision

/// On-device text recognition (Vision). Korean, English, Japanese and Chinese, reading order top-to-bottom, left-to-right.
enum TextRecognizer {
    /// Payloads of QR codes (and other 2D/1D barcodes) in the image, top to bottom.
    static func barcodes(_ image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        var seen = Set<String>()
        return (request.results ?? [])
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.payloadStringValue }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    typealias Line = (box: CGRect, text: String)
    private typealias Candidate = (box: CGRect, text: String, confidence: Float, rank: Int)

    /// One Vision pass with a single primary language. Vision only uses the first language's
    /// model for a fixed list, and its automatic detection misreads Korean, so each script gets
    /// its own pass and the passes are merged line by line.
    private static func pass(_ image: CGImage, language: String, rank: Int) -> [Candidate] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let supported = try? request.supportedRecognitionLanguages(), supported.contains(language) {
            request.recognitionLanguages = [language, "en-US"]
        } else if rank > 0 {
            return []
        }
        if #available(macOS 13.0, *) { request.automaticallyDetectsLanguage = false }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return (request.results ?? []).compactMap { obs in
            guard let c = obs.topCandidates(1).first, !c.string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (obs.boundingBox, c.string, c.confidence, rank)
        }
    }

    /// Korean, Japanese and Chinese passes; for each spot on the image the most confident reading
    /// wins, ties going to the earlier pass (Korean first, so Korean text never loses to a guess).
    static func recognize(_ image: CGImage) -> String {
        let candidates = ["ko-KR", "ja-JP", "zh-Hans"].enumerated()
            .flatMap { pass(image, language: $0.element, rank: $0.offset) }
            .sorted { $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.rank < $1.rank }
        func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
            let i = a.intersection(b)
            return !i.isNull && i.height > min(a.height, b.height) * 0.5 && i.width > min(a.width, b.width) * 0.3
        }
        var lines: [Line] = []
        for c in candidates where !lines.contains(where: { overlaps($0.box, c.box) }) {
            lines.append((c.box, c.text))
        }
        guard !lines.isEmpty else { return "" }
        // Group into rows: boxes whose vertical centres are within half a line height share a row.
        let sorted = lines.sorted { $0.box.midY > $1.box.midY }
        var rows: [[(box: CGRect, text: String)]] = []
        for l in sorted {
            if let last = rows.last?.first, abs(last.box.midY - l.box.midY) < min(last.box.height, l.box.height) * 0.5 {
                rows[rows.count - 1].append(l)
            } else {
                rows.append([l])
            }
        }
        return rows.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: "  ") }
            .joined(separator: "\n")
    }
}
