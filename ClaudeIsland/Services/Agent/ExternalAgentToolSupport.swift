//
//  ExternalAgentToolSupport.swift
//  ClaudeIsland
//
//  Shared normalization for Codex and Gemini tool calls/results.
//

import Foundation

struct AgentHistorySnapshot: Sendable {
    let messages: [ChatMessage]
    let completedToolIds: Set<String>
    let toolResults: [String: ConversationParser.ToolResult]
    let structuredResults: [String: ToolResultData]
    let conversationInfo: ConversationInfo
}

enum ExternalAgentToolSupport {
    static func normalizeToolName(agentId: String, rawName: String) -> String {
        let lowered = rawName.lowercased()

        switch agentId {
        case "codex":
            switch lowered {
            case "exec_command":
                return "Bash"
            case "write_stdin":
                return "BashOutput"
            case "request_user_input":
                return "request_user_input"
            case "apply_patch":
                return "Patch"
            default:
                return rawName
            }
        case "gemini":
            switch lowered {
            case "run_shell_command":
                return "Bash"
            case "ask_user":
                return "request_user_input"
            case "replace":
                return "Edit"
            case "write_file":
                return "Write"
            default:
                return rawName
            }
        default:
            return rawName
        }
    }

    static func normalizeToolInput(agentId: String, rawName: String, input: [String: String]) -> [String: String] {
        var normalized = input

        if let cmd = normalized["cmd"], normalized["command"] == nil {
            normalized["command"] = cmd
        }
        if let workdir = normalized["workdir"], normalized["cwd"] == nil {
            normalized["cwd"] = workdir
        }
        if let filePath = normalized["path"], normalized["file_path"] == nil {
            normalized["file_path"] = filePath
        }

        let normalizedName = normalizeToolName(agentId: agentId, rawName: rawName)
        if normalizedName == "request_user_input",
           normalized["question"] == nil,
           let questions = normalized["questions"] {
            normalized["questions"] = questions
        }

        return normalized
    }

    static func parseResult(
        agentId: String,
        rawToolName: String,
        toolInput: [String: String],
        rawOutput: String?,
        rawPayload: [String: Any]?
    ) -> (parserResult: ConversationParser.ToolResult?, structuredResult: ToolResultData?) {
        switch agentId {
        case "codex":
            return parseCodexResult(rawToolName: rawToolName, toolInput: toolInput, rawOutput: rawOutput)
        case "gemini":
            return parseGeminiResult(rawToolName: rawToolName, toolInput: toolInput, rawPayload: rawPayload)
        default:
            return (nil, nil)
        }
    }

    static func parseAskUserQuestions(_ rawQuestions: Any?) -> AskUserQuestionResult? {
        guard let rawQuestions = rawQuestions as? [[String: Any]], !rawQuestions.isEmpty else {
            return nil
        }

        let questions = rawQuestions.enumerated().compactMap { index, rawQuestion -> QuestionItem? in
            guard let question = stringValue(rawQuestion["question"]), !question.isEmpty else {
                return nil
            }

            let options = (rawQuestion["options"] as? [[String: Any]] ?? []).compactMap { option -> QuestionOption? in
                guard let label = stringValue(option["label"]), !label.isEmpty else {
                    return nil
                }
                return QuestionOption(label: label, description: stringValue(option["description"]))
            }

            return QuestionItem(
                id: stringValue(rawQuestion["id"]) ?? "question-\(index)",
                question: question,
                header: stringValue(rawQuestion["header"]),
                options: options
            )
        }

        guard !questions.isEmpty else { return nil }
        return AskUserQuestionResult(questions: questions, answers: [:])
    }

