import SwiftUI
import MetalKit

@main
struct TidalChamberApp: App {
    var body: some Scene { WindowGroup { ChamberScreen() } }
}

struct ChamberScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var refresh = UUID()
    @State private var rendererFailure = false
    @ScaledMetric(relativeTo:.largeTitle) private var timeFont: CGFloat = 49
    private let fixture: Date? = {
        #if DEBUG
        let args=ProcessInfo.processInfo.arguments
        if let i=args.firstIndex(of:"-fixture"),args.indices.contains(i+1) {
            let parts=args[i+1].split(separator:":").compactMap{Int($0)}
            if parts.count==2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) { return ClockState.fixtureDate(parts[0],parts[1]) }
        }
        #endif
        return nil
    }()
    private var reduceMotion: Bool {
        #if DEBUG
        return systemReduceMotion || ProcessInfo.processInfo.arguments.contains("-reduceMotion")
        #else
        return systemReduceMotion
        #endif
    }
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(red:0.035,green:0.085,blue:0.10)
                ChamberMetalView(reduceMotion:reduceMotion,active:scenePhase == .active,increaseContrast:contrast == .increased,accessibleLayout:typeSize.isAccessibilitySize,fixture:fixture,failure:$rendererFailure)
                    .accessibilityHidden(true)
                // A fixed scrim supports real text while leaving the modeled scene visible.
                VStack { Spacer(); LinearGradient(colors:[.clear,Color.black.opacity(0.84)],startPoint:.top,endPoint:.bottom).frame(height:proxy.size.height*(typeSize.isAccessibilitySize ? 0.55 : 0.32)) }
                    .allowsHitTesting(false)
                VStack(spacing:0) {
                    Spacer()
                    TimelineView(.periodic(from:.now,by:1)) { context in
                        let date=fixture ?? context.date
                        VStack(spacing:8) {
                            Text(date,format:.dateTime.hour(.defaultDigits(amPM:.omitted)).minute())
                                .font(.system(size:timeFont,weight:.light,design:.serif))
                                .multilineTextAlignment(.center)
                                .lineLimit(1)
                                .fixedSize(horizontal:false,vertical:true)
                                .monospacedDigit()
                                .foregroundStyle(Color(red:0.98,green:0.91,blue:0.77))
                                .contentTransition(.identity)
                            HStack(spacing:12) {
                                if let period=periodLabel(date) { Text(period).font(.title3) }
                                if !typeSize.isAccessibilitySize { Text("LOCAL TIME").font(.caption.weight(.medium)).tracking(3.2) }
                            }
                            .foregroundStyle(Color(red:0.98,green:0.91,blue:0.77).opacity(0.9))
                        }
                        .accessibilityElement(children:.ignore)
                        .accessibilityLabel(Text("Local time"))
                        .accessibilityValue(Text(date,format:.dateTime.hour().minute()))
                        .accessibilityIdentifier("clock.time")
                    }
                    .id(refresh)
                    .padding(.horizontal,20)
                    .padding(.bottom,max(28,proxy.safeAreaInsets.bottom)+proxy.size.height*0.045)
                }
                if rendererFailure {
                    VStack { Text("The 3D scene could not start.").font(.body); Text("The clock remains live.").font(.caption) }
                        .padding().foregroundStyle(.white).background(.black.opacity(0.8))
                }
                #if DEBUG
                if fixture != nil {
                    VStack { Text("TIME STUDY · PREVIEW").font(.system(size:11)).tracking(2).padding(10).background(.black.opacity(0.55)); Spacer() }
                        .foregroundStyle(.white).padding(.top,max(60,proxy.safeAreaInsets.top)).allowsHitTesting(false).accessibilityHidden(true)
                }
                #endif
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onChange(of:scenePhase) { _,phase in if phase == .active { refresh=UUID() } }
        .onReceive(NotificationCenter.default.publisher(for:UIApplication.significantTimeChangeNotification)) { _ in refresh=UUID() }
        .onReceive(NotificationCenter.default.publisher(for:NSNotification.Name.NSSystemTimeZoneDidChange)) { _ in refresh=UUID() }
    }

    private func periodLabel(_ date:Date)->String? {
        guard DateFormatter.dateFormat(fromTemplate:"j",options:0,locale:.autoupdatingCurrent)?.contains("a") == true else { return nil }
        let formatter=DateFormatter(); formatter.locale = .autoupdatingCurrent; formatter.dateFormat="a"
        return formatter.string(from:date)
    }
}

struct ChamberMetalView: UIViewRepresentable {
    var reduceMotion: Bool
    var active: Bool
    var increaseContrast: Bool
    var accessibleLayout: Bool
    var fixture: Date?
    @Binding var failure: Bool

    final class Coordinator {
        var renderer: ChamberRenderer?
        var redrawTimer: Timer?
        deinit { redrawTimer?.invalidate() }
    }
    func makeCoordinator()->Coordinator { Coordinator() }
    func makeUIView(context:Context)->MTKView {
        let view=MTKView(frame:.zero)
        view.isAccessibilityElement=false
        do { context.coordinator.renderer=try ChamberRenderer(view:view) }
        catch { DispatchQueue.main.async { failure=true }; print("Renderer initialization failed: \(error)") }
        return view
    }
    func updateUIView(_ view:MTKView,context:Context) {
        let c=context.coordinator
        c.renderer?.reduceMotion=reduceMotion; c.renderer?.increaseContrast=increaseContrast; c.renderer?.fixture=fixture
        c.renderer?.accessibleLayout=accessibleLayout
        c.renderer?.resetFrameClock()
        view.isPaused = !active || reduceMotion
        view.enableSetNeedsDisplay = reduceMotion && active
        c.redrawTimer?.invalidate(); c.redrawTimer=nil
        if active && reduceMotion {
            // No continuous GPU animation, but the analog hands still track wall time.
            c.redrawTimer=Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak view] _ in view?.setNeedsDisplay() }
            view.setNeedsDisplay()
        }
    }
    static func dismantleUIView(_ view:MTKView,coordinator:Coordinator) {
        coordinator.redrawTimer?.invalidate(); view.isPaused=true; view.delegate=nil
    }
}

#Preview("Live") { ChamberScreen() }
#Preview("Large text") { ChamberScreen().environment(\.dynamicTypeSize,.accessibility3) }
