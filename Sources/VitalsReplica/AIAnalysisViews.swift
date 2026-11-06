import AppKit
import SwiftUI

@MainActor struct AIAnalysisSettings: View {
  @ObservedObject var model: MonitorModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject private var store = AIAnalysisStore.shared
  @StateObject private var catalog = AIModelCatalog()
  @State private var draft = AIAnalysisStore.shared.config
  @State private var key = ""
  @State private var localError: String?
  @State private var advanced = false
  @State private var showModels = false
  @State private var showPrivacy = false
  @State private var search = ""
  @State private var visible = false
  @State private var clearingSavedKey = false
  @State private var savedKey = false
  private var changed: Bool { draft != store.config || !key.isEmpty }
  private var credentialID: String { draft.provider.rawValue + ":" + draft.endpoint }
  private var canLoad: Bool { !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || savedKey }
  private var filteredModels: [String] {
    catalog.models.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      AISentinelPreferences()
      VStack(alignment: .leading, spacing: 0) {
        Text("服务商").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.bottom, 12)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
          ForEach(AIProvider.allCases) { provider in
            Button {
              withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { selectProvider(provider) }
            } label: {
              Text(provider == .compatible ? "自定义" : provider.title).font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 40)
                .foregroundStyle(draft.provider == provider ? Theme.selectionForeground : .primary)
                .background(draft.provider == provider ? Theme.accent : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityLabel(provider.title)
              .accessibilityAddTraits(draft.provider == provider ? .isSelected : [])
          }
        }
        Divider().padding(.vertical, 17)
        HStack {
          Text("API Key").fontWeight(.medium)
          Spacer()
          if savedKey { Label("已保存", systemImage: "lock.fill").font(.system(size: 11)).foregroundStyle(.secondary) }
        }.padding(.bottom, 10)
        HStack(spacing: 10) {
          SecureField(savedKey ? "输入新 Key 以替换" : "粘贴 API Key", text: $key)
            .textFieldStyle(.plain).font(.system(size: 13)).padding(.horizontal, 14).frame(height: 44)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("AI API Key").onSubmit { refreshModels() }
          Button { refreshModels() } label: {
            HStack(spacing: 7) {
              if catalog.loading { ProgressView().controlSize(.small) }
              Text(catalog.loading ? "连接中…" : "测试连接")
            }.frame(minWidth: 80, minHeight: 34)
          }.buttonStyle(.bordered).controlSize(.large).disabled(!canLoad || catalog.loading)
            .accessibilityLabel("测试并获取模型")
        }
        if catalog.connected {
          Label(catalog.remote ? "已连接 · \(catalog.models.count) 个模型" : "已连接 · 预设模型", systemImage: "checkmark.circle")
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 10)
        }
        Divider().padding(.vertical, 17)
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 5) {
            Text("模型").fontWeight(.medium)
            Text(catalog.loading ? "正在获取…" : catalog.remote ? "接口模型 · \(catalog.models.count)" : catalog.connected || savedKey ? "预设模型" : "自动获取")
              .font(.system(size: 10)).foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          Button { search = ""; showModels = true } label: {
            HStack(spacing: 12) {
              Text(!catalog.connected && !savedKey || draft.model.isEmpty ? "测试后选择" : draft.model)
                .lineLimit(1).truncationMode(.middle)
              Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
            }.padding(.horizontal, 13).frame(height: 40)
              .foregroundStyle(Theme.accent)
              .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
              .contentShape(RoundedRectangle(cornerRadius: 12))
          }.buttonStyle(.plain).disabled(catalog.models.isEmpty || (!catalog.connected && !savedKey))
            .accessibilityLabel("选择 AI 模型")
            .popover(isPresented: $showModels, arrowEdge: .bottom) { modelPicker }

        }.frame(minHeight: 44)
      }.padding(22).background(Theme.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .disabled(store.busy)

      HStack(spacing: 12) {
        Button(!changed && savedKey ? "已保存" : "保存") { save() }.buttonStyle(.borderedProminent).controlSize(.large)
          .clipShape(RoundedRectangle(cornerRadius: 11))
          .disabled(store.busy || !changed || (try? draft.validated()) == nil)
        if let localError = localError ?? catalog.error {
          Label(localError, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        } else if let note = catalog.note {
          Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        if store.hasKey && !changed { Button("查看") { model.presentAI() }.controlSize(.large) }
      }
      if store.busy || store.error != nil { AIActivityMessage(store: store) }
      AIStatusStrip(model: model, showConnect: false).clipShape(RoundedRectangle(cornerRadius: 14))

      DisclosureGroup("高级", isExpanded: $advanced) {
        VStack(alignment: .leading, spacing: 14) {
          TextField("HTTPS 接口地址", text: $draft.endpoint)
            .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
            .accessibilityLabel("AI 接口地址").onSubmit { matchEndpoint() }
          if draft.provider == .compatible || catalog.error != nil || catalog.note != nil {
            TextField("自定义模型 ID（可选）", text: $draft.model).textFieldStyle(.roundedBorder)
              .accessibilityLabel("自定义 AI 模型")
          }
          if AIEndpoint.isTokenPlan(draft.endpoint) {
            Text("设备分析建议使用普通按量 API。请核对套餐适用范围。")
              .font(.system(size: 11)).foregroundStyle(.secondary)
          }
          HStack {
            Text("Key 仅保存在本机钥匙串").foregroundStyle(.secondary)
            Spacer()
            Button("移除 Key", role: .destructive) {
              Task { await store.removeKey(); savedKey = store.hasKey; key = ""; catalog.reset(draft) }
            }.disabled(changed || !savedKey || store.busy)
          }.font(.system(size: 11))
        }.padding(.top, 12)
      }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 4)
        .disabled(store.busy)
      HStack {
        Button { showPrivacy = true } label: { Label("隐私与用量", systemImage: "info.circle") }
          .buttonStyle(.plain).popover(isPresented: $showPrivacy) { privacy }
        Spacer()
        if !store.records.isEmpty {
          Menu("本机报告 · \(store.records.count)") {
            Button("清除报告历史", role: .destructive) { store.clearHistory() }
          }.menuStyle(.borderlessButton).fixedSize().disabled(store.busy)
        }
      }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4)
    }.onAppear { visible = true; store.refreshKeyStatus(); updateCatalog() }
      .task(id: credentialID) {
        savedKey = false
        let exists = await AIKeychain.containsAsync(draft)
        if !Task.isCancelled { savedKey = exists }
      }
      .onChange(of: store.hasKey) { _, value in
        if draft.provider == store.config.provider, draft.endpoint == store.config.endpoint { savedKey = value }
      }
      .onDisappear { visible = false; catalog.cancel(); key = "" }
      .onChange(of: draft.endpoint) { _, _ in key = ""; updateCatalog() }
      .onChange(of: key) { _, _ in
        if clearingSavedKey { clearingSavedKey = false; return }
        localError = nil; updateCatalog()
      }
      .onChange(of: catalog.models) { _, _ in reconcileModel() }
      .onChange(of: catalog.revision) { _, _ in reconcileModel() }
      .onChange(of: catalog.connected) { _, connected in
        if connected { store.clearMessage(); AISentinel.shared.resume() }
      }
  }

  private var modelPicker: some View {
    VStack(spacing: 12) {
      TextField("搜索模型", text: $search).textFieldStyle(.roundedBorder).accessibilityLabel("搜索 AI 模型")
      ScrollView {
        LazyVStack(spacing: 3) {
          ForEach(filteredModels, id: \.self) { name in
            Button { draft.model = name; showModels = false } label: {
              HStack(spacing: 10) {
                Text(verbatim: name).lineLimit(2)
                Spacer(minLength: 8)
                if draft.model == name { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
              }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                .background(draft.model == name ? Theme.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain)
          }
          if filteredModels.isEmpty { Text("没有匹配的模型").foregroundStyle(.secondary).padding(16) }
        }
      }.frame(maxHeight: 300)
    }.padding(14).frame(width: 350)
  }
  private var privacy: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("隐私与用量").font(.system(size: 14, weight: .semibold))
      Text("测试会查询模型，并发送一次短文字验证连接，可能产生少量用量。无查询接口时显示官方预设。")
      Text("自动分析定期发送匿名指标，异常时提前更新；可在上方关闭。IP、设备名称、路径与日志不发送，App 名称只在本机还原。手动分析可预览数据，补充问题会一起发送。")
      Text("普通模型单次输出上限 3072 Token；必须思考的已知模型上限 8192 Token。费用以服务商账单为准。")
      Text("Key 按服务商与地址保存在本机钥匙串，报告只存本机，最多 20 份。预设列表不代表账号已开通模型权限。")
    }.font(.system(size: 12)).foregroundStyle(.secondary).padding(20).frame(width: 330)
  }
  private func reconcileModel() {
    if (catalog.remote || draft.model.isEmpty), !catalog.models.contains(draft.model),
      let first = catalog.models.first { draft.model = first }
  }
  private func selectProvider(_ provider: AIProvider) {
    catalog.cancel(); key = ""; localError = nil; store.clearMessage()
    draft = store.configuration(for: provider)
    updateCatalog()
  }
  private func updateCatalog() {
    guard visible else { return }
    catalog.reset(draft)
  }
  private func refreshModels() {
    localError = nil; catalog.refresh(draft, key: key, test: true)
  }
  private func matchEndpoint() {
    if let provider = AIProvider.matching(draft.endpoint), provider != draft.provider {
      draft.provider = provider; draft.model = provider.models.first ?? ""
    }
    updateCatalog()
  }
  private func save() {
    catalog.cancel()
    Task {
      do {
        try await store.save(config: draft, key: key)
        draft = store.config; savedKey = store.hasKey; clearingSavedKey = !key.isEmpty; key = ""; localError = nil
        AISentinel.shared.resume()
      } catch { localError = error.localizedDescription }
    }
  }
}

