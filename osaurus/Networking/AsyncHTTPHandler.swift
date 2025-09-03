//
//  AsyncHTTPHandler.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation
import Dispatch
import NIOCore
import NIOHTTP1
import IkigaJSON
import MLXLMCommon

private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

/// Handles async operations for HTTP endpoints
class AsyncHTTPHandler {
    static let shared = AsyncHTTPHandler()
    
    // JSON encoder is created per write to avoid cross-request contention
    
    private init() {}
    
    @inline(__always)
    private func executeOnLoop(_ loop: EventLoop, _ block: @escaping () -> Void) {
        if loop.inEventLoop {
            block()
        } else {
            loop.execute {
                block()
            }
        }
    }
    
    /// Handle chat completions with streaming support (OpenAI-compatible SSE)
    func handleChatCompletion(
        request: ChatCompletionRequest,
        context: ChannelHandlerContext
    ) async {
        await handleChat(request: request, context: context, writer: SSEResponseWriter())
    }
    
    /// Handle chat endpoint with NDJSON streaming
    func handleChat(
        request: ChatCompletionRequest,
        context: ChannelHandlerContext
    ) async {
        await handleChat(request: request, context: context, writer: NDJSONResponseWriter())
    }
    
    /// Unified chat handler with pluggable response writer
    private func handleChat(
        request: ChatCompletionRequest,
        context: ChannelHandlerContext,
        writer: ResponseWriter
    ) async {
        do {
            // Find the model using nonisolated static accessor
            guard let model = MLXService.findModel(named: request.model) else {
                let error = OpenAIError(
                    error: OpenAIError.ErrorDetail(
                        message: "Model not found: \(request.model)",
                        type: "invalid_request_error",
                        param: "model",
                        code: nil
                    )
                )
                try await sendJSONResponse(error, status: .notFound, context: context)
                return
            }
            
            // Convert messages
            let messages = request.toInternalMessages()
            
            // Get generation parameters
            let temperature = request.temperature ?? 0.7
            let maxTokens = request.max_tokens ?? 2048
            
            // Honor only request-provided stop sequences; otherwise rely on library EOS handling
            let effectiveStops: [String] = request.stop ?? []

            // Check if streaming is requested
            if request.stream ?? false {
                try await handleStreamingResponse(
                    messages: messages,
                    model: model,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    requestModel: request.model,
                    tools: request.tools,
                    toolChoice: request.tool_choice,
                    sessionId: request.session_id,
                    stopSequences: effectiveStops,
                    context: context,
                    writer: writer
                )
            } else {
                try await handleNonStreamingResponse(
                    messages: messages,
                    model: model,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    requestModel: request.model,
                    tools: request.tools,
                    toolChoice: request.tool_choice,
                    sessionId: request.session_id,
                    stopSequences: effectiveStops,
                    context: context
                )
            }
        } catch {
            let errorResponse = OpenAIError(
                error: OpenAIError.ErrorDetail(
                    message: error.localizedDescription,
                    type: "internal_error",
                    param: nil,
                    code: nil
                )
            )
            try? await sendJSONResponse(errorResponse, status: .internalServerError, context: context)
        }
    }
    
