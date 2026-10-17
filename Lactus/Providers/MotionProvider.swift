import CoreMotion
import Foundation
import Observation

/// Pohybové senzory a barometr. Surové senzory nepotřebují souhlas; krokoměr, aktivita
/// a absolutní výška spadají pod oprávnění „Pohyb a fitness“, které se žádá až tlačítkem.
@Observable @MainActor
final class MotionProvider: SensorProvider {
    let id = "motion"
    let title = "Pohyb a tlak"
    let systemImage = "gyroscope"
    private(set) var metrics: [Metric] = []
    private(set) var series: [MetricSeries] = []

    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let pedometer = CMPedometer()
    private let activityManager = CMMotionActivityManager()
    private var timer: Timer?

    private var accel: CMAcceleration?
    private var gyro: CMRotationRate?
    private var mag: CMMagneticField?
    private var deviceMotion: CMDeviceMotion?
    private var pressureKPa: Double?
    private var relativeAltitude: Double?
    private var absoluteAltitude: CMAbsoluteAltitudeData?
    private var pedometerData: CMPedometerData?
    private var pedometerError: String?
    private var activity: CMMotionActivity?
    private var fitnessStarted = false

    private var pressureHistory: [Sample] = []
    private var accelHistory: [Sample] = []

    var actions: [MetricAction] {
        let status = CMPedometer.authorizationStatus()
        guard !fitnessStarted, status == .notDetermined else { return [] }
        return [MetricAction(id: "fitness", title: "Povolit Pohyb a fitness (krokoměr, aktivita, výška)",
                             systemImage: "figure.walk", kind: .button { [weak self] in self?.startFitness() })]
    }

