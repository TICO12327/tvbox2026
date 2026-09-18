import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("首页", systemImage: "sparkles") }
            DiscoverView()
                .tabItem { Label("发现", systemImage: "magnifyingglass") }
            SourcesView()
                .tabItem { Label("源管理", systemImage: "dot.radiowaves.left.and.right") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "slider.horizontal.3") }
        }
        .tint(.cyan)
    }
}

struct AppBackground<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.04, blue: 0.075).ignoresSafeArea()
            Circle()
                .fill(Color.cyan.opacity(0.13))
                .blur(radius: 70)
                .frame(width: 260, height: 260)
                .offset(x: 150, y: -280)
            Circle()
                .fill(Color.indigo.opacity(0.18))
                .blur(radius: 90)
                .frame(width: 320, height: 320)
                .offset(x: -180, y: 300)
            content
        }
    }
}

extension Color {
    static let flowCard = Color.white.opacity(0.075)
}
