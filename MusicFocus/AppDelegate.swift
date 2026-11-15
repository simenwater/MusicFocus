//
//  AppDelegate.swift
//  MusicFocus
//
//  Created by 姜伯龙 on 2025/3/7.
//

import UIKit
import UserNotifications

/**
 * @class AppDelegate
 * @description 应用程序委托，处理应用程序生命周期相关事件
 */
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor private var backgroundTasks: [UUID: UIBackgroundTaskIdentifier] = [:]
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        // 设置通知代理
        UNUserNotificationCenter.current().delegate = self
        
        // 配置音频会话以支持后台运行
        PracticeAudioCapture.prepareIdleAudioSession()
        
        return true
    }
    
    /**
     * @method userNotificationCenter
     * @description 当应用在前台时收到通知的处理
     */
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // 在前台也显示通知
        completionHandler([.banner, .list])
    }
    
    /**
     * @method applicationWillResignActive
     * @description 当应用将要进入非活动状态时调用
     */
    func applicationWillResignActive(_ application: UIApplication) {
        beginBackgroundTask(in: application, duration: 30)
    }
    
    /**
     * @method applicationDidEnterBackground
     * @description 当应用进入后台时调用
     */
    func applicationDidEnterBackground(_ application: UIApplication) {
        print("应用进入后台")
        
        beginBackgroundTask(in: application, duration: 180)
    }

    @MainActor
    private func beginBackgroundTask(in application: UIApplication, duration: TimeInterval) {
        // 回调捕获固定令牌；任务编号统一由主线程保存和清理。
        let token = UUID()
        let taskID = application.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask(token, in: application)
        }
        guard taskID != .invalid else { return }
        backgroundTasks[token] = taskID

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.endBackgroundTask(token, in: application)
        }
    }

    @MainActor
    private func endBackgroundTask(_ token: UUID, in application: UIApplication) {
        // 系统过期回调和定时回调可能先后发生，每个任务只结束一次。
        guard let taskID = backgroundTasks.removeValue(forKey: token) else { return }
        application.endBackgroundTask(taskID)
    }
    
    /**
     * @method applicationWillEnterForeground
     * @description 当应用将要进入前台时调用
     */
    func applicationWillEnterForeground(_ application: UIApplication) {
        print("应用进入前台")
        
        // 重新配置音频会话
        PracticeAudioCapture.prepareIdleAudioSession()
    }
}
