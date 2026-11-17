import PhotosUI
import PiRuntime
import SwiftUI
import UniformTypeIdentifiers

struct ConversationView: View {
    @Bindable var store: ChatStore
    let conversationId: Int
    @Binding var path: [Route]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    /// Photos, camera shots and files for the next message.
    @State private var attachments: [Attachment] = []
    /// A skill picked from the "/" menu: the next message runs it.
    @State private var skill: String?
    @State private var choosingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importingFiles = false
    @State private var takingPhoto = false
    /// Attachments being read and downscaled.
    @State private var attaching = 0
    @FocusState private var composing: Bool
    /// Queued messages with a withdraw or steer in flight.
    @State private var queueActions: Set<Int> = []
    @State private var keyboardScroll = TranscriptKeyboardScroll()
    @State private var voice = VoiceInput()
    /// Counts messages sent from the composer, for the send haptic.
    @State private var sent = 0
    /// The screen's width, which bounds the header (see `header`).
    @State private var width: CGFloat = 0
    /// The message a search hit opened the conversation at: marked until something is sent.
    @State private var found: Int?
    /// The transcript stays at the found message, rather than following its end, until the user scrolls or sends.
    @State private var atFound = false
    @State private var deleting: ConversationMeta?

    private var state: ConversationState { store.state(conversationId) }
    private var meta: ConversationMeta? { store.meta(conversationId) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: a LazyVStack's estimated row heights put the bottom anchor short of the end on open.
                VStack(alignment: .leading, spacing: 12) {
                    if let fork = meta?.forkOf {
                        Label("Forked from \(store.meta(fork.conversationId)?.title ?? "a conversation")", systemImage: "arrow.triangle.branch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    let rows = TranscriptRow.rows(state.items)
                    let answers = TranscriptRow.turnEnds(rows, busy: state.live.busy)
                    ForEach(rows) { row in
                        switch row {
                        case let .item(item, resent):
                            TranscriptItemView(item: item, state: state, store: store, resent: resent)
                                .contextMenu { itemMenu(item) }
                                .background {
                                    if found == item.id {
                                        RoundedRectangle(cornerRadius: 16).fill(.yellow.opacity(0.22)).padding(-6)
                                    }
                                }
                                .id(row.id)
                            if answers.contains(item.id), let text = item.text, !text.isEmpty {
                                AnswerActions(text: text) { fork(at: item) }
                            }
                        case let .work(_, steps):
                            WorkRow(steps: steps, state: state, store: store)
                        case let .voiceSession(session, date, lines):
                            VoiceSessionHeader(session: session, date: date, lines: lines)
                        }
                    }
                    LiveView(state: state, store: store)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(TranscriptScrollProbe(scroll: keyboardScroll))
                .environment(\.holdTranscriptPosition, TranscriptPositionHold(scroll: keyboardScroll))
            }
            .defaultScrollAnchor(.bottom)
            // Short conversations start at the top; overflowing transcripts still follow the latest content.
            .defaultScrollAnchor(.top, for: .alignment)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { old, new in
                keyboardScroll.resize(from: old, to: new)
                // Follow the laid-out transcript, including thinking, tool calls and result cards.
                // Model changes can arrive before the bottom anchor has moved. A row the user opens stays where it is.
                if old.contentSize != new.contentSize, keyboardScroll.followsContent {
                    if let found, atFound {
                        proxy.scrollTo(TranscriptRow.ID.item(found), anchor: .center)
                    } else {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .onScrollPhaseChange { _, phase in
                keyboardScroll.phaseChanged(phase)
                // The user takes over from the found message.
                if phase == .tracking || phase == .interacting { atFound = false }
            }
            .task(id: state.loaded) {
                // The rows are laid out a moment after the transcript arrives.
                guard state.loaded else { return }
                for _ in 0..<2 {
                    try? await Task.sleep(for: .milliseconds(60))
                    guard let found, atFound else { return }
                    proxy.scrollTo(TranscriptRow.ID.item(found), anchor: .center)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaBar(edge: .bottom) {
                composer
            }
        }
        .overlay {
            if state.loaded && state.items.isEmpty && !state.live.busy {
                // The suggestions step aside once something is typed or attached.
                let idle = draft.isEmpty && attachments.isEmpty && skill == nil && voice.phase == .idle
                ConversationWelcome(modelLine: modelLine, suggestions: idle ? ConversationWelcome.suggestions(offline: state.model?.provider == "scripted") : []) { prompt in
                    draft = prompt
                    composing = true
                }
                .transition(.opacity)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sent)
        .navigationTitle(meta?.title ?? "Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { header }
            ToolbarItem(placement: .topBarTrailing) {
                // Talk to Pi in this conversation: what is said and asked goes here.
                Button { path.append(.voice(continuing: conversationId)) } label: {
                    Image(systemName: "waveform")
                }
                .accessibilityLabel("Talk to Pi here")
                .accessibilityIdentifier("conversation.voice")
                .disabled(store.phase != .ready)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let meta {
                        ShareLink(item: ConversationMarkdown(id: meta.id, title: meta.title), preview: SharePreview(meta.title)) {
                            Label("Export as Markdown", systemImage: "square.and.arrow.up")
                        }
                        if meta.archivedAt == nil {
                            Button("Archive", systemImage: "archivebox") {
                                Task {
                                    await store.archive(meta.id)
                                    leave()
                                }
                            }
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = meta }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
                .accessibilityIdentifier("conversation.more")
                .disabled(store.phase != .ready || meta == nil)
            }
        }
        .deleteConversationDialog($deleting, store: store) { leave() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear {
            if let message = store.takeFoundMessage(conversationId) {
                found = message
                atFound = true
            }
            store.conversationAppeared(conversationId)
            store.watch(conversationId)
            // What was left here last time; a view that stayed alive under a pushed screen still holds it.
            if let kept = store.takeComposerDraft(conversationId), kept != .init(text: draft, attachments: attachments, skill: skill) {
                draft = [draft, kept.text].filter { !$0.isEmpty }.joined(separator: "\n")
                attachments += kept.attachments
                skill = skill ?? kept.skill
            }
        }
        .background(BackSwipeStopsPlayback())
        .onDisappear {
            VoicePlayback.shared.stop()
            store.conversationDisappeared(conversationId)
            voice.cancel()
            store.keepComposerDraft(.init(text: draft, attachments: attachments, skill: skill), for: conversationId)
        }
        .onChange(of: store.drafts[conversationId], initial: true) { takeDraft() }
    }

    /// Back to the screen under this conversation, once it is archived or deleted.
    private func leave() {
        if case .conversation(conversationId)? = path.last { path.removeLast() }
    }

    /// A share sheet item opened to edit: its text goes ahead of anything typed, its attachments after the ones here.
    private func takeDraft() {
        guard let shared = store.takeDraft(conversationId) else { return }
        draft = [shared.text, draft].filter { !$0.isEmpty }.joined(separator: "\n")
        attachments += shared.attachments
        composing = true
    }

    /// The title, and under it the model, or while a run goes how long it has been working, or that it waits for you.
    private var header: some View {
        VStack(spacing: 0) {
            Text(meta?.title ?? "Conversation").font(.headline).lineLimit(1)
            Group {
                if store.approvals.contains(where: { $0.conversationId == conversationId }) {
                    Text("Waiting for you").foregroundStyle(.orange)
                } else if state.live.busy, let since = state.busySince {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Working · \(WorkRow.elapsed(context.date.timeIntervalSince(since)))").monospacedDigit()
                    }
                } else {
                    Text(modelLine)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        // The bar lays a principal item out at its ideal width after a cancelled back swipe, and a long title's
        // ideal width runs past the screen. Capped to the room between the back buttons, the title truncates instead.
        .frame(maxWidth: width > 0 ? max(width - 136, 120) : nil)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation.header")
    }

    /// The model the conversation started with, and its effort unless thinking is off. Both are set in Settings, for new conversations.
    private var modelLine: String {
        // Nothing until the transcript has loaded, rather than a moment of "No model".
        guard state.model != nil else { return state.loaded ? store.modelName(nil) : " " }
        let name = store.modelName(state.model)
        return state.thinkingLevel == "off" ? name : "\(name) · \(ThinkingLevel.name(state.thinkingLevel)) effort"
    }

    @ViewBuilder private func itemMenu(_ item: DisplayItem) -> some View {
        if let text = item.text, !text.isEmpty {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
        }
        if item.kind == .assistant || item.kind == .user {
            Button("Fork from here", systemImage: "arrow.triangle.branch") { fork(at: item) }
        }
    }

    private func fork(at item: DisplayItem) {
        Task {
            if let fork = await store.fork(conversationId, at: item.id) { path.append(.conversation(fork.id)) }
        }
    }

    private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty || skill != nil }

    /// The "/" menu's skills while a "/" command is typed at the start of an otherwise empty composer.
    private var suggestedSkills: [SkillLibrary.Skill] {
        guard skill == nil, attachments.isEmpty, let query = SkillSuggestions.query(draft) else { return [] }
        return SkillSuggestions.matches(store.invocableSkills, query)
    }

    private var imagesUnseen: Bool {
        store.model(state.model)?.images == false && attachments.contains { if case .image = $0.content { true } else { false } }
    }

    /// Photos, Camera (one new photo) and Files (images, PDFs, text files).
    private var attachMenu: some View {
        Menu {
            Button("Photos", systemImage: "photo.on.rectangle") { choosingPhotos = true }
            Button("Camera", systemImage: "camera") { takingPhoto = true }
                .disabled(!CameraPicker.isAvailable)
            Button("Files", systemImage: "folder") { importingFiles = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .medium))
                .frame(width: Self.fieldHeight, height: Self.fieldHeight)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .tint(.primary)
        .accessibilityLabel("Attach")
        .accessibilityIdentifier("attach.menu")
    }

    private func attach(_ work: @escaping @Sendable () async -> [Attachment]) {
        attaching += 1
        Task {
            let loaded = await Task.detached(operation: work).value
            attachments += loaded
            attaching -= 1
        }
    }

    private func attachPhoto(_ data: Data?) {
        takingPhoto = false
        guard let data else { return }
        attach { Attachments.saveImage(data).map { [$0] } ?? [] }
    }

    private func attachPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoItems = []
        attach {
            var loaded: [Attachment] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self), let image = Attachments.saveImage(data) { loaded.append(image) }
            }
            return loaded
        }
    }

    private func attachFiles(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        attach {
            urls.compactMap { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return Attachments.file(url)
            }
        }
    }

    /// The height of a one-line field, and of the Attach button beside it.
    private static let fieldHeight: CGFloat = 44

    /// Attach in a circle before the field, and Send (or Stop) in one after it, always there.
    private var composer: some View {
        VStack(spacing: 8) {
            if !state.queue.isEmpty { queue }
            if !suggestedSkills.isEmpty {
                SkillSuggestions(skills: suggestedSkills) { picked in
                    skill = picked.name
                    draft = ""
                    composing = true
                }
            }
            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    attachMenu
                    field
                    primaryButton
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .animation(.snappy, value: state.queue)
        .animation(.snappy, value: attachments)
        .animation(.snappy, value: skill)
        .animation(.snappy, value: state.live.busy)
        .modifier(VoiceFeedback(voice: voice))
        .photosPicker(isPresented: $choosingPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: photoItems) { attachPhotos(photoItems) }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { attachPhoto($0) }.ignoresSafeArea()
        }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.image, .pdf, .text, .json, .sourceCode], allowsMultipleSelection: true) {
            attachFiles($0)
        }
    }

    /// Attachments over the text, as Messages puts them in its field; a capsule while it holds one line.
    private var field: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let skill {
                SkillChip(name: skill) { self.skill = nil }
                    .padding([.horizontal, .top], 8)
            }
            if !attachments.isEmpty || attaching > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        AttachmentStrip(attachments: attachments) { removed in attachments.removeAll { $0.id == removed.id } }
                        if attaching > 0 { ProgressView().controlSize(.small) }
                    }
                    if imagesUnseen {
                        Label("This model can't see images", systemImage: "eye.slash").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding([.horizontal, .top], 8)
            }
            if voice.phase == .idle {
                HStack(alignment: .bottom, spacing: 4) {
                    TextField(skill != nil ? "Add to /\(skill!)" : state.live.busy ? "Queue a message" : "Message", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($composing)
                        .padding(.leading, 16)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("composer")
                    if draft.isEmpty {
                        micButton
                            .padding(6)
                            .transition(.opacity)
                    }
                }
                .frame(minHeight: Self.fieldHeight)
            } else {
                recording
                    .frame(minHeight: Self.fieldHeight)
            }
        }
        .contentShape(.rect(cornerRadius: Self.fieldHeight / 2))
        .glassEffect(.regular, in: .rect(cornerRadius: Self.fieldHeight / 2))
    }

    /// Starts voice input; the transcript goes into the field, to edit before sending.
    private var micButton: some View {
        Button {
            composing = false
            Task {
                await voice.start(diagnostics: store.diagnostics) { [store, conversationId] text in
                    store.addDraft(text, to: conversationId)
                }
            }
        } label: {
            Image(systemName: "mic")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dictate")
        .accessibilityIdentifier("voice.start")
    }

    /// In place of the text while voice input records (Cancel, the input level, the time, Done) or transcribes.
    @ViewBuilder private var recording: some View {
        if voice.phase == .recording {
            HStack(spacing: 8) {
                Button("Cancel", systemImage: "xmark") { voice.cancel() }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(.circle)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("voice.cancel")
                VoiceLevels(levels: voice.levels)
                    .frame(maxWidth: .infinity)
                if let since = voice.startedAt {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(Duration.seconds(context.date.timeIntervalSince(since)).formatted(.time(pattern: .minuteSecond)))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Button { voice.finish() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.tint, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Done")
                .accessibilityIdentifier("voice.done")
            }
            .padding(.leading, 6)
            .padding(.trailing, 6)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Transcribing…").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("voice.transcribing")
        }
    }

    /// Send, or Stop while an answer runs and the field is empty. Text typed during an answer is queued. Dimmed while
    /// there is nothing to send, attachments are loading, or voice input is on.
    private var primaryButton: some View {
        let stops = state.live.busy && !hasDraft
        let enabled = stops || (hasDraft && attaching == 0 && voice.phase == .idle)
        return Button {
            if stops {
                Task { await store.abort(conversationId) }
            } else {
                let text = draft
                let sent = attachments
                let ran = skill
                composing = false
                draft = ""
                attachments = []
                skill = nil
                self.sent += 1
                found = nil
                atFound = false
                Task { await store.send(text, attachments: sent, skill: ran, to: conversationId) }
            }
        } label: {
            Image(systemName: stops ? "stop.fill" : "arrow.up")
                .font(.system(size: stops ? 15 : 18, weight: .bold))
                .foregroundStyle(enabled ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                .frame(width: Self.fieldHeight, height: Self.fieldHeight)
                .contentTransition(.symbolEffect(.replace))
                .glassEffect(enabled ? .regular.tint(.accentColor).interactive() : .regular, in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(.snappy, value: stops)
        .animation(.snappy, value: enabled)
        .accessibilityLabel(stops ? "Stop" : state.live.busy ? "Queue" : "Send")
        .accessibilityIdentifier(stops ? "stop" : "send")
    }

    /// Messages waiting for the answer to finish. Each can steer the answer, go back to the composer, or be removed.
    private var queue: some View {
        VStack(spacing: 0) {
            ForEach(Array(state.queue.enumerated()), id: \.element.id) { index, message in
                if index > 0 { Divider().padding(.leading, 40) }
                QueuedRow(
                    message: message,
                    working: queueActions.contains(message.id),
                    steer: { act(on: message) { await store.steer(message, in: conversationId) } },
                    edit: { edit(message) },
                    remove: { act(on: message) { _ = await store.withdraw(message, from: conversationId) } }
                )
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
    }

    private func act(on message: QueuedMessage, _ action: @escaping () async -> Void) {
        guard queueActions.insert(message.id).inserted else { return }
        Task {
            await action()
            queueActions.remove(message.id)
        }
    }

    /// Withdraws a queued message into the composer, its text and attachments ahead of what is already there.
    private func edit(_ message: QueuedMessage) {
        act(on: message) {
            guard let taken = await store.takeBack(message, from: conversationId) else { return }
            draft = [taken.text, draft].filter { !$0.isEmpty }.joined(separator: "\n")
            attachments = taken.attachments + attachments
            if let ran = taken.skill { skill = ran }
            composing = true
        }
    }
}

/// Moves the transcript up as the keyboard (or the composer) takes room and back down as it gives it back, as Messages
/// does, on the keyboard's own curve. Keeps out of the way while the user drags, or interactive dismissal gets stuck.
@MainActor
private final class TranscriptKeyboardScroll: NSObject {
    weak var view: UIScrollView?
    private var target: CGFloat?
    private var scheduled = false
    private var interacting = false
    private var animationEnd = Date.distantPast
    private var animationOptions: UIView.AnimationOptions = []
    private var heldUntil = Date.distantPast

    var allowsAutomaticScrolling: Bool {
        !interacting && view?.isTracking != true && view?.isDragging != true && view?.isDecelerating != true
    }

    /// Whether a change in the transcript's height should take it to the end.
    var followsContent: Bool { allowsAutomaticScrolling && Date() >= heldUntil }

    /// A row the user opens or closes changes the transcript's height too; don't follow it through its animation.
    func hold() { heldUntil = Date().addingTimeInterval(0.6) }

    func attach(_ view: UIScrollView) {
        guard self.view !== view else { return }
        self.view = view
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    func phaseChanged(_ phase: ScrollPhase) {
        // Keep hands off through the drag and its settling animation, including a cancelled dismissal.
        if phase == .tracking || phase == .interacting { interacting = true; target = nil }
        if phase == .idle { interacting = false }
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
        let curve = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
        animationEnd = Date().addingTimeInterval(duration)
        animationOptions = [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState, .allowUserInteraction]
    }

    func resize(from old: ScrollGeometry, to new: ScrollGeometry) {
        guard allowsAutomaticScrolling, old.contentSize == new.contentSize else { target = nil; return }
        let shift = old.containerSize.height - new.containerSize.height
        if shift != 0, old.containerSize.height > 0 {
            let position = target ?? (old.contentOffset.y + old.contentInsets.top)
            target = min(max(position + shift, 0), max(0, new.contentSize.height - new.containerSize.height))
        }
        guard target != nil, !scheduled else { return }
        scheduled = true
        // The keyboard notification and the final insets arrive after the viewport's first layout pass.
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    private func apply() {
        scheduled = false
        guard allowsAutomaticScrolling, let view, let target else { self.target = nil; return }
        let y = target - view.adjustedContentInset.top
        let bottom = max(-view.adjustedContentInset.top, view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height)
        guard y <= bottom + 0.5 else { return }
        self.target = nil
        let duration = max(0, animationEnd.timeIntervalSinceNow)
        UIView.animate(withDuration: duration, delay: 0, options: animationOptions) {
            view.contentOffset = CGPoint(x: view.contentOffset.x, y: y)
        }
    }
}

/// Called by a transcript row the user opens or closes (thinking, tool calls), so the transcript stays put. Equal when
/// it holds the same transcript, so setting it again doesn't invalidate every row that reads it, as a closure would.
struct TranscriptPositionHold: Equatable {
    fileprivate weak var scroll: TranscriptKeyboardScroll?

    @MainActor func callAsFunction() { scroll?.hold() }

    static func == (a: Self, b: Self) -> Bool { a.scroll === b.scroll }
}

extension EnvironmentValues {
    @Entry var holdTranscriptPosition = TranscriptPositionHold()
}

/// Hands the transcript's UIScrollView to `TranscriptKeyboardScroll`.
private struct TranscriptScrollProbe: UIViewRepresentable {
    let scroll: TranscriptKeyboardScroll

    func makeUIView(context: Context) -> Probe { Probe(scroll: scroll) }
    func updateUIView(_ uiView: Probe, context: Context) {}

    final class Probe: UIView {
        let scroll: TranscriptKeyboardScroll
        init(scroll: TranscriptKeyboardScroll) {
            self.scroll = scroll
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var ancestor = superview
            while let candidate = ancestor {
                if let view = candidate as? UIScrollView { scroll.attach(view); break }
                ancestor = candidate.superview
            }
        }
    }
}

/// The composer's animation, haptics and alert for voice input.
private struct VoiceFeedback: ViewModifier {
    @Bindable var voice: VoiceInput

    private var failed: Binding<Bool> {
        Binding(get: { voice.error != nil }, set: { if !$0 { voice.error = nil } })
    }

    func body(content: Content) -> some View {
        content
            .animation(.snappy, value: voice.phase)
            .sensoryFeedback(trigger: voice.phase) { old, new in
                new == .recording ? .start : old == .recording ? .stop : nil
            }
            .alert("Voice input", isPresented: failed) {
                Button("OK") {}
            } message: {
                Text(voice.error ?? "")
            }
    }
}

/// The microphone's recent input levels as bars, newest on the right.
private struct VoiceLevels: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                // Full height, scaled: a scale is drawn, not laid out, so each level update moves no other view.
                Capsule()
                    .fill(.tint)
                    .frame(width: 3, height: 24)
                    .scaleEffect(y: (4 + CGFloat(levels[index]) * 20) / 24)
            }
        }
        .frame(height: 24)
        .animation(.linear(duration: 0.06), value: levels)
        .accessibilityHidden(true)
    }
}

private struct QueuedRow: View {
    let message: QueuedMessage
    let working: Bool
    let steer: () -> Void
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: message.steering ? "arrow.turn.down.right" : "clock")
                .font(.footnote)
                .foregroundStyle(message.steering ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(message.text)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(message.steering ? "Sent when the running tools finish" : "Sent when this answer finishes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture(perform: edit)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Edits the message")
            if working {
                ProgressView().controlSize(.small)
            } else {
                if !message.steering {
                    Button("Steer", systemImage: "arrow.turn.down.right", action: steer)
                        .labelStyle(.titleOnly)
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .accessibilityHint("Sends it now: after the running tools, or by stopping the answer")
                        .accessibilityIdentifier("queue.steer")
                }
                Button("Remove", systemImage: "xmark", action: remove)
                    .labelStyle(.iconOnly)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(.circle)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("queue.remove")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .contextMenu {
            if !message.steering { Button("Steer", systemImage: "arrow.turn.down.right", action: steer) }
            Button("Edit", systemImage: "pencil", action: edit)
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
            Button("Remove", systemImage: "xmark", role: .destructive, action: remove)
        }
        .disabled(working)
    }
}

/// A new conversation's empty page: the logo, the model it runs on, and a few things to try, each of which fills the
/// composer (to edit before sending) rather than sending, so nothing reaches a provider without the user's say.
struct ConversationWelcome: View {
    struct Suggestion: Identifiable {
        let symbol: String
        let tint: Color
        let title: String
        let prompt: String
        var id: String { prompt }
    }

    let modelLine: String
    let suggestions: [Suggestion]
    let pick: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    /// With the offline demo model, prompts that start with the words it answers to (js/src/app/scripted.ts).
    static func suggestions(offline: Bool) -> [Suggestion] {
        offline ? [
            Suggestion(symbol: "calendar", tint: .red, title: "What's on my calendar today?", prompt: "Calendar for today"),
            Suggestion(symbol: "checklist", tint: .orange, title: "Make a checklist card", prompt: "Card with a checklist for my errands"),
            Suggestion(symbol: "square.grid.2x2.fill", tint: .cyan, title: "Design a morning widget", prompt: "Widget for my morning"),
            Suggestion(symbol: "text.alignleft", tint: .indigo, title: "Show what answers look like", prompt: "Markdown sample"),
        ] : [
            Suggestion(symbol: "calendar", tint: .red, title: "What's on my calendar today?", prompt: "What's on my calendar today?"),
            Suggestion(symbol: "checklist", tint: .orange, title: "Remind me to water the plants", prompt: "Remind me to water the plants at 6 pm"),
            Suggestion(symbol: "square.grid.2x2.fill", tint: .cyan, title: "Make a widget for my day", prompt: "Make a Home Screen widget with my steps and my next event"),
            Suggestion(symbol: "timer", tint: .pink, title: "Set a 10 minute timer", prompt: "Set a timer for 10 minutes"),
        ]
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            content(withSuggestions: true)
            content(withSuggestions: false)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Only the suggestions come and go here; nothing else in the conversation animates with them.
        .animation(.easeOut(duration: 0.2), value: suggestions.isEmpty)
        .onAppear { shown = true }
    }

    private func content(withSuggestions: Bool) -> some View {
        VStack(spacing: 0) {
            PiLogo()
                .frame(height: 44)
                .padding(.bottom, 16)
                .accessibilityHidden(true)
            Text("Ask Pi anything")
                .font(.title2.weight(.semibold))
            Text(modelLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            if withSuggestions && !suggestions.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        button(suggestion)
                            .opacity(shown || reduceMotion ? 1 : 0)
                            .offset(y: shown || reduceMotion ? 0 : 8)
                            .animation(.easeOut(duration: 0.3).delay(0.05 * Double(index)), value: shown)
                    }
                }
                .frame(maxWidth: 380)
                .padding(.top, 28)
                .transition(.opacity)
            }
        }
    }

    private func button(_ suggestion: Suggestion) -> some View {
        Button {
            pick(suggestion.prompt)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: suggestion.symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(suggestion.tint)
                    .frame(width: 24)
                Text(suggestion.title)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        .accessibilityHint("Puts it in the message field")
        .accessibilityIdentifier("welcome.suggestion")
    }
}
