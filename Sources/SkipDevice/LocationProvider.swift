// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
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
public class LocationProvider: NSObject {
    #if SKIP
    private let locationManager = ProcessInfo.processInfo.androidContext.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    private var listener: LocListener?
    private let sensorManager = ProcessInfo.processInfo.androidContext.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private var headingListener: SensorEventHandler? = nil
    private var lastLatitude: Double = 0.0
    private var lastLongitude: Double = 0.0
    private var lastAltitude: Double = 0.0
    #else
    private let locationManager = CLLocationManager()
    private var callback: ((Result<LocationEvent, Error>) -> Void)?
    private var headingContinuation: AsyncThrowingStream<HeadingEvent, Error>.Continuation?
    #endif

    /// Called when authorization status changes. Value is Int raw value of CLAuthorizationStatus.
    // SKIP DECLARE: var onAuthorizationChange: ((Int) -> Unit)? = null
    public var onAuthorizationChange: ((Int) -> Void)?

    private var _desiredAccuracy: Double = 10.0
    private var _distanceFilter: Double = -1.0

    // SKIP @nooverride
    public override init() {
        super.init()
        #if !SKIP
        locationManager.delegate = self
        #endif
    }

    deinit {
        stop()
        stopHeading()
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
        return Int(locationManager.authorizationStatus.rawValue)
        #endif
    }

    /// Requests when-in-use authorization. Android: no-op (handled at Activity level).
    public func requestWhenInUseAuthorization() {
        #if !SKIP
        locationManager.requestWhenInUseAuthorization()
        #endif
    }

    /// Requests always authorization. Android: no-op (handled at Activity level).
    public func requestAlwaysAuthorization() {
        #if !SKIP
        locationManager.requestAlwaysAuthorization()
        #endif
    }

    // MARK: - Availability

