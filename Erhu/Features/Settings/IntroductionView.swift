import SwiftUI

/// One page of the introduction (Android's IntroductionPage), in order.
enum IntroductionPage: String, CaseIterable, Identifiable {
    case language, welcome, library, artwork, tags, listening, lyrics, sound, transitions, vybe, shortcuts, widgets, ready
    var id: String { rawValue }

    var title: String {
        switch self {
        case .language: String(localized: "Choose your language")
        case .welcome: String(localized: "Your music. Your space.")
        case .library: String(localized: "Your music library.")
        case .artwork: String(localized: "Give every album its cover.")
        case .tags: String(localized: "Put the right names to your music.")
        case .listening: String(localized: "Your listening experience.")
        case .lyrics: String(localized: "Stay with the words.")
        case .sound: String(localized: "Make sound yours.")
        case .transitions: String(localized: "Make the next track flow.")
        case .vybe: String(localized: "Discover VYBE.")
        case .shortcuts: String(localized: "Navigation quick access")
        case .widgets: String(localized: "Music on your Home Screen.")
        case .ready: String(localized: "Everything is in place.")
        }
    }

    var text: String {
        switch self {
        case .language: String(localized: "Erhu follows the language you choose for it in the Settings app. You can change it there at any time.")
        case .welcome: String(localized: "A home for the music you own. Your collection and listening history stay on this iPhone.")
        case .library: String(localized: "Use + to choose files, or start Wi-Fi Transfer to send music from a computer. Browse albums, artists and tracks, and search everything you have.")
        case .artwork: String(localized: "Find album covers and artist photos with Artwork Fetcher, or choose a cover from your own photos.")
        case .tags: String(localized: "Use Auto Fix Tags to complete missing details and bring order to your collection. You review every match before it is applied.")
        case .listening: String(localized: "Tap the mini player to open Now Playing. Swipe the artwork to change tracks, and open Queue to reorder what plays next.")
        case .lyrics: String(localized: "Follow synchronized lyrics on supported tracks. Availability depends on the file and online providers.")
        case .sound: String(localized: "Use the graphic equalizer and its presets, or shape every band with the parametric equalizer.")
        case .transitions: String(localized: "Use Transition Studio to shape the handover between tracks, with defaults and individual transitions.")
        case .vybe: String(localized: "Search your own collection and browse generated radio stations. Playback starts when you choose.")
        case .shortcuts: String(localized: "Home stays first. Tap up to three other shortcuts in the order you want them. Tap again to remove a shortcut.")
        case .widgets: String(localized: "Touch and hold your Home Screen, tap Edit, then Add Widget, and choose Erhu.")
        case .ready: String(localized: "Your music is ready. Make yourself at home.")
        }
    }

    /// Screens of the app shown on the page (a choice of them when there are several).
    var previews: [(label: String, image: String)] {
        switch self {
        case .welcome: [(String(localized: "Now Playing"), "OnboardingNowPlaying")]
        case .library: [(String(localized: "Library"), "OnboardingLibrary"), (String(localized: "Albums"), "OnboardingAlbum"), (String(localized: "Home"), "OnboardingHome")]
        case .listening: [(String(localized: "Now Playing"), "OnboardingNowPlaying"), (String(localized: "Menu"), "OnboardingTrackMenu")]
        case .lyrics: [(String(localized: "Lyrics"), "OnboardingLyrics")]
        case .sound: [(String(localized: "Equalizer"), "OnboardingEqualizer")]
        case .transitions: [(String(localized: "Studio"), "OnboardingTransitions")]
        case .vybe: [(String(localized: "VYBE"), "OnboardingVybe")]
        default: []
        }
    }

    /// Pages without a screen of the app show a symbol instead.
    var symbol: String? {
        switch self {
        case .language: "globe"
        case .artwork: "photo.on.rectangle.angled"
        case .tags: "wand.and.stars"
        case .widgets: "square.grid.2x2"
        case .ready: "checkmark.circle"
        default: nil
        }
    }

    static func pages(vybe: Bool, firstLaunch: Bool) -> [Self] {
        allCases.filter { page in
            switch page {
            case .vybe: vybe || firstLaunch
            case .shortcuts, .language: firstLaunch
            default: true
            }
        }
    }
}

/// The introduction (Android's onboarding): a page per part of the app, with its screens, the
/// tab bar's shortcuts on first launch, and the Glass and VYBE choices before you start.
struct IntroductionView: View {
    var firstLaunch = false
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected = IntroductionPage.welcome.rawValue
    private var pages: [IntroductionPage] { IntroductionPage.pages(vybe: settings.vybeEnabled, firstLaunch: firstLaunch) }
    private var index: Int { pages.firstIndex { $0.rawValue == selected } ?? 0 }

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.md) {
                TabView(selection: $selected) {
                    ForEach(pages) { page in
                        IntroductionPageView(page: page).tag(page.rawValue)
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
        .onAppear { selected = pages.first?.rawValue ?? IntroductionPage.welcome.rawValue }
        .onChange(of: settings.vybeEnabled) { _, _ in
            if !pages.contains(where: { $0.rawValue == selected }) { selected = IntroductionPage.ready.rawValue }
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
        if reduceMotion { selected = pages[position].rawValue } else { withAnimation { selected = pages[position].rawValue } }
    }

    private func finish() {
        if firstLaunch { settings.introductionCompleted = true }
        dismiss()
    }
}

/// One page: a large title, its explanation, then the page's own content.
private struct IntroductionPageView: View {
    let page: IntroductionPage
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette
    @State private var preview = 0

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
        case .shortcuts:
            NavigationShortcutsPicker()
        case .ready:
            symbolVisual
            card {
                Toggle(isOn: settings.glassEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Glass Effect").font(.headline)
                        Text("Floating bars and buttons use Liquid Glass on iOS 26, a soft material on earlier versions.")
                            .font(.subheadline).foregroundStyle(palette.onSurfaceVariant)
                    }
                }
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
            gallery
            Toggle("Enable VYBE", isOn: settings.vybeEnabled)
                .padding(Spacing.lg)
                .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(palette.surface))
        default:
            if page.previews.isEmpty { symbolVisual } else { gallery }
        }
    }

    private var symbolVisual: some View {
        Image(systemName: page.symbol ?? "music.note")
            .font(.system(size: 72, weight: .regular))
            .foregroundStyle(palette.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xl)
            .accessibilityHidden(true)
    }

    /// The page's screens, with chips to switch between several.
    @ViewBuilder
    private var gallery: some View {
        let previews = page.previews
        let shown = previews[min(preview, previews.count - 1)]
        if previews.count > 1 {
            HStack(spacing: Spacing.sm) {
                ForEach(Array(previews.enumerated()), id: \.offset) { position, item in
                    Button(item.label) { withAnimation(.smooth(duration: 0.2)) { preview = position } }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.xs + 2)
                        .foregroundStyle(position == preview ? palette.onPrimary : palette.onSurface)
                        .background(Capsule().fill(position == preview ? palette.primary : palette.onSurface.opacity(0.08)))
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(position == preview ? .isSelected : [])
                }
            }
        }
        Image(shown.image)
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 440)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(palette.onSurface.opacity(0.12)))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
            .frame(maxWidth: .infinity)
            .id(shown.image)
            .transition(.opacity)
            .accessibilityLabel(shown.label)
        Text("Preview from an existing Erhu library.").font(.caption).foregroundStyle(palette.onSurfaceVariant)
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
