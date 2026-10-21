import AppKit
import HeaterKit
import SwiftUI

struct MiHeaterBarApp: App {
    @StateObject private var controller = HeaterController()

    var body: some Scene {
        // MenuBarExtra labels don't inherit scene-level environment objects; inject per view.
        MenuBarExtra {
            PanelView().environmentObject(controller)
        } label: {
            MenuLabel().environmentObject(controller)
        }
        .menuBarExtraStyle(.window)
    }
}

let ptLocale = Locale(identifier: "pt_PT")

/// PT-BR labels for the English mode names in MIoT specs; unknown names fall back to the original.
private let modeNames = [
    "Constant Temperature": "Constante",
    "Heat": "Quente",
    "Warm": "Morno",
    "Natural Wind": "Ventilar",
    "Auto": "Automático",
    "Sleep": "Noturno",
    "Silent": "Silencioso",
    "Low": "Baixo",
    "High": "Alto",
    "Max": "Máximo",
    "Normal": "Normal",
]

private let modeIcons = [
    "Constant Temperature": "thermometer.medium",
    "Heat": "flame.fill",
    "Warm": "heat.waves",
    "Natural Wind": "wind",
    "Auto": "a.circle",
    "Sleep": "moon.fill",
    "Silent": "speaker.slash.fill",
    "Low": "flame",
    "High": "flame.fill",
    "Max": "flame.fill",
]

private struct MenuLabel: View {
    @EnvironmentObject private var controller: HeaterController

    var body: some View {
        HStack {
            Image(systemName: controller.state?.isOn == true ? "flame.fill" : "flame")
            Text(temperatureText)
        }
    }

    private var temperatureText: String {
        guard controller.errorMessage == nil, let current = controller.state?.currentTemperature else { return "—" }
        return "\(formatTemp(current))°"
    }
}

/// Adapter: controller state in, plain values and closures out to `PanelContent`.
private struct PanelView: View {
    @EnvironmentObject private var controller: HeaterController
    @State private var showSettings = false

    var body: some View {
        let state = controller.state
        let caps = controller.capabilities
        PanelContent(
            model: PanelModel(
                connected: state != nil,
                isOn: state?.isOn == true,
                modeName: state?.mode.flatMap { value in caps?.modes.first { $0.value == value }?.name },
                current: state?.currentTemperature,
                target: state?.targetTemperature,
                targetRange: caps?.targetRange,
                targetStep: caps?.targetStep ?? 1,
                modes: caps?.modes.map { ($0.value, $0.name) } ?? [],
                selectedMode: state?.mode,
                oscillating: caps?.hasOscillation == true ? state?.oscillating == true : nil,
                error: controller.errorMessage,
                autoOn: controller.autoEnabled,
                autoTarget: controller.autoTarget,
                autoStatus: controller.autoStatus,
                summary: controller.weekSummary
            ),
            showSettings: $showSettings,
            actions: PanelActions(
                power: { Task { await controller.togglePower() } },
                setTarget: { value in Task { await controller.setTarget(value) } },
                setMode: { value in Task { await controller.setMode(value) } },
                oscillate: { Task { await controller.toggleOscillation() } },
                setAuto: { on in Task { await controller.setAuto(on) } },
                retry: { Task { await controller.reconnect() } }
            )
        )
    }
}

// MARK: - Panel (presentation only)

struct PanelModel {
    var connected: Bool
    var isOn: Bool
    var modeName: String?
    var current: Double?
    var target: Double?
    var targetRange: ClosedRange<Double>?
    var targetStep: Double
    var modes: [(value: Int, name: String)]
    var selectedMode: Int?
    var oscillating: Bool?  // nil: no oscillation support
    var error: String?
    var autoOn: Bool
    var autoTarget: Double
    var autoStatus: AutoStatus
    var summary: WeekSummary?

