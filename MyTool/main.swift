import Foundation
import PDFKit

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("pdftext: \(message)\n".utf8))
    exit(code)
}

let options: Options
do {
    guard let parsed = try Options.parse(Array(CommandLine.arguments.dropFirst())) else {
        print(Options.usage)
        exit(0)
    }
    options = parsed
} catch {
    fail("\(error)\n\n\(Options.usage)", code: 2)
}

let inputURL = URL(fileURLWithPath: options.inputPath)
guard FileManager.default.isReadableFile(atPath: inputURL.path) else {
    fail("cannot read '\(options.inputPath)'")
}
guard let document = PDFDocument(url: inputURL) else {
    fail("'\(options.inputPath)' is not a PDF file")
}
if document.isLocked && !document.unlock(withPassword: "") {
    fail("'\(options.inputPath)' is password protected")
}

let output: FileHandle
if let outputPath = options.outputPath {
    // open(2) rather than FileManager so devices and pipes work too.
    let fd = open(outputPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else {
        fail("cannot write '\(outputPath)': \(String(cString: strerror(errno)))")
    }
    output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
} else {
    output = FileHandle.standardOutput
}

// Show progress only when it won't get mixed into the text on the terminal.
let showProgress = isatty(STDERR_FILENO) != 0
    && (options.outputPath != nil || isatty(STDOUT_FILENO) == 0)

let extractor = PageExtractor(options: options)
let pageCount = document.pageCount
// Recognition runs concurrently; rendering and output stay in page order.
let maxInFlight = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)

var finished: [Int: String] = [:]
var nextToWrite = 0

func writeFinishedPages() throws {
    while let text = finished.removeValue(forKey: nextToWrite) {
        var chunk = nextToWrite > 0 ? "\u{000C}" : ""
        chunk += text
        if !text.isEmpty { chunk += "\n" }
        try output.write(contentsOf: Data(chunk.utf8))
        nextToWrite += 1
        if showProgress {
            FileHandle.standardError.write(Data("\rpage \(nextToWrite) of \(pageCount)".utf8))
        }
    }
}

do {
    try await withThrowingTaskGroup(of: (Int, String).self) { group in
        var inFlight = 0
        for index in 0..<pageCount {
            guard let page = document.page(at: index) else { continue }
            let job: PageJob
            do {
                // Rendering scanned pages creates autoreleased image data that
                // would otherwise pile up until the whole document is done.
                job = try autoreleasepool { try extractor.prepare(page) }
            } catch {
                throw PageError(page: index + 1, underlying: error)
            }
            group.addTask {
                do {
                    return (index, try await extractor.finish(job))
                } catch {
                    throw PageError(page: index + 1, underlying: error)
                }
            }
            inFlight += 1
            if inFlight >= maxInFlight, let (done, text) = try await group.next() {
                inFlight -= 1
                finished[done] = text
                try writeFinishedPages()
            }
        }
        for try await (done, text) in group {
            finished[done] = text
            try writeFinishedPages()
        }
    }
} catch {
    if showProgress { FileHandle.standardError.write(Data("\n".utf8)) }
    fail("\(error)")
}

if showProgress { FileHandle.standardError.write(Data("\n".utf8)) }
try? output.close()

struct PageError: Error, CustomStringConvertible {
    let page: Int
    let underlying: Error
    var description: String { "page \(page): \(underlying)" }
}
