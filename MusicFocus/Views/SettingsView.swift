//
//  SettingsView.swift
//  MusicFocus
//
//  Created by 姜伯龙 on 2025/3/7.
//

import SwiftUI
import UIKit
import SafariServices

private enum AppReleaseInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }
}

/**
 * @struct SettingsView
 * @description 应用设置视图
 */
struct SettingsView: View {
    @EnvironmentObject var focusManager: FocusManager
    @EnvironmentObject private var scoreLibrary: ScoreLibrary
    @Environment(\.scoreExternalWindowID) private var externalWindowID
    @State private var silenceDelayDraft = SilenceConfirmationSettings.defaultDelay
    @State private var editingSilenceDelay = false
    @AppStorage(ScoreFingeringFont.defaultsKey) private var fingeringFont = ScoreFingeringFont.handwritten
    @State private var showAboutSheet = false
    @State private var showBeianWebView = false

    var body: some View {
        NavigationStack {
            VStack {
                HStack {
                    Text("Settings".localized)
                        .font(.title)
                        .fontWeight(.bold)
                        .padding(.horizontal)

                    Spacer()
                }
                .padding(.top)
                     Form {
                    Section {
                        Picker("score.fingeringFont".localized, selection: $fingeringFont) {
                            ForEach(ScoreFingeringFont.allCases, id: \.self) { font in
                                Text(font.title).tag(font)
                            }
                        }
                        .accessibilityIdentifier("scoreFingeringFont")
                        Text("1  2  3  4  5")
                            .font(fingeringFont == .timesNewRoman ? .custom("TimesNewRomanPSMT", size: 28) : .system(size: 28, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("scoreFingeringFontPreview")
                    } header: { Text("score.annotationSettings".localized) }
                    footer: { Text("score.fingeringFontHint".localized) }
                    if ScoreSyncAvailability.internet {
                        Section(header: Text("score.sync.connectionSettings".localized)) {
                            ScoreSyncServerPicker()
                        }
                    }
                    ScoreBackupSettings()
                    Section(header: Text("Audio Monitoring Settings".localized)) {
                        PracticeModePicker()
                        Text("弱音会结合环境声音自动判断，无需手动设置音量门槛。".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Silence Confirmation Delay".localized)
                                Spacer()
                                Menu {
                                    ForEach(SilenceConfirmationSettings.presets, id: \.self) { seconds in
                                        Button(seconds == 0
                                            ? "0s (Immediate)".localized
                                            : "%d seconds".localizedFormat(seconds)) {
                                            silenceDelayDraft = Double(seconds)
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(silenceDelayDraft == 0
                                            ? "0s (Immediate)".localized
                                            : "%d seconds".localizedFormat(Int(silenceDelayDraft)))
                                            .monospacedDigit()
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.caption2)
                                    }
                                }
                                .disabled(focusManager.isActive)
                                .accessibilityLabel("Silence Confirmation Delay".localized)
                                .accessibilityValue("%d seconds".localizedFormat(Int(silenceDelayDraft)))
                                .accessibilityIdentifier("silenceConfirmationDelayMenu")
                            }
                            Slider(value: $silenceDelayDraft, in: SilenceConfirmationSettings.delayRange, step: 1) { editing in
                                editingSilenceDelay = editing
                                if !editing { focusManager.selectSilenceConfirmationDelay(silenceDelayDraft) }
                            }
                                .disabled(focusManager.isActive)
                                .accessibilityLabel("Silence Confirmation Delay".localized)
                                .accessibilityValue("%d seconds".localizedFormat(Int(silenceDelayDraft)))
                                .accessibilityIdentifier("silenceConfirmationDelaySlider")
                            HStack {
                                Text("duration.seconds".localizedFormat(0))
                                Spacer()
                                Text("duration.seconds".localizedFormat(Int(SilenceConfirmationSettings.delayRange.upperBound)))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        }
                        Text("Silence is never counted as practice. Brief silence stays within the same segment; longer silence confirms an interruption. Speech and noise do not use this delay.".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if focusManager.isActive {
                            Text("Finish this session to change the delay.".localized)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Text("声音分析约每 0.5 秒更新一次，仍有分析窗口带来的短暂延迟。".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        // 暂时隐藏后台监测模式 - 功能需要进一步优化
                        /*
                        Toggle(isOn: $focusManager.enableBackgroundMode) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Enable Background Monitoring Mode".localized)
                                Text("When enabled, the app will continue monitoring practice in the background but won't count distraction time".localized)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .onChange(of: focusManager.enableBackgroundMode) { _, _ in
                            focusManager.saveSettings()
                        }
                        */
                    }
                             // 暂时隐藏乐器声音学习功能
                    /*
                    Section(header: Text("乐器声音学习".localized)) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("录制您的乐器声音，让应用更准确地识别".localized)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                             if focusManager.audioMonitor.isRecordingTemplate {
                                // 显示录制进度
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("正在录制乐器声音...".localized)
                                        .font(.headline)
                                        .foregroundColor(.orange)
                                                             ProgressView(value: focusManager.audioMonitor.recordingProgress)
                                        .progressViewStyle(LinearProgressViewStyle())
                                        .frame(height: 8)
                                                             Text("请演奏您的乐器，保持稳定的音量".localized)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 5)
                            } else if focusManager.audioMonitor.hasLearnedInstrument {
                                // 显示已学习状态
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("已学习您的乐器声音".localized)
                                        .foregroundColor(.green)
                                    Spacer()
                                }
                                .padding(.vertical, 5)
                            }
                                             Text("提示：录制时请在安静环境下演奏您的乐器，持续30秒钟".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 5)
                        }
                        .padding(.vertical, 5)
                    }
                    */
                             // 隐藏账户设置部分
                    /*
                    Section(header: Text("账户".localized)) {
                        NavigationLink(destination: AccountView()) {
                            settingRow(title: "账户设置".localized, icon: "person.crop.circle", color: .blue)
                        }
                                     // 登录状态显示
                        HStack {
                            Text("登录状态".localized)
                            Spacer()
                            Text(focusManager.isLoggedIn() ? "已登录".localized : "未登录".localized)
                                .foregroundColor(focusManager.isLoggedIn() ? .green : .secondary)
                        }
                        .padding(.vertical, 8)
                                     if focusManager.isLoggedIn() {
                            HStack {
                                Text("用户名".localized)
                                Spacer()
                                Text(focusManager.currentUser?.username ?? "")
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    */
                             Section(header: Text("About".localized)) {
                        HStack {
                            Text("Version".localized)
                            Spacer()
                            Text(AppReleaseInfo.version)
                                .foregroundColor(.secondary)
                        }
                        Link("Privacy Policy".localized,
                             destination: URL(string: "https://feuxfollets.top/apps/MusicFocus/privacy.html")!)
                        Link("Source Code and Licenses".localized,
                             destination: URL(string: "https://github.com/simenwater/MusicFocus")!)
                        Button(action: {
                            showAboutSheet = true
                        }) {
                            HStack {
                                Text("About MusicFocus".localized)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // 更新备案信息部分年份
                    Section {
                        VStack(alignment: .center, spacing: 8) {
                            Text("Copyright © 2025 Jiang Bolong".localized)
                                .font(.footnote)
                                .foregroundColor(.secondary)

                            Button(action: {
                                showBeianWebView = true
                            }) {
                                Text("京ICP备2025117523号-2A".localized)
                                    .font(.footnote)
                                    .foregroundColor(.blue)
                                    .underline()
                            }
                            .sheet(isPresented: $showBeianWebView) {
                                SafariView(url: URL(string: "https://beian.miit.gov.cn/")!)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                }
            }
            .onAppear { silenceDelayDraft = focusManager.silenceConfirmationDelay }
            .onChange(of: scoreLibrary.externalRequestID) { _, _ in
                guard scoreLibrary.handlesExternalFiles(in: externalWindowID) else { return }
                showAboutSheet = false
                showBeianWebView = false
            }
            .onChange(of: focusManager.silenceConfirmationDelay) { _, value in
                if !editingSilenceDelay { silenceDelayDraft = value }
            }
            .onChange(of: silenceDelayDraft) { _, value in
                // Accessibility adjustments also save when there is no drag.
                if !editingSilenceDelay { focusManager.selectSilenceConfirmationDelay(value) }
            }
            .sheet(isPresented: $showAboutSheet) {
                AboutView()
            }

        }
    }
    
    // 设置行视图函数
    @ViewBuilder
    private func settingRow(title: String, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.1))
                .clipShape(Circle())
             Text(title)
                .font(.body)
             Spacer()
             Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding(.vertical, 8)
    }
}

/**
 * @struct AboutView
 * @description 关于页面，显示应用的操作手册
 */
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showBeianWebView = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 标题和版本
                    VStack(alignment: .center, spacing: 5) {
                        Image("Image1")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 120, height: 120)
                            .padding(.bottom, 10)
                                     Text("MusicFocus")
                            .font(.system(size: 28, weight: .bold))

                        Text("MusicFocus v\(AppReleaseInfo.version)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                             // 操作手册内容
                    Group {
                        sectionHeader("版本信息".localized)

                        detailItem("名称".localized, "MusicFocus (音乐专注)".localized)
                        detailItem("版本".localized, AppReleaseInfo.version)
                        detailItem("开发者".localized, "姜伯龙".localized)
                                     Divider()
                                     sectionHeader("产品特点".localized)
                                     featureSection(
                            title: "本机练琴检测".localized,
                            items: [
                                "在设备上区分乐器、人声和其他声音".localized,
                                "支持专注练琴、允许说话和声乐／弹唱模式".localized,
                                "无声切段等待可选 0–60 秒，等待时间不计入练习".localized,
                                "当前不评价音准、错音或演奏质量".localized
                            ],
                            iconName: "waveform.circle.fill",
                            color: .blue
                        )

                        featureSection(
                            title: "勋章激励系统".localized,
                            items: [
                                "基于练习时长的多级勋章奖励".localized,
                                "七个等级勋章：青铜、白银、黄金、铂金、钻石、大师、王者".localized,
                                "历史勋章记录和展示功能".localized,
                                "直观的进度显示，鼓励持续练习".localized
                            ],
                            iconName: "medal.fill",
                            color: .orange
                        )
                                     featureSection(
                            title: "专注练习辅助".localized,
                            items: [
                                "专注计时器，实时跟踪练习时间".localized,
                                "自动检测分心状态，区分专注和分心时间".localized,
                                "分心记录功能，追踪并分析练习中断".localized,
                                "专注数据统计：本次练习、分心时间和累计时间".localized
                            ],
                            iconName: "timer",
                            color: .green
                        )
                                     featureSection(
                            title: "练习笔记".localized,
                            items: [
                                "在记录页记下曲目和本周练习重点".localized,
                                "勾选已完成，随时修改文字".localized,
                                "原教师笔记继续保留在本机".localized
                            ],
                            iconName: "note.text",
                            color: .purple
                        )

                        featureSection(
                            title: "练习记录管理".localized,
                            items: [
                                "详细记录每次练习的曲目和改进".localized,
                                "练习会话回顾".localized,
                                "练习内容编辑功能".localized,
                                "时间线式练习历史查看".localized
                            ],
                            iconName: "list.bullet.clipboard",
                            color: .orange
                        )
                                     Divider()
                                     sectionHeader("Operation Guide".localized)
                                     guideSection(
                            title: "Getting Started".localized,
                            steps: [
                                "After opening the app, you will see the main interface".localized,
                                "Tap the start button to begin your practice session".localized,
                                "The app will automatically start monitoring audio and recording time".localized
                            ]
                        )
                                     guideSection(
                            title: "Focus Timer Feature".localized,
                            steps: [
                                "Start Focus: Tap the start button on the main interface".localized,
                                "End Focus: Tap the end button, optionally record practice content".localized,
                                "View Focus Data: Main interface displays current focus time and distraction time".localized,
                                "View History: Tap the record area to view historical practice sessions".localized
                            ]
                        )
                                     guideSection(
                            title: "Audio Monitoring Feature".localized,
                            steps: [
                                "The app automatically detects audio environment, no manual operation required".localized,
                                "Monitoring results are displayed in real-time on the interface:".localized,
                                "  • Volume Level: Displays current volume in decibels".localized,
                                "  • Instrument Recognition: Shows probability of detecting instrument sound".localized,
                                "  • Sound Type: Distinguishes between music, noise, and quiet states".localized
                            ]
                        )
                                     guideSection(
                            title: "Distraction Management".localized,
                            steps: [
                                "The app automatically detects practice interruptions and records them as distractions".localized,
                                "When instrument sound interruption is detected, the timer automatically pauses".localized,
                                "When instrument sound is detected again, timing automatically resumes".localized,
                                "Tap distraction records to view detailed distraction history".localized
                            ]
                        )
                                     guideSection(
                            title: "Badge System".localized,
                            steps: [
                                "Automatically earn badges when practice duration reaches specific thresholds".localized,
                                "Seven badge levels corresponding to different practice durations:".localized,
                                "  • Bronze Badge: 30-60 minutes".localized,
                                "  • Silver Badge: 1-1.5 hours".localized,
                                "  • Gold Badge: 1.5-2 hours".localized,
                                "  • Platinum Badge: 2-3 hours".localized,
                                "  • Diamond Badge: 3-4 hours".localized,
                                "  • Master Badge: 4-6 hours".localized,
                                "  • King Badge: 6+ hours".localized,
                                "View all your earned badges on the practice record page".localized
                            ]
                        )
                                     guideSection(
                            title: "Practice Content Recording".localized,
                            steps: [
                                "At the end of practice, you can record the following content:".localized,
                                "  • Practice Pieces: Name of pieces currently being practiced".localized,
                                "  • Improvements Made: Record progress and improvements during practice".localized,
                                "  • Other Notes: Any relevant notes and thoughts".localized,
                                "These records will be saved associated with the practice session".localized
                            ]
                        )
                                     guideSection(
                            title: "Practice Review".localized,
                            steps: [
                                "Tap the record area on the main interface".localized,
                                "View all practice sessions in the popup list".localized,
                                "Tap the edit button on the right side of a session to modify practice content".localized,
                                "Tap Done to return to the main interface".localized
                            ]
                        )
                                     Divider()
                                     sectionHeader("Frequently Asked Questions".localized)
                                     faqSection(
                            title: "App cannot detect audio".localized,
                            answers: [
                                "Please ensure microphone permission is granted".localized,
                                "Check if device volume is turned on".localized,
                                "Ensure practicing in a quiet environment to reduce background noise".localized
                            ]
                        )
                                     faqSection(
                            title: "Distraction detection is inaccurate".localized,
                            answers: [
                                "Choose a practice mode that matches instruments, speech or singing.".localized,
                                "Ensure instrument sound is clear enough, avoid too low volume".localized,
                                "Try to minimize environmental noise interference".localized
                            ]
                        )
                                     Divider()
                                     sectionHeader("Privacy and Data".localized)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Data Storage".localized)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .padding(.top, 5)

                            // Existing localization keys retain updated local/nearby and voice-note disclosures.
                            Text("• All practice data is stored only on local device".localized)
                                .font(.body)
                            Text("• The app does not upload or share your personal information".localized)
                                .font(.body)
                            Text("• No account creation required, all basic features available without login".localized)
                                .font(.body)
                                             Text("Audio Processing".localized)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .padding(.top, 10)

                            Text("• Audio monitoring is performed entirely locally on device, no raw audio upload".localized)
                                .font(.body)
                            Text("• The app only analyzes audio features, does not record or store your performance".localized)
                                .font(.body)
                            Text("• Audio processing algorithms optimized for various instruments, providing accurate practice monitoring".localized)
                                .font(.body)
                                             Text("Network Usage".localized)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .padding(.top, 10)

                            Text("• Practice detection, records, notes and badges work offline.".localized)
                                .font(.body)
                            Text("• Practice timing, audio monitoring, distraction detection, practice recording, statistical analysis, badge system and other features do not require network connection".localized)
                                .font(.body)
                            Text("• Opening external websites requires an internet connection.".localized)
                                .font(.body)
                            Text((ScoreSyncAvailability.internet ? "score.sync.privacyDevelopment" : "score.sync.privacyLocal").localized)
                                .font(.body)
                                             Text("Permission Usage".localized)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .padding(.top, 10)

                            Text("• Microphone Permission: Used for audio monitoring and instrument sound recognition".localized)
                                .font(.body)

                            DisclosureGroup("Handwriting data acknowledgements".localized) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("The offline fingering model uses adapted pen trajectories from these public datasets, licensed under CC BY 4.0.".localized)
                                    Link("Pen-Based Recognition of Handwritten Digits — Alpaydin & Alimoglu (1996)",
                                         destination: URL(string: "https://doi.org/10.24432/C5MG6K")!)
                                    Link("UJI Pen Characters (Version 2) — Prat, Castro, Llorens, Marzal & Vilar (2008)",
                                         destination: URL(string: "https://doi.org/10.24432/C5FG8S")!)
                                    Link("Creative Commons Attribution 4.0",
                                         destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                                }
                                .font(.caption)
                                .padding(.top, 8)
                            }
                            .padding(.top, 10)
                        }
                        .padding(.horizontal)
                    }
                    .padding(.horizontal)
                }
                .padding()
            }
            .navigationBarTitle("关于".localized, displayMode: .inline)
            .navigationBarItems(trailing: Button("关闭".localized) {
                dismiss()
            })
        }
    }
    
    // 辅助函数：创建章节标题
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .fontWeight(.bold)
            .padding(.vertical, 5)
    }
    
    // 辅助函数：创建详情项
    private func detailItem(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
        }
    }
    
    // 辅助函数：创建特点部分
    private func featureSection(title: String, items: [String], iconName: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: iconName)
                    .foregroundColor(color)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
             ForEach(items, id: \.self) { item in
                HStack(alignment: .top) {
                    Text("•")
                        .foregroundColor(color)
                    Text(item)
                        .font(.body)
                }
                .padding(.leading, 5)
            }
        }
        .padding(.vertical, 5)
    }
    
    // 辅助函数：创建指南部分
    private func guideSection(title: String, steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
             ForEach(0..<steps.count, id: \.self) { index in
                if !steps[index].hasPrefix("  ") { // 如果不是缩进项目
                    HStack(alignment: .top) {
                        // 显示步骤序号或小圆点
                        if steps[index].hasPrefix("•") {
                            Text("•")
                                .foregroundColor(.blue)
                        } else {
                            Text("\(index + 1).")
                                .foregroundColor(.blue)
                                .frame(width: 20, alignment: .leading)
                        }
                                     Text(steps[index].hasPrefix("•") ? String(steps[index].dropFirst()) : steps[index])
                            .font(.body)
                    }
                } else {
                    // 缩进项显示为子项目
                    Text(steps[index])
                        .font(.body)
                        .padding(.leading, 25)
                }
            }
        }
        .padding(.vertical, 5)
    }
    
    // 辅助函数：创建FAQ部分
    private func faqSection(title: String, answers: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
             ForEach(answers, id: \.self) { answer in
                HStack(alignment: .top) {
                    Text("•")
                        .foregroundColor(.orange)
                    Text(answer)
                        .font(.body)
                }
            }
        }
        .padding(.vertical, 5)
    }
}

