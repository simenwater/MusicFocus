//
//  MusicFocusApp.swift
//  MusicFocus
//
//  Created by 姜伯龙 on 2025/3/7.
//

import SwiftUI
import Combine
import AVFoundation
import AVFAudio

/**
 * @struct MusicFocusApp
 * @description 应用程序入口
 */
@main
struct MusicFocusApp: App {
    // 创建共享的 FocusManager 实例
    @StateObject private var focusManager = FocusManager()
    @StateObject private var scoreLibrary = ScoreLibrary()
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // Microphone permission is requested by startSession, only when the user
    // chooses to track practice. Browsing scores needs no audio permission.

    // Renewals, refunds and Ask to Buy approvals arrive at any time.
    init() {
        if ScoreSyncAvailability.internet { ScoreRoomSubscription.shared.start() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(focusManager)
                .environmentObject(scoreLibrary)
                .task { await scoreLibrary.load() }
                // Reuse an open window when another app sends a document.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { notification in
                    focusManager.handleAppStateChange(notification: notification as NSNotification)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { notification in
                    focusManager.handleAppStateChange(notification: notification as NSNotification)
                }
                .onAppear {
                    // 节拍器响着时，检测策略需要知道麦克风里有它的声音
                    let monitor = focusManager.audioMonitor
                    Metronome.shared.onAudibleChanged = { [weak monitor] audible in
                        monitor?.updateMetronomeActive(audible)
                    }
                    monitor.updateMetronomeActive(Metronome.shared.isAudible)
                    PracticePitchFeed.shared.isEnabled = PitchSettings.shared.isEnabled
                    // 应用启动时自动初始化音频监测
                    if focusManager.isActive {
                        focusManager.toggleAudioMonitoring()
                    }
                }
        }
    }
}
