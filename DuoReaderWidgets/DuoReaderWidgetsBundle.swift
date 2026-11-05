import SwiftUI
import WidgetKit

@main
struct DuoReaderWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ShelfWidget()
        NowReadingWidget()
        ReadingProgressWidget()
    }
}
