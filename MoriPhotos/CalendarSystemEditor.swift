import SwiftUI
import EventKit
import EventKitUI

struct CalendarPresentation: Identifiable {
    let id = UUID()
    let store: EKEventStore
    let event: EKEvent
    let isNew: Bool
}

struct CalendarEventSheet: UIViewControllerRepresentable {
    let presentation: CalendarPresentation
    let saved: (Date, String) -> Void
    let close: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UINavigationController {
        let result: UINavigationController
        if presentation.isNew {
            let editor = EKEventEditViewController()
            editor.eventStore = presentation.store
            editor.event = presentation.event
            editor.editViewDelegate = context.coordinator
            result = editor
        } else {
            let viewer = EKEventViewController()
            viewer.event = presentation.event
            viewer.allowsEditing = true // EventKitUI additionally enforces invitation / calendar write permissions.
            viewer.allowsCalendarPreview = false
            viewer.delegate = context.coordinator
            let done = UIBarButtonItem(barButtonSystemItem: .done, target: context.coordinator, action: #selector(Coordinator.done))
            done.accessibilityIdentifier = "calendarSheetDone"
            viewer.navigationItem.leftBarButtonItem = done
            result = UINavigationController(rootViewController: viewer)
        }
        result.view.tintColor = UIColor(Theme.accent)
        result.view.accessibilityIdentifier = "calendarSystemSheet"
        return result
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) { context.coordinator.parent = self }
    final class Coordinator: NSObject, EKEventEditViewDelegate, EKEventViewDelegate {
        var parent: CalendarEventSheet
        init(parent: CalendarEventSheet) { self.parent = parent }
        @objc func done() { parent.close() }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            if action == .saved, let event = controller.event, let date = event.startDate, let calendar = event.calendar {
                parent.saved(date, calendar.calendarIdentifier)
            }
            parent.close()
        }
        func eventViewController(_ controller: EKEventViewController, didCompleteWith action: EKEventViewAction) { parent.close() }
    }
}