    /// Returns `true` if the location is available on this device
    public var isAvailable: Bool {
        #if SKIP
        return locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER) || locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        #else
        return CLLocationManager.locationServicesEnabled()
        #endif
    }

    // MARK: - Configuration

    /// Sets the desired accuracy in meters. iOS: sets CLLocationManager.desiredAccuracy. Android: stored for LocationRequest quality.
    public func setDesiredAccuracy(_ accuracy: Double) {
        _desiredAccuracy = accuracy
        #if !SKIP
        locationManager.desiredAccuracy = accuracy
        #endif
    }

    /// Sets the distance filter in meters. iOS: sets CLLocationManager.distanceFilter. Android: stored for LocationRequest.
    public func setDistanceFilter(_ distance: Double) {
        _distanceFilter = distance
        #if !SKIP
        locationManager.distanceFilter = distance
        #endif
    }

    /// Enables or disables background location updates (iOS only).
    public func setAllowsBackgroundLocationUpdates(_ enabled: Bool) {
        #if !SKIP && !os(macOS)
        locationManager.allowsBackgroundLocationUpdates = enabled
        #endif
    }

    /// Sets whether location updates pause automatically (iOS only).
    public func setPausesLocationUpdatesAutomatically(_ pauses: Bool) {
        #if !SKIP
        locationManager.pausesLocationUpdatesAutomatically = pauses
        #endif
    }

    /// Shows the background location indicator (iOS only).
    public func setShowsBackgroundLocationIndicator(_ show: Bool) {
        #if !SKIP && !os(macOS)
        locationManager.showsBackgroundLocationIndicator = show
        #endif
    }

    /// Sets the activity type as Int raw value. iOS: maps to CLActivityType. Android: no-op.
    public func setActivityType(_ type: Int) {
        #if !SKIP
        locationManager.activityType = CLActivityType(rawValue: type) ?? .fitness
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
        locationManager.stopUpdatingLocation()
        #endif
    }

    public func monitor() -> AsyncThrowingStream<LocationEvent, Error> {
        logger.debug("starting location monitor")
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: LocationEvent.self)

        #if SKIP
        listener = LocListener(callback: { location in
            logger.info("location update: \(location.latitude) \(location.longitude)")
            self.lastLatitude = location.latitude
            self.lastLongitude = location.longitude
            self.lastAltitude = location.altitude
            continuation.yield(with: .success(location))
        })
        let intervalMillis = Int64(1_000)
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
            locationManager.requestLocationUpdates(LocationManager.GPS_PROVIDER, request, ProcessInfo.processInfo.androidContext.mainExecutor, listener!)
        } catch {
            logger.error("error requesting location updates: \(error) ")
            continuation.yield(with: .failure(error))
        }
        #else
        self.callback = { result in
            switch result {
            case .success(let location):
                logger.info("location update: \(location.latitude) \(location.longitude)")
                continuation.yield(with: .success(location))
            case .failure(let error):
                continuation.yield(with: .failure(error))
                self.callback = nil
            }
        }
        locationManager.startUpdatingLocation()
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
        return try await withCheckedThrowingContinuation { continuation in
            self.callback = { result in
                switch result {
                case .success(let location):
                    continuation.resume(returning: location)
                    self.locationManager.stopUpdatingLocation()
                    self.callback = nil
                case .failure(let error):
                    continuation.resume(throwing: error)
                    self.locationManager.stopUpdatingLocation()
                    self.callback = nil
                }
            }
            locationManager.startUpdatingLocation()
        }
        #else
        let context = ProcessInfo.processInfo.androidContext
        let locationManager = context.getSystemService(Context.LOCATION_SERVICE) as android.location.LocationManager
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
            locationManager.requestSingleUpdate(android.location.LocationManager.GPS_PROVIDER, locationListener, Looper.getMainLooper())
        }
        let _ = locationListener // need to hold the reference so it doesn't get gc'd
        return location
        #endif
    }

    // MARK: - Heading Monitoring

    /// Starts continuous heading monitoring. Returns an AsyncThrowingStream of HeadingEvent.
    /// iOS: uses CLLocationManager heading. Android: uses rotation vector sensor + GeomagneticField.
    /// macOS: heading not available, stream finishes immediately.
    public func monitorHeading() -> AsyncThrowingStream<HeadingEvent, Error> {
        logger.debug("starting heading monitor")
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: HeadingEvent.self)

        #if SKIP
        headingListener = sensorManager.startSensorUpdates(type: Sensor.TYPE_ROTATION_VECTOR, interval: nil) { event in
            let rotationMatrix = FloatArray(9)
            SensorManager.getRotationMatrixFromVector(rotationMatrix, event.values)
            let orientation = FloatArray(3)
            SensorManager.getOrientation(rotationMatrix, orientation)

            // orientation[0] is azimuth in radians (-π to π)
            var magneticHeading = Double(orientation[0]) * 180.0 / Double.pi
            if magneticHeading < 0 { magneticHeading += 360.0 }

            // Calculate true heading using GeomagneticField declination
            var trueHeading = -1.0
            if self.lastLatitude != 0.0 || self.lastLongitude != 0.0 {
                let geoField = GeomagneticField(
                    Float(self.lastLatitude),
                    Float(self.lastLongitude),
                    Float(self.lastAltitude),
                    System.currentTimeMillis()
                )
                trueHeading = magneticHeading + Double(geoField.getDeclination())
                if trueHeading < 0 { trueHeading += 360.0 }
                if trueHeading >= 360.0 { trueHeading -= 360.0 }
            }

            let headingEvent = HeadingEvent(
                trueHeading: trueHeading,
                magneticHeading: magneticHeading,
                headingAccuracy: Double(event.accuracy),
                timestamp: Double(event.timestamp) / 1_000_000_000.0
            )
            continuation.yield(with: .success(headingEvent))
        }
        #elseif !os(macOS)
        self.headingContinuation = continuation
        locationManager.startUpdatingHeading()
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
        #elseif !os(macOS)
        locationManager.stopUpdatingHeading()
        headingContinuation?.finish()
        headingContinuation = nil
        #endif
    }
}

#if SKIP
struct LocListener : LocationListener {
    var callback: (LocationEvent) -> Void = { _ in }

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
        logger.info("LocationProvider.didUpdateLocations: \(locations)")
        for location in locations {
            callback?(.success(LocationEvent(location: location)))
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logger.error("LocationProvider.didFailWithError: \(error)")
        callback?(.failure(error))
    }

    public func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: any Error) {
        logger.error("LocationProvider.monitoringDidFailFor: \(error)")
        callback?(.failure(error))
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        logger.info("LocationProvider.locationManagerDidChangeAuthorization: \(manager.authorizationStatus.rawValue)")
        onAuthorizationChange?(Int(manager.authorizationStatus.rawValue))
    }

    #if !os(macOS)
    public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let event = HeadingEvent(
            trueHeading: newHeading.trueHeading,
            magneticHeading: newHeading.magneticHeading,
            headingAccuracy: newHeading.headingAccuracy,
            timestamp: newHeading.timestamp.timeIntervalSince1970
        )
        headingContinuation?.yield(event)
    }
    #endif
}
#endif

public struct LocationError : LocalizedError {
    public var errorDescription: String?
}

/// A lat/lon location (in degrees).
public struct LocationEvent {
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
        self.altitude = location.hasMslAltitude() ? location.getMslAltitudeMeters() : 0.0
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
public struct HeadingEvent {
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
