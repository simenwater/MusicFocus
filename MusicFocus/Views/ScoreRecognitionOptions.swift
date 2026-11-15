#if MUSICFOCUS_HOMR
import SwiftUI

@MainActor
final class ScoreRecognitionJob: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var fraction = 0.0
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    func start(_ request: ScoreRecognizer.Request, completed: @escaping (ScoreAuditionPackage) -> Void) {
        cancel(); let id = UUID(); generation = id
        running = true; fraction = 0; error = nil
        status = ScoreAuditionText.value("准备识别", "Preparing recognition")
        task = Task { [weak self] in
            do {
                let progressOwner = self
                let package = try await ScoreRecognizer.shared.recognize(request) { [weak progressOwner] fraction, status in
                    guard let owner = progressOwner else { return }
                    Task { @MainActor in
                        guard owner.generation == id else { return }
                        owner.fraction = fraction; owner.status = status
                    }
                }
                try Task.checkCancellation()
                guard let self, self.generation == id else { return }
                self.running = false; self.task = nil; completed(package)
            } catch {
                guard let self, self.generation == id else { return }
                self.running = false; self.task = nil
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; running = false }
    func clearError() { error = nil }
    deinit { task?.cancel() }
}

struct ScoreRecognitionOptions: View {
    let pageCount: Int
    let currentPage: Int
    var recognize: ([Int], ScoreRecognitionLayout, Double, Bool, Bool, Bool, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var firstPage = 1
    @State private var count = 1
    @State private var layout = ScoreRecognitionLayout.automatic
    @State private var tempo = 80.0
    @State private var ignoreColoredMarks = false
    @AppStorage("dev.scoreAuditionOrnaments") private var ornaments = true
    @AppStorage("dev.scoreAuditionTrillFromUpper") private var trillFromUpper = true
    @AppStorage("dev.scoreAuditionRepeats") private var repeats = true
    private func text(_ zh: String, _ en: String) -> String { ScoreAuditionText.value(zh, en) }
    var body: some View {
        NavigationStack {
            Form {
                Section(text("选页", "Pages")) {
                    Stepper(text("从第 \(firstPage) 页开始", "Start at page \(firstPage)"), value: $firstPage, in: 1...max(1, pageCount))
                        .accessibilityIdentifier("scoreRecognitionFirstPage")
                    Stepper(text("识别 \(count) 页", "Recognize \(count) page(s)"), value: $count, in: 1...max(1, min(3, pageCount - firstPage + 1)))
                        .accessibilityIdentifier("scoreRecognitionPageCount")
                    Picker(text("每组谱表", "Staff layout"), selection: $layout) {
                        ForEach(ScoreRecognitionLayout.allCases) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("scoreRecognitionLayout")
                    Stepper(text("试听速度 \(Int(tempo)) BPM", "Preview tempo \(Int(tempo)) BPM"), value: $tempo, in: 30...180, step: 5)
                }
                Section(text("演奏规则", "Playback rules")) {
                    Toggle(text("演奏明确的反复段", "Play explicit paired repeats"), isOn: $repeats)
                    Toggle(text("倚音与装饰音", "Grace notes and ornaments"), isOn: $ornaments)
                        .accessibilityIdentifier("scoreRecognitionOrnaments")
                    if ornaments {
                        Picker(text("颤音起音", "Start trills on"), selection: $trillFromUpper) {
                            Text(text("上方音", "Upper note")).tag(true)
                            Text(text("本音", "Principal note")).tag(false)
                        }.accessibilityIdentifier("scoreRecognitionTrillStart")
                        Text(text("采用简化演奏：倚音从后面的本音中分取时长，装饰音不延长小节。附加升降号及复杂装饰写法暂不能可靠还原。", "Simplified playback: grace notes borrow time from the following note; ornaments keep the bar length. Ornament accidentals and complex variants are not reliably reproduced yet."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle(text("忽略彩色笔迹", "Ignore colored handwriting"), isOn: $ignoreColoredMarks)
                        .accessibilityIdentifier("scoreRecognitionIgnoreColor")
                    Text(text("仅用于彩色笔记已合入图片的黑白乐谱。只处理识别副本；彩色印刷音符也会被滤掉，被笔迹完全遮住的内容无法恢复。", "For black-and-white scores with flattened colored handwriting. Only the recognition image changes. Colored printed notes are also filtered; covered notation cannot be recovered."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text(text("在本机识别原谱，不上传乐谱，也不读取独立笔记层。已压平到原谱的笔记无法分离。请选清晰的印刷五线谱；弯曲照片、密集声部和混合编制总谱可能识别失败。", "Recognition reads the original score on this device, without uploading it or including separate annotation layers. Flattened handwriting cannot be separated. Use clear printed notation; curved photos, dense voices and variable ensemble layouts may fail."))
                    Text(text("仅演奏起止明确的反复；一房二房、D.S./D.C. 等复杂跳转暂按印刷顺序。识别结果可能有误，请以原谱为准。", "Only explicit paired repeats are performed. Numbered endings and D.S./D.C. navigation stay in printed order. Verify recognition against the original score."))
                }.font(.callout).foregroundStyle(.secondary)
                Section {
                    Text("HOMR 0.7.1 · AGPL-3.0\nPiano: FreePats / Roberto, Zenph Studios · CC BY 3.0")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(text("选页识别 · 实验版", "Recognize pages · Preview"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(text("取消", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(text("开始识别", "Recognize")) { recognize(Array(firstPage..<min(pageCount + 1, firstPage + count)), layout, tempo, ornaments, trillFromUpper, ignoreColoredMarks, repeats) }
                        .accessibilityIdentifier("scoreRecognitionStart")
                }
            }
            .onAppear { firstPage = min(pageCount, max(1, currentPage)) }
            .onChange(of: firstPage) { _, value in count = min(count, pageCount - value + 1) }
        }.presentationDetents([.large])
    }
}
#endif
