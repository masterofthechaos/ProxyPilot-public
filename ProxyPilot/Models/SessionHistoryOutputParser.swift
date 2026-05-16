import Foundation
import ProxyPilotCore

enum SessionHistoryParsedOutputKind: Equatable {
    case assistantResponse
    case toolCallOnly
    case rawStructure
}

struct SessionHistoryParsedToolCall: Equatable, Identifiable {
    let id: String
    let name: String
    let inputPreview: String
}

struct SessionHistoryParsedOutput: Equatable {
    let kind: SessionHistoryParsedOutputKind
    let assistantText: String
    let toolCalls: [SessionHistoryParsedToolCall]
    let hasMalformedData: Bool

    var summary: String {
        switch kind {
        case .assistantResponse:
            return "Assistant response"
        case .toolCallOnly:
            return "Tool call only"
        case .rawStructure:
            return "Raw structure"
        }
    }
}

enum SessionHistoryOutputParser {
    static func parse(_ content: InputOutputLogContent) -> SessionHistoryParsedOutput {
        parse(content.sessionHistoryText)
    }

    static func parse(_ rawOutput: String) -> SessionHistoryParsedOutput {
        let blocks = rawOutput
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var assistantText = ""
        var toolCalls: [ToolAccumulator] = []
        var activeToolIndex: Int?
        // OpenAI streams a single tool call across many SSE chunks keyed by
        // `choices[].delta.tool_calls[].index`. Continuation chunks omit `id`
        // and `function.name` and carry only the next slice of arguments.
        // The map remembers which `toolCalls` offset corresponds to each
        // streaming index so we can append to the right accumulator instead
        // of producing one ghost row per chunk.
        var openAIDeltaIndexMap: [Int: Int] = [:]
        var malformedData = false
        var sawStructuredPayload = false

        for block in blocks {
            let payload = payloadData(from: block)
            let candidate = payload.isEmpty ? block : payload
            guard !candidate.isEmpty, candidate != "[DONE]" else { continue }
            guard let jsonData = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                if !payload.isEmpty {
                    malformedData = true
                }
                continue
            }
            sawStructuredPayload = true

            parse(
                object,
                assistantText: &assistantText,
                toolCalls: &toolCalls,
                activeToolIndex: &activeToolIndex,
                openAIDeltaIndexMap: &openAIDeltaIndexMap
            )
        }

        let parsedToolCalls = toolCalls.map(\.parsed)
        let trimmedText = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: SessionHistoryParsedOutputKind
        if !trimmedText.isEmpty {
            kind = .assistantResponse
        } else if !parsedToolCalls.isEmpty {
            kind = .toolCallOnly
        } else {
            kind = .rawStructure
        }

