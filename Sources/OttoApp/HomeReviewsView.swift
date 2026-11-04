import OttoModels
import OttoServices
import SwiftUI

/// Drafts agents left on Home to approve, comment on or reject, e.g. a tip of the day that is
/// only posted to Discord once approved. Hidden when nothing is waiting.
struct HomeReviewsView: View {
  @ObservedObject var reviews: HomeReviewStore
  let services: ApplicationServices
  let openAgent: (UUID) -> Void
  @Environment(\.ottoPalette) private var palette
  @State private var status: OttoStatusToast?

  var body: some View {
    let shown = reviews.onHome
    if !shown.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("For your review").font(.ottoDisplay(16).weight(.semibold))
          let waiting = shown.filter(\.needsPerson).count
          if waiting > 0 {
            Text("\(waiting)").font(.ottoMono(11, weight: .semibold))
          }
          Spacer()
        }
        .foregroundStyle(palette.paper)
        .shadow(color: palette.textHalo, radius: 6)
        ForEach(shown) { review in
          if review.isActing {
            HomeReviewActionCard(review: review, services: services, openAgent: openAgent)
          } else {
            HomeReviewCard(
              review: review, services: services, openAgent: openAgent,
              report: { status = $0 })
          }
        }
      }
      .padding(.bottom, 36)
      .accessibilityIdentifier("home.reviews")
      .ottoStatusToast($status)
    }
  }
}

struct HomeReviewCard: View {
  let review: HomeReview
  let services: ApplicationServices
  let openAgent: (UUID) -> Void
  let report: (OttoStatusToast) -> Void
  /// Home marks cards waiting on the person with a thin accent edge; Activity does not.
  var accentEdge = true
  @Environment(\.ottoPalette) private var palette
  @State private var commenting = false
  @State private var comment = ""
  @State private var editing = false
  @State private var edited = ""
  @State private var working = false
  @FocusState private var commentFocused: Bool

