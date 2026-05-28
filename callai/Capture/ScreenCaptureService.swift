import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

// WHY: Protocol kept Sendable so a capture service can be passed across actor
// boundaries (e.g. AppCoordinator on @MainActor → capture pipeline). Caller is
// responsible for encoding the returned CGImage (PNG/base64). Capture stage
// intentionally does not bake an encoding choice in.
protocol ScreenCaptureService: Sendable {
    func capture(rect: CGRect) async throws -> CGImage
}

// WHY: Four error cases mirror the host UI's needs (Stage 6.2 inline banner):
// permission denied (TCC), user-cancelled selection, malformed region, and any
// other capture failure. `userFacingMessage` extension lives in this file so the
// type + its mapping stay co-located, matching the LLMClient.swift convention.
enum ScreenCaptureError: Error, Equatable, Sendable {
    case permissionDenied
    case cancelled
    case invalidRegion
    // WHY: distinguishes "the selected region's displayID disappeared between
    // overlay drag and SCShareableContent lookup" (hot-unplug, screen
    // re-arrangement) from a genuinely degenerate rect — the former is a
    // transient environment change, not a user mistake, and deserves its own
    // CTA wording ("다시 선택해 주세요") instead of the misleading "잘못된
    // 영역" message that .invalidRegion was producing.
    case displayNotFound
    case captureFailed(message: String)
}

extension ScreenCaptureError {
    // Wording mirrors `LLMClientError.userFacingMessage` (Conversation/ConversationStore.swift).
    var userFacingMessage: String {
        switch self {
        case .permissionDenied:
            return "화면 녹화 권한이 필요합니다. 시스템 설정에서 권한을 부여하세요."
        case .cancelled:
            return "캡쳐가 취소되었습니다."
        case .invalidRegion:
            return "선택한 영역이 잘못되었습니다."
        case .displayNotFound:
            return "선택한 화면이 사라졌습니다. 모니터 연결을 확인하고 다시 선택해 주세요."
        case .captureFailed(let message):
            return "화면 캡쳐 실패: \(message)"
        }
    }
}

// WHY: SCScreenshotManager.captureImage(contentFilter:configuration:) is the
// macOS 14+ one-shot screenshot API — no SCStream lifecycle to manage, ideal
// for a single region grab. Deployment target is macOS 14 (PLAN §1) so the
// symbol is available unconditionally.
//
// Coordinate convention (matches RegionSelectorOverlay's contract):
//   `rect` is in GLOBAL screen coordinates using the AppKit/Quartz convention
//   used by NSScreen.frame: origin bottom-left of the primary display, Y grows
//   upward. (NOT the CG global top-left coords that SCDisplay.frame uses —
//   `mapNSScreenGlobalRect` bridges between the two.)
final class SCKitScreenCaptureService: ScreenCaptureService {
    init() {}

    func capture(rect: CGRect) async throws -> CGImage {
        // Reject degenerate regions up-front so the rest of the pipeline can
        // assume positive width/height.
        guard rect.width > 0, rect.height > 0,
              rect.width.isFinite, rect.height.isFinite else {
            throw ScreenCaptureError.invalidRegion
        }

        // SCShareableContent.current is the recommended async accessor. Any
        // failure here is almost always TCC denial; map by error code, default
        // to .captureFailed.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw Self.mapShareableContentError(error)
        }

        // Build the (displayID, NSScreen.frame) table on the main actor so the
        // map helper stays pure. NSScreen reads must happen on the main thread.
        let displayInfos: [DisplayInfo] = await MainActor.run {
            NSScreen.screens.compactMap { screen -> DisplayInfo? in
                guard let id = screen.callai_displayID else { return nil }
                return DisplayInfo(displayID: id, screenFrame: screen.frame, backingScale: screen.backingScaleFactor)
            }
        }