    var ambience: Ambience {
        guard connected, isOn else { return .idle }
        switch autoStatus {
        case .heating(.strong): return .hot
        case .heating(.gentle): return .warm
        default: break
        }
        switch modeName {
        case "Heat", "High", "Max": return .hot
        case "Natural Wind": return .cold
        default: return .warm
        }
    }

    var heroWord: String {
        guard connected else { return error == nil ? "Conectando" : "Sem conexão" }
        guard isOn else {
            if case .paused = autoStatus { return "Em pausa" }
            return "Desligado"
        }
        switch ambience {
        case .hot: return "Quente"
        case .cold: return "Frio"
        default: return "Morno"
        }
    }

    var deviceStatus: String {
        guard connected else { return error == nil ? "Conectando…" : "Aparelho inacessível" }
        return isOn ? "Ligado" : "Desligado"
    }

    var heroSubtitle: String {
        guard connected else { return " " }
        var parts: [String] = []
        if isOn, let modeName {
            let name = modeNames[modeName] ?? modeName
            if name != heroWord { parts.append(name) }
        }
        if let target { parts.append("Alvo \(formatTemp(target))°") }
        if autoOn { parts.append("Auto") }
        if oscillating == true { parts.append("Oscilando") }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }
}

struct PanelActions {
    var power: () -> Void
    var setTarget: (Double) -> Void
    var setMode: (Int) -> Void
    var oscillate: () -> Void
    var setAuto: (Bool) -> Void
    var retry: () -> Void
}

struct PanelContent: View {
    var model: PanelModel
    @Binding var showSettings: Bool
    var actions: PanelActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            if showSettings {
                HStack {
                    Button { showSettings = false } label: { Label("Voltar", systemImage: "chevron.left") }
                        .buttonStyle(.glass)
                    Spacer()
                    Text("Configurações").font(.headline).foregroundStyle(.white)
                }
                .padding(.horizontal, 2)
                SettingsView { showSettings = false }
            } else {
                HeroModule(word: model.heroWord, status: model.deviceStatus, subtitle: model.heroSubtitle, current: model.current)
                GlassEffectContainer(spacing: 4) {
                    VStack(spacing: 10) {
                        PowerModule(isOn: model.isOn, status: model.deviceStatus, onPower: actions.power)
                            .disabled(!model.connected)
                        if let error = model.error {
                            StatusModule(connected: model.connected, message: error, onRetry: actions.retry)
                        }
                        if let range = model.targetRange {
                            TargetModule(range: range, step: model.targetStep, target: model.target, onCommit: actions.setTarget)
                                .disabled(!model.connected)
                        }
                        if !model.modes.isEmpty || model.oscillating != nil {
                            ModeModule(
                                modes: model.modes,
                                selected: model.selectedMode,
                                oscillating: model.oscillating,
                                onSelect: actions.setMode,
                                onOscillate: actions.oscillate,
                                animates: model.isOn
                            )
                            .disabled(!model.connected)
                        }
                        AutoModule(isOn: model.autoOn, target: model.autoTarget, status: model.autoStatus, onChange: actions.setAuto)
                            .disabled(!model.connected)
                    }
                }
            }
            FooterBar(showsSettingsButton: !showSettings, summary: model.summary) { showSettings = true }
        }
        .padding(12)
        .frame(width: 320)
        .background { AmbientBackground(ambience: model.ambience) }
        .tint(.orange)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: showSettings)
        .animation(reduceMotion ? nil : .snappy, value: model.heroWord)
        .animation(reduceMotion ? nil : .snappy, value: model.current)
        .animation(reduceMotion ? nil : .snappy, value: model.error)
    }
}

// MARK: - Living background

enum Ambience: Equatable {
    case hot, warm, cold, idle