    private static func parseCodexResult(
        rawToolName: String,
        toolInput: [String: String],
        rawOutput: String?
    ) -> (parserResult: ConversationParser.ToolResult?, structuredResult: ToolResultData?) {
        let normalizedName = normalizeToolName(agentId: "codex", rawName: rawToolName)

        switch normalizedName {
        case "Bash":
            guard let rawOutput else { return (nil, nil) }
            let parsed = parseCodexCommandOutput(rawOutput)
            let parserResult = ConversationParser.ToolResult(
                content: parsed.output,
                stdout: parsed.stdout,
                stderr: parsed.stderr,
                isError: parsed.exitCode.map { $0 != 0 } ?? false
            )
            let structured = ToolResultData.bash(
                BashResult(
                    command: firstNonEmpty(toolInput["command"], parsed.command),
                    workingDirectory: toolInput["cwd"],
                    stdout: parsed.stdout ?? "",
                    stderr: parsed.stderr ?? "",
                    interrupted: parserResult.isInterrupted,
                    isImage: false,
                    returnCodeInterpretation: parsed.exitCode.map { "Exit code: \($0)" },
                    backgroundTaskId: parsed.sessionId
                )
            )
            return (parserResult, structured)

        case "BashOutput":
            guard let rawOutput else { return (nil, nil) }
            let parsed = parseCodexCommandOutput(rawOutput)
            let parserResult = ConversationParser.ToolResult(
                content: parsed.output,
                stdout: parsed.stdout,
                stderr: parsed.stderr,
                isError: parsed.exitCode.map { $0 != 0 } ?? false
            )
            let structured = ToolResultData.bashOutput(
                BashOutputResult(
                    shellId: parsed.sessionId ?? toolInput["session_id"] ?? "codex-shell",
                    status: parsed.sessionId == nil ? "completed" : "running",
                    stdout: parsed.stdout ?? "",
                    stderr: parsed.stderr ?? "",
                    stdoutLines: lineCount(parsed.stdout),
                    stderrLines: lineCount(parsed.stderr),
                    exitCode: parsed.exitCode,
                    command: toolInput["chars"] ?? toolInput["command"],
                    timestamp: nil
                )
            )
            return (parserResult, structured)

        case "Patch":
            let diff = toolInput["patch"] ?? toolInput["input"] ?? ""
            guard !diff.isEmpty else {
                let parserResult = rawOutput.map {
                    ConversationParser.ToolResult(content: $0, stdout: $0, stderr: nil, isError: false)
                }
                return (parserResult, nil)
            }
            let files = parsePatchFiles(from: diff)
            let summary = rawOutput?.trimmingCharacters(in: .whitespacesAndNewlines)
            let parserResult = ConversationParser.ToolResult(content: summary ?? diff, stdout: summary, stderr: nil, isError: false)
            let structured = ToolResultData.patch(PatchResult(summary: summary, diff: diff, files: files))
            return (parserResult, structured)

        case "request_user_input":
            let structured = toolInput["questions"]
                .flatMap(decodeJSONArray)
                .flatMap(parseAskUserQuestions)
                .map { result in
                    let answers = parseAnswers(
                        from: rawOutput.flatMap(decodeJSONObject),
                        fallbackText: rawOutput,
                        questions: result.questions
                    )
                    return ToolResultData.askUserQuestion(
                        AskUserQuestionResult(questions: result.questions, answers: answers)
                    )
                }
            let text = rawOutput?.trimmingCharacters(in: .whitespacesAndNewlines)
            let parserResult = text.map { ConversationParser.ToolResult(content: $0, stdout: $0, stderr: nil, isError: false) }
            return (parserResult, structured)

        default:
            guard let rawOutput, !rawOutput.isEmpty else { return (nil, nil) }
            let cleaned = cleanANSI(rawOutput).trimmingCharacters(in: .whitespacesAndNewlines)
            let parserResult = ConversationParser.ToolResult(content: cleaned, stdout: cleaned, stderr: nil, isError: false)
            return (parserResult, ToolResultData.generic(GenericResult(rawContent: cleaned, rawData: nil)))
        }
    }

