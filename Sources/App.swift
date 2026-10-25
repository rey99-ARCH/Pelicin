import SwiftUI
import UIKit
import QuartzCore
import Darwin
import Foundation


@main
struct PeliciniApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}


final class DeviceMonitor: NSObject, ObservableObject {
    @Published var thermal: ProcessInfo.ThermalState = .nominal
    @Published var lowPower = false
    @Published var batteryPercent: Int? = nil
    @Published var fps = 0
    @Published var appMemoryMB = 0.0
    @Published var freeDiskGB = 0.0
    @Published var lastCleanMessage = ""

    let totalRAMGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    var maxFPS: Int { UIScreen.main.maximumFramesPerSecond }

    private var link: CADisplayLink?
    private var frameCount = 0
    private var lastStamp: CFTimeInterval = 0
    private var timer: Timer?

    func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
        lastStamp = CACurrentMediaTime()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func stop() {
        link?.invalidate(); link = nil
        timer?.invalidate(); timer = nil
    }

    @objc private func tick() {
        frameCount += 1
        let now = CACurrentMediaTime()
        if now - lastStamp >= 1 {
            fps = Int((Double(frameCount) / (now - lastStamp)).rounded())
            frameCount = 0
            lastStamp = now
        }
    }

    private func refresh() {
        thermal = ProcessInfo.processInfo.thermalState
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let lvl = UIDevice.current.batteryLevel
        batteryPercent = lvl < 0 ? nil : Int((lvl * 100).rounded())
        appMemoryMB = Self.footprintMB()
        freeDiskGB = Self.freeDiskGB()
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    static func freeDiskGB() -> Double {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let b = v.volumeAvailableCapacityForImportantUsage else { return 0 }
        return Double(b) / 1_073_741_824
    }

    /// Hanya membersihkan cache milik app ini sendiri. iOS tidak mengizinkan app membersihkan app lain.
    func cleanOwnCache() {
        URLCache.shared.removeAllCachedResponses()
        let fm = FileManager.default
        var freed: Int64 = 0
        let dirs = [fm.temporaryDirectory,
                    fm.urls(for: .cachesDirectory, in: .userDomainMask).first].compactMap { $0 }
        for dir in dirs {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for item in items {
                let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
                if (try? fm.removeItem(at: item)) != nil { freed += Int64(size) }
            }
        }
        lastCleanMessage = "Cache app ini dibersihkan: \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))"
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "Normal"
        case .fair: return "Hangat"
        case .serious: return "Panas (performa dikurangi iOS)"
        case .critical: return "Kritis (performa dibatasi berat)"
        @unknown default: return "Tidak diketahui"
        }
    }
}


enum PlayStyle: String, CaseIterable, Identifiable {
    case thumbs = "2 jari (jempol)"
    case claw3 = "3 jari (claw)"
    case claw4 = "4+ jari"
    var id: String { rawValue }
    var factor: Double {
        switch self {
        case .thumbs: return 1.00
        case .claw3: return 0.92
        case .claw4: return 0.85
        }
    }
}

struct SensitivityResult {
    let general: Int
    let ads: Int
    let scopes: [(name: String, value: Int)]
}

/// Perhitungan heuristik. Ini titik awal, bukan nilai pasti: setiap game memakai skala
/// sensitivitas sendiri, jadi hasilnya harus diketik manual di pengaturan game dan disetel ulang.
enum SensitivityModel {
    static func compute(screenInches: Double, style: PlayStyle, precisionBias: Double) -> SensitivityResult {
        // Layar lebih besar = jarak geser jari lebih jauh, jadi butuh sensitivitas sedikit lebih rendah.
        let screenFactor = 1.0 - (screenInches - 6.1) * 0.06
        // precisionBias: 0 = cepat/putar lincah, 1 = presisi/bidikan halus
        let biasFactor = 1.10 - precisionBias * 0.30
        let general = clamp(70 * screenFactor * style.factor * biasFactor)
        let ads = clamp(Double(general) * 0.85)
        let multipliers: [(String, Double)] = [("Red dot", 0.90), ("2x", 0.70), ("3x", 0.58), ("4x", 0.48), ("6x", 0.38), ("8x", 0.30)]
        let scopes = multipliers.map { ($0.0, clamp(Double(ads) * $0.1)) }
        return SensitivityResult(general: general, ads: ads, scopes: scopes)
    }

