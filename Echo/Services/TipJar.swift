import Foundation
import Observation
import StoreKit
import os

/// Settings → About → Support Redde: optional one-time tips through the App Store (consumables;
/// nothing is unlocked). Apple handles the payment; Redde only learns that a purchase went through.
@Observable
final class TipJar {
    static let shared = TipJar()

    /// A coffee, a snack, a dinner. Smallest first; the IDs match App Store Connect and `Redde.storekit`.
    static let productIDs = ["com.goosehouse.echo.tip.coffee", "com.goosehouse.echo.tip.snack", "com.goosehouse.echo.tip.dinner"]

    enum State: Equatable { case loading, ready, unavailable, purchasing(String), thanked }

    /// One tip as the screen shows it. `product` is nil only for the screenshot demo.
    struct Option: Identifiable {
        var id: String
        var name: String
        var price: String
        var product: Product?
    }

    private(set) var products: [Product] = []
    private(set) var options: [Option] = []
    private(set) var state: State = .loading

    private let log = Logger(subsystem: "com.goosehouse.echo", category: "tips")
    private var updates: Task<Void, Never>?

    /// Finishes transactions that complete outside a purchase call (Ask to Buy approved later, an
    /// interrupted purchase). A consumable left unfinished is delivered again on every launch.
    func start() {
        guard updates == nil else { return }
        updates = Task.detached { [log] in
            for await result in Transaction.updates {
                if case let .verified(transaction) = result {
                    await transaction.finish()
                    log.info("finished a tip that completed later")
                }
            }
        }
    }

    func load() async {
        #if DEBUG
        // Dev hook for the App Review screenshot: sample tips, no StoreKit.
        if DevHooks.has("-echo.demoTips") {
            options = zip(Self.productIDs, [("A coffee", "$2.99"), ("A snack", "$4.99"), ("A dinner", "$9.99")])
                .map { Option(id: $0, name: $1.0, price: $1.1) }
            state = .ready
            return
        }
        #endif
        guard products.isEmpty else { state = .ready; return }
        state = .loading
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            products = loaded.sorted { $0.price < $1.price }
            options = products.map { Option(id: $0.id, name: $0.displayName, price: $0.displayPrice, product: $0) }
            state = products.isEmpty ? .unavailable : .ready
        } catch {
            log.error("tips unavailable: \(error.localizedDescription)")
            state = .unavailable
        }
    }

    func buy(_ option: Option) async {
        guard let product = option.product else { return }
        state = .purchasing(product.id)
        do {
            switch try await product.purchase() {
            case let .success(.verified(transaction)):
                await transaction.finish()
                state = .thanked
            case .success(.unverified):
                state = .ready   // StoreKit couldn't verify it: no thanks for a purchase that may not count
            case .pending, .userCancelled:
                state = .ready
            @unknown default:
                state = .ready
            }
        } catch {
            log.error("tip failed: \(error.localizedDescription)")
            state = .ready
        }
    }

    /// Back to the list after the thank-you, for another tip.
    func reset() { if state == .thanked { state = .ready } }

    /// The icon for a tip, by its place in the list.
    static func symbol(for id: String) -> String {
        switch id {
        case productIDs[0]: "cup.and.saucer"
        case productIDs[1]: "takeoutbag.and.cup.and.straw"
        default: "fork.knife"
        }
    }
}
