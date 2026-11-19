import SwiftUI

/// One page of the introduction (Android's IntroductionPage), in order.
enum IntroductionPage: String, CaseIterable, Identifiable {
    case language, welcome, artwork, lyrics, sound, vybe, quickAccess, ready
    var id: String { rawValue }

    var title: String {
        switch self {
        case .language: String(localized: "Choose your language")
        case .welcome: String(localized: "Welcome to Erhu")
        case .artwork: String(localized: "Tools to refine and repair")
        case .lyrics: String(localized: "Lyrics and queue")
        case .sound: String(localized: "Equalizer and Transition Studio")
        case .vybe: String(localized: "Discover VYBE.")
        case .quickAccess: String(localized: "Navigation quick access")
        case .ready: String(localized: "Everything is in place.")
        }
    }

    var text: String {
        switch self {
        case .language: String(localized: "Erhu follows the language you choose for it in the Settings app. You can change it there at any time.")
        case .welcome: String(localized: "Explore Now Playing and Home. Swipe through your music and discover the gestures that keep it close.")
        case .artwork: String(localized: "Find them in the app sidebar.")
        case .lyrics: String(localized: "Follow the lyrics while you listen, and arrange what plays next in your queue.")
        case .sound: String(localized: "Shape your sound with the equalizer. Use Transition Studio to fine-tune how playlist tracks flow into one another.")
        case .vybe: String(localized: "Search your own collection and browse generated radio stations. Playback starts when you choose.")
        case .quickAccess: String(localized: "Home stays first. Tap up to three other shortcuts in the order you want them. Tap again to remove a shortcut.")
        case .ready: String(localized: "Your music is ready. Make yourself at home.")
        }
    }

    static func pages(vybe: Bool) -> [Self] {
        allCases.filter { $0 != .vybe || vybe }
    }

    static func restored(_ saved: String, vybe: Bool) -> Self {
        switch saved.lowercased() {
        case "welcome", "library", "listening": .welcome
        case "artwork", "tags", "builder": .artwork
        case "lyrics": .lyrics
        case "sound", "transitions": .sound
        case "vybe": vybe ? .vybe : .quickAccess
        case "quickaccess", "quick_access", "shortcuts", "widgets": .quickAccess
        case "ready": .ready
        default: .language
        }
    }
}

struct IntroductionView: View {
    var firstLaunch = false
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("introductionPage") private var savedPage = ""
    private var pages: [IntroductionPage] { IntroductionPage.pages(vybe: settings.vybeEnabled) }
    private var selected: IntroductionPage { IntroductionPage.restored(savedPage, vybe: settings.vybeEnabled) }
    private var index: Int { pages.firstIndex(of: selected) ?? 0 }

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.md) {
                TabView(selection: Binding<IntroductionPage>(get: { selected }, set: { savedPage = $0.rawValue })) {
                    ForEach(pages) { page in
                        IntroductionPageView(page: page, isActive: page == selected).tag(page)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                pageDots
                HStack(spacing: Spacing.md) {
                    if index > 0 {
                        Button("Back") { move(to: index - 1) }
                            .buttonStyle(.bordered).controlSize(.large)
                    }
                    Button(index == pages.count - 1 ? "Start listening" : "Continue") {
                        if index == pages.count - 1 { finish() } else { move(to: index + 1) }
                    }
                    .modifier(PaletteFilledButton()).controlSize(.large)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
            }
            .background(palette.background.ignoresSafeArea())
            .foregroundStyle(palette.onSurface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(firstLaunch ? "Skip" : "Done", action: finish) } }
        }
        .onChange(of: settings.vybeEnabled) { _, _ in
            savedPage = selected.rawValue
        }
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(Array(pages.enumerated()), id: \.element) { position, _ in
                Capsule()
                    .fill(position == index ? palette.primary : palette.onSurface.opacity(0.22))
                    .frame(width: position == index ? 18 : 6, height: 6)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: index)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Page \(index + 1) of \(pages.count)"))
    }

    private func move(to position: Int) {
        guard pages.indices.contains(position) else { return }
        if reduceMotion {
            savedPage = pages[position].rawValue
        } else {
            withAnimation { savedPage = pages[position].rawValue }
        }
    }

    private func finish() {
        savedPage = ""
        if firstLaunch { settings.introductionCompleted = true }
        dismiss()
    }
}

