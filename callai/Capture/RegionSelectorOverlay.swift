import AppKit
import SwiftUI

// WHY: Overlay only returns coordinates — the capture itself is performed by
// `SCKitScreenCaptureService`. Keeping the two responsibilities separate lets
// callers (Stage 6.2 AppCoordinator) sequence "select region → composer →
// capture" without coupling the UI to ScreenCaptureKit.
//
// Coordinate convention (read together with ScreenCaptureService.swift):
//   We resolve drag locations to AppKit global screen coordinates (bottom-left
//   origin, primary display at (0,0) — same space as `NSScreen.frame`). The
//   capture service then re-projects into a display-local top-left rect.
//
// M6 follow-up — multi-display: a single union-framed NSWindow only renders on
// one display when the union spans negative coordinates (common when the
// primary monitor is not the top-left). We now create one borderless
// NSWindow per NSScreen and share a single ContinuationResolver between them.
@MainActor
final class RegionSelectorOverlay {
    init() {}

    func presentForRegion() async throws -> CGRect {
        // WHY: A single non-cancelling continuation handle shared between the
        // SwiftUI drag callback (which may fire from any per-display window)
        // and the AppKit keyDown/rightMouseDown monitor. Both paths can fire;
        // the resolver guarantees `resume` is called exactly once.
        let resolver = ContinuationResolver()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGRect, Error>) in
            resolver.continuation = continuation

            let screens = NSScreen.screens.isEmpty
                ? (NSScreen.main.map { [$0] } ?? [])
                : NSScreen.screens

            var windows: [RegionSelectorWindow] = []
            windows.reserveCapacity(screens.count)

            for screen in screens {
                let window = RegionSelectorWindow.make(for: screen)
                let rootView = RegionSelectorRootView(
                    windowFrame: window.frame,
                    onSelected: { [weak resolver] rect in
                        resolver?.finish(with: .success(rect))
                    },
                    onCancel: { [weak resolver] in
                        resolver?.finish(with: .failure(ScreenCaptureError.cancelled))
                    }
                )
                let hosting = NSHostingView(rootView: rootView)
                hosting.frame = NSRect(origin: .zero, size: window.frame.size)
                hosting.autoresizingMask = [.width, .height]
                window.contentView = hosting
                windows.append(window)
            }
            resolver.windows = windows

            // Single local monitor — escape + right-click cancellation. Scoped
            // to the current process; we tear it down in `finish`. Registering
            // once (not per-window) avoids double-fire on multi-display setups.
            let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown]) { [weak resolver] event in
                guard let resolver else { return event }
                if event.type == .keyDown && event.keyCode == 0x35 /* Esc */ {
                    resolver.finish(with: .failure(ScreenCaptureError.cancelled))
                    return nil
                }
                if event.type == .rightMouseDown {
                    resolver.finish(with: .failure(ScreenCaptureError.cancelled))
                    return nil
                }
                return event
            }
            resolver.eventMonitor = monitor

            // WHY: if a monitor is hot-unplugged or the display arrangement
            // changes while the overlay is up, the per-screen windows we just
            // created no longer line up with reality — the user could finish a
            // drag on a window that's about to be orphaned, producing a
            // displayNotFound at capture time. Cleaner UX: cancel the
            // selection, let the caller reinvoke against the new arrangement.
            let screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak resolver] _ in
                Task { @MainActor [weak resolver] in
                    resolver?.finish(with: .failure(ScreenCaptureError.cancelled))
                }
            }
            resolver.screenObserver = screenObserver

            for window in windows {
                window.orderFrontRegardless()
            }
            // Bring the window under the cursor to key status so keyDown reaches
            // our local monitor even when called from a menu-bar (LSUIElement)
            // context with no other app windows.
            let cursor = NSEvent.mouseLocation
            let keyWindow = windows.first(where: { $0.frame.contains(cursor) }) ?? windows.first
            keyWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Continuation resolver

@MainActor
private final class ContinuationResolver {
    var continuation: CheckedContinuation<CGRect, Error>?
    var windows: [NSWindow] = []
    var eventMonitor: Any?
    var screenObserver: NSObjectProtocol?

    func finish(with result: Result<CGRect, Error>) {
        guard let continuation else { return }
        self.continuation = nil

        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()

        continuation.resume(with: result)
    }
}

// MARK: - Window

private final class RegionSelectorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    static func make(for screen: NSScreen) -> RegionSelectorWindow {
        // One borderless window per NSScreen. Pass GLOBAL coords as
        // contentRect with screen=nil — when `screen:` is non-nil, AppKit
        // interprets contentRect's origin as offset-from-that-screen, so
        // passing global `screen.frame` shoves non-primary windows off the
        // visible union (the bug that left dim layers on a single display
        // even though one window was created per NSScreen).
        let window = RegionSelectorWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Belt-and-braces — some macOS versions ignore the contentRect when
        // the deduced screen differs from the actual position. Force the
        // frame after init so the window snaps to the intended display.
        window.setFrame(screen.frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        return window
    }
}

// MARK: - SwiftUI overlay

private struct RegionSelectorRootView: View {
    let windowFrame: CGRect
    let onSelected: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    var body: some View {
        GeometryReader { _ in
            ZStack {
                // Dim layer — full window. Hairline so the marching-rectangle
                // selection still reads against a bright desktop.
                Color.black.opacity(0.25)
                    .ignoresSafeArea()

                if let rect = currentSelectionInView() {
                    // Punch-out: redraw the selection region with no dim to
                    // give the user a live preview of what will be captured.
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .blendMode(.destinationOut)

                    Rectangle()
                        .strokeBorder(Color.accentColor, lineWidth: 1)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .compositingGroup()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = value.startLocation
                        }
                        dragCurrent = value.location
                    }
                    .onEnded { value in
                        let start = dragStart ?? value.startLocation
                        let end = value.location
                        dragStart = nil
                        dragCurrent = nil

                        let viewRect = Self.normalisedRect(from: start, to: end)
                        guard viewRect.width > 0, viewRect.height > 0 else {
                            onCancel()
                            return
                        }
                        // Convert SwiftUI top-left view coords → AppKit
                        // bottom-left global screen coords using THIS window's
                        // own frame (each per-display window has its own).
                        let globalRect = Self.viewRectToGlobalScreenRect(
                            viewRect: viewRect,
                            windowFrame: windowFrame
                        )
                        onSelected(globalRect)
                    }
            )
        }
    }

    private func currentSelectionInView() -> CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        let rect = Self.normalisedRect(from: start, to: current)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    private static func normalisedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        let x = min(a.x, b.x)
        let y = min(a.y, b.y)
        let w = abs(a.x - b.x)
        let h = abs(a.y - b.y)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func viewRectToGlobalScreenRect(viewRect: CGRect, windowFrame: CGRect) -> CGRect {
        // SwiftUI gives us a top-left origin local to the hosting view. The
        // hosting view fills the window, which lives at `windowFrame` in AppKit
        // global (bottom-left) coordinates. So: global X = windowFrame.minX +
        // viewRect.minX, and global Y (bottom-left of the selection rect) =
        // windowFrame.maxY − viewRect.maxY.
        let globalX = windowFrame.minX + viewRect.minX
        let globalY = windowFrame.maxY - viewRect.maxY
        return CGRect(x: globalX, y: globalY, width: viewRect.width, height: viewRect.height)
    }
}
