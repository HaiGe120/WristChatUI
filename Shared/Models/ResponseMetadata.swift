import Foundation

public enum AttemptPhase: String, Codable, Sendable {
    case idle, connecting, receiving, searching, completed, failed, cancelled, partial

    public var isActive: Bool { self == .connecting || self == .receiving || self == .searching }
}

public enum SearchOutcome: String, Codable, Sendable {
    case off, notUsed, searching, succeeded, referencesOnly, failed, unavailable
}

/// Optional message metadata. Credentials and raw retrieved documents never belong here.
public struct ResponseMetadata: Codable, Hashable, Sendable {
    public var attemptID: UUID
    public var userMessageID: UUID
    public var phase: AttemptPhase
    public var searchOutcome: SearchOutcome
    public var searchSource: String?
    public var citations: [SourceCitation]
    public var errorCode: String?
    public var errorMessage: String?
    public var updatedAt: Date

    public init(attemptID: UUID, userMessageID: UUID, phase: AttemptPhase = .connecting,
                searchOutcome: SearchOutcome = .off, searchSource: String? = nil,
                citations: [SourceCitation] = [], errorCode: String? = nil,
                errorMessage: String? = nil, updatedAt: Date = .now) {
        self.attemptID = attemptID
        self.userMessageID = userMessageID
        self.phase = phase
        self.searchOutcome = searchOutcome
        self.searchSource = searchSource
        self.citations = citations
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case attemptID, userMessageID, phase, searchOutcome, searchSource, citations, errorCode, errorMessage, updatedAt, updatedAtEpochSeconds
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attemptID = try c.decode(UUID.self, forKey: .attemptID)
        userMessageID = try c.decode(UUID.self, forKey: .userMessageID)
        phase = try c.decode(AttemptPhase.self, forKey: .phase)
        searchOutcome = try c.decodeIfPresent(SearchOutcome.self, forKey: .searchOutcome) ?? .off
        searchSource = try c.decodeIfPresent(String.self, forKey: .searchSource)
        citations = try c.decodeIfPresent([SourceCitation].self, forKey: .citations) ?? []
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        if let epoch = try c.decodeIfPresent(Double.self, forKey: .updatedAtEpochSeconds) {
            updatedAt = Date(timeIntervalSince1970: epoch)
        } else { updatedAt = try c.decode(Date.self, forKey: .updatedAt) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(attemptID, forKey: .attemptID)
        try c.encode(userMessageID, forKey: .userMessageID)
        try c.encode(phase, forKey: .phase)
        try c.encode(searchOutcome, forKey: .searchOutcome)
        try c.encodeIfPresent(searchSource, forKey: .searchSource)
        try c.encode(citations, forKey: .citations)
        try c.encodeIfPresent(errorCode, forKey: .errorCode)
        try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try c.encode(updatedAt, forKey: .updatedAt)
        // Preserve subsecond ordering even through the companion's ISO8601 encoder.
        try c.encode(updatedAt.timeIntervalSince1970, forKey: .updatedAtEpochSeconds)
    }

    public var statusText: String? {
        switch phase {
        case .idle: return nil
        case .connecting: return "Connecting…"
        case .receiving: return "Receiving…"
        case .searching: return "Searching…"
        case .completed:
            switch searchOutcome {
            case .succeeded: return "Web search used"
            case .referencesOnly: return "Reference material retrieved"
            case .notUsed: return "Web search not used"
            case .failed, .unavailable: return "Live search unavailable"
            default: return nil
            }
        case .cancelled: return "Stopped"
        case .failed, .partial: return errorMessage ?? (phase == .partial ? "Partial reply" : "Request failed")
        }
    }
}
