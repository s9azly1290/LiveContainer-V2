//
//  LCSourcesViewV2.swift
//  LiveContainer
//
//  ⚠️ Version 2 من شاشة المصادر.
//
//  هدفها: تحويل الواجهة من "قائمة مصادر مكدّسة" إلى عرض مزدوج
//  (مصادر / كل التطبيقات) مع فرز ومؤشرات صحة.
//
//  الوضع المسطّح بيحل biggest problem في الواجهة القديمة:
//  إن الواحد كان لازم يفتح كل مصدر على حدة عشان يدوّر على تطبيق.
//

import SwiftUI

// MARK: - وضع العرض

enum LCSourcesDisplayMode: String, CaseIterable, Identifiable {
    case sources
    case flat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sources: return "lc.sources.mode.sources".loc
        case .flat:    return "lc.sources.mode.flat".loc
        }
    }

    var icon: String {
        switch self {
        case .sources: return "square.stack.3d.up"
        case .flat:    return "square.grid.2x2"
        }
    }
}

// MARK: - ترتيب التطبيقات في الوضع المسطّح

enum LCFlatSort: String, CaseIterable, Identifiable {
    case name
    case source
    case version

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name:    return "lc.sources.sort.name".loc
        case .source:  return "lc.sources.sort.source".loc
        case .version: return "lc.sources.sort.version".loc
        }
    }
}

// MARK: - عنصر مسطّح (تطبيق + مصدره)

/// ربط بين تطبيق والمصدر اللي جاي منه — عشان نقدر نعرض المصدر
/// على كل بطاقة في الوضع المسطّح.
struct LCFlatAppEntry: Identifiable, Hashable {
    let app: AltStoreSourceApp
    let sourceName: String
    let sourceID: URL

    var id: String { "\(sourceID.absoluteString)::\(app.bundleIdentifier)" }
}

// MARK: - Health indicator لمصدر

struct LCSourceHealth {
    let icon: String
    let tint: Color
    let label: String

    static func make(for item: AltStoreSourcesViewModel.SourceItem) -> LCSourceHealth {
        if item.isLoading {
            return .init(icon: "arrow.triangle.2.circlepath",
                         tint: .blue,
                         label: "lc.sources.status.loading".loc)
        }
        if let error = item.error, !error.isEmpty {
            return .init(icon: "exclamationmark.triangle.fill",
                         tint: .orange,
                         label: error)
        }
        guard let source = item.source else {
            return .init(icon: "questionmark.circle",
                         tint: .secondary,
                         label: "lc.sources.status.unknown".loc)
        }
        return .init(icon: "checkmark.circle.fill",
                     tint: .green,
                     label: "\(source.apps.count) " + "lc.sources.apps".loc)
    }
}

// MARK: - View

struct LCSourcesViewV2: View {

    @StateObject private var viewModel = AltStoreSourcesViewModel()
    @State private var errorMessage: String?
    @State private var sourcePendingRemoval: AltStoreSourcesViewModel.SourceItem?
    @ObservedObject public var searchContext: SearchContext = SearchContext()
    @State private var expandedSources: Set<URL> = []
    @State private var isManagingSources = false

    @EnvironmentObject private var sharedModel: SharedModel

    @State private var mode: LCSourcesDisplayMode = .sources
    @State private var flatSort: LCFlatSort = .name

    @State private var isViewAppeared = false

