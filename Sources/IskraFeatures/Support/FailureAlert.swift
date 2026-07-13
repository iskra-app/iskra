import SwiftUI
import IskraCore

extension View {
    /// The apology, written once.
    ///
    /// Five screens can refuse something, and until now all five carried their own copy of
    /// this — the same title, the same OK button, and the same fiddly hand-built `Binding`
    /// that puts the failure back to `nil` when the alert is dismissed. The copies were
    /// identical, which meant the *next* one would be too, and that giving failures a Retry
    /// button one day would be a five-file edit.
    ///
    /// Any `ActionFailure` drives it, because a failure knows the sentence it wants to say
    /// and nothing else. What an apology looks like is this modifier's business, and it is
    /// the only place that knows.
    func failureAlert<Failure: ActionFailure>(_ failure: Binding<Failure?>) -> some View {
        alert(Text(Strings.Problem.title),
              isPresented: Binding(get: { failure.wrappedValue != nil },
                                   set: { if !$0 { failure.wrappedValue = nil } }),
              presenting: failure.wrappedValue) { _ in
            Button(String(app: Strings.Problem.ok)) { failure.wrappedValue = nil }
        } message: { failure in
            Text(failure.explanation)
        }
    }
}