    /// Top → bottom gradient stops; the darkest stop sits under the white hero text.
    fileprivate func colors(dark: Bool) -> [Color] {
        let rgb: [(Double, Double, Double)] = switch self {
        case .hot: [(0.62, 0.07, 0.09), (0.86, 0.23, 0.10), (0.96, 0.49, 0.20)]
        case .warm: [(0.80, 0.38, 0.08), (0.92, 0.58, 0.26), (0.97, 0.75, 0.55)]
        case .cold: [(0.22, 0.52, 0.95), (0.43, 0.67, 0.97), (0.72, 0.84, 0.98)]
        case .idle: [(0.35, 0.42, 0.51), (0.48, 0.54, 0.61), (0.64, 0.69, 0.74)]
        }
        let k = dark ? 0.58 : 1
        return rgb.map { Color(red: $0.0 * k, green: $0.1 * k, blue: $0.2 * k) }
    }
}

/// Gradient + particles behind the whole panel. Idle states and Reduce Motion get a static
/// gradient; the animated ones run on Core Animation and pause while the panel is hidden.
struct AmbientBackground: View {
    var ambience: Ambience
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ZStack {
                LinearGradient(colors: ambience.colors(dark: colorScheme == .dark), startPoint: .top, endPoint: .bottom)
                if ambience != .idle && !reduceMotion {
                    ParticleLayer(ambience: ambience)
                }
            }
            .id(ambience)
            .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: ambience)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Embers / dust and heat haze as Core Animation layers: the render server animates them, so the
/// app does no per-frame work. (A SwiftUI TimelineView + Canvas measured ~7% CPU here: on macOS
/// it wakes the main thread at the display refresh rate whatever its schedule.)
struct ParticleLayer: NSViewRepresentable {
    var ambience: Ambience

    func makeNSView(context: Context) -> ParticleView { ParticleView(ambience: ambience) }
    func updateNSView(_ nsView: ParticleView, context: Context) {}

    final class ParticleView: NSView {
        private let ambience: Ambience
        private let root = CALayer()

        init(ambience: Ambience) {
            self.ambience = ambience
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            layer?.addSublayer(root)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            guard root.frame.size != bounds.size, bounds.width > 0 else { return }
            root.frame = bounds
            root.sublayers = nil
            switch ambience {
            case .hot:
                hazeLayers(bands: 3, opacity: 0.06, period: 5).forEach(root.addSublayer)
                root.addSublayer(emitter([ember(rate: 2.4, life: 9, speed: 40, scale: 0.28, rgb: (1, 0.82, 0.5)),
                                          spark()]))
            case .warm:
                hazeLayers(bands: 2, opacity: 0.05, period: 9).forEach(root.addSublayer)
                root.addSublayer(emitter([ember(rate: 1.4, life: 10, speed: 18, scale: 0.24, rgb: (1, 0.93, 0.75))]))
            case .cold:
                root.addSublayer(dust())
            case .idle:
                break
            }
        }

