import AppKit
import Vision

/// On-device text recognition (Vision). Korean + English, reading order top-to-bottom, left-to-right.
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

    static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let wanted = ["ko-KR", "en-US"]
        if let supported = try? request.supportedRecognitionLanguages() {
            let langs = wanted.filter { supported.contains($0) }
            if !langs.isEmpty { request.recognitionLanguages = langs }
        }
        if #available(macOS 13.0, *) { request.automaticallyDetectsLanguage = false }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return "" }
        let lines: [(box: CGRect, text: String)] = (request.results ?? []).compactMap { obs in
            guard let t = obs.topCandidates(1).first?.string, !t.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (obs.boundingBox, t)
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