    private static func clamp(_ v: Double) -> Int { max(1, min(100, Int(v.rounded()))) }
}


struct ContentView: View {
    var body: some View {
        TabView {
            PerformanceView()
                .tabItem { Label("Performa", systemImage: "speedometer") }
            SensitivityView()
                .tabItem { Label("Sensitivitas", systemImage: "hand.draw") }
        }
    }
}

struct PerformanceView: View {
    @StateObject private var m = DeviceMonitor()

    var body: some View {
        NavigationView {
            List {
                Section("Status langsung") {
                    row("FPS layar", "\(m.fps) / \(m.maxFPS)")
                    row("Suhu (thermal)", m.thermal.label)
                    row("Mode Daya Rendah", m.lowPower ? "Aktif" : "Mati")
                    row("Baterai", m.batteryPercent.map { "\($0)%" } ?? "n/a")
                    row("RAM perangkat", String(format: "%.1f GB", m.totalRAMGB))
                    row("Memori app ini", String(format: "%.0f MB", m.appMemoryMB))
                    row("Penyimpanan kosong", String(format: "%.1f GB", m.freeDiskGB))
                }
                Section("Saran") {
                    ForEach(advice, id: \.self) { Text($0) }
                }
                Section("Aksi") {
                    Button("Bersihkan cache app ini") { m.cleanOwnCache() }
                    if !m.lastCleanMessage.isEmpty {
                        Text(m.lastCleanMessage).font(.footnote).foregroundColor(.secondary)
                    }
                    Button("Buka Pengaturan iPhone") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }
                }
                Section {
                    Text("iOS tidak mengizinkan app pihak ketiga menutup app lain, membersihkan RAM sistem, atau menaikkan clock CPU. Aplikasi ini hanya mengukur kondisi perangkat dan memberi saran.")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Pelicin")
        }
        .onAppear { m.start() }
        .onDisappear { m.stop() }
    }

    private var advice: [String] {
        var a: [String] = []
        switch m.thermal {
        case .serious, .critical: a.append("iPhone panas: lepas casing, hentikan pengisian daya, dan istirahatkan sebentar. iOS sedang menurunkan performa.")
        case .fair: a.append("Suhu mulai naik. Kurangi kecerahan layar.")
        default: break
        }
        if m.lowPower { a.append("Mode Daya Rendah aktif dan membatasi FPS serta performa. Matikan saat bermain game.") }
        if m.freeDiskGB > 0 && m.freeDiskGB < 5 { a.append("Penyimpanan kurang dari 5 GB. Hapus file atau app yang tidak dipakai agar iOS tidak melambat.") }
        if let b = m.batteryPercent, b < 20 { a.append("Baterai rendah. Isi daya dulu agar performa stabil.") }
        if a.isEmpty { a.append("Kondisi perangkat baik. Tidak ada yang perlu dioptimalkan.") }
        return a
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundColor(.secondary) }
    }
}

struct SensitivityView: View {
    @State private var inches = 6.1
    @State private var style: PlayStyle = .claw3
    @State private var precision = 0.5

    var body: some View {
        let r = SensitivityModel.compute(screenInches: inches, style: style, precisionBias: precision)
        NavigationView {
            Form {
                Section("Perangkat & gaya main") {
                    VStack(alignment: .leading) {
                        Text(String(format: "Ukuran layar: %.1f inci", inches))
                        Slider(value: $inches, in: 4.7...6.9, step: 0.1)
                    }
                    Picker("Gaya jari", selection: $style) {
                        ForEach(PlayStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    VStack(alignment: .leading) {
                        Text("Preferensi: lincah  ←→  presisi")
                        Slider(value: $precision, in: 0...1)
                    }
                }
                Section("Saran nilai awal (skala 1-100)") {
                    row("Umum / kamera", r.general)
                    row("ADS / bidik", r.ads)
                    ForEach(r.scopes, id: \.name) { row($0.name, $0.value) }
                }
                Section {
                    Text("Ini perkiraan titik awal. Skala tiap game berbeda. Ketik nilainya di pengaturan game, uji di mode latihan, lalu naikkan atau turunkan 3-5 poin sesuai rasa. Aplikasi ini tidak mengubah sensitivitas sentuhan iPhone atau game apa pun.")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Sensitivitas")
        }
    }

    private func row(_ k: String, _ v: Int) -> some View {
        HStack { Text(k); Spacer(); Text("\(v)").bold() }
    }
}
