import Foundation

public enum ContactAuthorizationStatus: String, Codable, Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized
    case limited
    case unknown
}

public struct ContactRecord: Codable, Equatable, Sendable {
    public let externalID: String
    public let displayName: String
    public let namePrefix: String?
    public let givenName: String?
    public let middleName: String?
    public let familyName: String?
    public let nameSuffix: String?
    public let nickname: String?
    public let organizationName: String?
    public let departmentName: String?
    public let jobTitle: String?
    public let phoneNumbers: [String]
    public let emailAddresses: [String]

    public init(
        externalID: String,
        displayName: String,
        namePrefix: String? = nil,
        givenName: String? = nil,
        middleName: String? = nil,
        familyName: String? = nil,
        nameSuffix: String? = nil,
        nickname: String? = nil,
        organizationName: String? = nil,
        departmentName: String? = nil,
        jobTitle: String? = nil,
        phoneNumbers: [String] = [],
        emailAddresses: [String] = []
    ) {
        self.externalID = externalID
        self.displayName = displayName
        self.namePrefix = namePrefix
        self.givenName = givenName
        self.middleName = middleName
        self.familyName = familyName
        self.nameSuffix = nameSuffix
        self.nickname = nickname
        self.organizationName = organizationName
        self.departmentName = departmentName
        self.jobTitle = jobTitle
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
    }
}

public protocol ContactSource: Sendable {
    func authorizationStatus() async -> ContactAuthorizationStatus
    func requestAccess() async throws -> Bool
    func contacts() async throws -> [ContactRecord]
}
