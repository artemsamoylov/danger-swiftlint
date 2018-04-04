import Danger
import Foundation
import Files

public struct SwiftLint {
    internal static let danger = Danger()
    internal static let shellExecutor = ShellExecutor()

    /// This is the main entry point for linting Swift in PRs using Danger-Swift.
    /// Call this function anywhere from within your Dangerfile.swift.
    @discardableResult
    public static func lint(inline: Bool = false, directory: String? = nil, configFile: String? = nil, pathToSwiftLint: String? = nil, checkAllFiles: Bool = false) -> [Violation] {
        // First, for debugging purposes, print the working directory.
        print("Working directory: \(shellExecutor.execute("pwd"))")
        return self.lint(danger: danger, shellExecutor: shellExecutor, inline: inline, directory: directory, configFile: configFile, pathToSwiftLint: pathToSwiftLint, checkAllFiles: checkAllFiles)
    }
}

/// This extension is for internal workings of the plugin. It is marked as internal for unit testing.
internal extension SwiftLint {
    static func lint(
        danger: DangerDSL,
        shellExecutor: ShellExecutor,
        inline: Bool = false,
        directory: String? = nil,
        configFile: String? = nil,
        pathToSwiftLint: String? = nil,
        checkAllFiles: Bool = false,
        markdownAction: (String) -> Void = markdown,
        failAction: (String) -> Void = fail,
        failInlineAction: (String, String, Int) -> Void = fail,
        warnInlineAction: (String, String, Int) -> Void = warn) -> [Violation] {
        // Gathers modified+created files, invokes SwiftLint on each, and posts collected errors+warnings to Danger.

        var files: [String] = []
        if let directory = directory, checkAllFiles {
            do {
                try Folder(path: directory).makeSubfolderSequence(recursive: true).forEach { folder in
                    for file in folder.files {
                        files.append(file.path)
                    }
                }
            } catch let error {
                print("Error adding all Files: \(error)")
            }

            print("All Files: \(files.count)")
        } else {
            var files = danger.git.createdFiles + danger.git.modifiedFiles
            print("Count files in begining: \(files.count)")
            if let directory = directory {
                files = files.filter { $0.hasPrefix(directory) }
            }
            print("Count files after hasPrefix(directory): \(files.count)")
        }

        let decoder = JSONDecoder()
        let violations = files.filter { $0.hasSuffix(".swift") }.flatMap { file -> [Violation] in
            var arguments = ["lint", "--quiet", "--path \"\(file)\"", "--reporter json"]
            if let configFile = configFile {
                arguments.append("--config \"\(configFile)\"")
            }
            print("Execute swiftlint with: \(arguments)")
            let outputJSON = shellExecutor.execute(pathToSwiftLint ?? "swiftlint", arguments: arguments)
            print("Result execute swiftlint: \(outputJSON.description)")
            do {
                var violations = try decoder.decode([Violation].self, from: outputJSON.data(using: String.Encoding.utf8)!)
                // Workaround for a bug that SwiftLint returns absolute path
                violations = violations.map { violation in
                    var newViolation = violation
                    newViolation.update(file: file)

                    return newViolation
                }

                return violations
            } catch let error {
                failAction("Error deserializing SwiftLint JSON response (\(outputJSON)): \(error)")
                return []
            }
        }

        if !violations.isEmpty {
            if inline {
                violations.forEach { violation in
                    switch violation.severity {
                    case .error:
                        failInlineAction(violation.reason, violation.file, violation.line)
                    case .warning:
                        warnInlineAction(violation.reason, violation.file, violation.line)
                    }
                }
            } else {
                var markdownMessage = """
                ### SwiftLint found issues

                | Severity | File | Reason |
                | -------- | ---- | ------ |\n
                """
                markdownMessage += violations.map { $0.toMarkdown() }.joined(separator: "\n")
                markdownAction(markdownMessage)
            }
        }

        return violations
    }
}
