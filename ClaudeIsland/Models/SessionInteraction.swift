//
//  SessionInteraction.swift
//  ClaudeIsland
//
//  Shared interaction models derived from agent requests.
//

import Foundation

enum InteractionPresentationStyle: Equatable, Sendable {
    case popupThenInline
}

enum InteractionKind: Equatable, Sendable {
    case singleChoice
}

enum InteractionOptionRole: Equatable, Sendable {
    case primary
    case secondary
    case destructive
}

enum InteractionSubmitMode: Equatable, Sendable {
    case programmatic
    case ttyInjection
    case focusOnly
}

enum InteractionTransport: Equatable, Sendable {
    case hookSocket
    case tmux
    case tty
    case accessibilityInjection
    case focusFallback
}

enum InteractionTransportPreference: Equatable, Sendable {
    case automatic
    case programmaticOnly
}

enum InteractionSubmissionEncoding: Equatable, Sendable {
    case optionValue
    case optionLabel
}

enum InteractionProgrammaticStrategy: Equatable, Sendable {
    case none
    case claudeAskUserQuestion
}

struct InteractionSubmitResult: Equatable, Sendable {
    let succeeded: Bool
    let transport: InteractionTransport?
    let error: String?

    static func success(via transport: InteractionTransport) -> InteractionSubmitResult {
        InteractionSubmitResult(succeeded: true, transport: transport, error: nil)
    }

    static func failure(_ error: String, transport: InteractionTransport? = nil) -> InteractionSubmitResult {
        InteractionSubmitResult(succeeded: false, transport: transport, error: error)
    }
}

struct InteractionOption: Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let submissionValue: String
    let detail: String?
    let role: InteractionOptionRole
}

struct InteractionQuestion: Equatable, Identifiable, Sendable {
    let id: String
    let header: String?
    let question: String
    let options: [InteractionOption]
}

struct InteractionResponse: Equatable, Identifiable, Sendable {
    let questionId: String
    let option: InteractionOption

    var id: String { "\(questionId)-\(option.id)" }
}

struct SessionInteractionRequest: Equatable, Identifiable, Sendable {
    let id: String
    let sessionId: String
    let toolUseId: String?
    let sourceAgent: String
    let kind: InteractionKind
    let questions: [InteractionQuestion]
    let preferredOptionId: String?
    let createdAt: Date
    let presentationStyle: InteractionPresentationStyle
    let submitMode: InteractionSubmitMode
    let transportPreference: InteractionTransportPreference
    let submissionEncoding: InteractionSubmissionEncoding
    let programmaticStrategy: InteractionProgrammaticStrategy
    let sourceToolInputJSON: String?

    var title: String {
        if let firstHeader = questions.first?.header, !firstHeader.isEmpty {
            return firstHeader
        }
        return questions.count > 1 ? "Answer \(questions.count) questions" : "Choose an option"
    }

    var question: String {
        questions.first?.question ?? ""
    }

    var options: [InteractionOption] {
        questions.first?.options ?? []
    }

    var isMultiQuestion: Bool {
        questions.count > 1
    }
}

struct InteractionPopState: Equatable, Identifiable, Sendable {
    let sessionId: String
    let interaction: SessionInteractionRequest
    let createdAt: Date

    var id: String { interaction.id }
}

extension SessionInteractionRequest {
    static func submitMode(isInTmux: Bool, tty: String?) -> InteractionSubmitMode {
        if tty != nil {
            return .ttyInjection
        }
        return .focusOnly
    }

