import Foundation

/// Objective-C exceptions, caught (`ObjCExceptions.h`): Swift can't, and AVFAudio raises them.
enum ObjCExceptions {
    /// Runs `body`; the exception it raised, if any.
    static func catching(_ body: () -> Void) -> NSException? { ReddeCatchException(body) }
}
