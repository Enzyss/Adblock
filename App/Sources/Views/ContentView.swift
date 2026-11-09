import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Protezione", systemImage: "shield.lefthalf.filled") }
            FiltersView()
                .tabItem { Label("Filtri", systemImage: "line.3.horizontal.decrease.circle") }
            ActivityView()
                .tabItem { Label("Attività", systemImage: "list.bullet.rectangle") }
            RulesView()
                .tabItem { Label("Eccezioni", systemImage: "hand.raised") }
        }
    }
}