    static func from(
        permission: PermissionContext,
        sessionId: String,
        agentId: String,
        submitMode: InteractionSubmitMode
    ) -> SessionInteractionRequest? {
        if permission.toolName == "AskUserQuestion",
           let toolInput = permission.toolInput,
           let parsedQuestion = parseQuestionsPayload(from: toolInput) {
            return SessionInteractionRequest(
                id: "\(sessionId)-\(permission.toolUseId)",
                sessionId: sessionId,
                toolUseId: permission.toolUseId,
                sourceAgent: agentId,
                kind: .singleChoice,
                questions: parsedQuestion,
                preferredOptionId: parsedQuestion.first?.options.first(where: { $0.role == .primary })?.id,
                createdAt: permission.receivedAt,
                presentationStyle: .popupThenInline,
                submitMode: .programmatic,
                transportPreference: .programmaticOnly,
                submissionEncoding: .optionLabel,
                programmaticStrategy: .claudeAskUserQuestion,
                sourceToolInputJSON: encodeToolInputJSON(toolInput)
            )
        }

        let prompt = permission.formattedInput?.isEmpty == false
            ? "Allow \(permission.toolName) to run?\n\(permission.formattedInput!)"
            : "Allow \(permission.toolName) to run?"
        let options: [InteractionOption] = [
            InteractionOption(id: "deny", label: "Deny", submissionValue: "deny", detail: nil, role: .destructive),
            InteractionOption(id: "allow", label: "Allow", submissionValue: "allow", detail: nil, role: .primary)
        ]

        return SessionInteractionRequest(
            id: "\(sessionId)-\(permission.toolUseId)",
            sessionId: sessionId,
            toolUseId: permission.toolUseId,
            sourceAgent: agentId,
            kind: .singleChoice,
            questions: [
                InteractionQuestion(
                    id: "permission-\(permission.toolUseId)",
                    header: "Permission required",
                    question: prompt,
                    options: options
                )
            ],
            preferredOptionId: "allow",
            createdAt: permission.receivedAt,
            presentationStyle: .popupThenInline,
            submitMode: .programmatic,
            transportPreference: .programmaticOnly,
            submissionEncoding: .optionValue,
            programmaticStrategy: .none,
            sourceToolInputJSON: nil
        )
    }

    static func from(
        askUserQuestionResult: AskUserQuestionResult,
        sessionId: String,
        toolUseId: String,
        createdAt: Date,
        agentId: String,
        submitMode: InteractionSubmitMode
    ) -> SessionInteractionRequest? {
        let questions = buildQuestions(from: askUserQuestionResult.questions.enumerated().map { index, question in
            ParsedInteractionQuestion(
                id: "question-\(index)",
                header: question.header,
                question: question.question,
                options: question.options.map {
                    ParsedInteractionOption(label: $0.label, detail: $0.description)
                }
            )
        })

        guard !questions.isEmpty else {
            return nil
        }

        return SessionInteractionRequest(
            id: "\(sessionId)-\(toolUseId)",
            sessionId: sessionId,
            toolUseId: toolUseId,
            sourceAgent: agentId,
            kind: .singleChoice,
            questions: questions,
            preferredOptionId: questions.first?.options.first(where: { $0.role == .primary })?.id,
            createdAt: createdAt,
            presentationStyle: .popupThenInline,
            submitMode: submitMode,
            transportPreference: .automatic,
            submissionEncoding: .optionLabel,
            programmaticStrategy: .none,
            sourceToolInputJSON: nil
        )
    }

    static func fromCodexRequestUserInput(
        sessionId: String,
        callId: String,
        arguments: String,
        timestamp: Date,
        sourceAgent: String = "codex",
        submitMode: InteractionSubmitMode
    ) -> SessionInteractionRequest? {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parsedQuestion = parseQuestionsPayload(from: json) else {
            return nil
        }

        return SessionInteractionRequest(
            id: "\(sessionId)-\(callId)",
            sessionId: sessionId,
            toolUseId: callId,
            sourceAgent: sourceAgent,
            kind: .singleChoice,
            questions: parsedQuestion,
            preferredOptionId: parsedQuestion.first?.options.first(where: { $0.role == .primary })?.id,
            createdAt: timestamp,
            presentationStyle: .popupThenInline,
            submitMode: submitMode,
            transportPreference: .automatic,
            submissionEncoding: .optionLabel,
            programmaticStrategy: .none,
            sourceToolInputJSON: arguments
        )
    }

    static func fromToolInputPayload(
        sessionId: String,
        toolUseId: String,
        payload: [String: AnyCodable],
        timestamp: Date,
        sourceAgent: String,
        submitMode: InteractionSubmitMode
    ) -> SessionInteractionRequest? {
        guard let parsedQuestion = parseQuestionsPayload(from: payload) else {
            return nil
        }

        return SessionInteractionRequest(
            id: "\(sessionId)-\(toolUseId)",
            sessionId: sessionId,
            toolUseId: toolUseId,
            sourceAgent: sourceAgent,
            kind: .singleChoice,
            questions: parsedQuestion,
            preferredOptionId: parsedQuestion.first?.options.first(where: { $0.role == .primary })?.id,
            createdAt: timestamp,
            presentationStyle: .popupThenInline,
            submitMode: submitMode,
            transportPreference: .automatic,
            submissionEncoding: .optionLabel,
            programmaticStrategy: .none,
            sourceToolInputJSON: encodeToolInputJSON(payload)
        )
    }

