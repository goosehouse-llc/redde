#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and hands back the Objective-C exception it raised, if any. Swift can't catch
/// one, and AVFAudio raises them for a bad microphone format (`installTap`): with AirPods
/// between their modes that ended the app (2026-10-22).
FOUNDATION_EXPORT NSException * _Nullable ReddeCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