    private func handleStreamingResponse(
        messages: [Message],
        model: LMModel,
        temperature: Float,
        maxTokens: Int,
        requestModel: String,
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?,
        sessionId: String?,
        stopSequences: [String],
        context: ChannelHandlerContext,
        writer: ResponseWriter
    ) async throws {
        let loop = context.eventLoop
        let ctxBox = UncheckedSendableBox(value: context)
        
        // Write headers using the response writer
        executeOnLoop(loop) {
            writer.writeHeaders(ctxBox.value)
        }
        
        // Generate response ID
        let responseId = "chatcmpl-\(UUID().uuidString.prefix(8))"
        let created = Int(Date().timeIntervalSince1970)
        
        // Generate MLX event stream (chunks + tool calls)
        let eventStream = try await MLXService.shared.generateEvents(
            messages: messages,
            model: model,
            temperature: temperature,
            maxTokens: maxTokens,
            tools: tools,
            toolChoice: toolChoice,
            sessionId: sessionId
        )
        
        var fullResponse = ""
        var tokenCount = 0
        
        // If tools are provided (and tool_choice is not "none"), we need to check for tool calls
        // However, we'll stream content immediately for better performance
        let shouldCheckForTools: Bool = {
            guard tools?.isEmpty == false else { return false }
            if let toolChoice, case .none = toolChoice { return false }
            return true
        }()
        
        // For final content summary (non-tool path), collect chunks
        var responseBuffer: [String] = []
        responseBuffer.reserveCapacity(1024)
        
        if shouldCheckForTools {
            // Send initial role chunk
            executeOnLoop(loop) {
                writer.writeRole("assistant", model: requestModel, responseId: responseId, created: created, context: ctxBox.value)
            }
            
            var accumulatedBytes: Int = 0
            // When tools are enabled, buffer content until we know whether a tool call occurs.
            // If a tool call happens, we will discard buffered content (filters <think> for tool paths).
            // If no tool call happens, we will flush buffered content before finalizing.

            for await event in eventStream {
                if let chunk = event.chunk {
                    // Buffer only; do not emit yet. We will flush later iff no tool call occurs.
                    responseBuffer.append(chunk)
                    accumulatedBytes += chunk.utf8.count
                    tokenCount += 1
                }
                if let toolCall = event.toolCall {
                    // For SSE writer, we need to handle tool calls specially
                    // NDJSON writer doesn't support tool calls in the same way
                    if writer is SSEResponseWriter {
                        // Emit OpenAI-style tool_call deltas based on MLX ToolCall
                        let mlxName = toolCall.function.name
                        let argsObject = toolCall.function.arguments
                        let argsData = try? JSONSerialization.data(withJSONObject: argsObject.mapValues { $0.anyValue })
                        let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        let callId = "call_\(UUID().uuidString.prefix(8))"
                        
                        // Batch tool_call deltas
                        let idTypeChunk = ChatCompletionChunk(
                            id: responseId,
                            created: created,
                            model: requestModel,
                            choices: [StreamChoice(index: 0, delta: DeltaContent(tool_calls: [
                                DeltaToolCall(index: 0, id: callId, type: "function", function: nil)
                            ]), finish_reason: nil)],
                            system_fingerprint: nil
                        )
                        let nameChunk = ChatCompletionChunk(
                            id: responseId,
                            created: created,
                            model: requestModel,
                            choices: [StreamChoice(index: 0, delta: DeltaContent(tool_calls: [
                                DeltaToolCall(index: 0, id: callId, type: nil, function: DeltaToolCallFunction(name: mlxName, arguments: nil))
                            ]), finish_reason: nil)],
                            system_fingerprint: nil
                        )
                        let argsChunk = ChatCompletionChunk(
                            id: responseId,
                            created: created,
                            model: requestModel,
                            choices: [StreamChoice(index: 0, delta: DeltaContent(tool_calls: [
                                DeltaToolCall(index: 0, id: callId, type: nil, function: DeltaToolCallFunction(name: nil, arguments: argsString))
                            ]), finish_reason: nil)],
                            system_fingerprint: nil
                        )
                        executeOnLoop(loop) {
                            let context = ctxBox.value
                            guard context.channel.isActive else { return }
                            let encoder = IkigaJSONEncoder()
                            var buffer = context.channel.allocator.buffer(capacity: 1024)
                            func writeData<T: Encodable>(_ v: T) {
                                buffer.writeString("data: ")
                                do { try encoder.encodeAndWrite(v, into: &buffer) } catch {}
                                buffer.writeString("\n\n")
                            }
                            writeData(idTypeChunk)
                            writeData(nameChunk)
                            writeData(argsChunk)
                            // Write finish with tool_calls reason
                            let finishChunk = ChatCompletionChunk(
                                id: responseId,
                                created: created,
                                model: requestModel,
                                choices: [StreamChoice(index: 0, delta: DeltaContent(), finish_reason: "tool_calls")],
                                system_fingerprint: nil
                            )
                            writeData(finishChunk)
                            buffer.writeString("data: [DONE]\n\n")
                            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                            context.flush()
                            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
                                context.close(promise: nil)
                            }
                        }
                    }
                    return
                }
            }
            // Join buffered content and trim stops locally; we'll emit it below only if no tool call occurred
            fullResponse = responseBuffer.joined()
            if !stopSequences.isEmpty {
                for s in stopSequences {
                    if let range = fullResponse.range(of: s) {
                        fullResponse = String(fullResponse[..<range.lowerBound])
                        break
                    }
                }
            }
            if !fullResponse.isEmpty {
                executeOnLoop(loop) {
                    writer.writeContent(fullResponse, model: requestModel, responseId: responseId, created: created, context: ctxBox.value)
                }
            }
        } else {
            // Stream tokens with batching and stop detection
            // Cache env thresholds once per process to avoid per-request overhead
            struct StreamTuning {
                static let batchChars: Int = {
                    let env = ProcessInfo.processInfo.environment
                    return Int(env["OSU_STREAM_BATCH_CHARS"] ?? "") ?? 256
                }()
                static let batchMs: Int = {
                    let env = ProcessInfo.processInfo.environment
                    return Int(env["OSU_STREAM_BATCH_MS"] ?? "") ?? 16
                }()
            }
            let batchCharThreshold: Int = StreamTuning.batchChars
            let batchIntervalMs: Int = StreamTuning.batchMs
            let flushIntervalNs: UInt64 = UInt64(batchIntervalMs) * 1_000_000

            // Stop sequence rolling window
            let shouldCheckStop = !(stopSequences.isEmpty)
            let maxStopLen: Int = shouldCheckStop ? (stopSequences.map { $0.count }.max() ?? 0) : 0
            var stopTail = ""

            // Batching state (event-loop confined)
            var firstTokenSent = false
            let initialCapacity = max(1024, batchCharThreshold)
            var pendingBuffer = ByteBufferAllocator().buffer(capacity: initialCapacity)
            var pendingCharCount: Int = 0
            var lastFlushNs: UInt64 = DispatchTime.now().uptimeNanoseconds
            var scheduledFlush: Bool = false

            @inline(__always)
            func scheduleFlushOnLoopIfNeeded() {
                if scheduledFlush { return }
                scheduledFlush = true
                let deadline = NIODeadline.now() + .milliseconds(Int64(batchIntervalMs))
                loop.scheduleTask(deadline: deadline) {
                    scheduledFlush = false
                    if pendingBuffer.readableBytes > 0 {
                        let content = pendingBuffer.readString(length: pendingBuffer.readableBytes) ?? ""
                        writer.writeContent(content, model: requestModel, responseId: responseId, created: created, context: ctxBox.value)
                        pendingCharCount = 0
                        lastFlushNs = DispatchTime.now().uptimeNanoseconds
                    }
                }
            }

            @inline(__always)
            func processTokenOnLoop(_ token: String) {
                if !firstTokenSent {
                    writer.writeContent(token, model: requestModel, responseId: responseId, created: created, context: ctxBox.value)
                    firstTokenSent = true
                    lastFlushNs = DispatchTime.now().uptimeNanoseconds
                    return
                }
                pendingBuffer.writeString(token)
                pendingCharCount &+= token.count
                let nowNs = DispatchTime.now().uptimeNanoseconds
                if pendingCharCount >= batchCharThreshold || nowNs - lastFlushNs >= flushIntervalNs {
                    if pendingBuffer.readableBytes > 0 {
                        let content = pendingBuffer.readString(length: pendingBuffer.readableBytes) ?? ""
                        writer.writeContent(content, model: requestModel, responseId: responseId, created: created, context: ctxBox.value)
                        pendingCharCount = 0
                        lastFlushNs = nowNs
                    }
                } else {
                    scheduleFlushOnLoopIfNeeded()
                }
            }

            // Immediately send role prelude before first model token (helps TTFT)
            executeOnLoop(loop) {
                writer.writeRole("assistant", model: requestModel, responseId: responseId, created: created, context: ctxBox.value)
            }

            for await event in eventStream {
                guard let token = event.chunk else { continue }
                if shouldCheckStop {
                    stopTail += token
                    if stopTail.count > maxStopLen {
                        let overflow = stopTail.count - maxStopLen
                        stopTail.removeFirst(overflow)
                    }
                    if stopSequences.first(where: { stopTail.contains($0) }) != nil {
                        executeOnLoop(loop) {
                            if pendingBuffer.readableBytes > 0 {
                                let content = pendingBuffer.readString(length: pendingBuffer.readableBytes) ?? ""
                                writer.writeContent(content, model: requestModel, responseId: responseId, created: created, context: ctxBox.value)
                                pendingCharCount = 0
                                lastFlushNs = DispatchTime.now().uptimeNanoseconds
                            }
                        }
                        break
                    }
                }

                executeOnLoop(loop) {
                    processTokenOnLoop(token)
                }
            }

            executeOnLoop(loop) {
                if pendingBuffer.readableBytes > 0 {
                    let content = pendingBuffer.readString(length: pendingBuffer.readableBytes) ?? ""
                    writer.writeContent(content, model: requestModel, responseId: responseId, created: created, context: ctxBox.value)
                    pendingCharCount = 0
                    lastFlushNs = DispatchTime.now().uptimeNanoseconds
                }
            }
        }
        
