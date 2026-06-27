import Foundation

enum BQUploadError: LocalizedError {
    case invalidTableReference(String)
    case uploadCLINotFound
    case bqNotFound
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidTableReference(let ref):
            return "Invalid table reference '\(ref)'. Use project_id.dataset_id.table_id"
        case .uploadCLINotFound:
            #if DEBUG
            return "Local upload_bq_dataset module not found. Check /Users/makaroni4/Startups/upload_bq_dataset and ensure python3 is on your PATH."
            #else
            return "upload-bq-dataset CLI not found. Install it and ensure it is on your PATH."
            #endif
        case .bqNotFound:
            return "bq CLI not found. Install the Google Cloud SDK and ensure bq is on your PATH."
        case .uploadFailed(let message):
            return message
        }
    }
}

struct BQUploadService {
    private struct UploadCommand {
        let executable: String
        let prefixArguments: [String]
    }

    #if DEBUG
    private static let devUploadRepoPath = "/Users/makaroni4/Startups/upload_bq_dataset"
    private static let devUploadModule = "upload_bq_dataset.cli"
    #endif

    struct TableComponents {
        let project: String
        let dataset: String
        let table: String

        var datasetReference: String { "\(project):\(dataset)" }
        var tableReference: String { "\(project):\(dataset).\(table)" }
    }

    private static func isValidIdentifier(_ value: String, allowsHyphen: Bool) -> Bool {
        guard !value.isEmpty else { return false }
        return value.allSatisfy { character in
            character.isLetter || character.isNumber || character == "_" || (allowsHyphen && character == "-")
        }
    }

    static func parseTableComponents(_ input: String) throws -> TableComponents {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              isValidIdentifier(String(parts[0]), allowsHyphen: true),
              isValidIdentifier(String(parts[1]), allowsHyphen: false),
              isValidIdentifier(String(parts[2]), allowsHyphen: false)
        else {
            throw BQUploadError.invalidTableReference(trimmed)
        }
        return TableComponents(
            project: String(parts[0]),
            dataset: String(parts[1]),
            table: String(parts[2])
        )
    }

    static func findUploadExecutable() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["UPLOAD_BQ_DATASET_PATH"],
            "\(NSHomeDirectory())/.pyenv/shims/upload-bq-dataset",
            "/opt/homebrew/bin/upload-bq-dataset",
            "/usr/local/bin/upload-bq-dataset",
        ].compactMap { $0 }

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return resolveFromPATH(executable: "upload-bq-dataset")
    }

    static func findPythonExecutable() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["PYTHON_PATH"],
            ProcessInfo.processInfo.environment["UPLOAD_BQ_DATASET_PYTHON"],
            "\(NSHomeDirectory())/.pyenv/shims/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ].compactMap { $0 }

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return resolveFromPATH(executable: "python3")
    }

    private static func resolveUploadCommand(environment: inout [String: String]) -> UploadCommand? {
        #if DEBUG
        let cliPath = "\(devUploadRepoPath)/upload_bq_dataset/cli.py"
        guard FileManager.default.isReadableFile(atPath: cliPath),
              let pythonPath = findPythonExecutable()
        else {
            return nil
        }

        let existingPythonPath = environment["PYTHONPATH"] ?? ""
        environment["PYTHONPATH"] = existingPythonPath.isEmpty
            ? devUploadRepoPath
            : "\(devUploadRepoPath):\(existingPythonPath)"

        return UploadCommand(
            executable: pythonPath,
            prefixArguments: ["-m", devUploadModule]
        )
        #else
        guard let uploadPath = findUploadExecutable() else { return nil }
        return UploadCommand(executable: uploadPath, prefixArguments: [])
        #endif
    }

    static func findBQExecutable() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["BQ_PATH"],
            "/opt/homebrew/bin/bq",
            "/usr/local/bin/bq",
            "\(NSHomeDirectory())/google-cloud-sdk/bin/bq",
            "\(NSHomeDirectory())/Downloads/google-cloud-sdk/bin/bq",
        ].compactMap { $0 }

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return resolveFromPATH(executable: "bq")
    }

    private static func resolveFromPATH(executable: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [executable]
        process.environment = enrichedEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
                return nil
            }
            return path
        } catch {
            return nil
        }
    }

    private static func enrichedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = [
            "\(NSHomeDirectory())/.pyenv/shims",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/google-cloud-sdk/bin",
            "\(NSHomeDirectory())/Downloads/google-cloud-sdk/bin",
        ]
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = (extraPaths + [path]).joined(separator: ":")
        return environment
    }

    private static func runCommand(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return (process.terminationStatus, combined)
    }

    private static func bqObjectExists(
        executable: String,
        reference: String,
        environment: [String: String]
    ) -> Bool {
        guard let result = try? runCommand(
            executable: executable,
            arguments: ["show", reference],
            environment: environment
        ) else {
            return false
        }
        return result.status == 0
    }

    static func upload(csvURL: URL, tableReference: String) async throws -> String {
        let bqPath = findBQExecutable()
        guard let bqPath else { throw BQUploadError.bqNotFound }

        let components = try parseTableComponents(tableReference)
        var environment = enrichedEnvironment()
        guard let uploadCommand = resolveUploadCommand(environment: &environment) else {
            throw BQUploadError.uploadCLINotFound
        }
        var log: [String] = []

        if !bqObjectExists(executable: bqPath, reference: components.datasetReference, environment: environment) {
            let result = try runCommand(
                executable: bqPath,
                arguments: ["mk", "-d", components.datasetReference],
                environment: environment
            )
            guard result.status == 0 else {
                throw BQUploadError.uploadFailed(
                    result.output.isEmpty
                        ? "Failed to create dataset \(components.dataset)."
                        : result.output
                )
            }
            log.append("Created dataset \(components.dataset).")
        }

        let tableExists = bqObjectExists(
            executable: bqPath,
            reference: components.tableReference,
            environment: environment
        )

        var uploadArguments = [
            csvURL.path,
            "--project", components.project,
            "--dataset", components.dataset,
            "--table", components.table,
        ]
        if tableExists {
            uploadArguments.append("--replace")
            log.append("Replacing existing table \(components.table).")
        } else {
            log.append("Table \(components.table) not found — creating with autodetected schema.")
        }

        let uploadResult = try runCommand(
            executable: uploadCommand.executable,
            arguments: uploadCommand.prefixArguments + uploadArguments,
            environment: environment
        )

        guard uploadResult.status == 0 else {
            let message = uploadResult.output.isEmpty
                ? "upload-bq-dataset failed with exit code \(uploadResult.status)"
                : uploadResult.output
            throw BQUploadError.uploadFailed(message)
        }

        if !uploadResult.output.isEmpty {
            log.append(uploadResult.output)
        }
        if log.isEmpty {
            log.append("Upload complete.")
        }

        return log.joined(separator: "\n")
    }
}
