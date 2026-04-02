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
    case bypass  // "Don't ask again" — requires double-check confirmation
}

enum InteractionSubmitMode: Equatable, Sendable {
    case programmatic
    case ttyInjection
    case focusOnly
}

enum InteractionTransport: Equatable, Sendable {
    case hookSocket
    case keyboardFallback
    case tmux
    case tty
    case accessibilityInjection
    case focusFallback
}

enum InteractionResponseCapability: Equatable, Sendable {
    case nativeHookAvailable
    case keyboardFallbackAvailable
    case directTextAvailable
    case detectOnly
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

enum InteractionOrigin: String, Equatable, Sendable {
    case normalizedHook
    case codexParse
    case accessibilityFallback
    case permissionSynthetic
    case historyReplay
}

struct InteractionSubmitResult: Equatable, Sendable {
    let succeeded: Bool
    let confirmed: Bool
    let transport: InteractionTransport?
    let error: String?

    static func success(via transport: InteractionTransport, confirmed: Bool = true) -> InteractionSubmitResult {
        InteractionSubmitResult(succeeded: true, confirmed: confirmed, transport: transport, error: nil)
    }

    static func submittedPendingConfirmation(via transport: InteractionTransport) -> InteractionSubmitResult {
        InteractionSubmitResult(succeeded: true, confirmed: false, transport: transport, error: nil)
    }

