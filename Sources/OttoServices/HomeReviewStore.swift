import Combine
import Foundation
import OttoModels

/// Drafts waiting on Home for the person to approve, comment on or reject. Stored with the
/// space, so each space has its own.
@MainActor
public final class HomeReviewStore: ObservableObject {
  private struct State: Codable {
    var schemaVersion = 1
    var reviews: [HomeReview] = []
  }

  public enum ReviewError: Error, LocalizedError, Equatable {
    case unknown
    case alreadyDecided
    case busy
    case emptyDraft
    case tooMany
    public var errorDescription: String? {
      switch self {
      case .unknown: "That review no longer exists."
      case .alreadyDecided: "That review was already approved or rejected."
      case .busy: "The agent is still answering your last comment."
      case .emptyDraft: "There is nothing to review."
      case .tooMany:
        "\(HomeReviewStore.openLimit) things are already waiting for review. Decide on some first."
      }
    }
  }

  public nonisolated static let openLimit = 30
  public nonisolated static let maximumDraftCharacters = 8_000
  /// Decided reviews are kept this long so agents can still look up the outcome.
  public nonisolated static let decidedRetention: TimeInterval = 14 * 86_400

  @Published private var state = State()
  @Published public private(set) var persistenceError: String?
  private let fileURL: URL
  private let fileManager: FileManager

  public init(workspacePath: String, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    fileURL = URL(fileURLWithPath: workspacePath).appending(path: ".otto/home-reviews.json")
    do {
      if var saved = try WorkspaceJSONFile.load(State.self, from: fileURL, fileManager: fileManager)
      {
        // A revision that was in flight when Otto quit will never finish; reopen it.
        for index in saved.reviews.indices where saved.reviews[index].state == .revising {
          saved.reviews[index].state = .pending
        }
        // An approved action that was running can't be followed after a restart.
        for index in saved.reviews.indices
        where saved.reviews[index].actionStatus == .running {
          saved.reviews[index].actionStatus = .interrupted
          saved.reviews[index].actionPermission = nil
        }
        state = saved
      }
    } catch {
      persistenceError = error.localizedDescription
    }
  }

  public var all: [HomeReview] { state.reviews }
  /// Waiting on the person, oldest first so nothing gets buried.
  public var open: [HomeReview] {
    state.reviews.filter(\.isOpen).sorted { $0.createdAt < $1.createdAt }
  }

  /// Everything Home shows: open reviews, then approved actions still in progress or unread.
  public var onHome: [HomeReview] {
    open + state.reviews.filter(\.isActing).sorted { $0.updatedAt > $1.updatedAt }
  }

  public func review(id: UUID) -> HomeReview? { state.reviews.first { $0.id == id } }

  @discardableResult
  public func add(_ review: HomeReview, now: Date = .now) throws -> HomeReview {
    var review = review
    review.draft = String(
      review.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        .prefix(Self.maximumDraftCharacters))
    guard !review.draft.isEmpty else { throw ReviewError.emptyDraft }
    guard open.count < Self.openLimit else { throw ReviewError.tooMany }
    review.title = String(review.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    if review.title.isEmpty { review.title = review.requester }
    var next = state
    next.reviews = next.reviews.filter {
      $0.isOpen || ($0.decidedAt ?? $0.updatedAt) > now.addingTimeInterval(-Self.decidedRetention)
    }
    next.reviews.append(review)
    try persist(next)
    return review
  }

  @discardableResult
  public func update(id: UUID, _ change: (inout HomeReview) throws -> Void) throws -> HomeReview {
    guard let index = state.reviews.firstIndex(where: { $0.id == id }) else {
      throw ReviewError.unknown
    }
    var next = state
    try change(&next.reviews[index])
    next.reviews[index].updatedAt = .now
    try persist(next)
    return next.reviews[index]
  }

  private func persist(_ next: State) throws {
    try WorkspaceJSONFile.save(next, to: fileURL, fileManager: fileManager)
    state = next
    persistenceError = nil
  }
}
