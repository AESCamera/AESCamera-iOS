import SwiftUI

struct CameraScreen: View {
    @Binding var path: NavigationPath
    var body: some View {
        Button("Gallery") { path.append(Route.gallery) }
    }
}