    static func failure(_ error: String, transport: InteractionTransport? = nil) -> InteractionSubmitResult {
        InteractionSubmitResult(succeeded: false, confirmed: false, transport: transport, error: error)
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
    let origin: InteractionOrigin
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

    var canSubmitViaHookSocket: Bool {
        transportPreference == .programmaticOnly && origin == .normalizedHook
    }

    var responseCapability: InteractionResponseCapability {
        if canSubmitViaHookSocket {
            return .nativeHookAvailable
        }
        if sourceAgent == "codex",
           origin == .codexParse || origin == .accessibilityFallback {
            return .keyboardFallbackAvailable
        }
        if submitMode == .ttyInjection || submitMode == .programmatic {
            return .directTextAvailable
        }
        return .detectOnly
    }

    var canSubmitDirectly: Bool {
        responseCapability != .detectOnly
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
                origin: .permissionSynthetic,
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
            InteractionOption(id: "allow", label: "Allow", submissionValue: "allow", detail: nil, role: .primary),
            InteractionOption(id: "always_allow", label: "Bypass", submissionValue: "always_allow", detail: "Don't ask again", role: .bypass)
        ]

        return SessionInteractionRequest(
            id: "\(sessionId)-\(permission.toolUseId)",
            sessionId: sessionId,
            toolUseId: permission.toolUseId,
            sourceAgent: agentId,
            origin: .permissionSynthetic,
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
            origin: .historyReplay,
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
            origin: .codexParse,
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
        submitMode: InteractionSubmitMode,
        transportPreference: InteractionTransportPreference = .automatic
    ) -> SessionInteractionRequest? {
        guard let parsedQuestion = parseQuestionsPayload(from: payload) else {
            return nil
        }

        return SessionInteractionRequest(
            id: "\(sessionId)-\(toolUseId)",
            sessionId: sessionId,
            toolUseId: toolUseId,
            sourceAgent: sourceAgent,
            origin: .normalizedHook,
            kind: .singleChoice,
            questions: parsedQuestion,
            preferredOptionId: parsedQuestion.first?.options.first(where: { $0.role == .primary })?.id,
            createdAt: timestamp,
            presentationStyle: .popupThenInline,
            submitMode: submitMode,
            transportPreference: transportPreference,
            submissionEncoding: .optionLabel,
            programmaticStrategy: .none,
            sourceToolInputJSON: encodeToolInputJSON(payload)
        )
    }

    static func fromJSONObjectPayload(
        sessionId: String,
        toolUseId: String,
        payload: [String: Any],
        timestamp: Date,
        sourceAgent: String,
        submitMode: InteractionSubmitMode,
        transportPreference: InteractionTransportPreference = .automatic
    ) -> SessionInteractionRequest? {
        guard let parsedQuestion = parseQuestionsPayload(from: payload) else {
            return nil
        }

        return SessionInteractionRequest(
            id: "\(sessionId)-\(toolUseId)",
            sessionId: sessionId,
            toolUseId: toolUseId,
            sourceAgent: sourceAgent,
            origin: .normalizedHook,
            kind: .singleChoice,
            questions: parsedQuestion,
            preferredOptionId: parsedQuestion.first?.options.first(where: { $0.role == .primary })?.id,
            createdAt: timestamp,
            presentationStyle: .popupThenInline,
            submitMode: submitMode,
            transportPreference: transportPreference,
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
            origin: .normalizedHook,
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
        guard let parsed = parseHeuristicInteraction(from: text) else { return nil }

        return SessionInteractionRequest(
            id: "\(sessionId)-\(interactionId)",
            sessionId: sessionId,
            toolUseId: interactionId,
            sourceAgent: sourceAgent,
            origin: .codexParse,
            kind: .singleChoice,
            questions: parsed.questions,
            preferredOptionId: parsed.questions.first?.options.first(where: { $0.role == .primary })?.id,
            createdAt: timestamp,
            presentationStyle: .popupThenInline,
            submitMode: submitMode,
            transportPreference: .automatic,
            submissionEncoding: parsed.encoding,
            programmaticStrategy: .none,
            sourceToolInputJSON: nil
        )
    }

    /// Attempts accessibility-sourced text first (ground truth), then falls back to hook message.
    /// Both paths apply the same structural validation in parseChoicePrompt().
    static func fromAccessibilityEnrichedHook(
        accessibilityText: String?,
        hookMessage: String?,
        sessionId: String,
        interactionId: String,
        sourceAgent: String,
        timestamp: Date,
        submitMode: InteractionSubmitMode
    ) -> SessionInteractionRequest? {
        // Prefer accessibility text — it's what the user actually sees
        if let axText = accessibilityText {
            if let result = fromHeuristicText(
                sessionId: sessionId, interactionId: interactionId,
                sourceAgent: sourceAgent, text: axText,
                timestamp: timestamp, submitMode: submitMode
            ) {
                return SessionInteractionRequest(
                    id: result.id,
                    sessionId: result.sessionId,
                    toolUseId: result.toolUseId,
                    sourceAgent: result.sourceAgent,
                    origin: .accessibilityFallback,
                    kind: result.kind,
                    questions: result.questions,
                    preferredOptionId: result.preferredOptionId,
                    createdAt: result.createdAt,
                    presentationStyle: result.presentationStyle,
                    submitMode: result.submitMode,
                    transportPreference: result.transportPreference,
                    submissionEncoding: result.submissionEncoding,
                    programmaticStrategy: result.programmaticStrategy,
                    sourceToolInputJSON: result.sourceToolInputJSON
                )
            }
        }
        // Fall back to hook message
        if let hookMsg = hookMessage {
            if let result = fromHeuristicText(
                sessionId: sessionId, interactionId: interactionId,
                sourceAgent: sourceAgent, text: hookMsg,
                timestamp: timestamp, submitMode: submitMode
            ) {
                return SessionInteractionRequest(
                    id: result.id,
                    sessionId: result.sessionId,
                    toolUseId: result.toolUseId,
                    sourceAgent: result.sourceAgent,
                    origin: .accessibilityFallback,
                    kind: result.kind,
                    questions: result.questions,
                    preferredOptionId: result.preferredOptionId,
                    createdAt: result.createdAt,
                    presentationStyle: result.presentationStyle,
                    submitMode: result.submitMode,
                    transportPreference: result.transportPreference,
                    submissionEncoding: result.submissionEncoding,
                    programmaticStrategy: result.programmaticStrategy,
                    sourceToolInputJSON: result.sourceToolInputJSON
                )
            }
        }
        return nil
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

    func orderedProgrammaticAnswers(for responses: [InteractionResponse]) -> [String] {
        let responsesByQuestionId = Dictionary(uniqueKeysWithValues: responses.map { ($0.questionId, $0) })

        return questions.compactMap { question in
            guard let response = responsesByQuestionId[question.id] else {
                return nil
            }

            switch submissionEncoding {
            case .optionValue:
                return response.option.submissionValue
            case .optionLabel:
                return response.option.label
            }
        }
    }

    func simpleProgrammaticUpdatedInput(for responses: [InteractionResponse]) -> [String: Any]? {
        guard !responses.isEmpty else { return nil }

        let responsesByQuestionId = Dictionary(uniqueKeysWithValues: responses.map { ($0.questionId, $0) })

        switch sourceAgent {
        case "codex":
            let answers = questions.reduce(into: [String: Any]()) { partialResult, question in
                guard let response = responsesByQuestionId[question.id] else { return }

                let value: String
                switch submissionEncoding {
                case .optionValue:
                    value = response.option.submissionValue
                case .optionLabel:
                    value = response.option.label
                }

                partialResult[question.id] = ["answers": [value]]
            }
            return answers.isEmpty ? nil : ["answers": answers]

        default:
            let answers = orderedProgrammaticAnswers(for: responses)
            return answers.isEmpty ? nil : ["answers": answers]
        }
    }

    func askUserQuestionResult(for responses: [InteractionResponse]) -> AskUserQuestionResult {
        let responsesByQuestionId = Dictionary(uniqueKeysWithValues: responses.map { ($0.questionId, $0.option.label) })
        let resultQuestions = questions.map { question in
            QuestionItem(
                id: question.id,
                question: question.question,
                header: question.header,
                options: question.options.map { option in
                    QuestionOption(label: option.label, description: option.detail)
                }
            )
        }

        let answers = resultQuestions.reduce(into: [String: String]()) { partialResult, question in
            if let answer = responsesByQuestionId[question.id] {
                partialResult[question.id] = answer
            }
        }

        return AskUserQuestionResult(questions: resultQuestions, answers: answers)
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

    private static func parseHeuristicInteraction(
        from text: String
    ) -> ParsedHeuristicInteraction? {
        if let approvalPrompt = parseApprovalPrompt(from: text) {
            return approvalPrompt
        }

        if let choicePrompt = parseChoicePrompt(from: text) {
            return ParsedHeuristicInteraction(questions: choicePrompt, encoding: inferHeuristicEncoding(from: text))
        }

        return nil
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
            let numbered = line.replacingOccurrences(
                of: #"^[›>→➜]?\s*\d+\.\s+"#,
                with: "",
                options: .regularExpression
            )
            if numbered != line, !numbered.isEmpty {
                return ParsedInteractionOption(label: numbered, detail: nil)
            }

            let bulleted = line.replacingOccurrences(
                of: #"^[›>→➜]?\s*[-*•]\s+"#,
                with: "",
                options: .regularExpression
            )
            if bulleted != line, !bulleted.isEmpty {
                return ParsedInteractionOption(label: bulleted, detail: nil)
            }

            return nil
        }

        guard optionLines.count >= 2, optionLines.count <= 6 else { return nil }

        // Structural: option lines should be short labels, not paragraphs
        let maxOptionLength = optionLines.map(\.label.count).max() ?? 0
        guard maxOptionLength <= 100 else { return nil }

        // Structural: options should make up a meaningful fraction of all lines
        let optionDensity = Double(optionLines.count) / Double(lines.count)
        guard optionDensity >= 0.3 else { return nil }
        let optionLabelSet = Set(optionLines.map(\.label))

        let questionLine = lines.first(where: { line in
            let lower = line.lowercased()
            return line.hasSuffix("?")
                || lower.contains("choose")
                || lower.contains("select")
                || lower.contains("which")
                || lower.contains("pick")
                || lower.contains("how should")
                || lower.contains("would you like")
                || lower.hasPrefix("question ")
        }) ?? lines.first

        guard let question = questionLine, !question.isEmpty else { return nil }

        // Structural: question should be concise
        guard question.count < 200 else { return nil }

        // Structural: question must be adjacent to the option block (within 3 lines)
        if let questionIdx = lines.firstIndex(of: question) {
            let optionIndices = lines.enumerated().compactMap { idx, line -> Int? in
                let stripped = line.replacingOccurrences(
                    of: #"^(\d+\.\s+|[-*•]\s+)"#, with: "", options: .regularExpression
                )
                return optionLabelSet.contains(stripped) ? idx : nil
            }
            if let firstOpt = optionIndices.min(), let lastOpt = optionIndices.max() {
                let dist = min(abs(questionIdx - firstOpt), abs(questionIdx - lastOpt))
                guard dist <= 3 else { return nil }
            }
        }

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

    private static func parseApprovalPrompt(
        from text: String
    ) -> ParsedHeuristicInteraction? {
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cleanedText.lowercased()
        guard lower.contains("would you like to run the following command")
            || lower.contains("approve")
            || lower.contains("allow")
            || lower.contains("permission required") else {
            return nil
        }

        let lines = cleanedText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let question = lines.first(where: { line in
            let lower = line.lowercased()
            return lower.contains("would you like to run the following command")
                || lower.contains("allow ")
                || lower.contains("approve ")
                || lower.contains("permission required")
        }) ?? "Allow this command to run?"

        var detailLines: [String] = []
        if let reasonLine = lines.first(where: { $0.lowercased().hasPrefix("reason:") }) {
            detailLines.append(reasonLine)
        }
        if let commandIndex = lines.firstIndex(where: { $0.hasPrefix("$ ") }) {
            detailLines.append(contentsOf: lines[commandIndex...].prefix(8))
        }
        let detail = detailLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        let options: [InteractionOption] = [
            InteractionOption(id: "allow", label: "Allow", submissionValue: "allow", detail: detail.isEmpty ? nil : detail, role: .primary),
            InteractionOption(id: "deny", label: "Deny", submissionValue: "deny", detail: nil, role: .destructive),
            InteractionOption(id: "always_allow", label: "Bypass", submissionValue: "always_allow", detail: "Don't ask again", role: .bypass)
        ]

        let interactionQuestion = InteractionQuestion(
            id: "approval-0",
            header: "Permission required",
            question: question,
            options: options
        )
        return ParsedHeuristicInteraction(questions: [interactionQuestion], encoding: .optionValue)
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
            if normalizedLabel.contains("bypass") {
                role = .bypass
            } else if normalizedLabel.contains("deny")
                || normalizedLabel.contains("reject")
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

private struct ParsedHeuristicInteraction {
    let questions: [InteractionQuestion]
    let encoding: InteractionSubmissionEncoding
}

private struct ParsedInteractionQuestion {
    let id: String
    let header: String?
    let question: String
    let options: [ParsedInteractionOption]
}
