import SwiftUI

/// The fold of an iPhone Duo (Apple's foldable, 2026-10-23) across a view, while it is partly
/// open: where it lies, in the view's own coordinates, and which way it runs. Flat open, closed, on
/// any other device or before iOS 27.1, there is none. Scrolling content is left to run across it,
/// as Apple asks; what stands still in the middle of the screen (the voice screen, the jump to the
/// newest message) moves to one side of it.
nonisolated struct Fold: Equatable, Sendable {
    var frame: CGRect
    /// Down the middle, the device held like a book; else across it, propped like a laptop.
    var isVertical: Bool { frame.height > frame.width }
}

extension GeometryProxy {
    /// The fold, if one lies across this view, not along its edge.
    nonisolated var fold: Fold? {
        #if DEBUG
        if let fake = Fold.fake(in: size) { return fake }
        #endif
        #if os(iOS)
        guard #available(iOS 27.1, *) else { return nil }
        guard let region = reservedRegions(kind: .division).first(where: \.isActive) else { return nil }
        let fold = Fold(frame: region.frame)
        let inside = fold.isVertical ? fold.frame.minX > 0 && fold.frame.maxX < size.width
                                     : fold.frame.minY > 0 && fold.frame.maxY < size.height
        return inside ? fold : nil
        #else
        return nil   // a Mac has no fold
        #endif
    }
}

extension View {
    /// The fold across this view, kept in `fold` as the device opens and closes; `vertical`, only
    /// one down it.
    func readingFold(_ fold: Binding<Fold?>, vertical: Bool = false) -> some View {
        onGeometryChange(for: Fold?.self) { proxy in
            proxy.fold.flatMap { !vertical || $0.isVertical ? $0 : nil }
        } action: { fold.wrappedValue = $0 }
    }
}

#if DEBUG
nonisolated extension Fold {
    /// `-echo.fakeFold vertical|horizontal`: a fold down or across the middle of every view that
    /// asks, to look at the layouts without a Duo half open.
    /// Read from the launch arguments as `DevHooks` does, but off the main actor: geometry is
    /// read there.
    private static let fakeKind: String? = {
        let args = ProcessInfo.processInfo.arguments
        return args.firstIndex(of: "-echo.fakeFold").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }()

    static func fake(in size: CGSize) -> Fold? {
        switch fakeKind {
        case "vertical": Fold(frame: CGRect(x: size.width / 2 - 12, y: 0, width: 24, height: size.height))
        case "horizontal": Fold(frame: CGRect(x: 0, y: size.height / 2 - 12, width: size.width, height: 24))
        default: nil
        }
    }
}
#endif
