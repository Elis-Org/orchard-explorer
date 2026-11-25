public struct SidebarBackgroundCheckOptions: Equatable, Sendable {
    public let protectedLocal: Bool
    public let cloud: Bool
    public let network: Bool

    public init(protectedLocal: Bool = false, cloud: Bool = false, network: Bool = false) {
        self.protectedLocal = protectedLocal
        self.cloud = cloud
        self.network = network
    }
}
