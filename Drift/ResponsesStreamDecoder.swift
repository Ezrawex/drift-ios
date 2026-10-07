import Foundation

/// Incrementally decodes one Responses API SSE stream and returns the completed
/// response's single assistant text part as UTF-8 JSON data.
///
/// The decoded JSON is intended for `ValidatedCloudSelector.validate` and is
/// never exposed until a valid `response.completed` event has been received.
struct ResponsesStreamDecoder: Sendable {
    enum Failure: Error, Equatable {
        case streamTooLarge
        case eventTooLarge
        case outputTooLarge
        case malformedSSE
        case malformedEvent
        case unsupportedEvent(String)
        case streamAlreadyFinished
        case terminalMissing
        case provider(code: String?, parameter: String?)
        case responseIncomplete
        case refusal
        case ambiguousOutput
        case deltaMismatch
    }

    let maximumTotalBytes: Int
    let maximumEventBytes: Int
    let maximumOutputBytes: Int

    private(set) var receivedBytes = 0
    private var line = Data()
    private var eventByteCount = 0
    private var eventName: String?
    private var dataLines: [String] = []
    private var firstLine = true
    private var finished = false
    private var terminalBody: Data?
    private var textDeltas = Data()
    private var sawTextDelta = false
    private var deltaOutputIndex: Int?
    private var textDone = false
    private var finalizedText: Data?
    private var finalizedOutputIndex: Int?

    var isComplete: Bool { terminalBody != nil }

    init(maximumTotalBytes: Int = 4 * 1_024 * 1_024,
         maximumEventBytes: Int = 1 * 1_024 * 1_024,
         maximumOutputBytes: Int = 1 * 1_024 * 1_024) {
        self.maximumTotalBytes = max(0, maximumTotalBytes)
        self.maximumEventBytes = max(0, maximumEventBytes)
        self.maximumOutputBytes = max(0, maximumOutputBytes)
    }

    mutating func append(_ bytes: Data) throws {
        guard !finished else { throw Failure.streamAlreadyFinished }
        guard bytes.count <= maximumTotalBytes - receivedBytes else { throw Failure.streamTooLarge }
        receivedBytes += bytes.count

        for byte in bytes {
            eventByteCount += 1
            guard eventByteCount <= maximumEventBytes else { throw Failure.eventTooLarge }
            if byte == 0x0A {
                try consumeLine()
            } else {
                line.append(byte)
            }
        }
    }

    mutating func finish() throws -> Data {
        guard !finished else { throw Failure.streamAlreadyFinished }
        finished = true
        // SSE dispatch requires the terminating empty line. WHATWG discards
        // unfinished line/event buffers at EOF rather than dispatching them.
        guard let body = terminalBody else { throw Failure.terminalMissing }
        return body
    }

    private mutating func consumeLine() throws {
        var bytes = line
        line.removeAll(keepingCapacity: true)
        if bytes.last == 0x0D { bytes.removeLast() }
        guard var value = String(data: bytes, encoding: .utf8) else { throw Failure.malformedSSE }
        if firstLine {
            firstLine = false
            if value.hasPrefix("\u{FEFF}") { value.removeFirst() }
        }
        if value.isEmpty {
            try dispatchEvent()
            eventByteCount = 0
            return
        }
        if value.first == ":" { return } // SSE comment / keep-alive.

        let split = value.firstIndex(of: ":")
        let field = split.map { String(value[..<$0]) } ?? value
        var fieldValue = split.map { String(value[value.index(after: $0)...]) } ?? ""
        if fieldValue.first == " " { fieldValue.removeFirst() }
        switch field {
        case "event": eventName = fieldValue
        case "data": dataLines.append(fieldValue)
        default: break // SSE fields such as id and retry do not affect decoding.
        }
    }

