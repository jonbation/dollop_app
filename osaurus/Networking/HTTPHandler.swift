//
//  HTTPHandler.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// SwiftNIO HTTP request handler
final class HTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var requestHead: HTTPRequestHead?
    private var requestBody = Data()
    private var context: ChannelHandlerContext?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.context = context
        let part = self.unwrapInboundIn(data)
        
        switch part {
        case .head(let head):
            requestHead = head
            
        case .body(var buffer):
            // Collect body data
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                requestBody.append(Data(bytes))
            }
            
        case .end:
            guard let head = requestHead else {
                sendBadRequest(context: context)
                return
            }

            // Extract path without query parameters
            let pathOnly = extractPath(from: head.uri)
            
            // Create router with context
            let router = Router(context: context, handler: self)
            let response = router.route(method: head.method.rawValue, path: pathOnly, body: requestBody)
            // Only send response if not handled asynchronously
            if !response.body.isEmpty || response.status != .ok {
                sendResponse(
                    context: context,
                    version: head.version,
                    status: response.status,
                    headers: response.headers,
                    body: response.body
                )
            }
            
            requestHead = nil
            requestBody = Data()
        }
    }
    
    // MARK: - Private Helpers
    
    private func extractPath(from uri: String) -> String {
        if let queryIndex = uri.firstIndex(of: "?") {
            return String(uri[..<queryIndex])
        }
        return uri
    }
    
    private func sendBadRequest(context: ChannelHandlerContext) {
        sendResponse(
            context: context,
            version: HTTPVersion(major: 1, minor: 1),
            status: .badRequest,
            headers: [("Content-Type", "text/plain; charset=utf-8")],
            body: "Bad Request"
        )
    }

    private func sendResponse(
        context: ChannelHandlerContext,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        headers: [(String, String)],
        body: String
    ) {
        // Create response head
        var responseHead = HTTPResponseHead(version: version, status: status)
        
        // Create body buffer
        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)

        // Build headers
        var nioHeaders = HTTPHeaders()
        for (name, value) in headers {
            nioHeaders.add(name: name, value: value)
        }
        nioHeaders.add(name: "Content-Length", value: String(buffer.readableBytes))
        nioHeaders.add(name: "Connection", value: "close")
        responseHead.headers = nioHeaders

        // Send response
        context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