    func start() {
        if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = 0.1
            motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                MainActor.assumeIsolated { self?.accel = data?.acceleration }
            }
        }
        if motion.isGyroAvailable {
            motion.gyroUpdateInterval = 0.1
            motion.startGyroUpdates(to: .main) { [weak self] data, _ in
                MainActor.assumeIsolated { self?.gyro = data?.rotationRate }
            }
        }
        if motion.isMagnetometerAvailable {
            motion.magnetometerUpdateInterval = 0.1
            motion.startMagnetometerUpdates(to: .main) { [weak self] data, _ in
                MainActor.assumeIsolated { self?.mag = data?.magneticField }
            }
        }
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.1
            let frames = CMMotionManager.availableAttitudeReferenceFrames()
            let frame: CMAttitudeReferenceFrame = frames.contains(.xMagneticNorthZVertical)
                ? .xMagneticNorthZVertical : .xArbitraryCorrectedZVertical
            motion.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] data, _ in
                MainActor.assumeIsolated { self?.deviceMotion = data }
            }
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                MainActor.assumeIsolated {
                    guard let data else { return }
                    self?.pressureKPa = data.pressure.doubleValue
                    self?.relativeAltitude = data.relativeAltitude.doubleValue
                }
            }
        }
        if CMPedometer.authorizationStatus() == .authorized {
            startFitness()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        motion.stopAccelerometerUpdates()
        motion.stopGyroUpdates()
        motion.stopMagnetometerUpdates()
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        if fitnessStarted {
            altimeter.stopAbsoluteAltitudeUpdates()
            pedometer.stopUpdates()
            activityManager.stopActivityUpdates()
            fitnessStarted = false
        }
        timer?.invalidate()
        timer = nil
    }

    private func startFitness() {
        guard !fitnessStarted else { return }
        fitnessStarted = true
        if CMAltimeter.isAbsoluteAltitudeAvailable() {
            altimeter.startAbsoluteAltitudeUpdates(to: .main) { [weak self] data, _ in
                MainActor.assumeIsolated { self?.absoluteAltitude = data }
            }
        }
        if CMPedometer.isStepCountingAvailable() {
            let startOfDay = Calendar.current.startOfDay(for: Date())
            pedometer.startUpdates(from: startOfDay) { [weak self] data, error in
                Task { @MainActor [weak self] in
                    self?.pedometerData = data
                    self?.pedometerError = error?.localizedDescription
                }
            }
        }
        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.startActivityUpdates(to: .main) { [weak self] activity in
                MainActor.assumeIsolated { self?.activity = activity }
            }
        }
    }

    // MARK: - Metriky

    private func refresh() {
        let now = Date()
        var m: [Metric] = []

        // Surové senzory
        if motion.isAccelerometerAvailable {
            if let a = accel {
                let magnitude = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
                accelHistory.append(Sample(date: now, value: magnitude))
                trim(&accelHistory)
                m.append(.available("accel", "Akcelerometr", Fmt.xyz(a.x, a.y, a.z, 3) + " g",
                                    source: "CMMotionManager.accelerometerData"))
                m.append(.derived("accelmag", "Celkové zrychlení", Fmt.num(magnitude, 3) + " g",
                                  note: "√(x² + y² + z²); v klidu ≈ 1 g"))
            }
        } else {
            m.append(.unsupported("accel", "Akcelerometr", "Zařízení nehlásí akcelerometr."))
        }

        if motion.isGyroAvailable {
            if let g = gyro {
                m.append(.available("gyro", "Gyroskop",
                                    Fmt.xyz(Fmt.degrees(g.x), Fmt.degrees(g.y), Fmt.degrees(g.z), 1) + " °/s",
                                    source: "CMMotionManager.gyroData (rad/s → °/s)"))
            }
        } else {
            m.append(.unsupported("gyro", "Gyroskop", "Zařízení nehlásí gyroskop."))
        }

        if motion.isMagnetometerAvailable {
            if let f = mag {
                let total = (f.x * f.x + f.y * f.y + f.z * f.z).squareRoot()
                m.append(.available("mag", "Magnetometr (surový)", Fmt.xyz(f.x, f.y, f.z, 1) + " µT",
                                    source: "CMMotionManager.magnetometerData"))
                m.append(.derived("magtotal", "Celkové magnetické pole", Fmt.num(total, 1) + " µT",
                                  note: "Velikost vektoru; zemské pole je zhruba 25–65 µT, víc znamená rušení"))
            }
        } else {
            m.append(.unsupported("mag", "Magnetometr", "Zařízení nehlásí magnetometr."))
        }

        // Fúze senzorů
        if motion.isDeviceMotionAvailable {
            if let d = deviceMotion {
                let att = d.attitude
                m.append(.available("attitude", "Náklon (roll / pitch / yaw)",
                                    "\(Fmt.num(Fmt.degrees(att.roll), 1))° / \(Fmt.num(Fmt.degrees(att.pitch), 1))° / \(Fmt.num(Fmt.degrees(att.yaw), 1))°",
                                    source: "CMDeviceMotion.attitude"))
                m.append(.available("gravity", "Gravitace", Fmt.xyz(d.gravity.x, d.gravity.y, d.gravity.z, 2) + " g",
                                    source: "CMDeviceMotion.gravity"))
                let u = d.userAcceleration
                m.append(.available("useraccel", "Zrychlení uživatele", Fmt.xyz(u.x, u.y, u.z, 3) + " g",
                                    source: "CMDeviceMotion.userAcceleration"))
                if d.heading >= 0 {
                    m.append(.available("heading", "Směr (kompas ze senzorů)", Fmt.num(d.heading, 0) + "°",
                                        source: "CMDeviceMotion.heading"))
                }
                m.append(.available("calmag", "Magnetické pole (kalibrované)",
                                    Fmt.xyz(d.magneticField.field.x, d.magneticField.field.y, d.magneticField.field.z, 1)
                                        + " µT · " + accuracyText(d.magneticField.accuracy),
                                    source: "CMDeviceMotion.magneticField"))
                m.append(.available("sensorloc", "Umístění senzorů", sensorLocationText(d.sensorLocation),
                                    source: "CMDeviceMotion.sensorLocation"))
            }
        } else {
            m.append(.unsupported("devmotion", "Fúze senzorů", "CMDeviceMotion není k dispozici."))
        }

        // Barometr
        if CMAltimeter.isRelativeAltitudeAvailable() {
            if let p = pressureKPa {
                pressureHistory.append(Sample(date: now, value: p * 10))
                trim(&pressureHistory)
                m.append(.available("pressure", "Atmosférický tlak", Fmt.num(p * 10, 2) + " hPa",
                                    source: "CMAltitudeData.pressure (kPa → hPa)"))
            }
            if let r = relativeAltitude {
                m.append(.available("relalt", "Relativní výška od spuštění", Fmt.signed(r, 2) + " m",
                                    source: "CMAltitudeData.relativeAltitude"))
            }
        } else {
            m.append(.unsupported("baro", "Barometr", "Zařízení nehlásí barometr."))
        }

        // Pohyb a fitness
        let auth = CMPedometer.authorizationStatus()
        if CMAltimeter.isAbsoluteAltitudeAvailable() {
            if let a = absoluteAltitude {
                m.append(.available("absalt", "Absolutní výška",
                                    Fmt.num(a.altitude, 1) + " m " + Fmt.plusMinus(a.accuracy, 1, unit: "m")
                                        + " (přesnost měření \(Fmt.num(a.precision, 1)) m)",
                                    source: "CMAbsoluteAltitudeData"))
            } else if !fitnessStarted {
                m.append(.permission("absalt", "Absolutní výška", permissionReason(auth)))
            }
        } else {
            m.append(.unsupported("absalt", "Absolutní výška", "Zařízení ji nehlásí (vyžaduje iPhone 12 a novější)."))
        }

        if CMPedometer.isStepCountingAvailable() {
            if let p = pedometerData {
                m.append(.available("steps", "Kroky dnes", p.numberOfSteps.stringValue, source: "CMPedometer"))
                if let dist = p.distance {
                    m.append(.available("distance", "Vzdálenost dnes", Fmt.num(dist.doubleValue / 1000, 2) + " km",
                                        source: "CMPedometerData.distance"))
                }
                if let up = p.floorsAscended, let down = p.floorsDescended {
                    m.append(.available("floors", "Patra nahoru / dolů", "\(up) / \(down)",
                                        source: "CMPedometerData.floorsAscended"))
                }
                if let pace = p.currentPace, pace.doubleValue > 0 {
                    m.append(.available("pace", "Aktuální tempo", Fmt.num(pace.doubleValue, 2) + " s/m",
                                        source: "CMPedometerData.currentPace"))
                }
                if let cadence = p.currentCadence {
                    m.append(.available("cadence", "Kadence", Fmt.num(cadence.doubleValue * 60, 0) + " kroků/min",
                                        source: "CMPedometerData.currentCadence"))
                }
            } else if let err = pedometerError {
                m.append(.permission("steps", "Krokoměr", err))
            } else if !fitnessStarted {
                m.append(.permission("steps", "Krokoměr", permissionReason(auth)))
            }
        } else {
            m.append(.unsupported("steps", "Krokoměr", "Zařízení nehlásí počítání kroků."))
        }

        if CMMotionActivityManager.isActivityAvailable() {
            if let a = activity {
                m.append(.available("activity", "Aktivita", activityText(a), source: "CMMotionActivityManager"))
            } else if !fitnessStarted {
                m.append(.permission("activity", "Aktivita", permissionReason(auth)))
            }
        }

        m += [
            .unavailable("sensortemp", "Teplota senzorů", "Bez veřejného API."),
            .unavailable("sensorvendor", "Výrobce a model senzorů", "Bez veřejného API; iOS je skrývá za CoreMotion."),
            .unavailable("rawadc", "Surová ADC data", "CoreMotion dává už přepočtené fyzikální jednotky."),
            .unavailable("hz", "Vzorkování nad 100 Hz", "CMMotionManager omezuje aplikace na 100 Hz."),
        ]

        metrics = m
        series = [
            MetricSeries(id: "accel", name: "Celkové zrychlení", unit: "g", samples: accelHistory),
            MetricSeries(id: "pressure", name: "Tlak", unit: "hPa", samples: pressureHistory),
        ].filter { !$0.samples.isEmpty }
    }

    private func trim(_ samples: inout [Sample]) {
        if samples.count > 300 { samples.removeFirst(samples.count - 300) }
    }

    private func permissionReason(_ status: CMAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Vyžaduje souhlas „Pohyb a fitness“ (tlačítko níže)."
        case .denied: return "Souhlas odepřen; povolit lze v Nastavení › Soukromí › Pohyb a fitness."
        case .restricted: return "Omezeno správou zařízení."
        case .authorized: return "Spouští se…"
        @unknown default: return "Neznámý stav oprávnění."
        }
    }

    private func accuracyText(_ a: CMMagneticFieldCalibrationAccuracy) -> String {
        switch a {
        case .uncalibrated: return "nekalibrováno"
        case .low: return "nízká přesnost"
        case .medium: return "střední přesnost"
        case .high: return "vysoká přesnost"
        @unknown default: return "?"
        }
    }

    private func sensorLocationText(_ l: CMDeviceMotion.SensorLocation) -> String {
        switch l {
        case .default: return "Telefon"
        case .headphoneLeft: return "Levé sluchátko"
        case .headphoneRight: return "Pravé sluchátko"
        @unknown default: return "Neznámé"
        }
    }

    private func activityText(_ a: CMMotionActivity) -> String {
        var parts: [String] = []
        if a.stationary { parts.append("V klidu") }
        if a.walking { parts.append("Chůze") }
        if a.running { parts.append("Běh") }
        if a.cycling { parts.append("Kolo") }
        if a.automotive { parts.append("Vozidlo") }
        if a.unknown || parts.isEmpty { parts.append("Neznámá") }
        let confidence: String
        switch a.confidence {
        case .low: confidence = "nízká jistota"
        case .medium: confidence = "střední jistota"
        case .high: confidence = "vysoká jistota"
        @unknown default: confidence = "?"
        }
        return parts.joined(separator: ", ") + " · " + confidence
    }
}