// 添加Safari视图容器
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> SFSafariViewController {
        return SFSafariViewController(url: url)
    }
    
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

/**
 * @struct AIHelpView
 * @description AI帮助说明视图，提供设置AI的步骤和说明
 */
struct AIHelpView: View {
    @Environment(\.dismiss) private var dismiss
    
    // 定义要显示的服务提供商信息
    let providers = [
        (name: "DeepSeek", url: "https://www.deepseek.com", path: "找到右上方API开放平台—充值（如需）—API Keys—创建API Key"),
        (name: "硅基流动", url: "https://www.siliconflow.cn", path: "登录或注册-API密钥—新建密钥—余额充值（如需）"), 
        (name: "火山引擎", url: "https://www.volcengine.com/experience/ark", path: "注册或登录(右上角)—右上角API接入—获取API Key—选择模型并开通（建议全部开通）")
    ]
    
    // 显示复制成功的提示
    @State private var copiedProvider: String? = nil
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 顶部免责声明
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Important Disclaimer".localized)
                            .font(.headline)
                            .foregroundColor(.red)

                        Text("This app only provides technical connection functionality and does not provide AI services itself. The following information is for technical configuration reference only and does not constitute any commercial promotion. Users need to register for the corresponding services and obtain API keys themselves. Fees incurred during use are settled directly between users and service providers.".localized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 4)
                    .background(Color(.systemGray6).opacity(0.5))
                    .cornerRadius(8)
                             Text("请按照以下步骤配置AI分析:")
                        .font(.headline)
                        .padding(.bottom, 10)
                             // 第1步：访问AI提供商网站
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. 访问AI提供商官网注册账号")
                            .font(.title3)
                            .fontWeight(.semibold)
                                     // 列出每个提供商
                        ForEach(providers, id: \.name) { provider in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("• \(provider.name)")
                                    .font(.subheadline)
                                    .fontWeight(.bold)
                                                     HStack {
                                    if provider.name == "火山引擎" {
                                        Text("\(provider.url) (建议用电脑打开)")
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundColor(.blue)
                                    } else {
                                        Text(provider.url)
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundColor(.blue)
                                    }
                                                             Button(action: {
                                        UIPasteboard.general.string = provider.url
                                        // 显示复制成功的提示
                                        copiedProvider = provider.name
                                                                     // 创建触觉反馈
                                        let generator = UIImpactFeedbackGenerator(style: .light)
                                        generator.impactOccurred()
                                                                     // 设置延迟后自动清除提示
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                            if copiedProvider == provider.name {
                                                copiedProvider = nil
                                            }
                                        }
                                    }) {
                                        Image(systemName: copiedProvider == provider.name ? "checkmark" : "doc.on.doc")
                                            .foregroundColor(copiedProvider == provider.name ? .green : .blue)
                                    }
                                    .buttonStyle(BorderlessButtonStyle())
                                }
                                .padding(.vertical, 4)
                                                     if copiedProvider == provider.name {
                                    Text("已复制\(provider.name)网址")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                        .padding(.leading, 4)
                                        .transition(.opacity)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .padding(.bottom, 10)
                             // 第2步：创建API密钥
                    VStack(alignment: .leading, spacing: 10) {
                        Text("2. 创建API密钥")
                            .font(.title3)
                            .fontWeight(.semibold)
                                     ForEach(providers, id: \.name) { provider in
                            HStack(alignment: .top) {
                                Text("• \(provider.name): ")
                                    .fontWeight(.medium)
                                                     Text(provider.path)
                            }
                            .padding(.vertical, 2)
                        }
                                     Text("⚠️ 注意：所有平台都有免费额度限制，用完需要充值。各平台免费额度和价格请参考官网最新信息。")
                            .padding(.top, 8)
                            .foregroundColor(.orange)
                    }
                    .padding(.bottom, 10)
                             // 第3步和第4步
                    VStack(alignment: .leading, spacing: 16) {
                        Text("3. 将API密钥复制到应用设置中")
                            .font(.title3)
                            .fontWeight(.semibold)
                                     Text("4. 选择对应的服务商和模型")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }
                             // 警告信息
                    VStack(alignment: .leading, spacing: 10) {
                        Text("重要提示")
                            .font(.headline)
                            .foregroundColor(.red)
                            .padding(.top, 16)
                                     Text("使用AI分析功能会消耗您的账户额度，请合理使用")
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 10)
                }
                .padding()
                .animation(.easeInOut(duration: 0.2), value: copiedProvider)
            }
            .navigationTitle("AI Setup Guide".localized)
            .navigationBarItems(trailing: Button("Close".localized) {
                dismiss()
            })
        }
    }
} 
