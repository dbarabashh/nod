import SwiftUI

extension View {
    /// Reports this view's current width into `width` on layout and whenever it
    /// changes. A clear background `GeometryReader`, so it adds no visual.
    func readingWidth(into width: Binding<CGFloat>) -> some View {
        background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { width.wrappedValue = geo.size.width }
                    .onChange(of: geo.size.width) { width.wrappedValue = $0 }
            }
        )
    }
}
