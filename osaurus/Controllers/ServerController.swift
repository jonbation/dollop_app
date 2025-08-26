//
//  ServerController.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// Main controller responsible for managing the server lifecycle
@MainActor
final class ServerController: ObservableObject {
    // MARK: - Published Properties
    
    @Published var isRunning: Bool = false
    @Published var lastErrorMessage: String?
    @Published var serverHealth: ServerHealth = .stopped
    @Published var configuration: ServerConfiguration = .default
    
    // Provide shared access to configuration for non-UI callers
    nonisolated static func sharedConfiguration() async -> ServerConfiguration? {
        await MainActor.run { [weak shared = ServerControllerHolder.shared.controller] in
            shared?.configuration
        }
    }
    
    /// Convenience property for accessing port
    var port: Int {
        get { configuration.port }
        set { configuration.port = newValue }
    }
    
    // MARK: - Private Properties
    
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var serverChannel: Channel?

    // Singleton holder to allow async access to the current controller instance when injected as EnvironmentObject
    private struct ServerControllerHolder {
        static var shared = ServerControllerHolder()
        weak var controller: ServerController?
        private init() {}
    }

    // MARK: - Public Methods
    
    /// Starts the server with current configuration
    func startServer() async {
        guard !isRunning else { return }
        guard configuration.isValidPort else {
            lastErrorMessage = "Invalid port: \(configuration.port). Port must be between 1 and 65535."
            serverHealth = .error(lastErrorMessage!)
            return
        }
        
        serverHealth = .starting
        
        do {
            print("[Osaurus] Starting NIO server on port \(configuration.port)")

            // Ensure any previous instance is shut down
            try await stopServerIfNeeded()

            // Create event loop group (allow env-based override to reduce contention)
            let env = ProcessInfo.processInfo.environment
            let nioThreads = Int(env["OSU_NIO_THREADS"] ?? "") ?? configuration.numberOfThreads
            let group = MultiThreadedEventLoopGroup(numberOfThreads: nioThreads)
            self.eventLoopGroup = group

            // Bootstrap server using a nonisolated creator to avoid MainActor hops
            let currentConfig = self.configuration
            let bootstrap = ServerController.createServerBootstrap(group: group, configuration: currentConfig)

            // Bind to configured host and port (async-safe)
            let channel = try await bootstrap.bind(host: configuration.host, port: configuration.port).get()
            self.serverChannel = channel

            // Update state
            isRunning = true
            serverHealth = .running
            lastErrorMessage = nil
            print("[Osaurus] NIO server started successfully on port \(configuration.port)")

            // Handle channel closure
            setupChannelClosureHandler(channel)

            // Best-effort warm-up to reduce TTFT on first request.
            // Environment variables:
            //   OSU_WARMUP_MODEL   - optional model name to warm up
            //   OSU_WARMUP_TOKENS  - number of tokens to generate during warm-up (default 16)
            //   OSU_WARMUP_PREFILL - approximate number of characters for prefill warmup (default 16384)
            Task {
                let env = ProcessInfo.processInfo.environment
                let envModel = env["OSU_WARMUP_MODEL"]
                // More aggressive defaults compile prefill/decoding paths better
                let warmTokens = Int(env["OSU_WARMUP_TOKENS"] ?? "") ?? 16
                let prefillChars = Int(env["OSU_WARMUP_PREFILL"] ?? "") ?? 16384
                await MLXService.shared.warmUp(modelName: envModel, prefillChars: max(0, prefillChars), maxTokens: max(1, warmTokens))
            }
        } catch {
            handleServerError(error)
            await cleanupRuntime()
        }
    }
    
    /// Stops the running server
    func stopServer() async {
        // If nothing to stop, return
        guard serverChannel != nil || eventLoopGroup != nil else { return }

        serverHealth = .stopping
        print("[Osaurus] Stopping NIO server...")

        isRunning = false

        // Close the server channel if present
        if let channel = serverChannel {
            do { try await channel.close().get() } catch { print("[Osaurus] Error closing channel: \(error)") }
            serverChannel = nil
        }

        await cleanupRuntime()

        serverHealth = .stopped
        print("[Osaurus] Server stopped successfully")
    }
    
    /// Ensures the server is properly shut down before app termination
    func ensureShutdown() async {
        guard serverChannel != nil || eventLoopGroup != nil else { return }

        print("[Osaurus] Ensuring NIO server shutdown before app termination")
        isRunning = false
        serverHealth = .stopping

        if let channel = serverChannel {
            do { try await channel.close().get() } catch { print("[Osaurus] Error closing channel: \(error)") }
            serverChannel = nil
        }

        await cleanupRuntime()

        print("[Osaurus] Server shutdown completed")
    }
    
    // Capture singleton pointer on init attach to UI
    init() {
        ServerControllerHolder.shared.controller = self
    }
    
    /// Checks if the server is responsive
    func checkServerHealth() async -> Bool {
        guard isRunning else { return false }
        
        do {
            let url = URL(string: "http://127.0.0.1:\(port)/health")!
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            print("[Osaurus] Health check failed: \(error)")
            return false
        }
    }

    // MARK: - Private Helpers
    
    /// Creates configured server bootstrap outside of MainActor to ensure pipeline ops run on the channel's EventLoop
    nonisolated static func createServerBootstrap(group: EventLoopGroup, configuration: ServerConfiguration) -> ServerBootstrap {
        let env = ProcessInfo.processInfo.environment
        let maxMessagesPerReadEnv = Int(env["OSU_NIO_MAX_MESSAGES_PER_READ"] ?? "") ?? 8
        let maxMessagesPerRead: ChannelOptions.Types.MaxMessagesPerReadOption.Value = numericCast(maxMessagesPerReadEnv)
        return ServerBootstrap(group: group)
            // Server options
            .serverChannelOption(ChannelOptions.backlog, value: configuration.backlog)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // Child channels (accepted connections)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false, withErrorHandling: false).flatMap {
                    channel.pipeline.addHandler(HTTPHandler())
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: maxMessagesPerRead)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
    }
    
    /// Sets up channel closure handler
    private func setupChannelClosureHandler(_ channel: Channel) {
        channel.closeFuture.whenComplete { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isRunning = false
                self.serverHealth = .stopped
                self.serverChannel = nil
            }
        }
    }
    
    /// Handles server startup errors
    private func handleServerError(_ error: Error) {
        print("[Osaurus] Failed to start server: \(error)")
        serverHealth = .error(error.localizedDescription)
        isRunning = false
        lastErrorMessage = error.localizedDescription
    }
    private func stopServerIfNeeded() async throws {
        if serverChannel != nil || eventLoopGroup != nil {
            await stopServer()
        }
    }

    private func cleanupRuntime() async {
        // Shutdown the event loop group gracefully
        if let group = eventLoopGroup {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                group.shutdownGracefully { error in
                    if let error {
                        print("[Osaurus] Error shutting down EventLoopGroup: \(error)")
                    }
                    continuation.resume()
                }
            }
            eventLoopGroup = nil
        }
    }
}