  private var revising: Bool { review.state == .revising }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      draft
      Label {
        Text(approvalOutcome)
      } icon: {
        Image(systemName: "arrow.turn.down.right")
      }
      .font(.ottoDisplay(11))
      .foregroundStyle(palette.muted)
      if !review.notes.isEmpty { thread }
      if commenting { commentField }
      if let problem = review.problem {
        Text(problem).font(.ottoDisplay(11)).foregroundStyle(palette.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      actions
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .ottoGlass(cornerRadius: 12)
    .overlay(alignment: .leading) {
      // A thin accent edge marks it as waiting on the person, not just information.
      if accentEdge {
        RoundedRectangle(cornerRadius: 2).fill(palette.signal.opacity(0.85))
          .frame(width: 3).padding(.vertical, 16)
      }
    }
    .foregroundStyle(palette.paper)
    .accessibilityIdentifier("home.review.\(review.id.uuidString)")
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 3) {
        Text(review.title).font(.ottoDisplay(14).weight(.semibold)).lineLimit(1)
        Text(
          "\(review.requester) · \(review.createdAt.formatted(.relative(presentation: .named)))"
        )
        .font(.ottoDisplay(10.5)).foregroundStyle(palette.muted).lineLimit(1)
      }
      Spacer()
      if revising {
        HStack(spacing: 6) {
          ProgressView().controlSize(.mini)
          Text("Revising…")
        }
        .font(.ottoDisplay(10.5)).foregroundStyle(palette.signal)
      } else {
        Text("NEEDS YOU").font(.ottoMono(9, weight: .semibold)).tracking(1.4)
          .foregroundStyle(palette.signal)
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(palette.signal.opacity(0.12), in: Capsule())
      }
    }
  }

  @ViewBuilder private var draft: some View {
    if editing {
      TextEditor(text: $edited)
        .font(.ottoDisplay(13))
        .scrollContentBackground(.hidden)
        .frame(minHeight: 110, maxHeight: 320)
        .padding(8)
        .background(palette.paper.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.signal.opacity(0.5)))
    } else {
      HomeReviewDraftView(text: review.draft, maxHeight: 320)
        .opacity(revising ? 0.55 : 1)
    }
  }

  private var thread: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(review.notes.suffix(6)) { note in
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: note.author == .person ? "person.crop.circle" : "sparkles")
            .font(.system(size: 11))
            .foregroundStyle(note.author == .person ? palette.muted : palette.signal)
            .frame(width: 14)
          if note.author == .agent {
            MarkdownMessageView(text: note.text, scale: 1, palette: palette)
          } else {
            Text(note.text).font(.ottoDisplay(11.5))
              .foregroundStyle(palette.paper.opacity(0.85))
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
          }
        }
      }
    }
  }

  private var commentField: some View {
    HStack(alignment: .bottom, spacing: 8) {
      TextField("Ask for a change or a question…", text: $comment, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.ottoDisplay(12.5))
        .lineLimit(1...5)
        .focused($commentFocused)
        .onSubmit(sendComment)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(palette.paper.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
      Button(action: sendComment) {
        Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
          .frame(width: 26, height: 26)
          .background(palette.signal, in: Circle())
          .foregroundStyle(palette.onSignal)
      }
      .buttonStyle(.plain)
      .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .accessibilityLabel("Send comment")
    }
  }

  private var actions: some View {
    HStack(spacing: 8) {
      if editing {
        Button("Approve edited") { approve() }
          .buttonStyle(.borderedProminent)
          .tint(palette.signal)
          .disabled(edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Cancel") { editing = false }.buttonStyle(.bordered)
      } else {
        Button {
          approve()
        } label: {
          Label("Approve", systemImage: "checkmark")
        }
        .buttonStyle(.borderedProminent)
        .tint(palette.signal)
        .accessibilityIdentifier("home.review.approve")
        Button {
          commenting.toggle()
          commentFocused = commenting
        } label: {
          Label("Comment", systemImage: "text.bubble")
        }
        .buttonStyle(.bordered)
        Button {
          edited = review.draft
          editing = true
          commenting = false
        } label: {
          Label("Edit", systemImage: "pencil")
        }
        .buttonStyle(.bordered)
        Button(role: .destructive) {
          reject()
        } label: {
          Label("Reject", systemImage: "xmark")
        }
        .buttonStyle(.bordered)
      }
      Spacer()
      if let nodeID = review.agentNodeID {
        Button("Open chat") { openAgent(nodeID) }
          .buttonStyle(.plain).font(.ottoDisplay(10.5)).foregroundStyle(palette.muted)
      }
    }
    .controlSize(.small)
    .disabled(working || revising)
  }

  /// The steps that start once this is approved, by name.
  private var nextSteps: [String] {
    review.routineID.map { id in services.routines.followers(of: id).map(\.name) } ?? []
  }

  /// What Approve will set off, so it's never a surprise that nothing happens.
  private var approvalOutcome: String {
    var parts: [String] = []
    if let action = review.afterApproval { parts.append(action) }
    if !nextSteps.isEmpty { parts.append("then " + nextSteps.joined(separator: ", ")) }
    return parts.isEmpty
      ? "Approving only marks this as reviewed. Nothing else is set to run."
      : "When you approve: " + parts.joined(separator: ", ")
  }

  private func approve() {
    let text = editing ? edited : nil
    let action = review.afterApproval
    let follows = nextSteps
    let id = review.id
    working = true
    Task {
      do {
        try await services.approveReview(id: id, editedDraft: text)
        report(
          OttoStatusToast(
            kind: .success, title: "Approved",
            detail: action != nil
              ? "It’s doing it now. Follow along on the card."
              : follows.isEmpty
                ? "Marked as reviewed. Nothing else was set to run."
                : "Started \(follows.joined(separator: ", "))."))
      } catch {
        report(
          OttoStatusToast(
            kind: .error, title: "Couldn’t finish approving", detail: error.localizedDescription)
        )
      }
      working = false
    }
  }

  private func reject() {
    do {
      try services.rejectReview(
        id: review.id, reason: comment.trimmingCharacters(in: .whitespacesAndNewlines))
      report(OttoStatusToast(kind: .info, title: "Rejected", detail: "Nothing else will run."))
    } catch {
      report(
        OttoStatusToast(kind: .error, title: "Couldn’t reject", detail: error.localizedDescription))
    }
  }

  private func sendComment() {
    let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let id = review.id
    comment = ""
    commenting = false
    Task {
      do { try await services.commentOnReview(id: id, text: text) } catch {
        // The card shows the problem; the comment stays in the thread.
      }
    }
  }
}

/// An approved review whose "when I approve, do this" action is under way. It stays on Home
/// until the person dismisses it, so a permission prompt or the result is never missed.
struct HomeReviewActionCard: View {
  let review: HomeReview
  let services: ApplicationServices
  let openAgent: (UUID) -> Void
  var accentEdge = true
  @Environment(\.ottoPalette) private var palette
  @State private var answering = false

  private var status: HomeReview.ActionStatus { review.actionStatus ?? .running }
  private var waitingForPermission: Bool { review.actionPermission != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        VStack(alignment: .leading, spacing: 3) {
          Text(review.title).font(.ottoDisplay(14).weight(.semibold)).lineLimit(1)
          Text(
            "Approved \((review.decidedAt ?? review.updatedAt).formatted(.relative(presentation: .named)))"
          )
          .font(.ottoDisplay(10.5)).foregroundStyle(palette.muted).lineLimit(1)
        }
        Spacer()
        pill
      }
      HomeReviewDraftView(text: review.draft, maxHeight: 140)
        .opacity(0.8)
      if let action = review.afterApproval {
        Label {
          Text(
            status == .done
              ? "Did: \(action)" : status == .declined ? "Didn’t do: \(action)" : "Doing: \(action)"
          )
        } icon: {
          Image(systemName: "arrow.turn.down.right")
        }
        .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
      }
      if let request = review.actionPermission { permissionBox(request) }
      outcome
      HStack(spacing: 8) {
        if status != .running {
          Button("Dismiss") { services.dismissReview(id: review.id) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("home.review.dismiss")
        }
        Spacer()
        if let nodeID = review.agentNodeID {
          Button("Open chat") { openAgent(nodeID) }
            .buttonStyle(.plain).font(.ottoDisplay(10.5)).foregroundStyle(palette.muted)
        }
      }
      .controlSize(.small)
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .ottoGlass(cornerRadius: 12)
    .overlay(alignment: .leading) {
      if accentEdge && waitingForPermission {
        RoundedRectangle(cornerRadius: 2).fill(palette.signal.opacity(0.85))
          .frame(width: 3).padding(.vertical, 16)
      }
    }
    .foregroundStyle(palette.paper)
    .accessibilityIdentifier("home.review.action.\(review.id.uuidString)")
  }

  @ViewBuilder private var pill: some View {
    switch status {
    case .running where waitingForPermission:
      tag("NEEDS YOUR OK", palette.signal)
    case .running:
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Doing it…")
      }
      .font(.ottoDisplay(10.5)).foregroundStyle(palette.signal)
    case .done: tag("DONE", palette.muted)
    case .declined: tag("STOPPED", palette.muted)
    case .failed, .interrupted: tag("DIDN’T FINISH", palette.red)
    }
  }

  private func tag(_ text: String, _ color: Color) -> some View {
    Text(text).font(.ottoMono(9, weight: .semibold)).tracking(1.4)
      .foregroundStyle(color)
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(color.opacity(0.12), in: Capsule())
  }

  private func permissionBox(_ request: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("It needs your OK to carry on:")
        .font(.ottoDisplay(11.5).weight(.medium))
      Text(request)
        .font(.ottoMono(11))
        .lineLimit(6)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(palette.paper.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
      HStack(spacing: 8) {
        Button("Allow") { answer(true) }
          .buttonStyle(.borderedProminent).tint(palette.signal)
          .accessibilityIdentifier("home.review.allow")
        Button("Deny", role: .destructive) { answer(false) }
          .buttonStyle(.bordered)
      }
      .controlSize(.small)
      .disabled(answering)
    }
  }

  @ViewBuilder private var outcome: some View {
    switch status {
    case .done:
      Label(Self.plain(review.actionResult ?? "Done."), systemImage: "checkmark.circle")
        .font(.ottoDisplay(12)).foregroundStyle(palette.paper)
        .fixedSize(horizontal: false, vertical: true)
    case .declined:
      Label(
        Self.plain(review.actionResult ?? "You denied what it needed, so it wasn’t done."),
        systemImage: "xmark.circle"
      )
      .font(.ottoDisplay(12)).foregroundStyle(palette.paper.opacity(0.85))
      .fixedSize(horizontal: false, vertical: true)
    case .failed:
      Text(review.problem ?? "The action didn’t finish.")
        .font(.ottoDisplay(11)).foregroundStyle(palette.red)
        .fixedSize(horizontal: false, vertical: true)
    case .interrupted:
      Text("Otto quit before this finished. Open the chat to see whether it was done.")
        .font(.ottoDisplay(11)).foregroundStyle(palette.red)
        .fixedSize(horizontal: false, vertical: true)
    case .running:
      EmptyView()
    }
  }

  /// Agents reply in Markdown; a card shows "[tips.md](</path>)" as just "tips.md".
  nonisolated static func plain(_ text: String) -> String {
    text.replacingOccurrences(
      of: #"\[([^\]]+)\]\(<?[^>)]*>?\)"#, with: "$1", options: .regularExpression
    )
    .replacingOccurrences(of: "**", with: "")
    .replacingOccurrences(of: "`", with: "")
  }

  private func answer(_ allow: Bool) {
    answering = true
    let id = review.id
    Task {
      await services.answerReviewPermission(id: id, allow: allow)
      answering = false
    }
  }
}

/// A draft rendered as Markdown (headings, bold, lists, tables, code) in a plate that grows
/// with short drafts and scrolls inside once it reaches `maxHeight`, so a long report never
/// makes the card huge.
struct HomeReviewDraftView: View {
  let text: String
  let maxHeight: CGFloat
  @Environment(\.ottoPalette) private var palette

  var body: some View {
    ViewThatFits(in: .vertical) {
      content
      ScrollView(.vertical) { content }
        .scrollIndicators(.visible)
        // macOS hides scroll bars until you scroll, so a fade says there's more below.
        .overlay(alignment: .bottom) {
          LinearGradient(
            colors: [palette.surface.opacity(0), palette.surface.opacity(0.55)],
            startPoint: .top, endPoint: .bottom
          )
          .frame(height: 36)
          .allowsHitTesting(false)
        }
    }
    .frame(maxHeight: maxHeight)
    .background(palette.paper.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private var content: some View {
    MarkdownMessageView(text: text, scale: 1.1, palette: palette)
      .textSelection(.enabled)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
