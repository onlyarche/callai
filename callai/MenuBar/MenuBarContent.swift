import SwiftUI

struct MenuBarContent: View {
    let onboardingStatus: OnboardingStatus
    let onOpenOnboarding: () -> Void
    let onOpenComposer: () -> Void
    let onRegionThenComposer: () -> Void
    let onOpenMainWindow: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        Button(
            onboardingStatus.isComplete ? "온보딩 다시 열기" : "⚠ 설정 완료하기",
            action: onOpenOnboarding
        )

        Divider()

        Button("Composer 열기", action: onOpenComposer)
        Button("영역 + Composer", action: onRegionThenComposer)
        Button("메인 창 열기", action: onOpenMainWindow)

        Divider()

        Button("설정", action: onOpenSettings)

        Divider()

        Button("종료", action: onQuit)
    }
}
