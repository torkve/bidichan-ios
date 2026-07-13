import SwiftUI
import SwiftTerm
import BidichanKit

/// An interactive shell backed by a bidichan shell channel in the extension.
/// SwiftTerm renders the terminal; bytes are relayed to/from the extension over
/// the provider IPC (input via `shellWrite`, output via a `shellRead` long-poll).
struct ShellView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TerminalContainer(tunnel: model.tunnel)
            .navigationTitle("Shell")
            .navigationBarTitleDisplayMode(.inline)
            .ignoresSafeArea(.container, edges: .bottom)
    }
}

struct TerminalContainer: UIViewRepresentable {
    let tunnel: TunnelManager

    func makeCoordinator() -> Coordinator { Coordinator(tunnel: tunnel) }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.close()
    }

    /// Bridges the SwiftTerm delegate to the extension's shell session.
    /// NOTE: `TerminalViewDelegate`'s required method set is version-specific;
    /// reconcile with the installed SwiftTerm if the build complains.
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let tunnel: TunnelManager
        private weak var terminal: TerminalView?
        private var shellID: String?
        private var readTask: Task<Void, Never>?

        init(tunnel: TunnelManager) { self.tunnel = tunnel }

        func attach(_ view: TerminalView) {
            terminal = view
            let term = view.getTerminal()
            Task { await open(cols: term.cols, rows: term.rows) }
        }

        private func open(cols: Int, rows: Int) async {
            do {
                let resp = try await tunnel.send(.shellOpen(term: "xterm-256color", rows: rows, cols: cols))
                guard resp.ok, let id = resp.shellID else {
                    feed("\r\n[shell open failed: \(resp.error ?? "unknown")]\r\n")
                    return
                }
                shellID = id
                startReading(id)
            } catch {
                feed("\r\n[shell error: \(error.localizedDescription)]\r\n")
            }
        }

        private func startReading(_ id: String) {
            readTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    do {
                        let resp = try await self.tunnel.send(.shellRead(id))
                        if resp.eof == true {
                            self.feed("\r\n[shell closed]\r\n")
                            break
                        }
                        if let b64 = resp.dataBase64,
                           let data = Data(base64Encoded: b64), !data.isEmpty {
                            await MainActor.run {
                                self.terminal?.feed(byteArray: ArraySlice(data))
                            }
                        }
                    } catch {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                }
            }
        }

        private func feed(_ text: String) {
            Task { @MainActor in self.terminal?.feed(text: text) }
        }

        func close() {
            readTask?.cancel()
            readTask = nil
            if let id = shellID {
                Task { [tunnel] in _ = try? await tunnel.send(.shellClose(id)) }
            }
            shellID = nil
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard let id = shellID else { return }
            let b64 = Data(data).base64EncodedString()
            Task { [tunnel] in _ = try? await tunnel.send(.shellWrite(id, base64: b64)) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard let id = shellID else { return }
            Task { [tunnel] in _ = try? await tunnel.send(.shellResize(id, rows: newRows, cols: newCols)) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func bell(source: TerminalView) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    }
}
