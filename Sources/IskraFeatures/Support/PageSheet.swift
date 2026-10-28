import SwiftUI
import IskraDesign

/// A sheet standing on the conversation's page — on a Mac. On iPhone and iPad it is `.sheet`,
/// unchanged.
///
/// A Mac sheet is a window of its own, and each list and form in it painted its own grey: the
/// system's list colour, the settings page's near-black — a third and a fourth colour beside the
/// chat it came up over. Here the sheet's background is the chat's page, the lists in it draw none
/// of their own, and a grouped form is told to stand on the same page (`EnvironmentValues.formPage`).
///
/// Every sheet goes through this, except the ones that show a picture full-size on black.
extension View {
    func pageSheet<Content: View>(isPresented: Binding<Bool>,
                                  onDismiss: (() -> Void)? = nil,
                                  @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            content().onPage()
        }
    }

    func pageSheet<Item: Identifiable, Content: View>(item: Binding<Item?>,
                                                      onDismiss: (() -> Void)? = nil,
                                                      @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        sheet(item: item, onDismiss: onDismiss) { value in
            content(value).onPage()
        }
    }

    @ViewBuilder
    private func onPage() -> some View {
        #if os(macOS)
        self
            .scrollContentBackground(.hidden)
            .environment(\.formPage, Color.page)
            .presentationBackground(Color.page)
        #else
        self
        #endif
    }
}