        // Zero frames while the panel is closed: freeze the layer clock on occlusion.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            NotificationCenter.default.removeObserver(self)
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                                       name: NSWindow.didChangeOcclusionStateNotification, object: window)
            }
            occlusionChanged()
        }

        @objc private func occlusionChanged() {
            let visible = window?.occlusionState.contains(.visible) == true
            guard visible != (root.speed != 0) else { return }
            if visible {
                let pausedAt = root.timeOffset
                root.speed = 1
                root.timeOffset = 0
                root.beginTime = 0
                root.beginTime = root.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
            } else {
                root.timeOffset = root.convertTime(CACurrentMediaTime(), from: nil)
                root.speed = 0
            }
        }

        private func emitter(_ cells: [CAEmitterCell]) -> CAEmitterLayer {
            let layer = CAEmitterLayer()
            layer.emitterShape = .line
            layer.emitterPosition = CGPoint(x: bounds.midX, y: -6)  // bottom edge (unflipped)
            layer.emitterSize = CGSize(width: bounds.width, height: 1)
            layer.emitterCells = cells
            layer.beginTime = CACurrentMediaTime() - 12  // pre-warm: opens with particles in flight
            return layer
        }

        /// Rising ember fading out with height.
        private func ember(rate: Float, life: Float, speed: CGFloat, scale: CGFloat,
                           rgb: (CGFloat, CGFloat, CGFloat)) -> CAEmitterCell {
            let cell = CAEmitterCell()
            cell.contents = glowDot
            cell.birthRate = rate
            cell.lifetime = life
            cell.lifetimeRange = 2
            cell.velocity = speed
            cell.velocityRange = speed * 0.35
            cell.emissionLongitude = .pi / 2
            cell.emissionRange = .pi / 12
            cell.scale = scale
            cell.scaleRange = scale * 0.45
            cell.alphaRange = 0.35
            cell.alphaSpeed = -1 / life
            cell.color = CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
            return cell
        }

        /// Short-lived bright spark that blinks out: the "flicker" of the hot state.
        private func spark() -> CAEmitterCell {
            let cell = ember(rate: 1, life: 2.4, speed: 70, scale: 0.18, rgb: (1, 0.95, 0.75))
            cell.lifetimeRange = 0.8
            cell.alphaSpeed = -0.45
            return cell
        }

        /// Cold: specks appearing anywhere, growing slowly and fading while drifting.
        private func dust() -> CAEmitterLayer {
            let layer = CAEmitterLayer()
            layer.emitterShape = .rectangle
            layer.emitterMode = .surface
            layer.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
            layer.emitterSize = bounds.size
            let cell = CAEmitterCell()
            cell.contents = glowDot
            cell.birthRate = 2.5
            cell.lifetime = 8
            cell.lifetimeRange = 2
            cell.velocity = 6
            cell.velocityRange = 4
            cell.emissionRange = .pi * 2
            cell.scale = 0.04
            cell.scaleSpeed = 0.025
            cell.alphaSpeed = -0.08
            cell.color = CGColor(srgbRed: 0.93, green: 0.96, blue: 1, alpha: 0.85)
            layer.emitterCells = [cell]
            layer.beginTime = CACurrentMediaTime() - 10
            return layer
        }

        /// Translucent sine bands under the hero, sliding one wavelength per period (seamless loop).
        private func hazeLayers(bands: Int, opacity: Float, period: CFTimeInterval) -> [CALayer] {
            let wavelength = bounds.width / 1.5
            let width = bounds.width + wavelength
            return (0..<bands).map { b in
                let base = bounds.height * (0.94 - 0.13 * CGFloat(b))
                let phase = CGFloat(b) * 1.7
                let xs = stride(from: 0, through: width, by: wavelength / 12).map { $0 }
                let path = CGMutablePath()
                path.addLines(between: xs.map { CGPoint(x: $0, y: base + sin($0 / wavelength * 2 * .pi + phase) * 6) })
                path.addLines(between: xs.reversed().map {
                    CGPoint(x: $0, y: base - 16 + sin($0 / wavelength * 2 * .pi + phase + 0.8) * 6)
                })
                path.closeSubpath()
                let layer = CAShapeLayer()
                layer.path = path
                layer.fillColor = .white
                layer.opacity = opacity
                let slide = CABasicAnimation(keyPath: "transform.translation.x")
                slide.fromValue = 0
                slide.toValue = -wavelength
                slide.duration = period + CFTimeInterval(b)
                slide.repeatCount = .infinity
                layer.add(slide, forKey: "slide")
                return layer
            }
        }
    }
}

/// Soft round particle sprite (bright core, faded rim), drawn once.
private let glowDot: CGImage? = {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: 24, height: 24, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let gradient = CGGradient(colorsSpace: space, colors: [
              CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
              CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.3),
              CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
          ] as CFArray, locations: [0, 0.25, 1])
    else { return nil }
    ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: 12, y: 12), startRadius: 0,
                           endCenter: CGPoint(x: 12, y: 12), endRadius: 12, options: [])
    return ctx.makeImage()
}()

// MARK: - Modules (presentation only: plain values in, closures out)