    private static func parseGeminiResult(
        rawToolName: String,
        toolInput: [String: String],
        rawPayload: [String: Any]?
    ) -> (parserResult: ConversationParser.ToolResult?, structuredResult: ToolResultData?) {
        let normalizedName = normalizeToolName(agentId: "gemini", rawName: rawToolName)
        let responseText = rawPayload.flatMap(extractGeminiResponseText)

        switch normalizedName {
        case "Bash":
            guard let responseText else { return (nil, nil) }
            let parserResult = ConversationParser.ToolResult(content: responseText, stdout: responseText, stderr: nil, isError: false)
            let structured = ToolResultData.bash(
                BashResult(
                    command: toolInput["command"],
                    workingDirectory: firstNonEmpty(toolInput["cwd"], toolInput["workdir"]),
                    stdout: responseText,
                    stderr: "",
                    interrupted: false,
                    isImage: false,
                    returnCodeInterpretation: nil,
                    backgroundTaskId: nil
                )
            )
            return (parserResult, structured)

        case "Edit":
            guard let rawPayload else { return (nil, nil) }
            let diffPayload = rawPayload["resultDisplay"] as? [String: Any]
            let diff = stringValue(diffPayload?["fileDiff"]) ?? responseText ?? ""
            let originalContent = stringValue(diffPayload?["originalContent"]) ?? toolInput["old_string"] ?? ""
            let newContent = stringValue(diffPayload?["newContent"]) ?? toolInput["new_string"] ?? ""
            let filePath = stringValue(diffPayload?["filePath"]) ?? toolInput["file_path"] ?? ""
            let parserResult = ConversationParser.ToolResult(content: diff.isEmpty ? responseText : diff, stdout: diff.isEmpty ? responseText : diff, stderr: nil, isError: false)
            let structured = ToolResultData.edit(
                EditResult(
                    filePath: filePath,
                    oldString: originalContent,
                    newString: newContent,
                    replaceAll: toolInput["allow_multiple"] == "true",
                    userModified: false,
                    structuredPatch: nil
                )
            )
            return (parserResult, structured)

        case "Write":
            guard let rawPayload else { return (nil, nil) }
            let diffPayload = rawPayload["resultDisplay"] as? [String: Any]
            let filePath = stringValue(diffPayload?["filePath"]) ?? toolInput["file_path"] ?? ""
            let newContent = stringValue(diffPayload?["newContent"]) ?? toolInput["content"] ?? responseText ?? ""
            let isNewFile = (diffPayload?["isNewFile"] as? Bool) ?? false
            let parserResult = ConversationParser.ToolResult(content: responseText, stdout: responseText, stderr: nil, isError: false)
            let structured = ToolResultData.write(
                WriteResult(
                    type: isNewFile ? .create : .overwrite,
                    filePath: filePath,
                    content: newContent,
                    structuredPatch: nil
                )
            )
            return (parserResult, structured)

        case "request_user_input":
            guard let rawPayload else { return (nil, nil) }
            let questions = (rawPayload["args"] as? [String: Any])?["questions"]
            let result = parseAskUserQuestions(questions)
            let answers = parseGeminiAnswers(from: rawPayload, questions: result?.questions ?? [])
            let structured = result.map { ToolResultData.askUserQuestion(AskUserQuestionResult(questions: $0.questions, answers: answers)) }
            let text = stringValue(rawPayload["resultDisplay"]) ?? responseText
            let parserResult = text.map { ConversationParser.ToolResult(content: $0, stdout: $0, stderr: nil, isError: false) }
            return (parserResult, structured)

        default:
            let text = firstNonEmpty(stringValue(rawPayload?["resultDisplay"]), responseText)
            guard let text else { return (nil, nil) }
            let parserResult = ConversationParser.ToolResult(content: text, stdout: text, stderr: nil, isError: false)
            return (parserResult, ToolResultData.generic(GenericResult(rawContent: text, rawData: rawPayload)))
        }
    }