        // Send final chunk (non-tool path). For tool_calls path we already returned above
        // Trim to first stop sequence if present (non-tool path)
        if !stopSequences.isEmpty {
            for s in stopSequences {
                if let range = fullResponse.range(of: s) {
                    fullResponse = String(fullResponse[..<range.lowerBound])
                    break
                }
            }
        }

        // Send finish and end
        executeOnLoop(loop) {
            writer.writeFinish(requestModel, responseId: responseId, created: created, context: ctxBox.value)
            writer.writeEnd(ctxBox.value)
        }
    }
    
    private func handleNonStreamingResponse(
        messages: [Message],
        model: LMModel,
        temperature: Float,
        maxTokens: Int,
        requestModel: String,
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?,
        sessionId: String?,
        stopSequences: [String],
        context: ChannelHandlerContext
    ) async throws {
        // Generate complete response
        let eventStream = try await MLXService.shared.generateEvents(
            messages: messages,
            model: model,
            temperature: temperature,
            maxTokens: maxTokens,
            tools: tools,
            toolChoice: toolChoice,
            sessionId: sessionId
        )
        
        var fullResponse = ""
        var tokenCount = 0
        var segments: [String] = []
        segments.reserveCapacity(512)
        
        let stopSequences: [String] = stopSequences
        let shouldCheckStop = !stopSequences.isEmpty
        let maxStopLen: Int = shouldCheckStop ? (stopSequences.map { $0.count }.max() ?? 0) : 0
        var stopTail = ""
        for await event in eventStream {
            if let toolCall = event.toolCall {
                // Build OpenAI-compatible tool_calls in non-streaming response
                let argsData = try? JSONSerialization.data(withJSONObject: toolCall.function.arguments.mapValues { $0.anyValue })
                let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                let tc = ToolCall(
                    id: "call_\(UUID().uuidString.prefix(8))",
                    type: "function",
                    function: ToolCallFunction(name: toolCall.function.name, arguments: argsString)
                )
                // Construct response with tool call and return immediately
                let response = ChatCompletionResponse(
                    id: "chatcmpl-\(UUID().uuidString.prefix(8))",
                    created: Int(Date().timeIntervalSince1970),
                    model: requestModel,
                    choices: [
                        ChatChoice(
                            index: 0,
                            message: ChatMessage(role: "assistant", content: nil, tool_calls: [tc], tool_call_id: nil),
                            finish_reason: "tool_calls"
                        )
                    ],
                    usage: Usage(
                        prompt_tokens: messages.reduce(0) { $0 + $1.content.count / 4 },
                        completion_tokens: 0,
                        total_tokens: messages.reduce(0) { $0 + $1.content.count / 4 }
                    ),
                    system_fingerprint: nil
                )
                try await sendJSONResponse(response, status: .ok, context: context)
                return
            }
            guard let token = event.chunk else { continue }
            if shouldCheckStop {
                stopTail += token
                if stopTail.count > maxStopLen {
                    let overflow = stopTail.count - maxStopLen
                    stopTail.removeFirst(overflow)
                }
                if stopSequences.first(where: { stopTail.contains($0) }) != nil {
                    break
                }
            }
            segments.append(token)
            tokenCount += 1
        }
        fullResponse = segments.joined()
        
        // Trim at stop if present
        if !stopSequences.isEmpty {
            for s in stopSequences {
                if let range = fullResponse.range(of: s) {
                    fullResponse = String(fullResponse[..<range.lowerBound])
                    break
                }
            }
        }
        // Since we route tool calls immediately above, remaining path is normal text completion
        let toolCalls: [ToolCall]? = nil
        let finishReason = "stop"

        // Create response
        let response = ChatCompletionResponse(
            id: "chatcmpl-\(UUID().uuidString.prefix(8))",
            created: Int(Date().timeIntervalSince1970),
            model: requestModel,
            choices: [
                ChatChoice(
                    index: 0,
                    message: ChatMessage(role: "assistant", content: fullResponse, tool_calls: nil, tool_call_id: nil),
                    finish_reason: finishReason
                )
            ],
            usage: Usage(
                prompt_tokens: messages.reduce(0) { $0 + $1.content.count / 4 },
                completion_tokens: tokenCount,
                total_tokens: messages.reduce(0) { $0 + $1.content.count / 4 } + tokenCount
            ),
            system_fingerprint: nil
        )
        
        try await sendJSONResponse(response, status: .ok, context: context)
    }

    // Tool Call Parsing moved to ToolCallParser
    
    private func sendJSONResponse<T: Encodable>(
        _ response: T,
        status: HTTPResponseStatus,
        context: ChannelHandlerContext
    ) async throws {
        let loop = context.eventLoop
        let ctxBox = UncheckedSendableBox(value: context)
        // Send response on the event loop
        loop.execute {
            let context = ctxBox.value
            guard context.channel.isActive else { return }
            let encoder = IkigaJSONEncoder()
            var responseHead = HTTPResponseHead(version: .http1_1, status: status)
            var buffer = context.channel.allocator.buffer(capacity: 1024)
            do { try encoder.encodeAndWrite(response, into: &buffer) } catch {
                buffer.clear()
                buffer.writeString("{}")
            }
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
            headers.add(name: "Content-Length", value: String(buffer.readableBytes))
            headers.add(name: "Connection", value: "close")
            responseHead.headers = headers
            context.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
                let context = ctxBox.value
                context.close(promise: nil)
            }
        }
    }

    // MARK: - Helpers
    private func encodeJSONString<T: Encodable>(_ value: T) -> String? {
        let encoder = IkigaJSONEncoder()
        var buffer = ByteBufferAllocator().buffer(capacity: 1024)
        do {
            try encoder.encodeAndWrite(value, into: &buffer)
            return buffer.readString(length: buffer.readableBytes)
        } catch {
            return nil
        }
    }
}
