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
            return "bqcsv not found. Set BQCSV_DEV_REPO to your local bqcsv repo, install bqcsv (pip install bqcsv), or set BQCSV_PATH."
            #else
            return "bqcsv CLI not found. Install it and ensure it is on your PATH."
            #endif
        case .bqNotFound:
            return "bq CLI not found. Install the Google Cloud SDK and ensure bq is on your PATH."
        case .uploadFailed(let message):
            return message
        }
    }
}

struct BQUploadService {
    struct UploadResult {
        let succeeded: Bool
        let log: String?
    }

    private struct UploadCommand {
        let cliName: String
        let pathEnvironmentKeys: [String]
        let prefixArguments: [String]
    }

    private static let shell = "/bin/zsh"
    private static let devUploadModule = "src.cli"
    private static let googleCloudSDKPattern = #"['"]([^'"]+/google-cloud-sdk)/path\.(?:zsh|bash)\.inc['"]"#
    private static var cachedToolEnvironment: [String: String]?

    private static func shellQuote(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func directoryContainingExecutable(at path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).deletingLastPathComponent
    }

    private static func shellConfigBinDirectories() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configFiles = [".zprofile", ".zshrc", ".bash_profile", ".bashrc"]
        var directories: [String] = []

        guard let regex = try? NSRegularExpression(pattern: googleCloudSDKPattern) else {
            return directories
        }

        for file in configFiles {
            let configPath = "\(home)/\(file)"
            guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
                continue
            }

            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            regex.enumerateMatches(in: content, range: range) { match, _, _ in
                guard let match,
                      let sdkRange = Range(match.range(at: 1), in: content) else {
                    return
                }
                directories.append("\(content[sdkRange])/bin")
            }
        }

        return directories
    }

    private static func toolSearchPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var directories: [String] = []

        func append(_ path: String?) {
            guard let path,
                  !path.isEmpty,
                  !directories.contains(path) else {
                return
            }
            directories.append(path)
        }

        for key in ["BQ_PATH", "BQCSV_PATH", "PYTHON_PATH", "BQCSV_PYTHON"] {
            if let configuredPath = ProcessInfo.processInfo.environment[key] {
                append(directoryContainingExecutable(at: configuredPath))
            }
        }

        append("\(home)/.pyenv/shims")
        append("/opt/homebrew/bin")
        append("/usr/local/bin")
        append("\(home)/google-cloud-sdk/bin")

        for directory in shellConfigBinDirectories() {
            append(directory)
        }

        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in inheritedPath.split(separator: ":", omittingEmptySubsequences: true) {
            append(String(directory))
        }

        return directories.joined(separator: ":")
    }

    private static func toolEnvironment(extra: [String: String] = [:]) -> [String: String] {
        if extra.isEmpty, let cachedToolEnvironment {
            return cachedToolEnvironment
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = toolSearchPath()
        for (key, value) in extra {
            environment[key] = value
        }

        if extra.isEmpty {
            cachedToolEnvironment = environment
        }

        return environment
    }

    private static func runShell(
        _ script: String,
        environment: [String: String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", script]
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = trimmedStdout.isEmpty
            ? trimmedStderr
            : [trimmedStdout, trimmedStderr].filter { !$0.isEmpty }.joined(separator: "\n")

        return (process.terminationStatus, combined)
    }

    private static func cliCommand(name: String, pathEnvironmentKeys: [String]) -> String {
        for key in pathEnvironmentKeys {
            if let path = ProcessInfo.processInfo.environment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        }
        return name
    }

    private static func resolveUploadCommand(environment: inout [String: String]) -> UploadCommand {
        #if DEBUG
        if let devUploadRepoPath = resolveDevUploadRepoPath() {
            let existingPythonPath = environment["PYTHONPATH"] ?? ""
            environment["PYTHONPATH"] = existingPythonPath.isEmpty
                ? devUploadRepoPath
                : "\(devUploadRepoPath):\(existingPythonPath)"

            return UploadCommand(
                cliName: "python3",
                pathEnvironmentKeys: ["PYTHON_PATH", "BQCSV_PYTHON"],
                prefixArguments: ["-m", devUploadModule]
            )
        }
        #endif

        return UploadCommand(cliName: "bqcsv", pathEnvironmentKeys: ["BQCSV_PATH"], prefixArguments: [])
    }

    #if DEBUG
    private static func resolveDevUploadRepoPath() -> String? {
        guard let path = ProcessInfo.processInfo.environment["BQCSV_DEV_REPO"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }

        let cliPath = "\(path)/src/cli.py"
        guard FileManager.default.fileExists(atPath: cliPath) else {
            return nil
        }

        return path
    }
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

    private static func uploadCommandInvocation(_ uploadCommand: UploadCommand) -> String {
        let command = cliCommand(
            name: uploadCommand.cliName,
            pathEnvironmentKeys: uploadCommand.pathEnvironmentKeys
        )
        return ([command] + uploadCommand.prefixArguments).map(shellQuote).joined(separator: " ")
    }

    private static func buildUploadScript(
        csvURL: URL,
        components: TableComponents,
        uploadCommand: UploadCommand
    ) -> String {
        let uploadCLI = uploadCommandInvocation(uploadCommand)
        let csvPath = shellQuote(csvURL.path)
        let datasetReference = shellQuote(components.datasetReference)
        let tableReference = shellQuote(components.tableReference)
        let project = shellQuote(components.project)
        let dataset = shellQuote(components.dataset)
        let table = shellQuote(components.table)

        return """
        set -e
        command -v bq >/dev/null 2>&1 || { echo "BQ_NOT_FOUND"; exit 127; }
        command -v \(shellQuote(uploadCommand.cliName)) >/dev/null 2>&1 || { echo "UPLOAD_CLI_NOT_FOUND"; exit 127; }
        if ! bq show \(datasetReference) >/dev/null 2>&1; then
          bq mk -d \(datasetReference)
        fi
        replace_flag=""
        if bq show \(tableReference) >/dev/null 2>&1; then
          replace_flag="--replace"
        fi
        \(uploadCLI) \(csvPath) --project \(project) --dataset \(dataset) --table \(table) --output json "$replace_flag"
        """
    }

    private static func parseUploadResponse(_ output: String) -> UploadResult? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String
        else {
            return nil
        }

        let log = (json["log"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return UploadResult(
            succeeded: status == "success",
            log: log?.isEmpty == false ? log : nil
        )
    }

    static func upload(csvURL: URL, tableReference: String) async throws -> UploadResult {
        let components = try parseTableComponents(tableReference)
        var environment = toolEnvironment()
        let uploadCommand = resolveUploadCommand(environment: &environment)

        let script = buildUploadScript(
            csvURL: csvURL,
            components: components,
            uploadCommand: uploadCommand
        )

        let uploadResult = try runShell(script, environment: environment)

        switch uploadResult.output {
        case "BQ_NOT_FOUND":
            throw BQUploadError.bqNotFound
        case "UPLOAD_CLI_NOT_FOUND":
            throw BQUploadError.uploadCLINotFound
        default:
            break
        }

        if let parsed = parseUploadResponse(uploadResult.output) {
            return parsed
        }

        guard uploadResult.status == 0 else {
            let message = uploadResult.output.isEmpty
                ? "bqcsv failed with exit code \(uploadResult.status)"
                : uploadResult.output
            throw BQUploadError.uploadFailed(message)
        }

        return UploadResult(succeeded: true, log: nil)
    }
}