    private static func parseCodexCommandOutput(_ rawOutput: String) -> (
        command: String?,
        output: String,
        stdout: String?,
        stderr: String?,
        exitCode: Int?,
        sessionId: String?
    ) {
        let cleaned = cleanANSI(rawOutput)
        let command = firstMatch(in: cleaned, pattern: #"(?m)^Command:\s+(.+)$"#)
        let exitCode = firstMatch(in: cleaned, pattern: #"(?m)^Process exited with code (\d+)$"#).flatMap(Int.init)
        let sessionId = firstMatch(in: cleaned, pattern: #"(?m)^Process running with session ID (\d+)$"#)

        let body: String
        if let outputRange = cleaned.range(of: "\nOutput:\n") {
            body = String(cleaned[outputRange.upperBound...])
        } else if let outputRange = cleaned.range(of: "Output:\n") {
            body = String(cleaned[outputRange.upperBound...])
        } else {
            body = cleaned
        }

        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return (command, trimmedBody, trimmedBody.isEmpty ? nil : trimmedBody, nil, exitCode, sessionId)
    }

    private static func extractGeminiResponseText(from rawPayload: [String: Any]) -> String? {
        if let resultDisplay = stringValue(rawPayload["resultDisplay"]) {
            return resultDisplay
        }

        let results = rawPayload["result"] as? [[String: Any]] ?? []
        var parts: [String] = []

        for result in results {
            guard let functionResponse = result["functionResponse"] as? [String: Any],
                  let response = functionResponse["response"] as? [String: Any] else {
                continue
            }

            if let output = stringValue(response["output"]) {
                parts.append(output)
            } else if let error = stringValue(response["error"]) {
                parts.append(error)
            }
        }

        let joined = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func parseGeminiAnswers(from rawPayload: [String: Any], questions: [QuestionItem]) -> [String: String] {
        guard let results = rawPayload["result"] as? [[String: Any]] else { return [:] }

        for result in results {
            guard let functionResponse = result["functionResponse"] as? [String: Any],
                  let response = functionResponse["response"] as? [String: Any],
                  let output = stringValue(response["output"]),
                  let json = decodeJSONObject(output),
                  let answers = json["answers"] as? [String: Any] else {
                continue
            }

            return normalizeAnswers(answers, questions: questions)
        }

        return [:]
    }

    private static func parseAnswers(
        from json: [String: Any]?,
        fallbackText: String?,
        questions: [QuestionItem]
    ) -> [String: String] {
        if let json,
           let answers = json["answers"] {
            if let answersArray = answers as? [Any] {
                return normalizeAnswerArray(answersArray, questions: questions)
            }
            if let answersObject = answers as? [String: Any] {
                return normalizeAnswers(answersObject, questions: questions)
            }
        }

        if questions.count == 1,
           let text = stringValue(fallbackText)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return [questions[0].id: text]
        }

        return [:]
    }

    private static func normalizeAnswers(_ answers: [String: Any], questions: [QuestionItem]) -> [String: String] {
        let questionsById = Dictionary(uniqueKeysWithValues: questions.map { ($0.id, $0) })
        let questionsByText = Dictionary(uniqueKeysWithValues: questions.map { ($0.question, $0) })

        return answers.reduce(into: [String: String]()) { partialResult, item in
            let value = nestedAnswerValue(from: item.value) ?? stringValue(item.value)
            guard let value else { return }

            if let question = questionsById[item.key] ?? questionsByText[item.key] {
                partialResult[question.id] = value
            } else if let index = Int(item.key), questions.indices.contains(index) {
                partialResult[questions[index].id] = value
            }
        }
    }

    private static func normalizeAnswerArray(_ answers: [Any], questions: [QuestionItem]) -> [String: String] {
        answers.enumerated().reduce(into: [String: String]()) { partialResult, item in
            let (index, value) = item
            guard questions.indices.contains(index),
                  let answer = nestedAnswerValue(from: value) ?? stringValue(value) else { return }
            partialResult[questions[index].id] = answer
        }
    }

    private static func nestedAnswerValue(from value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }

        if let answers = object["answers"] as? [Any],
           let first = answers.first,
           let text = stringValue(first) {
            return text
        }

        if let answer = stringValue(object["answer"]) {
            return answer
        }

        return nil
    }

    private static func parsePatchFiles(from diff: String) -> [String] {
        var files: [String] = []

        let patterns = [
            #"(?m)^\*\*\* (?:Update|Add|Delete) File: (.+)$"#,
            #"(?m)^\+\+\+ (?:b/)?(.+)$"#
        ]

        for pattern in patterns {
            let regex = try? NSRegularExpression(pattern: pattern)
            let nsRange = NSRange(diff.startIndex..<diff.endIndex, in: diff)
            let matches = regex?.matches(in: diff, range: nsRange) ?? []
            for match in matches {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: diff) else {
                    continue
                }
                let file = String(diff[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !file.isEmpty, !files.contains(file), file != "/dev/null" {
                    files.append(file)
                }
            }
        }

        return files
    }

    static func decodeJSONObject(_ value: String) -> [String: Any]? {
        guard let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func decodeJSONArray(_ value: String) -> [[String: Any]]? {
        guard let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return json
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.first { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? nil
    }

    private static func lineCount(_ text: String?) -> Int {
        guard let text, !text.isEmpty else { return 0 }
        return text.components(separatedBy: .newlines).count
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanANSI(_ text: String) -> String {
        let pattern = #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
}
