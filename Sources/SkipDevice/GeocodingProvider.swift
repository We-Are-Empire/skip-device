// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import Foundation
#if canImport(OSLog)
import OSLog
#endif
#if canImport(CoreLocation)
import CoreLocation
#elseif SKIP
import android.content.Context
import android.location.Geocoder
import android.location.Address
import java.util.Locale
#endif

private let logger: Logger = Logger(subsystem: "skip.device", category: "GeocodingProvider")

/// A cross-platform reverse geocoding provider.
///
/// iOS: Uses CLGeocoder
/// Android: Uses android.location.Geocoder
public class GeocodingProvider {

    #if SKIP
    private let geocoder = Geocoder(ProcessInfo.processInfo.androidContext, Locale.getDefault())
    #else
    private let geocoder = CLGeocoder()
    #endif

    public init() {}

    /// Whether geocoding is available on this device.
    public var isAvailable: Bool {
        #if SKIP
        return Geocoder.isPresent()
        #else
        return true // CLGeocoder is always available on iOS
        #endif
    }

    /// Performs reverse geocoding for the given coordinates.
    ///
    /// - Parameters:
    ///   - latitude: Latitude in degrees.
    ///   - longitude: Longitude in degrees.
    /// - Returns: A GeocodingResult with place information, or nil if no result found.
    public func reverseGeocode(latitude: Double, longitude: Double) async throws -> GeocodingResult? {
        logger.debug("reverseGeocode: \(latitude), \(longitude)")

        #if SKIP
        // Android: Geocoder.getFromLocation is synchronous, run off main thread
        let addresses = geocoder.getFromLocation(latitude, longitude, 1)
        guard let address = addresses?.firstOrNull() else {
            return nil
        }
        return GeocodingResult(
            name: address.featureName,
            locality: address.locality,
            administrativeArea: address.adminArea,
            postalCode: address.postalCode,
            country: address.countryName,
            isoCountryCode: address.countryCode
        )
        #else
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let placemarks = try await geocoder.reverseGeocodeLocation(location)

        guard let placemark = placemarks.first else {
            return nil
        }

        return GeocodingResult(
            name: placemark.name,
            locality: placemark.locality,
            administrativeArea: placemark.administrativeArea,
            postalCode: placemark.postalCode,
            country: placemark.country,
            isoCountryCode: placemark.isoCountryCode
        )
        #endif
    }

    /// Cancels any ongoing geocoding request.
    public func cancel() {
        #if !SKIP
        geocoder.cancelGeocode()
        #endif
    }
}

/// Result of a reverse geocoding operation.
public struct GeocodingResult {
    /// Feature name or address.
    public var name: String?
    /// City or locality.
    public var locality: String?
    /// State, province, or administrative area.
    public var administrativeArea: String?
    /// Postal/ZIP code.
    public var postalCode: String?
    /// Country name.
    public var country: String?
    /// ISO 3166-1 alpha-2 country code.
    public var isoCountryCode: String?
}

#endif
