import Foundation
import CoreLocation

enum GeocoderService {
    static func coordinates(for address: String) async throws -> CLLocationCoordinate2D? {
        let clean = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        
        let geocoder = CLGeocoder()
        let placemarks = try await geocoder.geocodeAddressString(clean)
        
        guard let location = placemarks.first?.location else {
            return nil
        }
        
        return location.coordinate
    }
}

