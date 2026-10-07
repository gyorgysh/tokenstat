// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI
import Observation

/// Scene/account-owned setup, independent of the adaptive content branches.
@MainActor @Observable
final class ClientSetupSession {
    struct Presentation: Identifiable { let id = UUID() }
    private(set) var presentation: Presentation?
    var model = ClientSetupModel()
    var library: SSHLibraryModel
    var path: [SetupStep] = []
    var entryAttempted = false
    @ObservationIgnored private let ownership: SSHOperationOwner
    @ObservationIgnored private var preparation: (UUID, Task<Void, Never>)?

    init(scope: WorkReference.Scope?) {
        ownership = SSHOperationOwner(scope: scope)
        library = SSHLibraryModel(ownerScope: scope)
    }

    func open() {
        guard ownership.claim() != nil, presentation == nil else { return }
        model = ClientSetupModel()
        path = []; entryAttempted = false
        presentation = Presentation()
    }

    func close(_ id: UUID) {
        guard presentation?.id == id else { return }
        cancelPreparation()
        model.retire()
        path = []; entryAttempted = false
        presentation = nil
    }

    func cancelPreparation() {
        preparation?.1.cancel()
        preparation = nil
    }

    /// Cancellation of a remounted view's waiter cannot cancel setup loading.
    func prepare() async {
        guard presentation != nil, ownership.claim() != nil, !model.prepared else { return }
        if let current = preparation { await current.1.value; return }
        let id = UUID(), model = model, library = library
        let task = Task { _ = await model.prepare(library: library) }
        preparation = (id, task)
        await task.value
        if preparation?.0 == id { preparation = nil }
    }

    func deactivate() {
        ownership.retire()
        if let presentation { close(presentation.id) }
        cancelPreparation()
        model.retire()
        library.deactivate()
    }
}

struct ClientSetupPresentation: ViewModifier {
    @Bindable var session: ClientSetupSession
    func body(content: Content) -> some View {
        let request = session.presentation
        content.fullScreenCover(item: Binding(
            get: { session.presentation },
            set: { value in
                if value == nil, let request { session.close(request.id) }
            }
        )) { request in
            ClientSetupWizard(session: session)
                .id(request.id)
        }
    }
}
#endif
