import Foundation
import Supabase

/// Records which retrieved session the user actually opened.
///
/// Clicking a source is the strongest relevance signal this product can get —
/// far stronger than any offline metric — and until now it was discarded the
/// moment it happened. Kept so retrieval can be reranked against real
/// behaviour later; without it the system can only ever fail silently.
///
/// Fire-and-forget by design: this is telemetry about an action the user has
/// already taken, so a failed write must never surface or delay the navigation.
@MainActor
final class RetrievalFeedbackStore {
    private static let tableName = "retrieval_feedback"

    private let supabase: SupabaseClient

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    private struct Row: Encodable {
        let user_id: UUID
        let question: String
        let meeting_id: UUID
        let rank: Int
    }

    func logOpened(meetingID: UUID, question: String, rank: Int) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        Task {
            do {
                let userID = try await supabase.auth.session.user.id
                try await supabase
                    .from(Self.tableName)
                    .insert(Row(user_id: userID, question: question, meeting_id: meetingID, rank: rank))
                    .execute()
            } catch {
                Log.ui.info("RetrievalFeedbackStore.logOpened skipped: \(error.localizedDescription)")
            }
        }
    }
}
