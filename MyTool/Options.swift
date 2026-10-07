import Foundation

/// Command line options for the tool.
struct Options {
    var inputPath = ""
    var outputPath: String?
    var forceOCR = false
    var languages: [String] = []
    var dpi = 300.0

    static let usage = """
        Usage: pdftext [options] <input.pdf>

        Extracts the text from every page of a PDF. Pages that contain real text are
        read directly; scanned pages are recognized with the Vision framework. Pages
        are separated by form feed characters.

        Options:
          -o, --output <file>     Write the text to <file> instead of stdout
              --ocr               Run text recognition on every page, ignoring any
                                  text already embedded in the PDF
          -l, --language <code>   Recognition language, e.g. en-US or fr-FR. May be
                                  repeated or comma separated (default: en-US)
              --dpi <n>           Resolution used to render pages for recognition
                                  (default: 300)
          -h, --help              Show this help
        """

    struct UsageError: Error, CustomStringConvertible {
        let description: String
    }

    /// Parses the arguments (not including the program name). Returns nil if help was requested.
    static func parse(_ arguments: [String]) throws -> Options? {
        var options = Options()
        var positional: [String] = []
        var remaining = arguments[...]

        func value(for name: String, inline: String?) throws -> String {
            if let inline { return inline }
            guard let next = remaining.popFirst() else {
                throw UsageError(description: "\(name) requires a value")
            }
            return next
        }

        while let arg = remaining.popFirst() {
            if arg == "--" {
                positional.append(contentsOf: remaining)
                break
            }
            guard arg.hasPrefix("-"), arg != "-" else {
                positional.append(arg)
                continue
            }

            // Allow --name=value as well as --name value.
            var name = arg
            var inline: String?
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                name = String(arg[..<eq])
                inline = String(arg[arg.index(after: eq)...])
            }

            switch name {
            case "-h", "--help":
                return nil
            case "-o", "--output":
                options.outputPath = try value(for: name, inline: inline)
            case "--ocr":
                options.forceOCR = true
            case "-l", "--language":
                let codes = try value(for: name, inline: inline)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                options.languages.append(contentsOf: codes)
            case "--dpi":
                let text = try value(for: name, inline: inline)
                guard let dpi = Double(text), dpi >= 72, dpi <= 1200 else {
                    throw UsageError(description: "--dpi must be a number between 72 and 1200")
                }
                options.dpi = dpi
            default:
                throw UsageError(description: "unknown option '\(arg)'")
            }
        }

        guard positional.count == 1 else {
            throw UsageError(description: positional.isEmpty
                ? "no input file given"
                : "expected one input file, got \(positional.count)")
        }
        options.inputPath = positional[0]
        return options
    }
}
