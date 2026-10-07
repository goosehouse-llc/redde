import AppIntents
import Foundation

/// Approve and Deny on a reply's Live Activity (Lock Screen, Dynamic Island). A Live Activity
/// intent runs in the app's process, not the widget's, so the answer goes to the conversation
/// that is waiting on it: the app sets `ApprovalAnswer.deliver` at launch. Compiled into the
/// controls extension too, which only names these on its buttons.
///
/// Approving asks for the device to be unlocked first, as the notification's Approve does;
/// denying doesn't.
struct ApproveRequestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Approve"
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Request") var requestID: String
    @Parameter(title: "Choice") var choice: String

    init() {}
    init(requestID: String, choice: String) {
        self.requestID = requestID
        self.choice = choice
    }

    func perform() async throws -> some IntentResult {
        let (id, choice) = (requestID, choice)
        await MainActor.run { ApprovalAnswer.deliver?(id, choice) }
        return .result()
    }
}

struct DenyRequestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Deny"
    static let isDiscoverable = false

    @Parameter(title: "Request") var requestID: String
    @Parameter(title: "Choice") var choice: String

    init() {}
    init(requestID: String, choice: String) {
        self.requestID = requestID
        self.choice = choice
    }

    func perform() async throws -> some IntentResult {
        let (id, choice) = (requestID, choice)
        await MainActor.run { ApprovalAnswer.deliver?(id, choice) }
        return .result()
    }
}

/// Where an answer given on the Live Activity goes.
@MainActor
enum ApprovalAnswer {
    /// Request id and choice. Set by the app; nil in an extension, where the intents never run.
    static var deliver: (@MainActor (String, String) -> Void)?
}
