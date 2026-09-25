import AppIntents
import SwiftUI
import WidgetKit

@main
struct EchoControlsBundle: WidgetBundle {
    var body: some Widget {
        ListenControl()
        HandsFreeControl()
        LastReplyWidget()
        QuickAskWidget()
        EchoTurnLiveActivity()
    }
}

/// Control Center / Lock Screen / Action Button: one tap, Echo opens listening.
struct ListenControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.goosehouse.echo.listen") {
            ControlWidgetButton(action: StartListeningIntent()) {
                Label("Ask Redde", systemImage: "waveform")
            }
        }
        .displayName("Ask Redde")
        .description("Open Redde and start listening.")
    }
}

struct HandsFreeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.goosehouse.echo.handsfree") {
            ControlWidgetButton(action: StartHandsFreeIntent()) {
                Label("Talk with Redde", systemImage: "ear")
            }
        }
        .displayName("Talk with Redde")
        .description("Open Redde in hands-free mode.")
    }
}
