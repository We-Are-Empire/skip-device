// Copyright 2025–2026 Skip
// SPDX-License-Identifier: MPL-2.0
#if !SKIP_BRIDGE
import Foundation
#if canImport(OSLog)
import OSLog
#endif
#if !SKIP
import CoreLocation
#else
import android.os.Looper
import android.content.Context
import android.location.LocationManager
import android.location.LocationRequest
import android.location.LocationListener
import android.hardware.Sensor
import android.hardware.SensorManager
import android.hardware.SensorEvent
import android.hardware.GeomagneticField
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

typealias NSObject = AnyObject
#endif

private let logger: Logger = Logger(subsystem: "skip.device", category: "LocationProvider") // adb logcat '*:S' 'skip.device.LocationProvider:V'

/// A current location fetcher.
///
/// Requires `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription` in `App.xcconfig` and
/// `<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>` in `AndroidManifest.xml`.
public final class LocationProvider: NSObject, @unchecked Sendable {
    #if SKIP
    private let locationManager = ProcessInfo.processInfo.androidContext.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    private var listener: LocListener?
    private let sensorManager = ProcessInfo.processInfo.androidContext.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private var headingListener: SensorEventHandler? = nil
    private var lastLatitude: Double = 0.0
    private var lastLongitude: Double = 0.0
    private var lastAltitude: Double = 0.0
    #else
    private var locationManager: CLLocationManager?
    private var monitorContinuation: AsyncThrowingStream<LocationEvent, Error>.Continuation?
    private var pendingFetchContinuations: [UUID: CheckedContinuation<LocationEvent, Error>] = [:]
    private var isFetchingCurrentLocation = false
    private var headingContinuation: AsyncThrowingStream<HeadingEvent, Error>.Continuation?
    /// Settings made through the `set…` methods, replayed onto the manager when it is created.
    private var managerConfiguration: [@MainActor (CLLocationManager) -> Void] = []
    #endif

    /// Called when authorization status changes. Value is Int raw value of CLAuthorizationStatus.
    // SKIP DECLARE: var onAuthorizationChange: ((Int) -> Unit)? = null
    public var onAuthorizationChange: ((Int) -> Void)?

    private var _desiredAccuracy: Double = 10.0
    private var _distanceFilter: Double = -1.0

    // SKIP @nooverride
    public override init() {
        super.init()
    }

    deinit {
        #if SKIP
        stop()
        stopHeading()
        #else
        locationManager?.delegate = nil
        locationManager?.stopUpdatingLocation()
        #if os(iOS)
        locationManager?.stopUpdatingHeading()
        #endif
        #endif
    }

    // MARK: - Authorization

