import SwiftUI

/// A segmented control at ordinary text sizes; a menu at accessibility sizes, where three or
/// four segments of large type can't share one row without truncating to "…".
struct AdaptiveSegmented: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            content.pickerStyle(.menu)
        } else {
            content.pickerStyle(.segmented)
        }
    }
}

extension View {
    func adaptiveSegmented() -> some View { modifier(AdaptiveSegmented()) }
}