    private mutating func dispatchEvent() throws {
        guard !dataLines.isEmpty else {
            eventName = nil
            return
        }
        guard terminalBody == nil else { throw Failure.malformedEvent }
        let jsonData = Data(dataLines.joined(separator: "\n").utf8)
        dataLines.removeAll(keepingCapacity: true)
        let parsed: Any
        do { parsed = try JSONSerialization.jsonObject(with: jsonData) }
        catch { throw Failure.malformedEvent }
        guard let object = parsed as? [String: Any], let type = object["type"] as? String else {
            throw Failure.malformedEvent
        }
        if let eventName, !eventName.isEmpty, eventName != type { throw Failure.malformedEvent }
        eventName = nil

        switch type {
        case "error":
            throw Failure.provider(code: object["code"] as? String, parameter: object["param"] as? String)
        case "response.failed", "response.cancelled":
            let response = object["response"] as? [String: Any]
            let error = response?["error"] as? [String: Any]
            throw Failure.provider(code: error?["code"] as? String, parameter: error?["param"] as? String)
        case "response.incomplete":
            throw Failure.responseIncomplete
        case "response.refusal.delta", "response.refusal.done":
            throw Failure.refusal
        case "response.output_text.delta":
            guard let delta = object["delta"] as? String,
                  let outputIndex = object["output_index"] as? Int, outputIndex >= 0,
                  (object["content_index"] as? Int ?? 0) == 0,
                  !textDone else { throw Failure.ambiguousOutput }
            if let deltaOutputIndex, deltaOutputIndex != outputIndex { throw Failure.ambiguousOutput }
            deltaOutputIndex = outputIndex
            sawTextDelta = true
            textDeltas.append(contentsOf: delta.utf8)
            guard textDeltas.count <= maximumOutputBytes else { throw Failure.outputTooLarge }
        case "response.output_text.done":
            guard let finalDeltaText = object["text"] as? String,
                  let outputIndex = object["output_index"] as? Int, outputIndex >= 0,
                  (object["content_index"] as? Int ?? 0) == 0,
                  !textDone else { throw Failure.malformedEvent }
            if let deltaOutputIndex, deltaOutputIndex != outputIndex { throw Failure.ambiguousOutput }
            let finalData = Data(finalDeltaText.utf8)
            if sawTextDelta && finalData != textDeltas { throw Failure.deltaMismatch }
            guard finalData.count <= maximumOutputBytes else { throw Failure.outputTooLarge }
            textDone = true
            finalizedText = finalData
            finalizedOutputIndex = outputIndex
        case "response.output_item.added", "response.output_item.done":
            guard let item = object["item"] as? [String: Any],
                  let itemType = item["type"] as? String,
                  ["message", "reasoning"].contains(itemType),
                  let outputIndex = object["output_index"] as? Int, outputIndex >= 0 else { throw Failure.ambiguousOutput }
        case "response.content_part.added", "response.content_part.done":
            guard let part = object["part"] as? [String: Any],
                  part["type"] as? String == "output_text",
                  let outputIndex = object["output_index"] as? Int, outputIndex >= 0,
                  (object["content_index"] as? Int ?? 0) == 0 else { throw Failure.ambiguousOutput }
        case "response.completed":
            guard let response = object["response"] as? [String: Any] else { throw Failure.malformedEvent }
            let status = response["status"] as? String
            if status == "failed" || status == "cancelled" {
                let error = response["error"] as? [String: Any]
                throw Failure.provider(code: error?["code"] as? String, parameter: error?["param"] as? String)
            }
            guard status == "completed" else { throw Failure.responseIncomplete }
            if let error = response["error"], !(error is NSNull) {
                let details = error as? [String: Any]
                throw Failure.provider(code: details?["code"] as? String, parameter: details?["param"] as? String)
            }
            if let incomplete = response["incomplete_details"], !(incomplete is NSNull) { throw Failure.responseIncomplete }
            guard let output = response["output"] as? [[String: Any]],
                  output.allSatisfy({ ["message", "reasoning"].contains($0["type"] as? String ?? "") }),
                  output.filter({ $0["type"] as? String == "message" }).count == 1,
                  let messageIndex = output.firstIndex(where: { $0["type"] as? String == "message" }) else {
                throw Failure.ambiguousOutput
            }
            let message = output[messageIndex]
            guard
                  message["role"] as? String == "assistant",
                  let content = message["content"] as? [[String: Any]], content.count == 1,
                  let part = content.first else { throw Failure.ambiguousOutput }
            guard part["type"] as? String != "refusal" else { throw Failure.refusal }
            guard part["type"] as? String == "output_text", let text = part["text"] as? String else {
                throw Failure.ambiguousOutput
            }
            guard text.utf8.count <= maximumOutputBytes else { throw Failure.outputTooLarge }
            if let deltaOutputIndex, deltaOutputIndex != messageIndex { throw Failure.ambiguousOutput }
            if let finalizedOutputIndex, finalizedOutputIndex != messageIndex { throw Failure.ambiguousOutput }
            if let finalizedText, finalizedText != Data(text.utf8) { throw Failure.deltaMismatch }
            if sawTextDelta && Data(text.utf8) != textDeltas { throw Failure.deltaMismatch }
            terminalBody = Data(text.utf8)
        case "response.created", "response.queued", "response.in_progress",
             "response.output_text.annotation.added", "response.reasoning_summary_part.added",
             "response.reasoning_summary_part.done", "response.reasoning_summary_text.delta",
             "response.reasoning_summary_text.done":
            // Known lifecycle / metadata events carry no user-visible answer text.
            break
        default:
            throw Failure.unsupportedEvent(type)
        }
    }
}
