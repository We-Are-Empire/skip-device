// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import Foundation
#if canImport(OSLog)
import OSLog
#endif
#if !SKIP
import CoreMotion
#else
import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorManager
import android.hardware.SensorEvent
#endif

private let logger: Logger = Logger(subsystem: "skip.device", category: "DeviceMotionProvider")

/// A provider for sensor-fused device motion events.
///
/// Provides gravity-free user acceleration, gravity vector, and rotation rate
/// in a single event — matching CMDeviceMotion on iOS.
///
/// - iOS: Uses `CMDeviceMotion` (hardware sensor fusion via CoreMotion).
/// - Android: Combines `TYPE_LINEAR_ACCELERATION` + `TYPE_GRAVITY` + `TYPE_GYROSCOPE`.
public class DeviceMotionProvider {
    #if SKIP
    private let sensorManager = ProcessInfo.processInfo.androidContext.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private var linearAccelListener: SensorEventHandler? = nil
    private var gravityListener: SensorEventHandler? = nil
    private var gyroListener: SensorEventHandler? = nil
    // Cache latest gravity and gyro values to pair with linear acceleration events
    private var latestGravityX: Double = 0.0
    private var latestGravityY: Double = 0.0
    private var latestGravityZ: Double = -1.0
    private var latestGyroX: Double = 0.0
    private var latestGyroY: Double = 0.0
    private var latestGyroZ: Double = 0.0
    #elseif os(iOS) || os(watchOS)
    private let motionManager = CMMotionManager()
    #endif

    /// Set the update interval in seconds. Must be set before `monitor()` is invoked.
    public var updateInterval: TimeInterval? {
        didSet {
            #if os(iOS) || os(watchOS)
            if let interval = updateInterval {
                motionManager.deviceMotionUpdateInterval = interval
            }
            #endif
        }
    }

    public init() {
    }

    deinit {
        stop()
    }

    /// Returns `true` if device motion is available on this device.
    public var isAvailable: Bool {
        #if SKIP
        return sensorManager.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION) != nil
        #elseif os(iOS) || os(watchOS)
        return motionManager.isDeviceMotionAvailable
        #else
        return false
        #endif
    }

    public func stop() {
        #if SKIP
        if linearAccelListener != nil {
            sensorManager.unregisterListener(linearAccelListener)
            linearAccelListener = nil
        }
        if gravityListener != nil {
            sensorManager.unregisterListener(gravityListener)
            gravityListener = nil
        }
        if gyroListener != nil {
            sensorManager.unregisterListener(gyroListener)
            gyroListener = nil
        }
        #elseif os(iOS) || os(watchOS)
        motionManager.stopDeviceMotionUpdates()
        #endif
    }

    public func monitor() -> AsyncThrowingStream<DeviceMotionEvent, Error> {
        logger.debug("starting device motion monitor")
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: DeviceMotionEvent.self)

        #if SKIP
        // Android: TYPE_LINEAR_ACCELERATION is the primary clock.
        // TYPE_GRAVITY and TYPE_GYROSCOPE update cached values paired with each linear accel event.

        // Start gravity sensor — cache latest values
        gravityListener = sensorManager.startSensorUpdates(type: Sensor.TYPE_GRAVITY, interval: updateInterval) { event in
            self.latestGravityX = (-event.values[0] / SensorManager.GRAVITY_EARTH).toDouble()
            self.latestGravityY = (-event.values[1] / SensorManager.GRAVITY_EARTH).toDouble()
            self.latestGravityZ = (-event.values[2] / SensorManager.GRAVITY_EARTH).toDouble()
        }

        // Start gyroscope — cache latest values
        gyroListener = sensorManager.startSensorUpdates(type: Sensor.TYPE_GYROSCOPE, interval: updateInterval) { event in
            self.latestGyroX = event.values[0].toDouble()
            self.latestGyroY = event.values[1].toDouble()
            self.latestGyroZ = event.values[2].toDouble()
        }

        // Start linear acceleration — primary clock, yields combined events
        linearAccelListener = sensorManager.startSensorUpdates(type: Sensor.TYPE_LINEAR_ACCELERATION, interval: updateInterval) { event in
            let userAccelX = (-event.values[0] / SensorManager.GRAVITY_EARTH).toDouble()
            let userAccelY = (-event.values[1] / SensorManager.GRAVITY_EARTH).toDouble()
            let userAccelZ = (-event.values[2] / SensorManager.GRAVITY_EARTH).toDouble()
            let timestamp = event.timestamp / 1_000_000_000.0

            continuation.yield(DeviceMotionEvent(
                userAccelerationX: userAccelX,
                userAccelerationY: userAccelY,
                userAccelerationZ: userAccelZ,
                gravityX: self.latestGravityX,
                gravityY: self.latestGravityY,
                gravityZ: self.latestGravityZ,
                rotationRateX: self.latestGyroX,
                rotationRateY: self.latestGyroY,
                rotationRateZ: self.latestGyroZ,
                timestamp: timestamp
            ))
        }
        #elseif os(iOS) || os(watchOS)
        motionManager.startDeviceMotionUpdates(to: OperationQueue.main) { data, error in
            if let error = error {
                logger.debug("device motion update error: \(error)")
                continuation.yield(with: .failure(error))
            } else if let data = data {
                continuation.yield(with: .success(DeviceMotionEvent(motion: data)))
            }
        }
        #endif

        continuation.onTermination = { [weak self] _ in
            logger.debug("cancelling device motion monitor")
            self?.stop()
        }

        return stream
    }
}

