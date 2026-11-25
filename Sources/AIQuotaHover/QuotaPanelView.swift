import AppKit
import SwiftUI

private struct CardFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct FrostedEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct BrandBadge: View {
    let id: String

    var gradientColors: [Color] {
        switch id {
        case "kimi":
            return [Color(red: 0.16, green: 0.22, blue: 0.48), Color(red: 0.29, green: 0.44, blue: 0.82)]
        case "chatgpt":
            return [Color(red: 0.06, green: 0.64, blue: 0.50), Color(red: 0.04, green: 0.48, blue: 0.39)]
        case "cursor":
            return [Color(red: 0.20, green: 0.22, blue: 0.26), Color(red: 0.08, green: 0.09, blue: 0.12)]
        case "workbuddy":
            return [Color(red: 0.00, green: 0.49, blue: 0.99), Color(red: 0.05, green: 0.32, blue: 0.86)]
        case "copilot":
            return [Color(red: 0.22, green: 0.36, blue: 0.92), Color(red: 0.48, green: 0.22, blue: 0.88)]
        case "gemini":
            return [Color(red: 0.30, green: 0.52, blue: 0.97), Color(red: 0.62, green: 0.42, blue: 0.92)]
        case "qoder":
            return [Color(red: 0.16, green: 0.44, blue: 0.96), Color(red: 0.11, green: 0.30, blue: 0.84)]
        case "qwenwork":
            return [Color(red: 0.48, green: 0.25, blue: 0.93), Color(red: 0.36, green: 0.16, blue: 0.78)]
        case "claude":
            return [Color(red: 0.85, green: 0.46, blue: 0.34), Color(red: 0.73, green: 0.34, blue: 0.22)]
        case "volcark":
            return [Color(red: 0.16, green: 0.54, blue: 0.98), Color(red: 0.32, green: 0.34, blue: 0.96)]
        case "glm":
            return [Color(red: 0.12, green: 0.48, blue: 0.96), Color(red: 0.08, green: 0.70, blue: 0.88)]
        case "minimax":
            return [Color(red: 0.96, green: 0.34, blue: 0.44), Color(red: 0.94, green: 0.52, blue: 0.22)]
        default: // dsh / deepseek
            return [Color(red: 0.06, green: 0.63, blue: 0.92), Color(red: 0.15, green: 0.39, blue: 0.92)]
        }
    }

    var symbolName: String {
        switch id {
        case "kimi": return "moon.stars.fill"
        case "chatgpt": return "sparkles"
        case "cursor": return "cursorarrow.rays"
        case "workbuddy": return "briefcase.fill"
        case "copilot": return "airplane.circle.fill"
        case "gemini": return "sparkle"
        case "qoder": return "chevron.left.forwardslash.chevron.right"
        case "qwenwork": return "bolt.fill"
        case "claude": return "sun.max.fill"
        case "volcark": return "flame.fill"
        case "glm": return "brain.head.profile"
        case "minimax": return "waveform.path.ecg"
        default: return "wave.3.right"
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: symbolName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 20, height: 20)
        .shadow(color: gradientColors[0].opacity(0.28), radius: 3, x: 0, y: 1)
    }
}

struct QuotaBentoTile: View {
    let item: QuotaItem
    let now: Date
    var onAction: () -> Void
    var onRemove: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                BrandBadge(id: item.id)

                Text(item.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 2)

                if isHovering, let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 17, height: 17)
                            .background(
                                Circle()
                                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.09))
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("从面板移除（可随时在 +添加 中恢复）")
                } else if let win = item.windowLabel, !item.isPending {
                    Text(win)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07))
                        )
                }
            }

            if item.isPending, let btnTitle = item.actionButtonTitle {
                Spacer(minLength: 8)

                Button(action: onAction) {
                    HStack(spacing: 4) {
                        Image(systemName: item.actionSymbolName)
                            .font(.system(size: 10, weight: .semibold))
                        Text(btnTitle)
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor)
                    )
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                Text(item.countdownString(from: now))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Spacer(minLength: 8)

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(item.remainingText)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(
                            item.status == "critical"
                                ? item.accentColor
                                : Color.primary
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    if !item.isPending {
                        Text(item.subText ?? "剩余")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 7)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.09))

                        if !item.isPending {
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [item.accentColor.opacity(0.85), item.accentColor],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(5, geo.size.width * item.clampedFraction))
                                .animation(.spring(response: 0.45, dampingFraction: 0.82), value: item.clampedFraction)
                        }
                    }
                }
                .frame(height: 5)

                Spacer(minLength: 7)

                HStack(spacing: 4) {
                    Image(systemName: item.isStale ? "exclamationmark.triangle.fill" : (item.isPending ? "clock" : "arrow.clockwise"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(item.isStale ? Color.orange : Color.secondary.opacity(0.65))

                    Text(item.countdownString(from: now))
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(item.isStale ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 102, maxHeight: 102)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color.white.opacity(0.065)
                        : Color.black.opacity(0.038)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    item.status == "critical"
                        ? item.accentColor.opacity(0.45)
                        : (colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.06)),
                    lineWidth: 0.8
                )
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
    }
}