        return SessionHistoryParsedOutput(
            kind: sawStructuredPayload ? kind : .rawStructure,
            assistantText: assistantText,
            toolCalls: parsedToolCalls,
            hasMalformedData: malformedData
        )
    }

    private static func parse(
        _ object: [String: Any],
        assistantText: inout String,
        toolCalls: inout [ToolAccumulator],
        activeToolIndex: inout Int?,
        openAIDeltaIndexMap: inout [Int: Int]
    ) {
        switch object["type"] as? String {
        case "content_block_start":
            guard let contentBlock = object["content_block"] as? [String: Any] else { return }
            if contentBlock["type"] as? String == "tool_use" {
                let tool = ToolAccumulator(
                    id: contentBlock["id"] as? String ?? UUID().uuidString,
                    name: contentBlock["name"] as? String ?? "Tool",
                    inputJSON: compactJSONString(from: contentBlock["input"])
                )
                toolCalls.append(tool)
                activeToolIndex = toolCalls.indices.last
            } else if let text = contentBlock["text"] as? String {
                assistantText += text
            }

        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any] else { return }
            if delta["type"] as? String == "text_delta" {
                assistantText += delta["text"] as? String ?? ""
            } else if delta["type"] as? String == "input_json_delta",
                      let index = activeToolIndex,
                      toolCalls.indices.contains(index) {
                toolCalls[index].inputJSON += delta["partial_json"] as? String ?? ""
            }

        case "content_block_stop":
            activeToolIndex = nil

        default:
            break
        }

        if let content = object["content"] as? [[String: Any]] {
            for item in content {
                if item["type"] as? String == "text" {
                    assistantText += item["text"] as? String ?? ""
                } else if item["type"] as? String == "tool_use" {
                    toolCalls.append(ToolAccumulator(
                        id: item["id"] as? String ?? UUID().uuidString,
                        name: item["name"] as? String ?? "Tool",
                        inputJSON: compactJSONString(from: item["input"])
                    ))
                }
            }
        }

        guard let choices = object["choices"] as? [[String: Any]] else { return }
        for choice in choices {
            if let message = choice["message"] as? [String: Any] {
                assistantText += message["content"] as? String ?? ""
                // Non-streaming `message.tool_calls`: each entry is a
                // complete tool call. Append each as its own row.
                appendOpenAIMessageToolCalls(from: message, to: &toolCalls)
            }
            if let delta = choice["delta"] as? [String: Any] {
                assistantText += delta["content"] as? String ?? ""
                // Streaming `delta.tool_calls`: chunks keyed by `index`.
                // Use the map to coalesce continuation chunks into the
                // existing accumulator.
                appendOpenAIDeltaToolCalls(
                    from: delta,
                    to: &toolCalls,
                    deltaIndexMap: &openAIDeltaIndexMap
                )
            }
        }
    }

    private static func payloadData(from block: String) -> String {
        block
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                guard line.hasPrefix("data:") else { return nil }
                return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
    }

    private static func appendOpenAIMessageToolCalls(
        from object: [String: Any],
        to toolCalls: inout [ToolAccumulator]
    ) {
        guard let calls = object["tool_calls"] as? [[String: Any]] else { return }
        for call in calls {
            let function = call["function"] as? [String: Any]
            toolCalls.append(ToolAccumulator(
                id: call["id"] as? String ?? UUID().uuidString,
                name: function?["name"] as? String ?? "Tool",
                inputJSON: function?["arguments"] as? String ?? ""
            ))
        }
    }

    private static func appendOpenAIDeltaToolCalls(
        from object: [String: Any],
        to toolCalls: inout [ToolAccumulator],
        deltaIndexMap: inout [Int: Int]
    ) {
        guard let calls = object["tool_calls"] as? [[String: Any]] else { return }
        for call in calls {
            let function = call["function"] as? [String: Any]
            let chunkArguments = function?["arguments"] as? String ?? ""

            guard let chunkIndex = openAIToolCallIndex(call) else {
                // Streaming chunk without an `index` field (rare; older
                // OpenAI-compatible providers). Preserve the prior behavior
                // of appending each as a complete row.
                toolCalls.append(ToolAccumulator(
                    id: call["id"] as? String ?? UUID().uuidString,
                    name: function?["name"] as? String ?? "Tool",
                    inputJSON: chunkArguments
                ))
                continue
            }

            if let existing = deltaIndexMap[chunkIndex],
               toolCalls.indices.contains(existing) {
                // Continuation chunk for a tool call we have already
                // seen — append the argument slice instead of producing
                // another placeholder row.
                toolCalls[existing].inputJSON += chunkArguments
                // First chunk usually carries id+name; later chunks
                // typically omit them. If a later chunk supplies a real id
                // and the existing slot held a synthesized UUID, prefer the
                // real id. Same for a placeholder name.
                if let realID = call["id"] as? String,
                   toolCalls[existing].id != realID,
                   toolCalls[existing].id.count == UUID().uuidString.count {
                    toolCalls[existing].id = realID
                }
                if toolCalls[existing].name == "Tool",
                   let realName = function?["name"] as? String,
                   !realName.isEmpty {
                    toolCalls[existing].name = realName
                }
            } else {
                toolCalls.append(ToolAccumulator(
                    id: call["id"] as? String ?? UUID().uuidString,
                    name: function?["name"] as? String ?? "Tool",
                    inputJSON: chunkArguments
                ))
                deltaIndexMap[chunkIndex] = toolCalls.indices.last
            }
        }
    }

    private static func openAIToolCallIndex(_ call: [String: Any]) -> Int? {
        if let direct = call["index"] as? Int { return direct }
        if let number = call["index"] as? NSNumber { return number.intValue }
        return nil
    }

    private static func compactJSONString(from value: Any?) -> String {
        guard let value else { return "" }
        if let dictionary = value as? [String: Any], dictionary.isEmpty {
            return ""
        }
        if let array = value as? [Any], array.isEmpty {
            return ""
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return string
    }
}

private struct ToolAccumulator {
    var id: String
    var name: String
    var inputJSON = ""

    var parsed: SessionHistoryParsedToolCall {
        SessionHistoryParsedToolCall(
            id: id,
            name: name,
            inputPreview: inputJSON
        )
    }
}