    /// Current authorization status as Int raw value of CLAuthorizationStatus.
    /// iOS: actual CLAuthorizationStatus.rawValue. Android: 3 (authorizedWhenInUse) if providers enabled, 0 otherwise.
    public var authorizationStatus: Int {
        #if SKIP
        let gps = locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)
        let network = locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        return (gps || network) ? 3 : 0
        #else
        if let locationManager {
            return Int(locationManager.authorizationStatus.rawValue)
        }
        return Int(CLLocationManager.authorizationStatus().rawValue)
        #endif
    }

    /// Requests when-in-use authorization. Android: no-op (handled at Activity level).
    public func requestWhenInUseAuthorization() {
        #if !SKIP
        Task { @MainActor [weak self] in
            self?.configuredLocationManager().requestWhenInUseAuthorization()
        }
        #endif
    }

    /// Requests always authorization. Android: no-op (handled at Activity level).
    public func requestAlwaysAuthorization() {
        #if !SKIP && !os(tvOS)
        Task { @MainActor [weak self] in
            self?.configuredLocationManager().requestAlwaysAuthorization()
        }
        #endif
    }

    /// Returns `true` if the location is available on this device
    public var isAvailable: Bool {
        #if SKIP
        return locationManager.isProviderEnabled(LocationManager.FUSED_PROVIDER) || locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER) || locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        #else
        return CLLocationManager.locationServicesEnabled()
        #endif
    }

    // MARK: - Configuration

    /// Sets the desired accuracy in meters. iOS: sets CLLocationManager.desiredAccuracy. Android: stored for LocationRequest quality.
    public func setDesiredAccuracy(_ accuracy: Double) {
        _desiredAccuracy = accuracy
        #if !SKIP
        configureManager { $0.desiredAccuracy = accuracy }
        #endif
    }

    /// Sets the distance filter in meters. iOS: sets CLLocationManager.distanceFilter. Android: stored for LocationRequest.
    public func setDistanceFilter(_ distance: Double) {
        _distanceFilter = distance
        #if !SKIP
        configureManager { $0.distanceFilter = distance }
        #endif
    }

    /// Enables or disables background location updates (iOS only).
    public func setAllowsBackgroundLocationUpdates(_ enabled: Bool) {
        #if os(iOS)
        configureManager { $0.allowsBackgroundLocationUpdates = enabled }
        #endif
    }

    /// Sets whether location updates pause automatically (iOS only).
    public func setPausesLocationUpdatesAutomatically(_ pauses: Bool) {
        #if os(iOS) || os(macOS)
        configureManager { $0.pausesLocationUpdatesAutomatically = pauses }
        #endif
    }

    /// Shows the background location indicator (iOS only).
    public func setShowsBackgroundLocationIndicator(_ show: Bool) {
        #if os(iOS)
        configureManager { $0.showsBackgroundLocationIndicator = show }
        #endif
    }

    /// Sets the activity type as Int raw value. iOS: maps to CLActivityType. Android: no-op.
    public func setActivityType(_ type: Int) {
        #if os(iOS) || os(macOS) || os(watchOS)
        configureManager { $0.activityType = CLActivityType(rawValue: type) ?? .fitness }
        #endif
    }

    // MARK: - Location Monitoring

    public func stop() {
        #if SKIP
        if listener != nil {
            locationManager.removeUpdates(listener!)
            listener = nil
        }
        #else
        Task { @MainActor [weak self] in
            self?.stopMonitoring()
        }
        #endif
    }

    public func monitor() -> AsyncThrowingStream<LocationEvent, Error> {
        logger.debug("starting location monitor")
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: LocationEvent.self)

        #if SKIP
        listener = LocListener(callback: { location in
            self.lastLatitude = location.latitude
            self.lastLongitude = location.longitude
            self.lastAltitude = location.altitude
            continuation.yield(with: .success(location))
        })
        let intervalMillis = Int64(1_000)
        // https://developer.android.com/reference/android/location/LocationRequest.Builder
        let builder = LocationRequest.Builder(intervalMillis)
        if _desiredAccuracy <= 10.0 {
            builder.setQuality(LocationRequest.QUALITY_HIGH_ACCURACY)
        } else if _desiredAccuracy <= 100.0 {
            builder.setQuality(LocationRequest.QUALITY_BALANCED_POWER_ACCURACY)
        } else {
            builder.setQuality(LocationRequest.QUALITY_LOW_POWER)
        }
        if _distanceFilter > 0 {
            builder.setMinUpdateDistanceMeters(Float(_distanceFilter))
        }
        let request = builder.build()
        do {
            // GPS_PROVIDER, not FUSED_PROVIDER: raw GNSS at 1 Hz carries Doppler speed and
            // bearing on every fix. The fused provider may answer with Wi-Fi or cell fixes
            // that have neither, which a fitness recorder cannot use.
            locationManager.requestLocationUpdates(LocationManager.GPS_PROVIDER, request, ProcessInfo.processInfo.androidContext.mainExecutor, listener!)
        } catch {
            logger.error("error requesting location updates: \(error) ")
            continuation.yield(with: .failure(error))
        }
        #else
        Task { @MainActor [weak self] in
            guard let self else {
                continuation.finish()
                return
            }

            let manager = self.configuredLocationManager()
            self.monitorContinuation = continuation
            manager.startUpdatingLocation()
        }
        #endif

        continuation.onTermination = { [weak self] _ in
            logger.debug("cancelling location monitor")
            self?.stop()
        }

        return stream
    }

    /// Issues a single-shot request for the current location
    public func fetchCurrentLocation() async throws -> LocationEvent {
        logger.info("fetchCurrentLocation")
        #if !SKIP
        @MainActor
        func requestCurrentLocation() async throws -> LocationEvent {
            let manager = configuredLocationManager()

            if let location = manager.location {
                logger.info("using last known location")
                return LocationEvent(location: location)
            }

            let requestID = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pendingFetchContinuations[requestID] = continuation
                    manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters

                    if !isFetchingCurrentLocation {
                        isFetchingCurrentLocation = true
                        manager.requestLocation()
                    }
                }
            } onCancel: { [weak self] in
                Task { @MainActor in
                    self?.cancelPendingFetch(id: requestID)
                }
            }
        }

        return try await requestCurrentLocation()
        #else
        let context = ProcessInfo.processInfo.androidContext
        let locationManager = context.getSystemService(Context.LOCATION_SERVICE) as android.location.LocationManager
        let providers = [
            android.location.LocationManager.FUSED_PROVIDER,
            android.location.LocationManager.GPS_PROVIDER,
            android.location.LocationManager.NETWORK_PROVIDER,
        ]

        var newestCachedLocation: android.location.Location?
        for provider in providers {
            guard let location = locationManager.getLastKnownLocation(provider) else {
                continue
            }

            if let newest = newestCachedLocation {
                if location.getElapsedRealtimeNanos() > newest.getElapsedRealtimeNanos() {
                    newestCachedLocation = location
                }
            } else {
                newestCachedLocation = location
            }
        }

        if let newestCachedLocation {
            logger.info("using newest last known location")
            return LocationEvent(location: newestCachedLocation)
        }

        let locationListener = LocListener()
        let location = suspendCancellableCoroutine { continuation in
            locationListener.callback = {
                locationManager.removeUpdates(locationListener)
                continuation.resume($0)
            }

            continuation.invokeOnCancellation { _ in
                locationManager.removeUpdates(locationListener)
                continuation.cancel()
            }

            logger.info("locationManager.requestSingleUpdate")
            locationManager.requestSingleUpdate(android.location.LocationManager.FUSED_PROVIDER, locationListener, Looper.getMainLooper())
        }
        let _ = locationListener // need to hold the reference so it doesn't get gc'd
        return location
        #endif
    }

    // MARK: - Heading Monitoring

    /// Starts continuous heading monitoring. Returns an AsyncThrowingStream of HeadingEvent.
    /// iOS: uses CLLocationManager heading (magnetometer + accelerometer, no gyroscope).
    /// Android: uses TYPE_GEOMAGNETIC_ROTATION_VECTOR (magnetometer + accelerometer, no gyroscope)
    ///          to match iOS behavior — no gyroscope drift. Low-pass filtered for stability.
    /// Other Apple platforms: heading not provided, stream finishes immediately.
    public func monitorHeading() -> AsyncThrowingStream<HeadingEvent, Error> {
        logger.debug("starting heading monitor")
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: HeadingEvent.self)

        #if SKIP
        // Use TYPE_GEOMAGNETIC_ROTATION_VECTOR: accelerometer + magnetometer only (no gyroscope).
        // Matches iOS CLLocationManager.heading — magnetometer-based, no gyro drift.
        // Falls back to TYPE_ROTATION_VECTOR on rare devices without the geomagnetic sensor.
        let hasGeomagSensor = sensorManager.getDefaultSensor(Sensor.TYPE_GEOMAGNETIC_ROTATION_VECTOR) != nil
        let sensorType = hasGeomagSensor
            ? Sensor.TYPE_GEOMAGNETIC_ROTATION_VECTOR
            : Sensor.TYPE_ROTATION_VECTOR
        logger.info("🧭 COMPASS: using \(hasGeomagSensor ? "TYPE_GEOMAGNETIC_ROTATION_VECTOR" : "TYPE_ROTATION_VECTOR (fallback)")")

        // Low-pass filter state for heading smoothing (magnetometer-only is noisier than gyro-fused)
        var filteredHeading: Double = -1.0
        let alpha: Double = 0.4  // 0.4 = responsive yet smooth; lower = smoother but laggier
        var headingSampleCount: Int = 0

        // Request ~16Hz updates (SENSOR_DELAY_UI = 60ms) instead of default SENSOR_DELAY_NORMAL (~5Hz)
        headingListener = sensorManager.startSensorUpdates(type: sensorType, interval: 0.06) { event in
            let rotationMatrix = FloatArray(9)
            SensorManager.getRotationMatrixFromVector(rotationMatrix, event.values)
            let orientation = FloatArray(3)
            SensorManager.getOrientation(rotationMatrix, orientation)

            // orientation[0] is azimuth in radians (-π to π)
            var rawHeading = Double(orientation[0]) * 180.0 / Double.pi
            if rawHeading < 0 { rawHeading += 360.0 }

            // Low-pass filter with circular wraparound handling
            if filteredHeading < 0 {
                filteredHeading = rawHeading
            } else {
                var delta = rawHeading - filteredHeading
                if delta > 180.0 { delta -= 360.0 }
                if delta < -180.0 { delta += 360.0 }
                filteredHeading += alpha * delta
                if filteredHeading < 0 { filteredHeading += 360.0 }
                if filteredHeading >= 360.0 { filteredHeading -= 360.0 }
            }

            // Calculate true heading using GeomagneticField declination
            var trueHeading = -1.0
            if self.lastLatitude != 0.0 || self.lastLongitude != 0.0 {
                let geoField = GeomagneticField(
                    Float(self.lastLatitude),
                    Float(self.lastLongitude),
                    Float(self.lastAltitude),
                    System.currentTimeMillis()
                )
                trueHeading = filteredHeading + Double(geoField.getDeclination())
                if trueHeading < 0 { trueHeading += 360.0 }
                if trueHeading >= 360.0 { trueHeading -= 360.0 }
            }

            headingSampleCount += 1
            if headingSampleCount <= 5 || headingSampleCount % 500 == 0 {
                let decl = self.lastLatitude != 0.0 || self.lastLongitude != 0.0
                    ? "\(GeomagneticField(Float(self.lastLatitude), Float(self.lastLongitude), Float(self.lastAltitude), System.currentTimeMillis()).getDeclination())°"
                    : "N/A (no GPS)"
                logger.info("🧭 COMPASS [\(headingSampleCount)]: raw=\(String(format: "%.1f", rawHeading))° filtered=\(String(format: "%.1f", filteredHeading))° true=\(String(format: "%.1f", trueHeading))° decl=\(decl) accuracy=\(event.accuracy) lat=\(self.lastLatitude)")
            }

            let headingEvent = HeadingEvent(
                trueHeading: trueHeading,
                magneticHeading: filteredHeading,
                headingAccuracy: Double(event.accuracy),
                timestamp: Double(event.timestamp) / 1_000_000_000.0
            )
            continuation.yield(with: .success(headingEvent))
        }
        #elseif os(iOS)
        Task { @MainActor [weak self] in
            guard let self else {
                continuation.finish()
                return
            }
            self.headingContinuation = continuation
            self.configuredLocationManager().startUpdatingHeading()
        }
        #else
        continuation.finish()
        #endif

        continuation.onTermination = { [weak self] _ in
            logger.debug("cancelling heading monitor")
            self?.stopHeading()
        }

        return stream
    }

    /// Stops heading monitoring.
    public func stopHeading() {
        #if SKIP
        if let listener = headingListener {
            sensorManager.unregisterListener(listener)
            headingListener = nil
        }
        #elseif os(iOS)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.locationManager?.stopUpdatingHeading()
            self.headingContinuation?.finish()
            self.headingContinuation = nil
        }
        #endif
    }

    #if !SKIP
    @MainActor
    private func configuredLocationManager() -> CLLocationManager {
        if let locationManager {
            locationManager.delegate = self
            return locationManager
        }

        let locationManager = CLLocationManager()
        locationManager.delegate = self
        self.locationManager = locationManager
        for configure in managerConfiguration {
            configure(locationManager)
        }
        return locationManager
    }

    /// Applies a setting to the live manager, and records it for a manager created later.
    private func configureManager(_ configure: @escaping @MainActor (CLLocationManager) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.managerConfiguration.append(configure)
            if let locationManager = self.locationManager {
                configure(locationManager)
            }
        }
    }

    @MainActor
    private func stopMonitoring() {
        locationManager?.stopUpdatingLocation()
        monitorContinuation = nil
    }

    @MainActor
    private func cancelPendingFetch(id: UUID) {
        guard let continuation = pendingFetchContinuations.removeValue(forKey: id) else {
            return
        }

        continuation.resume(throwing: CancellationError())
        if pendingFetchContinuations.isEmpty {
            isFetchingCurrentLocation = false
        }
    }

    @MainActor
    private func completePendingFetches(with result: Result<LocationEvent, Error>) {
        guard !pendingFetchContinuations.isEmpty else {
            isFetchingCurrentLocation = false
            return
        }

        let continuations = pendingFetchContinuations.values
        pendingFetchContinuations.removeAll()
        isFetchingCurrentLocation = false

        for continuation in continuations {
            switch result {
            case .success(let location):
                continuation.resume(returning: location)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }
    #endif
}

#if SKIP
class LocListener : LocationListener {
    var callback: (LocationEvent) -> Void = { _ in }

    init() {}

    init(callback: @escaping (LocationEvent) -> Void) {
        self.callback = callback
    }

    override func onLocationChanged(location: android.location.Location) {
        callback(LocationEvent(location: location))
    }

    override func onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}
    //override func onProviderEnabled(provider: String?) {}
    //override func onProviderDisabled(provider: String?) {}
}
#else
extension LocationProvider: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            logger.info("LocationProvider.didUpdateLocations: \(locations)")

            for location in locations {
                monitorContinuation?.yield(with: .success(LocationEvent(location: location)))
            }

            if let location = locations.last {
                completePendingFetches(with: .success(LocationEvent(location: location)))
            }
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            logger.error("LocationProvider.didFailWithError: \(error)")
            monitorContinuation?.yield(with: .failure(error))
            monitorContinuation = nil
            completePendingFetches(with: .failure(error))
        }
    }

    #if !os(watchOS)
    public func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: any Error) {
        MainActor.assumeIsolated {
            logger.error("LocationProvider.monitoringDidFailFor: \(error)")
            monitorContinuation?.yield(with: .failure(error))
            monitorContinuation = nil
            completePendingFetches(with: .failure(error))
        }
    }
    #endif

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        logger.info("LocationProvider.locationManagerDidChangeAuthorization: \(manager.authorizationStatus.rawValue)")
        onAuthorizationChange?(Int(manager.authorizationStatus.rawValue))
    }

    #if os(iOS)
    public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        MainActor.assumeIsolated {
            let event = HeadingEvent(
                trueHeading: newHeading.trueHeading,
                magneticHeading: newHeading.magneticHeading,
                headingAccuracy: newHeading.headingAccuracy,
                timestamp: newHeading.timestamp.timeIntervalSince1970
            )
            headingContinuation?.yield(event)
        }
    }
    #endif
}
#endif

