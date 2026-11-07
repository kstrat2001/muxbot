import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device LLM via Apple Foundation Models. All inference runs locally;
/// nothing leaves the device. Falls back to a canned reply when the system
/// model is unavailable (older hardware, Apple Intelligence off).
@MainActor @Observable
final class OnDeviceLLMService {
    var isAvailable = false
    var isProcessing = false
    var lastError: String?

    init() {
        checkAvailability()
    }

    func checkAvailability() {
        #if canImport(FoundationModels)
        isAvailable = SystemLanguageModel.default.isAvailable
        #else
        isAvailable = false
        #endif
    }

    /// One-shot reply with a 15-second timeout.
    func respond(to prompt: String, instructions: String) async -> String? {
        #if canImport(FoundationModels)
        checkAvailability()
        guard isAvailable else { return nil }
        isProcessing = true
        defer { isProcessing = false }
        do {
            let session = LanguageModelSession(instructions: instructions)
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await session.respond(to: prompt).content }
                group.addTask {
                    try await Task.sleep(for: .seconds(15))
                    throw CancellationError()
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            lastError = error.localizedDescription
            return nil
        }
        #else
        return nil
        #endif
    }
}