    static func fromClaudeAskUserQuestion(
        sessionId: String,
        toolUseId: String,
        payload: [String: AnyCodable],
        timestamp: Date,
        sourceAgent: String,
        submitMode _: InteractionSubmitMode
    ) -> SessionInteractionRequest? {
        guard let parsedQuestion = parseQuestionsPayload(from: payload) else {
            return nil
        }

        return SessionInteractionRequest(
            id: "\(sessionId)-\(toolUseId)",
            sessionId: sessionId,
            toolUseId: toolUseId,
            sourceAgent: sourceAgent,
            kind: .singleChoice,
            questions: parsedQuestion,
            preferredOptionId: parsedQuestion.first?.options.first(where: { $0.role == .primary })?.id,
            createdAt: timestamp,
            presentationStyle: .popupThenInline,
            submitMode: .programmatic,
            transportPreference: .programmaticOnly,
            submissionEncoding: .optionLabel,
            programmaticStrategy: .claudeAskUserQuestion,
            sourceToolInputJSON: encodeToolInputJSON(payload)
        )
    }

    static func fromHeuristicText(
        sessionId: String,
        interactionId: String,
        sourceAgent: String,
        text: String,
        timestamp: Date,
        submitMode: InteractionSubmitMode
    ) -> SessionInteractionRequest? {
        guard let parsed = parseChoicePrompt(from: text) else { return nil }

        return SessionInteractionRequest(
            id: "\(sessionId)-\(interactionId)",
            sessionId: sessionId,
            toolUseId: interactionId,
            sourceAgent: sourceAgent,
            kind: .singleChoice,
            questions: parsed,
            preferredOptionId: parsed.first?.options.first(where: { $0.role == .primary })?.id,
            createdAt: timestamp,
            presentationStyle: .popupThenInline,
            submitMode: submitMode,
            transportPreference: .automatic,
            submissionEncoding: inferHeuristicEncoding(from: text),
            programmaticStrategy: .none,
            sourceToolInputJSON: nil
        )
    }

    func programmaticUpdatedInput(for responses: [InteractionResponse]) -> [String: Any]? {
        switch programmaticStrategy {
        case .none:
            return nil
        case .claudeAskUserQuestion:
            guard !responses.isEmpty else { return nil }

            let questionsById = Dictionary(uniqueKeysWithValues: questions.map { ($0.id, $0) })
            var updatedInput = decodedToolInputPayload() ?? serializedQuestionsPayload()
            var answers: [String: String] = [:]

            for response in responses {
                guard let question = questionsById[response.questionId] else { continue }
                answers[question.question] = response.option.label
            }

            guard !answers.isEmpty else { return nil }
            updatedInput["answers"] = answers
            return updatedInput
        }
    }

    private static func parseQuestionsPayload(
        from toolInput: [String: AnyCodable]
    ) -> [InteractionQuestion]? {
        let plainObject = toolInput.reduce(into: [String: Any]()) { partialResult, item in
            partialResult[item.key] = item.value.value
        }
        return parseQuestionsPayload(from: plainObject)
    }

