// Throwaway measurement probe. NOT shipped code.
//
// What does each way of moving four 3pt bars cost? One small borderless
// panel near the bottom-right corner, holding the bars drawn one of six ways:
//   static         SwiftUI capsules, no animation (the closed notch until now)
//   swiftui-frame  .repeatForever on each bar's frame height (the old peek)
//   swiftui-scale  .repeatForever on a vertical scaleEffect
//   ca             a repeating CABasicAnimation per bar, uncapped
//   ca-30, ca-20   the same, preferredFrameRateRange capped at 30 / 20 fps
//
// Build: swiftc -O 2026-10-29-equalizer-probe.swift -o BarsProbe
// Usage: BarsProbe <mode> <seconds>
// Prints this process's CPU seconds and energy (rusage ri_energy_nj) over the
// run, after a 2s settle. WindowServer's CPU time is sampled around it with
// `ps -o time= -p $(pgrep -x WindowServer)`; see the research note.
import AppKit
import SwiftUI
import QuartzCore
import Darwin

let mode = CommandLine.arguments[1]
let seconds = Double(CommandLine.arguments[2])!

struct SwiftUIBars: View {
    let useScale: Bool
    var body: some View {
        HStack(spacing: 2) { ForEach(0..<4, id: \.self) { Bar(i: $0, useScale: useScale) } }
            .frame(width: 30, height: 14)
    }
    struct Bar: View {
        let i: Int; let useScale: Bool
        @State var up = false
        static let low: [CGFloat] = [0.3, 0.45, 0.25, 0.4]
        static let high: [CGFloat] = [0.9, 1.0, 0.8, 0.95]
        static let period: [Double] = [0.42, 0.33, 0.5, 0.38]
        var body: some View {
            Group {
                if useScale {
                    Capsule().fill(.white).frame(width: 3, height: 14)
                        .scaleEffect(x: 1, y: up ? Self.high[i] : Self.low[i], anchor: .bottom)
                } else {
                    Capsule().fill(.white).frame(width: 3, height: 14 * (up ? Self.high[i] : Self.low[i]))
                }
            }
            .frame(height: 14, alignment: .bottom)
            .onAppear {
                withAnimation(.easeInOut(duration: Self.period[i]).repeatForever(autoreverses: true)) { up = true }
            }
        }
    }
}

final class CABars: NSView {
    init(fps: Float?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 14))
        wantsLayer = true
        let low: [CGFloat] = [0.3, 0.45, 0.25, 0.4]
        let high: [CGFloat] = [0.9, 1.0, 0.8, 0.95]
        let period: [Double] = [0.42, 0.33, 0.5, 0.38]
        for i in 0..<4 {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = 1.5
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.frame = CGRect(x: CGFloat(i) * 5, y: 0, width: 3, height: 14)
            let a = CABasicAnimation(keyPath: "transform.scale.y")
            a.fromValue = low[i]; a.toValue = high[i]
            a.duration = period[i]; a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if let fps { a.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps) }
            bar.add(a, forKey: "eq")
            layer!.addSublayer(bar)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

func usage() -> (cpu: Double, energy: UInt64) {
    var info = rusage_info_v6()
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
    }
    precondition(r == 0)
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
    let ns = Double(info.ri_user_time + info.ri_system_time) * Double(tb.numer) / Double(tb.denom)
    return (ns / 1e9, info.ri_energy_nj)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main!.frame
let panel = NSPanel(contentRect: NSRect(x: screen.maxX - 60, y: screen.minY + 8, width: 44, height: 24),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.level = .statusBar
panel.backgroundColor = .black
panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
let content: NSView
switch mode {
case "static":        content = NSHostingView(rootView: Capsule().fill(.white).frame(width: 30, height: 14))
case "swiftui-frame": content = NSHostingView(rootView: SwiftUIBars(useScale: false))
case "swiftui-scale": content = NSHostingView(rootView: SwiftUIBars(useScale: true))
case "ca":            content = CABars(fps: nil)
case "ca-30":         content = CABars(fps: 30)
case "ca-20":         content = CABars(fps: 20)
default: fatalError(mode)
}
content.frame = NSRect(x: 7, y: 5, width: 30, height: 14)
panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
panel.contentView!.addSubview(content)
panel.orderFrontRegardless()

var start: (cpu: Double, energy: UInt64)!
DispatchQueue.main.asyncAfter(deadline: .now() + 2) {   // let launch settle
    start = usage()
    print("START \(ProcessInfo.processInfo.processIdentifier)"); fflush(stdout)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        let end = usage()
        print(String(format: "RESULT mode=%@ cpu_s=%.3f cpu_pct=%.3f energy_mJ=%.1f",
                     mode, end.cpu - start.cpu, (end.cpu - start.cpu) / seconds * 100,
                     Double(end.energy - start.energy) / 1e6))
        exit(0)
    }
}
app.run()
