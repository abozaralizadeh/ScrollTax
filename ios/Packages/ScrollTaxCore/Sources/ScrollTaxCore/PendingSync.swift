import Foundation

public enum PendingSync {
    /// Sends purchases the backend hasn't heard about yet, oldest first.
    /// Stops at the first network problem and tries again next time.
    /// A purchase the backend refuses for good is dropped (it would never succeed).
    /// `onResult` hears what the backend said about each purchase it accepted.
    /// Returns how many were cleared from the queue.
    @discardableResult
    public static func flush(
        store: StateStore, api: PaymentSubmitting, onResult: ((PaymentResult) -> Void)? = nil
    ) async -> Int {
        var cleared = 0
        while let next = store.load().pendingTransactions.first {
            do {
                let result = try await api.submitPayment(
                    signedTransaction: next.signedTransaction, timeZone: next.timeZone)
                onResult?(result)
            } catch let error as APIError where error.isPermanent {
                // refused for good, drop it below
            } catch {
                break
            }
            store.update { $0.pendingTransactions.removeAll { $0 == next } }
            cleared += 1
        }
        return cleared
    }
}