    private static func encodeToolInputJSON(_ payload: [String: AnyCodable]) -> String? {
        guard let data = try? JSONEncoder().encode(payload) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func encodeToolInputJSON(_ payload: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func parseQuestionsPayload(
        from payload: [String: Any]
    ) -> [InteractionQuestion]? {
        guard let rawQuestions = payload["questions"] as? [[String: Any]] else {
            return nil
        }

        let questions = buildQuestions(from: rawQuestions.enumerated().compactMap { index, rawQuestion in
            guard let questionText = rawQuestion["question"] as? String else { return nil }

            let rawOptions = (rawQuestion["options"] as? [[String: Any]] ?? []).compactMap { optionDict -> ParsedInteractionOption? in
                guard let label = optionDict["label"] as? String else { return nil }
                return ParsedInteractionOption(
                    label: label,
                    detail: optionDict["description"] as? String
                )
            }

            return ParsedInteractionQuestion(
                id: (rawQuestion["id"] as? String) ?? "question-\(index)",
                header: rawQuestion["header"] as? String,
                question: questionText,
                options: rawOptions
            )
        })

        guard !questions.isEmpty else { return nil }
        return questions
    }

    private static func parseChoicePrompt(
        from text: String
    ) -> [InteractionQuestion]? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count >= 3 else { return nil }

        let optionLines = lines.compactMap { line -> ParsedInteractionOption? in
            let numbered = line.replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
            if numbered != line, !numbered.isEmpty {
                return ParsedInteractionOption(label: numbered, detail: nil)
            }

            let bulleted = line.replacingOccurrences(of: #"^[-*•]\s+"#, with: "", options: .regularExpression)
            if bulleted != line, !bulleted.isEmpty {
                return ParsedInteractionOption(label: bulleted, detail: nil)
            }

            return nil
        }

        guard optionLines.count >= 2, optionLines.count <= 6 else { return nil }

        let questionLine = lines.first(where: { line in
            let lower = line.lowercased()
            return line.hasSuffix("?")
                || lower.contains("choose")
                || lower.contains("select")
                || lower.contains("which")
                || lower.contains("pick")
                || lower.contains("how should")
        }) ?? lines.first

        guard let question = questionLine, !question.isEmpty else { return nil }

        let options = buildOptions(from: optionLines)
        guard !options.isEmpty else { return nil }

        return [
            InteractionQuestion(
                id: "question-0",
                header: nil,
                question: question,
                options: options
            )
        ]
    }

    private static func buildQuestions(from rawQuestions: [ParsedInteractionQuestion]) -> [InteractionQuestion] {
        rawQuestions.compactMap { rawQuestion in
            let options = buildOptions(from: rawQuestion.options)
            guard !options.isEmpty else { return nil }
            return InteractionQuestion(
                id: rawQuestion.id,
                header: rawQuestion.header,
                question: rawQuestion.question,
                options: options
            )
        }
    }

    private static func inferHeuristicEncoding(from text: String) -> InteractionSubmissionEncoding {
        let lower = text.lowercased()
        if lower.contains("type exact")
            || lower.contains("reply with the exact")
            || lower.contains("enter the exact")
            || lower.contains("type the exact") {
            return .optionLabel
        }

        return .optionValue
    }

    private static func buildOptions(from rawOptions: [ParsedInteractionOption]) -> [InteractionOption] {
        rawOptions.enumerated().compactMap { index, option -> InteractionOption? in
            let trimmedLabel = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLabel.isEmpty else { return nil }

            let normalizedLabel = trimmedLabel.lowercased()
            let role: InteractionOptionRole
            if normalizedLabel.contains("deny")
                || normalizedLabel.contains("reject")
                || normalizedLabel.contains("bypass")
                || normalizedLabel.contains("cancel")
                || normalizedLabel.contains("skip") {
                role = .destructive
            } else if index == 0 {
                role = .primary
            } else {
                role = .secondary
            }

            return InteractionOption(
                id: "\(index)-\(trimmedLabel)",
                label: trimmedLabel.replacingOccurrences(of: "(Recommended)", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                submissionValue: String(index + 1),
                detail: option.detail,
                role: role
            )
        }
    }

    private func decodedToolInputPayload() -> [String: Any]? {
        guard let sourceToolInputJSON,
              let data = sourceToolInputJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return json
    }

    private func serializedQuestionsPayload() -> [String: Any] {
        let serializedQuestions = questions.map { question -> [String: Any] in
            var result: [String: Any] = [
                "id": question.id,
                "question": question.question,
                "multiSelect": false,
                "options": question.options.map { option -> [String: Any] in
                    var optionResult: [String: Any] = ["label": option.label]
                    if let detail = option.detail {
                        optionResult["description"] = detail
                    }
                    return optionResult
                }
            ]

            if let header = question.header {
                result["header"] = header
            }

            return result
        }

        return ["questions": serializedQuestions]
    }
}

private struct ParsedInteractionOption {
    let label: String
    let detail: String?
}

private struct ParsedInteractionQuestion {
    let id: String
    let header: String?
    let question: String
    let options: [ParsedInteractionOption]
}