/// Liquid Glass card; dims its whole content when disabled.
private struct GlassCard: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .opacity(isEnabled ? 1 : 0.45)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

private extension View {
    func glassCard() -> some View { modifier(GlassCard()) }

    /// One-shot SF Symbol animation when a mode becomes active (no looping: zero cost at rest).
    @ViewBuilder func activationSymbolEffect(_ icon: String, isActive: Bool) -> some View {
        switch icon {
        case "wind", "fan.oscillation":
            symbolEffect(.wiggle.byLayer, value: isActive)
        case "heat.waves":
            symbolEffect(.variableColor.iterative, value: isActive)
        default:
            symbolEffect(.bounce.up, value: isActive)
        }
    }
}

/// Circular Liquid Glass button: orange-tinted glass when active, optional caption below.
private struct GlassCircleButtonStyle: ButtonStyle {
    var isActive: Bool
    var diameter: CGFloat = 40
    var caption: String?

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 5) {
            configuration.label
                .font(.system(size: diameter * 0.42, weight: .medium))
                .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: diameter, height: diameter)
                .glassEffect(isActive ? .regular.tint(.orange).interactive() : .regular.interactive(), in: .circle)
                .scaleEffect(configuration.isPressed ? 0.93 : 1)
                .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            if let caption {
                Text(caption)
                    .font(.caption.weight(isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .contentShape(Rectangle())
    }
}

struct HeroModule: View {
    var word: String
    var status: String
    var subtitle: String
    var current: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Aquecedor Xiaomi").font(.headline)
                Text(status).font(.caption).opacity(0.85).contentTransition(.opacity)
            }
            HStack(alignment: .firstTextBaseline) {
                ZStack(alignment: .leading) {
                    Text(word)
                        .id(word)
                        .transition(.push(from: .bottom).combined(with: .opacity))
                }
                .font(.system(size: 44, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .clipped()
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: -4) {
                    Text(current.map { "\(formatTemp($0))°" } ?? "—")
                        .font(.system(size: 44, weight: .thin))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: current ?? 0))
                    Text("Ambiente").font(.caption2).opacity(0.85)
                }
            }
            Text(subtitle)
                .font(.subheadline.weight(.medium))
                .opacity(0.9)
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.22), radius: 6, y: 1)
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct PowerModule: View {
    var isOn: Bool
    var status: String
    var onPower: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPower) { Image(systemName: "power") }
                .buttonStyle(GlassCircleButtonStyle(isActive: isOn, diameter: 48))
                .help(isOn ? "Desligar" : "Ligar")
                .accessibilityLabel(isOn ? "Desligar" : "Ligar")
            VStack(alignment: .leading, spacing: 1) {
                Text(isOn ? "Desligar" : "Ligar").font(.body.weight(.semibold))
                Text(status).font(.caption).foregroundStyle(.secondary).contentTransition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .glassCard()
    }
}

struct StatusModule: View {
    var connected: Bool
    var message: String
    var onRetry: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: connected ? "exclamationmark.triangle" : "wifi.exclamationmark")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(connected ? "Falha de comunicação" : "Sem conexão").font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Tentar de novo", action: onRetry)
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .glassCard()
    }
}

struct TargetModule: View {
    var range: ClosedRange<Double>
    var step: Double
    var target: Double?
    var onCommit: (Double) -> Void

    @State private var draft: Double?
    @State private var editing = false