        guard let mapped = Self.mapNSScreenGlobalRect(rect, displayInfos: displayInfos) else {
            // No NSScreen contained or intersected the rect — the rect itself
            // is degenerate or points at empty union space.
            throw ScreenCaptureError.invalidRegion
        }
        guard let display = content.displays.first(where: { $0.displayID == mapped.displayID }) else {
            // NSScreen matched but the displayID is no longer in SCShareableContent
            // — almost always a monitor that was unplugged between overlay
            // close and capture, or a Sidecar/AirPlay display that dropped.
            throw ScreenCaptureError.displayNotFound
        }
        let local = mapped.sourceRect
        guard local.width > 0, local.height > 0 else {
            throw ScreenCaptureError.invalidRegion
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let configuration = SCStreamConfiguration()
        // Output pixel dimensions = region's point dimensions × display backing
        // scale, so HiDPI displays return a 1:1 pixel image of the selection.
        let scale = mapped.backingScale
        configuration.width = max(1, Int((local.width * scale).rounded()))
        configuration.height = max(1, Int((local.height * scale).rounded()))
        configuration.sourceRect = local
        configuration.capturesAudio = false
        // WHY: cursor hidden — selection arrow / hotkey-driven capture should
        // not bake the system cursor into the screenshot.
        configuration.showsCursor = false

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return image
        } catch {
            throw Self.mapCaptureError(error)
        }
    }

    // MARK: - Coordinate mapping

    // Stub-friendly value type so the mapping helper stays pure (no NSScreen /
    // SCDisplay instances required). Tests can construct DisplayInfo arrays
    // directly once a test target exists.
    struct DisplayInfo: Equatable, Sendable {
        let displayID: CGDirectDisplayID
        let screenFrame: CGRect    // NSScreen.frame: AppKit bottom-left global coords
        let backingScale: CGFloat
    }

    struct DisplayMatch: Equatable {
        let displayID: CGDirectDisplayID
        let sourceRect: CGRect     // Top-left, local to the matched display, in points
        let backingScale: CGFloat
    }

    // WHY: SCDisplay.frame is in CG global *top-left* coordinates while our
    // overlay returns *AppKit bottom-left* (NSScreen) globals. Matching across
    // two systems silently breaks on multi-display layouts whenever the
    // primary monitor is not the top-left of the union. We avoid the issue
    // entirely by routing through NSScreen.frame for the match, then
    // converting to that screen's LOCAL top-left rect (which is what
    // SCStreamConfiguration.sourceRect expects).
    //
    // Core formula (NSScreen bottom-left global → NSScreen local top-left):
    //   localX = rect.minX − screen.minX
    //   localY = screen.maxY − rect.maxY           (flip Y inside the screen)
    static func mapNSScreenGlobalRect(_ rect: CGRect, displayInfos: [DisplayInfo]) -> DisplayMatch? {
        guard !displayInfos.isEmpty else { return nil }

        // Primary match: the screen whose frame contains the rect's origin.
        // (Rect origin = bottom-left in our convention, which is how the
        // overlay reports the selection.)
        let originHit = displayInfos.first(where: { $0.screenFrame.contains(rect.origin) })

        // Fallback: largest area-intersection — guards against an origin
        // landing in empty space between irregular monitor arrangements.
        let chosen = originHit ?? displayInfos.max(by: { lhs, rhs in
            lhs.screenFrame.intersection(rect).callai_area
                < rhs.screenFrame.intersection(rect).callai_area
        })
        guard let info = chosen else { return nil }

        let screen = info.screenFrame
        let localX = rect.minX - screen.minX
        let localY = screen.maxY - rect.maxY
        let sourceRect = CGRect(x: localX, y: localY, width: rect.width, height: rect.height)
        return DisplayMatch(displayID: info.displayID, sourceRect: sourceRect, backingScale: info.backingScale)
    }

    // MARK: - Error mapping

    private static func mapShareableContentError(_ error: Error) -> ScreenCaptureError {
        if let captured = error as? ScreenCaptureError { return captured }
        let nsError = error as NSError
        if Self.isPermissionDenied(nsError: nsError) {
            return .permissionDenied
        }
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
            return .cancelled
        }
        return .captureFailed(message: nsError.localizedDescription)
    }

    private static func mapCaptureError(_ error: Error) -> ScreenCaptureError {
        if let captured = error as? ScreenCaptureError { return captured }
        if error is CancellationError {
            return .cancelled
        }
        let nsError = error as NSError
        if Self.isPermissionDenied(nsError: nsError) {
            return .permissionDenied
        }
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
            return .cancelled
        }
        return .captureFailed(message: nsError.localizedDescription)
    }

    private static func isPermissionDenied(nsError: NSError) -> Bool {
        // Heuristic per SCStreamError codes: -3801 (userDeclined) and -3812
        // (missingEntitlements) reliably mean "no screen recording permission".
        // If Apple changes the codes we surface .captureFailed instead — that's
        // a safer default than masking unknown failures as permission issues.
        guard nsError.domain == SCStreamErrorDomain || nsError.domain == "com.apple.ScreenCaptureKit" else {
            return false
        }
        switch nsError.code {
        case -3801, -3812:
            return true
        default:
            return false
        }
    }
}

private extension CGRect {
    var callai_area: CGFloat { width * height }
}

private extension NSScreen {
    var callai_displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value
    }
}