@MainActor struct AIActivityMessage: View {
  @ObservedObject var store: AIAnalysisStore
  var body: some View {
    if let activity = store.activity {
      HStack(spacing: 10) {
        ProgressView().controlSize(.small)
        Text(activity)
        Spacer()
        Button("取消请求") { store.cancel() }
      }.font(.system(size: 12)).padding(12).background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
    if let error = store.error {
      Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.system(size: 12)).textSelection(.enabled)
    } else if let status = store.status {
      Label(status, systemImage: "info.circle").foregroundStyle(.secondary).font(.system(size: 12))
    }
  }
}

@MainActor struct AIAnalysisWorkspace: View {
  @ObservedObject var model: MonitorModel
  @ObservedObject private var store = AIAnalysisStore.shared
  @Environment(\.dismiss) private var dismiss
  @State private var mode: AIAnalysisMode = .overview
  @State private var minutes = 15
  @State private var includeNames = false
  @State private var question = ""
  @State private var sample: AIPreparedSample?
  @State private var prepareError: String?
  @State private var selected: UUID?
  @State private var showOptions = false
  @State private var showPreview = false
  @State private var showInfo = false
  @State private var copied = false
  @State private var composeVisible = false
  @State private var showHistory = false
  @State private var showReportActions = false
  @State private var showChanges = false
  @State private var showDetails = false
  @State private var expandedEvidence = Set<Int>()
  private var record: AIAnalysisRecord? { store.records.first { $0.id == selected } }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        Label("AI", systemImage: "sparkles").font(.system(size: 15, weight: .semibold))
          .foregroundStyle(Theme.accent)
        if store.busy { ProgressView().controlSize(.small) }
        Spacer()
        Button { selected = nil; composeVisible = false } label: { Image(systemName: "waveform.path.ecg").frame(width: 14) }
          .help("实时状态").accessibilityLabel("实时状态")
        Button { selected = nil; composeVisible = true; prepare() } label: { Image(systemName: "plus").frame(width: 14) }
          .help("手动分析").accessibilityLabel("手动分析")
        if !store.records.isEmpty {
          Button { showHistory.toggle() } label: { Image(systemName: "clock.arrow.circlepath").frame(width: 14) }
            .help("历史").accessibilityLabel("历史报告")
            .popover(isPresented: $showHistory, arrowEdge: .bottom) { historyPicker }
        }
        Button { openAISettings() } label: { Image(systemName: "gearshape").frame(width: 14) }.help("模型设置").accessibilityLabel("模型设置")
        Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 14) }
          .help("关闭").accessibilityLabel("关闭").keyboardShortcut(.cancelAction)
      }.buttonStyle(AIControlButtonStyle()).padding(.horizontal, 20).padding(.vertical, 12)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if let error = store.error ?? prepareError {
            Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange)
          }
          if store.deletedRecord != nil {
            HStack {
              Text("已删除报告").font(.system(size: 12)).foregroundStyle(.secondary)
              Spacer()
              Button("撤销删除") {
                if let restored = store.undoDelete() { selected = restored; composeVisible = false }
              }.buttonStyle(AIControlButtonStyle(compact: true))
            }
          }
          if let record { reportView(record) }
          else if composeVisible { compose }
          else { AdvisorTimeline(model: model, openReport: { selected = $0; composeVisible = false }) }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
      }
    }.frame(width: 720, height: record == nil ? (composeVisible ? 390 : 460) : 590).background(Color(nsColor: .windowBackgroundColor)).tint(Theme.accent)
      .onAppear { prepare() }
      .onChange(of: store.records.first?.id) { old, value in
        if let value, selected != nil, !composeVisible, selected == old {
          selected = value; composeVisible = false
        }
      }
      .onChange(of: store.config) { _, _ in prepare() }
      .onChange(of: minutes) { _, _ in prepare() }
      .onChange(of: includeNames) { _, _ in prepare() }
      .onChange(of: selected) { _, _ in copied = false; showReportActions = false; expandedEvidence = [] }
  }

  private var historyPicker: some View {
    ScrollView {
      VStack(spacing: 5) {
        ForEach(store.records) { item in
          Button { selected = item.id; composeVisible = false; showHistory = false } label: {
            HStack(spacing: 10) {
              Image(systemName: item.id == selected ? "checkmark" : "clock").frame(width: 14)
              Text(item.createdAt.formatted(date: .abbreviated, time: .shortened) + " · " + item.mode.shortTitle)
              Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.buttonStyle(AIControlButtonStyle())
        }
      }.padding(8)
    }.frame(width: 300).frame(maxHeight: 300)
  }

  private var compose: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 8) {
        ForEach(AIAnalysisMode.allCases) { item in
          Button { mode = item } label: {
            Label(item.shortTitle, systemImage: item.symbol).font(.system(size: 12, weight: .medium))
              .frame(maxWidth: .infinity).frame(height: 40)
              .foregroundStyle(mode == item ? Theme.selectionForeground : .primary)
              .background(mode == item ? Theme.accent : Theme.panel, in: RoundedRectangle(cornerRadius: 12))
              .contentShape(RoundedRectangle(cornerRadius: 12))
          }.buttonStyle(.plain).accessibilityAddTraits(mode == item ? .isSelected : [])
        }
      }.disabled(store.busy)
      TextField("想重点了解什么？（可选）", text: $question, axis: .vertical)
        .lineLimit(1...3).textFieldStyle(.plain).font(.system(size: 13)).padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14)).accessibilityLabel("AI 补充问题")
        .onChange(of: question) { _, value in if value.count > 500 { question = String(value.prefix(500)) } }
        .disabled(store.busy)
      DisclosureGroup("选项", isExpanded: $showOptions) {
        HStack {
          Picker("范围", selection: $minutes) {
            ForEach([5, 15, 30], id: \.self) { Text("\($0) 分钟").tag($0) }
          }.frame(width: 190)
          Spacer()
          Toggle("包含 App 名称", isOn: $includeNames).toggleStyle(.switch).controlSize(.small)
        }.padding(.top, 12)
      }.disclosureGroupStyle(AIWholeRowDisclosureStyle()).disabled(store.busy)
      if let sample {
        DisclosureGroup("数据预览 · \(sample.sampleCount) 个样本", isExpanded: $showPreview) {
          VStack(alignment: .leading, spacing: 10) {
            Text("已观察 \(Int(sample.observedSeconds)) 秒 · \(sample.includesAppNames ? "包含 App 名称" : "App 已匿名")")
              .foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
              Text(verbatim: sample.json).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).padding(10)
            }.frame(height: 150).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
          }.padding(.top, 10)
        }.disclosureGroupStyle(AIWholeRowDisclosureStyle())
      }
      HStack(spacing: 10) {
        Text("\(includeNames ? "资源指标与 App 名称" : "匿名指标") → \(store.config.provider.title)")
          .font(.system(size: 11)).foregroundStyle(.secondary)
        Button { showInfo = true } label: { Image(systemName: "info.circle") }.buttonStyle(AIControlButtonStyle(compact: true))
          .popover(isPresented: $showInfo) {
            Text("点击分析会发送当前指标与补充问题，可能产生 API 用量。不发送 IP、设备名称、路径或日志；Key 只在本机钥匙串。模型建议基于已采集样本，不能保证发现所有问题。")
              .font(.system(size: 12)).foregroundStyle(.secondary).padding(18).frame(width: 300)
          }.accessibilityLabel("分析数据与用量")
        Spacer()
        if store.busy { Button("停止") { store.cancel() }.buttonStyle(AIControlButtonStyle()) }
        else {
          Button(store.hasKey ? "开始分析" : "连接模型") {
            if store.hasKey { analyze() } else { openAISettings() }
          }.buttonStyle(AIControlButtonStyle(prominent: true))
        }
      }
    }
  }
  private func reportView(_ item: AIAnalysisRecord) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(verbatim: item.conciseSummary).font(.system(size: 20, weight: .semibold)).lineSpacing(5).textSelection(.enabled)
      Text("\(item.sampledAt.formatted(date: .omitted, time: .shortened)) · \(Int(item.observedSeconds)) 秒 / \(item.sampleCount) 个样本\(item.trigger.map { " · " + $0 } ?? "")\(item.isRecent() ? "" : " · 历史分析")")
        .font(.system(size: 11)).foregroundStyle(.secondary)
      ForEach(Array(item.report.findings.sorted { $0.priority.rank < $1.priority.rank }.prefix(3).enumerated()), id: \.offset) { index, finding in
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text(verbatim: item.displayText(finding.title)).font(.system(size: 13, weight: .semibold))
            Spacer()
            if let tab = finding.target.tab {
              Button("查看\(tab.title)") { model.select(tab); dismiss() }.buttonStyle(AIControlButtonStyle(compact: true))
            }
            if let url = finding.target.settingsURL {
              Button("设置") { NSWorkspace.shared.open(url) }.buttonStyle(AIControlButtonStyle(compact: true))
            }
          }
          Text(verbatim: item.displayText(finding.suggestion)).font(.system(size: 13)).textSelection(.enabled)
          DisclosureGroup("依据", isExpanded: Binding(get: { expandedEvidence.contains(index) }, set: {
            if $0 { expandedEvidence.insert(index) } else { expandedEvidence.remove(index) }
          })) {
            Text(verbatim: item.displayText(finding.evidence + "\n" + finding.explanation))
              .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
          }.disclosureGroupStyle(AIWholeRowDisclosureStyle())
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
          .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
      }
      DisclosureGroup("变化与处理", isExpanded: $showChanges) { AdvisorTimeline(model: model) }
        .disclosureGroupStyle(AIWholeRowDisclosureStyle())
      DisclosureGroup("详情", isExpanded: $showDetails) {
        VStack(alignment: .leading, spacing: 10) {
          Text(verbatim: item.displayText(item.report.summary))
          ForEach(Array((item.report.limitations + item.report.nextChecks).enumerated()), id: \.offset) { _, text in
            Text(verbatim: "· " + item.displayText(text))
          }
          Text("\(item.provider) · \(item.model) · \(item.usage?.totalTokens.map(String.init) ?? "—") Token")
        }.font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
      }.disclosureGroupStyle(AIWholeRowDisclosureStyle())
      HStack(spacing: 10) {
        Button(copied ? "已复制" : "复制") {
          NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.markdown, forType: .string); copied = true
        }.buttonStyle(AIControlButtonStyle())
        Button { showReportActions.toggle() } label: { Image(systemName: "ellipsis").frame(width: 14) }
          .buttonStyle(AIControlButtonStyle()).accessibilityLabel("更多操作")
          .popover(isPresented: $showReportActions, arrowEdge: .bottom) {
            Button(role: .destructive) {
              showReportActions = false
              if store.delete(item.id) { selected = store.records.first?.id }
            } label: {
              Label("删除报告", systemImage: "trash").frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(AIControlButtonStyle()).padding(8).frame(width: 180)
          }
        Spacer()
        if store.busy { Button("停止") { store.cancel() }.buttonStyle(AIControlButtonStyle()) }
        else { Button("刷新") { mode = item.mode; analyze() }.buttonStyle(AIControlButtonStyle()).disabled(!store.hasKey) }
      }.font(.system(size: 12))
    }
  }
  private func prepare() {
    do {
      sample = try AIPreparedSample.prepare(snapshot: model.snapshot, history: model.history, minutes: minutes,
                                            includeAppNames: includeNames, paused: model.paused)
      prepareError = nil
    } catch { sample = nil; prepareError = error.localizedDescription }
  }
  private func analyze() {
    prepare()
    if let sample { store.analyze(sample: sample, mode: mode, question: question) }
  }
  private func openAISettings() { dismiss(); model.presentSettings(section: "AI 分析") }
}