    // MARK: body

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                modePicker
                content
            }
            .navigationTitle("lc.tabView.sources".loc)
            .toolbar { toolbarContent }
        }
        .navigationViewStyle(StackNavigationViewStyle())

        .searchable(text: $searchContext.query,
                    placement: .navigationBarDrawer(displayMode: .always))

        .sheet(isPresented: $isManagingSources) {
            ManageSourcesSheet(
                viewModel: viewModel,
                isPresented: $isManagingSources,
                onAdd: { rawValue in await handleAddSource(rawValue) }
            )
            .presentationDetents([.large])
        }

        .alert("lc.common.error".loc, isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })
        ) {
            Button("lc.common.ok".loc, role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }

        .alert("lc.sources.removeConfirmation.title".loc, isPresented: Binding(
            get: { sourcePendingRemoval != nil },
            set: { if !$0 { sourcePendingRemoval = nil } })
        ) {
            Button("lc.common.remove".loc, role: .destructive) {
                if let sourcePendingRemoval { viewModel.removeSource(sourcePendingRemoval) }
                sourcePendingRemoval = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) { sourcePendingRemoval = nil }
        } message: {
            Text("lc.sources.removeConfirmation.message %@"
                .localizeWithFormat(sourcePendingRemoval?.displayName ?? ""))
        }

        .onAppear {
            expandedSources = []
            if !isViewAppeared {
                guard sharedModel.selectedTab == .sources,
                      let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .onChange(of: viewModel.sources) { newSources in
            let newSet = Set(newSources.map { $0.id })
            expandedSources = expandedSources.intersection(newSet)
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .sources, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
    }

    // MARK: - الوضع المختار

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            ForEach(LCSourcesDisplayMode.allCases) { m in
                Label(m.title, systemImage: m.icon).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.sources.isEmpty {
            emptyState
        } else {
            switch mode {
            case .sources: sourcesMode
            case .flat:    flatMode
            }
        }
    }

    // MARK: - الوضع 1: المصادر (زي الأصلي + صحة)

    private var sourcesMode: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                // ملخص في الأول
                sourcesSummary

                ForEach(viewModel.sources, id: \.id) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        sourceHeader(item)
                            .contentShape(Rectangle())
                            .onTapGesture { toggleExpansion(for: item.id) }

                        if expandedSources.contains(item.id) {
                            sourceApps(item)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 12))
                }

                if totalFilteredAppCount == 0 {
                    noResults
                }
            }
            .padding(.vertical)
        }
    }

    /// ملخص سريع: كام مصدر شغّال / فاشل
    private var sourcesSummary: some View {
        let total = viewModel.sources.count
        let failed = viewModel.sources.filter { $0.error != nil }.count
        let apps = viewModel.sources.reduce(0) { $0 + ($1.source?.apps.count ?? 0) }

        return HStack(spacing: 16) {
            summaryChip(icon: "square.stack.3d.up", value: "\(total)", label: "sources", tint: .blue)
            summaryChip(icon: "app.dashed", value: "\(apps)", label: "apps", tint: .green)
            if failed > 0 {
                summaryChip(icon: "exclamationmark.triangle.fill",
                            value: "\(failed)", label: "failed", tint: .orange)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private func summaryChip(icon: String, value: String,
                             label: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            Text(value)
                .font(.headline)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// هيدر المصدر: أيقونة + اسم + حالة + عدد
    private func sourceHeader(_ item: AltStoreSourcesViewModel.SourceItem) -> some View {
        let health = LCSourceHealth.make(for: item)
        let isExpanded = expandedSources.contains(item.id)

        return HStack(spacing: 10) {
            AsyncImage(url: item.primaryIconURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit()
                } else {
                    Image(systemName: "square.stack.3d.up")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Label(health.label, systemImage: health.icon)
                    .font(.caption2)
                    .foregroundStyle(health.tint)
                    .lineLimit(1)
            }

            Spacer()

            if item.isLoading {
                ProgressView().controlSize(.small)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.vertical, 2)
        .swipeActionsCompat(contextMenu: {
            Button {
                Task { await viewModel.refreshSource(item) }
            } label: { Label("Refresh", systemImage: "arrow.clockwise") }

            Button(role: .destructive) {
                sourcePendingRemoval = item
            } label: { Label("Remove", systemImage: "trash") }
        })
    }

    @ViewBuilder
    private func sourceApps(_ item: AltStoreSourcesViewModel.SourceItem) -> some View {
        let apps = filteredApps(for: item)
        if apps.isEmpty {
            Text("lc.sources.section.noApps".loc)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        } else {
            LazyVStack(spacing: 6) {
                ForEach(apps) { app in
                    LCFlatAppRow(app: app,
                                 sourceName: nil,
                                 onInstall: { install(app: app) })
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - الوضع 2: مسطّح (الجديد)

    private var flatMode: some View {
        VStack(spacing: 0) {
            if !flatEntries.isEmpty {
                flatSortBar
            }

            if flatEntries.isEmpty {
                noResults
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(flatEntries) { entry in
                            LCFlatAppRow(app: entry.app,
                                         sourceName: entry.sourceName,
                                         onInstall: { install(app: entry.app) })
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var flatSortBar: some View {
        HStack {
            Text("\(flatEntries.count) " + "lc.sources.apps".loc)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Picker("Sort", selection: $flatSort) {
                ForEach(LCFlatSort.allCases) { s in
                    Text(s.title).tag(s)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    /// كل التطبيقات من كل المصادر، مع اسم المصدر، بعد الفرز
    private var flatEntries: [LCFlatAppEntry] {
        var entries: [LCFlatAppEntry] = []
        let query = searchContext.debouncedQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        for item in viewModel.sources {
            guard let source = item.source else { continue }
            for app in source.apps {
                if !query.isEmpty {
                    let hit = app.name.lowercased().contains(query)
                        || app.bundleIdentifier.lowercased().contains(query)
                        || (app.developerName?.lowercased().contains(query) ?? false)
                    if !hit { continue }
                }
                entries.append(.init(app: app,
                                     sourceName: item.displayName,
                                     sourceID: item.id))
            }
        }

        switch flatSort {
        case .name:
            entries.sort { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
        case .source:
            entries.sort {
                let bySource = $0.sourceName.localizedCaseInsensitiveCompare($1.sourceName)
                if bySource != .orderedSame { return bySource == .orderedAscending }
                return $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending
            }
        case .version:
            entries.sort {
                $0.app.version.compare($1.app.version, options: .numeric) == .orderedDescending
            }
        }

        return entries
    }

    // MARK: - الحالات الفارغة

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("lc.sources.empty".loc)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var noResults: some View {
        VStack(spacing: 8) {
            Text("lc.sources.section.noApps".loc)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 160, alignment: .center)
        .padding(.horizontal)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if viewModel.isRefreshingAll {
                ProgressView()
            } else {
                Button("lc.sources.refreshAll".loc, systemImage: "arrow.clockwise") {
                    Task { await viewModel.refreshAllSources() }
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("lc.sources.addSource".loc, systemImage: "plus") {
                isManagingSources = true
            }
        }
    }

    // MARK: - Helpers

    private var isFiltering: Bool {
        !searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var totalFilteredAppCount: Int {
        viewModel.sources.reduce(0) { $0 + filteredApps(for: $1).count }
    }

    private func filteredApps(for item: AltStoreSourcesViewModel.SourceItem) -> [AltStoreSourceApp] {
        guard let source = item.source else { return [] }
        let query = searchContext.debouncedQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !query.isEmpty else { return source.apps }

        return source.apps.filter { app in
            app.name.lowercased().contains(query)
                || app.bundleIdentifier.lowercased().contains(query)
                || (app.developerName?.lowercased().contains(query) ?? false)
                || (app.subtitle?.lowercased().contains(query) ?? false)
        }
    }

    private func handleAddSource(_ rawValue: String) async -> Bool {
        if let error = await viewModel.addSource(from: rawValue) {
            errorMessage = error
            return false
        }
        return true
    }

    private func install(app: AltStoreSourceApp) {
        // نفس منطق التثبيت الموجود في LCSourcesView الأصلي (سطر 679)
        guard let downloadURL = app.latestVersion?.downloadURL else {
            errorMessage = "lc.sources.error.missingDownload".loc
            return
        }
        withAnimation {
            DataManager.shared.model.selectedTab = .apps
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(
                name: NSNotification.InstallAppNotification,
                object: ["url": downloadURL]
            )
        }
    }

    private func toggleExpansion(for id: URL) {
        if expandedSources.contains(id) {
            expandedSources.remove(id)
        } else {
            expandedSources.insert(id)
        }
    }

    private func handleURL(url: URL) {
        Task { await handleAddSource(url.absoluteString) }
    }
}

// MARK: - صف التطبيق (مشترك بين الوضعين)

/// صف واحد يعرض التطبيق. لو `sourceName` مش nil بيعرض اسم المصدر كـ badge
/// — وده الفرق بين الوضعين.
struct LCFlatAppRow: View {

    let app: AltStoreSourceApp
    let sourceName: String?
    let onInstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: app.iconURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit()
                } else {
                    Image(systemName: "app.dashed")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("v\(app.version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let subtitle = app.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let sourceName {
                        Text(sourceName)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15),
                                        in: Capsule())
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 4)

            Button(action: onInstall) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Swipe helper

private extension View {
    /// بديل لـ .contextMenu على iOS 16، بشكل متوافق
    @ViewBuilder
    func swipeActionsCompat<Menu: View>(@ViewBuilder content: () -> Menu) -> some View {
        self.contextMenu(content)
    }
}