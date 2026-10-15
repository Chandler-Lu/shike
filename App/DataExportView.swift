import SwiftUI
import UniformTypeIdentifiers
import ShikeCore

struct ShikeJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw ShikeError.message("无法读取 JSON 文件。") }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
@MainActor enum AppExportSnapshot {
    static func make(environment: AppEnvironment) throws -> AppDataExport {
        guard environment.countdowns.error == nil else { throw ShikeError.message(environment.countdowns.error!) }
        guard let sessions = environment.store else { throw ShikeError.message(environment.startupError ?? "无法读取本地记录。") }
        let p = environment.preferences
        return AppDataExport(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                             build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
                             preferences: p.exportPreferences, profiles: p.profiles, prompts: p.promptSettings,
                             countdowns: environment.countdowns.entries, categories: environment.countdowns.categories,
                             sessions: try sessions.all(), calendarReferences: p.exportCalendarReferences)
    }
}
struct DataExportView: View {
    let environment: AppEnvironment
    @ObservedObject private var backups: DataBackupService
    @State private var document: ShikeJSONDocument?
    @State private var exporting = false
    @State private var filename = "Shike_Export"
    @State private var message: String?
    @State private var failed = false
    @State private var importing = false
    @State private var pending: AppDataImport?
    @State private var reviewing = false
    @State private var includeSettings = true
    @State private var restoring = false
    @State private var showBackups = false
    init(environment: AppEnvironment) {
        self.environment = environment; _backups = ObservedObject(wrappedValue: environment.backups)
    }
    var body: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("数据与备份", systemImage: "externaldrive.badge.icloud").font(Notebook.handwriting(23))
                Text("将倒数日、分类、原文、日程草稿、保存记录、问答和设置导出为标准 JSON。包含接口地址与提示词，不包含 API Key、授权记录或原图。")
                    .font(.caption).foregroundStyle(Notebook.secondaryInk)
                Button("导出 JSON 文件") {
                    do {
                        // All reads and encoding occur on the main actor without suspension:
                        // either one consistent snapshot is ready, or no file picker opens.
                        let snapshot = try AppExportSnapshot.make(environment: environment)
                        document = ShikeJSONDocument(data: try snapshot.data())
                        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd_HHmmss"
                        filename = "Shike_Export_" + formatter.string(from: snapshot.exportedAt)
                        message = nil; exporting = true
                    } catch { failed = true; message = error.localizedDescription }
                }.buttonStyle(InkButtonStyle(prominent: false)).accessibilityIdentifier("exportAppJSON")
                Button("导入 JSON 备份") { importing = true }
                    .buttonStyle(InkButtonStyle(prominent: false)).accessibilityIdentifier("importAppJSON")
                DisclosureGroup("自动备份") {
                    VStack(alignment: .leading, spacing: 12) {
                        // The system switch draws slightly beyond its layout bounds;
                        // keep its trailing edge inside DisclosureGroup's clipping area.
                        Toggle("自动保存备份", isOn: $backups.automatic)
                            .padding(.trailing, 4).accessibilityIdentifier("automaticDataBackup")
                        Toggle("同时备份到 iCloud Drive", isOn: $backups.cloudEnabled)
                            .padding(.trailing, 4).accessibilityIdentifier("backupToCloud")
                        Text("数据变化后、打开或离开 App 时检查备份。每台设备保留最近 30 份本地与云端副本；文件保存在 iCloud Drive → 拾刻计划 → Backups。")
                            .font(.caption).foregroundStyle(Notebook.secondaryInk)
                        Text(backups.status).font(.caption).foregroundStyle(Notebook.secondaryInk)
                        if backups.cloudEnabled {
                            Text(backups.cloudStatus).font(.caption).foregroundStyle(Notebook.secondaryInk)
                                .accessibilityIdentifier("cloudBackupStatus")
                            Button(backups.cloudBusy ? "正在检查…" : "检查云端备份") { backups.checkCloudBackup() }
                                .frame(minHeight: 44).disabled(backups.cloudBusy)
                                .accessibilityIdentifier("checkCloudBackup")
                        }
                        Button(backups.busy ? "正在备份…" : "立即备份") {
                            Task {
                                do { _ = try await backups.create(); failed = false; message = "本地备份已保存。" }
                                catch { failed = true; message = error.localizedDescription }
                            }
                        }.buttonStyle(InkButtonStyle(prominent: false)).disabled(backups.busy).accessibilityIdentifier("backupNow")
                        Button("查看本地备份") { showBackups = true }.frame(minHeight: 44).accessibilityIdentifier("showLocalBackups")
                    }.padding(.top, 10)
                }.tint(Notebook.accent)
                if let message { NoteMessage(text: message, isError: failed) }
            }
        }
        .task { backups.checkCloudBackup() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do { try prepare(try result.get()) }
            catch { failed = true; message = error.localizedDescription }
        }
        .sheet(isPresented: $reviewing, onDismiss: { pending = nil }) {
            NavigationStack {
                ZStack {
                    PaperBackground()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if let pending {
                                Text("把记下的日子，带回来。").font(Notebook.handwriting(28))
                                Text("备份包含 \(pending.backup.countdowns.count) 个日子、\(pending.backup.countdownCategories.count) 个分组、\(pending.backup.importSessions.count) 条记录。")
                                Text("按编号合并，保留本机已有内容。导入前自动保存备份；日程记录不会自动加入系统日历。")
                                    .font(.subheadline).foregroundStyle(Notebook.secondaryInk)
                                Toggle("恢复接口、提示词与日历偏好", isOn: $includeSettings)
                                Text("已有接口及其 Key 保留。新增接口需重新填写 Key；iCloud 同步开关由本机设置决定。原图不在备份中。")
                                    .font(.caption).foregroundStyle(Notebook.secondaryInk)
                                Button(restoring ? "正在导入…" : "确认导入") {
                                    restoring = true
                                    Task {
                                        defer { restoring = false }
                                        do { message = try await backups.restore(pending, includeSettings: includeSettings); failed = false; reviewing = false }
                                        catch { failed = true; message = error.localizedDescription }
                                    }
                                }.buttonStyle(InkButtonStyle()).disabled(restoring || backups.busy).accessibilityIdentifier("confirmDataImport")
                                if failed, let message { NoteMessage(text: message, isError: true) }
                            }
                        }.padding(22)
                    }
                }.navigationTitle("导入备份").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { reviewing = false }.disabled(restoring) } }
                    .interactiveDismissDisabled(restoring)
            }
        }
        .sheet(isPresented: $showBackups) {
            NavigationStack {
                List {
                    if backups.backups.isEmpty { Text("还没有本地备份，点「立即备份」保存一份。") }
                    ForEach(backups.backups, id: \.self) { url in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(backupTitle(url)).font(.subheadline)
                            HStack {
                                ShareLink("导出", item: url)
                                Spacer()
                                Button("恢复") {
                                    showBackups = false
                                    // Present review after the list sheet has finished dismissing.
                                    Task { @MainActor in
                                        try? await Task.sleep(for: .milliseconds(400))
                                        do { try prepare(url) } catch { failed = true; message = error.localizedDescription }
                                    }
                                }
                            }.buttonStyle(.borderless)
                        }.padding(.vertical, 4)
                    }
                }.navigationTitle("本地备份")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showBackups = false } } }
                    .task { await backups.refreshList() }
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: filename) { result in
            switch result {
            case .success: failed = false; message = "JSON 文件已导出。请妥善保管其中的个人内容。"
            case .failure(let error): failed = true; message = "导出未完成：\(error.localizedDescription)"
            }
            document = nil
        }
    }
    private func prepare(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?, readError: Error?, imported: AppDataImport?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { location in
            do {
                let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 50_000_000 else { throw ShikeError.message("备份超过 50 MB，请选择较小的文件。") }
                imported = try AppDataImport(data: Data(contentsOf: location, options: .mappedIfSafe))
            } catch { readError = error }
        }
        if let error = coordinationError ?? readError as NSError? { throw error }
        guard let imported else { throw ShikeError.message("无法读取备份文件。") }
        pending = imported; failed = false; message = nil; includeSettings = true; reviewing = true
    }
    private func backupTitle(_ url: URL) -> String {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "_")
        guard parts.count > 2, let stamp = Double(parts[1]) else { return url.lastPathComponent }
        return Date(timeIntervalSince1970: stamp / 1000).formatted(date: .abbreviated, time: .standard) + (parts[2] == "BeforeImport" ? " · 导入前" : "")
    }
}