    private var value: Double { draft ?? target ?? range.lowerBound }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Temperatura alvo").font(.subheadline.weight(.semibold))
                Spacer()
                Text(target == nil && draft == nil ? "—" : "\(formatTemp(value)) °C")
                    .font(.title3.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(editing ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .contentTransition(.numericText(value: value))
                    .animation(.snappy, value: value)
            }
            // Only the released value goes to the device; dragging just updates the local draft.
            Slider(
                value: Binding(get: { value }, set: { draft = $0 }),
                in: range,
                step: step,
                label: { Text("Temperatura alvo") },
                minimumValueLabel: { Text("\(formatTemp(range.lowerBound))°") },
                maximumValueLabel: { Text("\(formatTemp(range.upperBound))°") },
                onEditingChanged: { isEditing in
                    editing = isEditing
                    guard !isEditing, let draft else { return }
                    if draft != target { onCommit(draft) }
                }
            )
            .labelsHidden()
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onChange(of: target) { _, _ in
            if !editing { draft = nil }
        }
        .glassCard()
    }
}

struct ModeModule: View {
    var modes: [(value: Int, name: String)]
    var selected: Int?
    var oscillating: Bool?  // nil: no oscillation support
    var onSelect: (Int) -> Void
    var onOscillate: () -> Void
    var animates = true  // animate symbol activation only while the heater runs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Modo").font(.subheadline.weight(.semibold))
            HStack(alignment: .top, spacing: 4) {
                ForEach(modes, id: \.value) { mode in
                    let name = modeNames[mode.name] ?? mode.name
                    let icon = modeIcons[mode.name] ?? "circle"
                    let active = mode.value == selected
                    Button { onSelect(mode.value) } label: {
                        Image(systemName: icon).activationSymbolEffect(icon, isActive: active && animates && !reduceMotion)
                    }
                    .buttonStyle(GlassCircleButtonStyle(isActive: active, caption: name))
                    .frame(maxWidth: .infinity)
                    .help(name)
                    .accessibilityLabel(name)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
                if let oscillating {
                    Button(action: onOscillate) {
                        Image(systemName: "fan.oscillation")
                            .activationSymbolEffect("fan.oscillation", isActive: oscillating && animates && !reduceMotion)
                    }
                    .buttonStyle(GlassCircleButtonStyle(isActive: oscillating, caption: "Oscilar"))
                    .frame(maxWidth: .infinity)
                    .help(oscillating ? "Parar oscilação" : "Oscilar")
                    .accessibilityLabel("Oscilar")
                    .accessibilityAddTraits(oscillating ? .isSelected : [])
                }
            }
        }
        .glassCard()
    }
}

struct AutoModule: View {
    var isOn: Bool
    var target: Double
    var status: AutoStatus
    var onChange: (Bool) -> Void

    private var subtitle: String {
        switch status {
        case .off: "Mantém a sala em \(formatTemp(target))° gastando o mínimo"
        case .heating(.strong): "Aquecendo forte (Quente)"
        case .heating(.gentle): "Mantendo (Morno)"
        case .paused(let resumeIn?): "Em pausa · volta em ~\(max(1, Int((resumeIn / 60).rounded()))) min"
        case .paused(nil): "Em pausa"
        case .noSensor: "Sem leitura de temperatura"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: 32, height: 32)
                .glassEffect(isOn ? .regular.tint(.orange) : .regular, in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text("Auto inteligente · \(formatTemp(target))°").font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 4)
            Toggle("Auto inteligente", isOn: Binding(get: { isOn }, set: onChange))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .glassCard()
    }
}

struct FooterBar: View {
    var showsSettingsButton: Bool
    var summary: WeekSummary?
    var onSettings: () -> Void

    private func number(_ value: Double, _ digits: Int) -> String {
        value.formatted(.number.locale(ptLocale).precision(.fractionLength(digits)))
    }

    var body: some View {
        HStack {
            if showsSettingsButton {
                Button(action: onSettings) {
                    Label("Configurações", systemImage: "gearshape").labelStyle(.iconOnly)
                }
                .help("Configurações")
            }
            Spacer()
            if let summary {
                Text("7 dias: \(number(summary.hours, 1)) h · \(number(summary.kWh, 1)) kWh · €\(number(summary.cost, 2))")
                    .font(.caption)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .help("Estimativa a partir dos modos; o aparelho não mede consumo")
                Spacer()
            }
            Button("Sair") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }
}