/// One page: a large title, its explanation, then the page's own content.
private struct IntroductionPageView: View {
    let page: IntroductionPage
    let isActive: Bool
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                if page == .welcome {
                    Image("ErhuLogo").resizable().scaledToFit().frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityHidden(true)
                }
                Text(page.title)
                    .font(page == .welcome || page == .ready || page == .language ? .largeTitle.bold() : .title.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(page.text)
                    .font(.body)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                content(settings: $settings)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.md)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func content(settings: Bindable<AppSettings>) -> some View {
        switch page {
        case .language:
            card {
                Label("Language: \(AppLanguage.currentName)", systemImage: "globe").font(.headline)
                Button { AppLanguage.openSystemSettings() } label: { Label("Change in Settings", systemImage: "arrow.up.right") }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Opens the Settings app, where you can choose Erhu's language")
            }
        case .welcome:
            pairedPreviews(
                IntroductionPreview("Now Playing", image: "OnboardingNowPlaying", video: "now_playing"),
                IntroductionPreview("Home", image: "OnboardingHome", video: "home")
            )
        case .artwork:
            IntroductionToolsCarousel()
        case .lyrics:
            pairedPreviews(
                IntroductionPreview("Lyrics", image: "OnboardingLyrics", video: "lyrics"),
                IntroductionPreview("Queue", image: "OnboardingQueue", video: "queue")
            )
        case .sound:
            pairedPreviews(
                IntroductionPreview("Equalizer", image: "OnboardingEqualizer"),
                IntroductionPreview("Transitions", image: "OnboardingTransitions")
            )
        case .quickAccess:
            NavigationShortcutsPicker()
            Text("Touch and hold your Home Screen, tap Edit, then Add Widget, and choose Erhu.")
                .font(.subheadline)
                .foregroundStyle(palette.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            pairedPreviews(
                IntroductionPreview("Medium widget", image: "OnboardingWidgetMedium", aspectRatio: 2.1),
                IntroductionPreview("Large widget", image: "OnboardingWidgetLarge", aspectRatio: 1.05)
            )
        case .ready:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 72, weight: .regular))
                .foregroundStyle(palette.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.xl)
                .accessibilityHidden(true)
            card {
                Toggle(isOn: settings.glassEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Glass Effect").font(.headline)
                        Text("Floating bars and buttons use Liquid Glass on iOS 26, a soft material on earlier versions.")
                            .font(.subheadline).foregroundStyle(palette.onSurfaceVariant)
                    }
                }
                glassPreview(enabled: settings.glassEnabled.wrappedValue)
            }
            card {
                Toggle(isOn: settings.vybeEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable VYBE").font(.headline)
                        Text("Enable VYBE discovery and make its shortcut available.").font(.subheadline).foregroundStyle(palette.onSurfaceVariant)
                    }
                }
            }
            Text("Choose a song when you are ready.").font(.footnote).foregroundStyle(palette.onSurfaceVariant)
            card {
                Text("Beta release").font(.headline)
                Text("Erhu is in beta. You may come across bugs or inconsistent behaviour. VYBE recommendations are still being refined, with further improvements planned for matching and accuracy.")
                    .font(.subheadline).foregroundStyle(palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You can revisit this introduction in Settings → About Erhu. No Erhu account or music subscription is needed.")
                    .font(.footnote).foregroundStyle(palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .vybe:
            IntroductionPreviewView(
                preview: IntroductionPreview("VYBE", image: "OnboardingVybe"),
                isActive: isActive
            )
            .frame(maxWidth: 216)
            .frame(maxWidth: .infinity)
            Text("Preview from an existing Erhu library.").font(.caption).foregroundStyle(palette.onSurfaceVariant)
            Toggle("Enable VYBE", isOn: settings.vybeEnabled)
                .padding(Spacing.lg)
                .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(palette.surface))
        }
    }

    private func pairedPreviews(_ first: IntroductionPreview, _ second: IntroductionPreview) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            IntroductionPreviewView(preview: first, isActive: isActive)
            IntroductionPreviewView(preview: second, isActive: isActive)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
    }

    private func glassPreview(enabled: Bool) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "music.note")
            Image(systemName: "play.fill")
            Image(systemName: "ellipsis")
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .glassSurface(cornerRadius: Radius.large, enabled: enabled)
        .frame(maxWidth: .infinity, minHeight: 60)
        .background(
            LinearGradient(colors: [palette.primary.opacity(0.35), palette.surfaceVariant],
                           startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: Radius.large)
        )
        .accessibilityHidden(true)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.lg)
            .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(palette.surface))
    }
}

private struct VybeEnabledKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var vybeEnabled: Bool {
        get { self[VybeEnabledKey.self] }
        set { self[VybeEnabledKey.self] = newValue }
    }
}
