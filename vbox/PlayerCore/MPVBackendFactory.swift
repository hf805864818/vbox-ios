import Foundation

enum MPVBackendFactory {
    static func makeBackend(_ type: MPVBackendType) -> MPVBackend {
        switch type {
        case .automatic:
            if MPVKitBackend.isAvailable {
                return MPVKitBackend()
            }
            if LibMPVBackend.isAvailable {
                return LibMPVBackend()
            }
            return MPVUnavailableBackend(backendType: .automatic, name: "MPV")
        case .mpvKit:
            if MPVKitBackend.isAvailable {
                return MPVKitBackend()
            }
            return MPVUnavailableBackend(backendType: .mpvKit, name: "MPV")
        case .libmpv:
            if LibMPVBackend.isAvailable {
                return LibMPVBackend()
            }
            return MPVUnavailableBackend(backendType: .libmpv, name: "自由度")
        }
    }
}
