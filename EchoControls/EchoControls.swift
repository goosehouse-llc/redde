import AppIntents
import SwiftUI
import WidgetKit

@main
struct EchoControlsBundle: WidgetBundle {
    var body: some Widget {
        ListenControl()
        HandsFreeControl()
        CaptureControl()
        // The Home Screen's, revamped 2026-11-24: Up Next, Needs You, Lists, Your Day, Your
        // Agents (in Last Reply's place) and Goals; then the ones that were there before.
        UpNextWidget()
        NeedsYouWidget()
        ListsWidget()
        DayWidget()
        AgentsWidget()
        GoalsWidget()
        QuickAskWidget()
        ContextWidget()
        BoardWidget()
        EchoTurnLiveActivity()
        AlarmCountdownActivity()
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

/// Quick capture: one tap, Redde opens listening for a note.
struct CaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.goosehouse.echo.capture") {
            ControlWidgetButton(action: StartCaptureIntent()) {
                Label("Note to Redde", systemImage: "square.and.pencil")
            }
        }
        .displayName("Note to Redde")
        .description("Open Redde and say a note for it to file.")
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
