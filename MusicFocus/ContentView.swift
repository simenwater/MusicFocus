//
//  ContentView.swift
//  MusicFocus
//
//  Created by 姜伯龙 on 2025/3/7.
//

import SwiftUI

/**
 * @struct ContenView
 * @description 应用主视图
 */
struct ContentView: View {
    @EnvironmentObject var focusManager: FocusManager
    @EnvironmentObject private var scoreLibrary: ScoreLibrary
    @State private var selectedTab = 0
    @State private var externalWindowID = UUID()
    
    var body: some View {
        // 统一iPad和iPhone的布局，都使用标签栏导航
        TabView(selection: $selectedTab) {
            Group {
                if UIDevice.current.userInterfaceIdiom == .pad {
                    ScoreLibraryView(isPracticeHome: true)
                } else {
                    FocusTimerView()
                }
            }
                .tabItem {
                    Label("Practice Tab".localized, systemImage: "clock.fill")
                }
                .tag(0)

            PracticeRecordView()
                .tabItem {
                    Label("Records Tab".localized, systemImage: "list.bullet.clipboard")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings".localized, systemImage: "gearshape.fill")
                }
                .tag(3)
        }
        // Keep the three navigation entries at the bottom on iPad as well.
        .environment(\.horizontalSizeClass, .compact)
        .tint(.blue) // 设置选中时的颜色
        .environment(\.scoreExternalWindowID, externalWindowID)
        .onOpenURL { url in
            if let invitation = ScoreRoomInvitation(url: url) {
                if ScoreSyncAvailability.internet { selectedTab = 0 }
                scoreLibrary.openRoomInvitation(invitation, windowID: externalWindowID)
            } else {
                scoreLibrary.openExternalFile(url, windowID: externalWindowID)
            }
        }
        .onChange(of: scoreLibrary.externalRequestID) { _, _ in
            if scoreLibrary.handlesExternalFiles(in: externalWindowID) { selectedTab = 0 }
        }
        .onAppear {
            // 使用适合iOS设备的外观
            let appearance = UITabBarAppearance()
            appearance.configureWithDefaultBackground()
            
            // 添加细微阴影
            appearance.shadowColor = UIColor.black.withAlphaComponent(0.1)
            
            UITabBar.appearance().standardAppearance = appearance
            
            if #available(iOS 15.0, *) {
                UITabBar.appearance().scrollEdgeAppearance = appearance
            }
        }
    }
}

// Only the window receiving the document may consume its pending navigation.
private struct ScoreExternalWindowIDKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}
extension EnvironmentValues {
    var scoreExternalWindowID: UUID? {
        get { self[ScoreExternalWindowIDKey.self] }
        set { self[ScoreExternalWindowIDKey.self] = newValue }
    }
}

/**
 * @struct EmptyPreviewProvider
 * @description 预览提供者
 */
#Preview("主界面") {
    let manager = FocusManager()
    return ContentView()
        .environmentObject(manager)
        .environmentObject(ScoreLibrary())
}