struct BalanceWideBar: View {
    let item: QuotaItem
    var onAction: () -> Void
    var onRemove: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            BrandBadge(id: item.id)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(item.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(item.subText ?? "账户余额 · 长期有效")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if item.isPending, let btnTitle = item.actionButtonTitle {
                Button(action: onAction) {
                    Text(btnTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
            } else {
                Text(item.remainingText)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(item.status == "critical" ? item.accentColor : .primary)
            }

            if isHovering, let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 17, height: 17)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.09))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("从面板移除（可随时在 +添加 中恢复）")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    colorScheme == .dark
                        ? Color.white.opacity(0.065)
                        : Color.black.opacity(0.038)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.06),
                    lineWidth: 0.8
                )
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
    }
}

struct QuotaPanelView: View {
    @ObservedObject var viewModel: QuotaViewModel
    var onTogglePin: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    @State private var cardFrames: [String: CGRect] = [:]
    @State private var cardsContainerSize: CGSize = .zero
    @State private var draggingItem: QuotaItem?
    @State private var dragStartRect: CGRect = .zero
    @State private var dragTranslation: CGSize = .zero
    @State private var isHoveringRemoveZone: Bool = false

    private var gridColumns: [GridItem] {
        viewModel.gridItems.count == 1
            ? [GridItem(.flexible(), spacing: 8)]
            : [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    }

    var body: some View {
        Group {
            if viewModel.isShowingSettings {
                InlineSettingsView(viewModel: viewModel)
            } else {
                quotaDashboardBody
            }
        }
        .padding(12)
        .frame(width: 336)
        .background(FrostedEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            colorScheme == .dark ? Color.white.opacity(0.24) : Color.white.opacity(0.65),
                            colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.08)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
    }

    private var quotaDashboardBody: some View {
        VStack(spacing: 8) {
            if let active = draggingItem {
                // Drag-mode header: transforms into a zero-layout-shift Trash Drop Bar
                HStack(spacing: 5) {
                    Image(systemName: isHoveringRemoveZone ? "trash.fill" : "trash")
                        .font(.system(size: 10.5, weight: .bold))
                    Text(isHoveringRemoveZone ? "松手即可移除「\(active.name)」" : "拖到此处或拖出面板外即可移除")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(isHoveringRemoveZone ? Color.white : Color.red)
                .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
                .background(
                    Capsule(style: .continuous)
                        .fill(isHoveringRemoveZone ? Color.red.opacity(0.88) : Color.red.opacity(colorScheme == .dark ? 0.16 : 0.10))
                )
                .padding(.bottom, 2)
            } else {
                // Minimal Header with explicit "+ 添加" & "管理" buttons
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(red: 0.12, green: 0.78, blue: 0.53))
                        .frame(width: 6, height: 6)

                    Text("AI 剩余额度")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.88))

                    Spacer(minLength: 4)

                    Text(viewModel.relativeUpdateText())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    Button {
                        Task { await viewModel.refresh(force: true) }
                    } label: {
                        Image(systemName: viewModel.isRefreshing ? "ellipsis" : "arrow.clockwise")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(viewModel.isRefreshing ? Color.accentColor : Color.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isRefreshing)
                    .help("立即刷新全部额度")

                    Button {
                        onTogglePin()
                    } label: {
                        Image(systemName: viewModel.isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(viewModel.isPinned ? Color.accentColor : Color.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(viewModel.isPinned ? "取消固定 (恢复鼠标移开自动收起)" : "固定面板")

                    Button {
                        viewModel.openAddAgentCatalog()
                    } label: {
                        HStack(spacing: 2.5) {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                            Text("添加")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7.5)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.12))
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("一键添加主流 AI Agent / IDE")

                    Button {
                        viewModel.openManageSettings()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("管理已启用服务、排序与刷新频率")
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            }

            if viewModel.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("暂未启用任何服务卡片")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button("+ 一键添加主流 Agent") {
                        viewModel.openAddAgentCatalog()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if viewModel.items.count > 8 {
                ScrollView(.vertical, showsIndicators: false) {
                    dashboardCardsStack
                }
                .frame(maxHeight: 420)
            } else {
                dashboardCardsStack
            }
        }
        .onDisappear {
            draggingItem = nil
            dragTranslation = .zero
            isHoveringRemoveZone = false
        }
    }

    private var dashboardCardsStack: some View {
        VStack(spacing: 8) {
            if !viewModel.gridItems.isEmpty {
                LazyVGrid(columns: gridColumns, spacing: 8) {
                    ForEach(viewModel.gridItems) { item in
                        QuotaBentoTile(
                            item: item,
                            now: viewModel.now,
                            onAction: { viewModel.performCardAction(item) },
                            onRemove: { viewModel.removeItemFromPanel(item.id) }
                        )
                        .opacity(draggingItem?.id == item.id ? 0.22 : 1.0)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: CardFramePreferenceKey.self,
                                    value: [item.id: geo.frame(in: .named("dashboardCards"))]
                                )
                            }
                        )
                        .simultaneousGesture(cardReorderGesture(for: item))
                    }
                }
            }

            ForEach(viewModel.balanceItems) { item in
                BalanceWideBar(
                    item: item,
                    onAction: { viewModel.performCardAction(item) },
                    onRemove: { viewModel.removeItemFromPanel(item.id) }
                )
                .opacity(draggingItem?.id == item.id ? 0.22 : 1.0)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: CardFramePreferenceKey.self,
                            value: [item.id: geo.frame(in: .named("dashboardCards"))]
                        )
                    }
                )
                .simultaneousGesture(cardReorderGesture(for: item))
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { cardsContainerSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in cardsContainerSize = newSize }
            }
        )
        .coordinateSpace(name: "dashboardCards")
        .onPreferenceChange(CardFramePreferenceKey.self) { frames in
            cardFrames = frames
        }
        .overlay(alignment: .topLeading) {
            if let active = draggingItem {
                Group {
                    if active.kind == "balance" {
                        BalanceWideBar(item: active, onAction: {})
                    } else {
                        QuotaBentoTile(item: active, now: viewModel.now, onAction: {})
                    }
                }
                .frame(width: dragStartRect.width, height: dragStartRect.height)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.red.opacity(isHoveringRemoveZone ? 0.75 : 0), lineWidth: 1.5)
                )
                .scaleEffect(isHoveringRemoveZone ? 0.90 : 1.03)
                .opacity(isHoveringRemoveZone ? 0.78 : 1.0)
                .shadow(color: .black.opacity(0.24), radius: 10, x: 0, y: 5)
                .offset(
                    x: dragStartRect.minX + dragTranslation.width,
                    y: dragStartRect.minY + dragTranslation.height
                )
                .allowsHitTesting(false)
            }
        }
    }

    private func isLocationInRemoveZone(_ loc: CGPoint) -> Bool {
        let w = max(cardsContainerSize.width, 280)
        let h = max(cardsContainerSize.height, 48)
        return loc.y < -8 || loc.x < -22 || loc.x > w + 22 || loc.y > h + 16
    }

    private func cardReorderGesture(for item: QuotaItem) -> some Gesture {
        DragGesture(minimumDistance: 7, coordinateSpace: .named("dashboardCards"))
            .onChanged { value in
                if draggingItem == nil {
                    guard let startRect = cardFrames[item.id] else { return }
                    draggingItem = item
                    dragStartRect = startRect
                }
                guard draggingItem?.id == item.id else { return }
                dragTranslation = value.translation

                let loc = value.location
                let shouldRemove = isLocationInRemoveZone(loc)

                if shouldRemove != isHoveringRemoveZone {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        isHoveringRemoveZone = shouldRemove
                    }
                }
                guard !shouldRemove else { return }

                let candidates = item.kind == "balance" ? viewModel.balanceItems : viewModel.gridItems
                for candidate in candidates where candidate.id != item.id {
                    guard let rect = cardFrames[candidate.id] else { continue }
                    let hitZone = rect.insetBy(dx: rect.width * 0.16, dy: rect.height * 0.16)
                    if hitZone.contains(loc) {
                        viewModel.moveItem(fromID: item.id, toID: candidate.id)
                        break
                    }
                }
            }
            .onEnded { value in
                let shouldRemove = draggingItem?.id == item.id && isLocationInRemoveZone(value.location)
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.85)) {
                    draggingItem = nil
                    dragTranslation = .zero
                    isHoveringRemoveZone = false
                }
                if shouldRemove {
                    viewModel.removeItemFromPanel(item.id)
                }
            }
    }
}