/// A sensor-fused motion sample providing gravity-free acceleration, gravity vector, and rotation rate.
///
/// Encapsulates:
/// - Darwin: [CMDeviceMotion](https://developer.apple.com/documentation/coremotion/cmdevicemotion)
/// - Android: `TYPE_LINEAR_ACCELERATION` + `TYPE_GRAVITY` + `TYPE_GYROSCOPE`
public struct DeviceMotionEvent {
    /// Gravity-free user acceleration along the x-axis, in G's.
    public var userAccelerationX: Double
    /// Gravity-free user acceleration along the y-axis, in G's.
    public var userAccelerationY: Double
    /// Gravity-free user acceleration along the z-axis, in G's.
    public var userAccelerationZ: Double
    /// Gravity vector x-component, in G's.
    public var gravityX: Double
    /// Gravity vector y-component, in G's.
    public var gravityY: Double
    /// Gravity vector z-component, in G's.
    public var gravityZ: Double
    /// Angular velocity around the x-axis, in radians/second.
    public var rotationRateX: Double
    /// Angular velocity around the y-axis, in radians/second.
    public var rotationRateY: Double
    /// Angular velocity around the z-axis, in radians/second.
    public var rotationRateZ: Double
    /// The time when the logged item is valid.
    public var timestamp: TimeInterval

    #if os(iOS) || os(watchOS)
    init(motion: CMDeviceMotion) {
        self.userAccelerationX = motion.userAcceleration.x
        self.userAccelerationY = motion.userAcceleration.y
        self.userAccelerationZ = motion.userAcceleration.z
        self.gravityX = motion.gravity.x
        self.gravityY = motion.gravity.y
        self.gravityZ = motion.gravity.z
        self.rotationRateX = motion.rotationRate.x
        self.rotationRateY = motion.rotationRate.y
        self.rotationRateZ = motion.rotationRate.z
        self.timestamp = motion.timestamp
    }
    #endif

    public init(
        userAccelerationX: Double, userAccelerationY: Double, userAccelerationZ: Double,
        gravityX: Double, gravityY: Double, gravityZ: Double,
        rotationRateX: Double, rotationRateY: Double, rotationRateZ: Double,
        timestamp: TimeInterval
    ) {
        self.userAccelerationX = userAccelerationX
        self.userAccelerationY = userAccelerationY
        self.userAccelerationZ = userAccelerationZ
        self.gravityX = gravityX
        self.gravityY = gravityY
        self.gravityZ = gravityZ
        self.rotationRateX = rotationRateX
        self.rotationRateY = rotationRateY
        self.rotationRateZ = rotationRateZ
        self.timestamp = timestamp
    }
}

#endif