public struct LocationError : LocalizedError {
    public var errorDescription: String?
}

/// A lat/lon location (in degrees).
public struct LocationEvent: Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var horizontalAccuracy: Double

    public var altitude: Double
    public var ellipsoidalAltitude: Double
    public var verticalAccuracy: Double

    public var speed: Double
    public var speedAccuracy: Double

    public var course: Double
    public var courseAccuracy: Double

    public var timestamp: TimeInterval

    #if SKIP
    /// https://developer.android.com/reference/android/location/Location
    init(location: android.location.Location) {
        self.latitude = location.getLatitude()
        self.longitude = location.getLongitude()
        // some accessors may fail with precondition exceptions like `java.lang.IllegalStateException: The Mean Sea Level altitude of this location is not set.`, so we defensively check whether the property is set and fallback to empty values
        self.horizontalAccuracy = location.hasAccuracy() ? location.getAccuracy().toDouble() : 0.0
        // https://developer.android.com/reference/android/location/Location#getMslAltitudeMeters()
        // `hasMslAltitude()`/`getMslAltitudeMeters()` were added in API 34 (Android 14); calling them on older devices throws NoSuchMethodError
        if android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.UPSIDE_DOWN_CAKE, location.hasMslAltitude() {
            self.altitude = location.getMslAltitudeMeters()
        } else {
            self.altitude = 0.0
        }
        self.ellipsoidalAltitude = location.hasAltitude() ? location.getAltitude() : 0.0
        self.verticalAccuracy = location.hasVerticalAccuracy() ? location.getVerticalAccuracyMeters().toDouble() : 0.0
        self.speed = location.hasSpeed() ? location.getSpeed().toDouble() : 0.0
        self.speedAccuracy = location.hasSpeedAccuracy() ? location.getSpeedAccuracyMetersPerSecond().toDouble() : 0.0
        self.course = location.hasBearing() ? location.getBearing().toDouble() : 0.0
        self.courseAccuracy = location.hasBearingAccuracy() ? location.getBearingAccuracyDegrees().toDouble() : 0.0
        self.timestamp = location.getTime().toDouble() / 1_000.0
    }
    #else
    /// https://developer.apple.com/documentation/corelocation/cllocation
    init(location: CLLocation) {
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.horizontalAccuracy = location.horizontalAccuracy
        self.altitude = location.altitude
        self.ellipsoidalAltitude = location.ellipsoidalAltitude
        self.verticalAccuracy = location.verticalAccuracy
        self.speed = location.speed
        self.speedAccuracy = location.speedAccuracy
        self.course = location.course
        self.courseAccuracy = location.courseAccuracy
        self.timestamp = location.timestamp.timeIntervalSince1970
    }
    #endif
}

/// A heading measurement event.
public struct HeadingEvent: Hashable, Sendable {
    /// True heading in degrees (0-360). -1 if unavailable.
    public var trueHeading: Double
    /// Magnetic heading in degrees (0-360).
    public var magneticHeading: Double
    /// Heading accuracy in degrees. Negative means invalid.
    public var headingAccuracy: Double
    /// Timestamp as seconds since epoch.
    public var timestamp: TimeInterval
}
#endif
