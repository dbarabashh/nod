import Foundation

/// What a member may do inside an organization.
///
/// Mirrors the `role` check on `org_members`. Administering and reading content
/// are deliberately different questions — an administrator manages people and
/// settings, and can read what members recorded only where the organization has
/// switched that on (`org_policies.admin_content_access`).
enum OrgRole: String, Codable, Equatable, CaseIterable, Identifiable {
    case owner
    case admin
    case member

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .owner: "Owner"
        case .admin: "Admin"
        case .member: "Member"
        }
    }

    var administers: Bool {
        self == .owner || self == .admin
    }
}

struct Organization: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let slug: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case slug
    }
}

/// One organization the signed-in person belongs to, with their own role in it.
struct OrgMembership: Identifiable, Equatable {
    let organization: Organization
    let role: OrgRole

    var id: UUID {
        organization.id
    }
}

struct Team: Codable, Identifiable, Equatable {
    let id: UUID
    let orgID: UUID
    let name: String

    enum CodingKeys: String, CodingKey {
        case id
        case orgID = "org_id"
        case name
    }
}

/// The row shape `org_members` returns with its organization embedded. Kept
/// apart from `OrgMembership` because the wire nests what the app wants flat,
/// and a role that fails to parse should drop the row rather than the response.
struct OrgMembershipRow: Decodable {
    let role: String
    let organizations: Organization?

    var membership: OrgMembership? {
        guard let organizations, let role = OrgRole(rawValue: role) else { return nil }
        return OrgMembership(organization: organizations, role: role)
    }
}

extension Organization {
    /// A slug the `organizations` check constraint will accept: lowercase, digits
    /// and single hyphens, 3–40 characters, never starting or ending with one.
    ///
    /// Derived here rather than asked for, because it is a database detail the
    /// person naming their company should not have to think about. Uniqueness is
    /// still the server's to enforce — this only guarantees the shape.
    static func slug(from name: String, suffix: String = "") -> String {
        let ascii = name.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : "-"
        }
        var slug = String(ascii)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")

        if !suffix.isEmpty {
            slug = slug.isEmpty ? suffix : "\(slug)-\(suffix)"
        }
        slug = String(slug.prefix(40))
        while let last = slug.last, last == "-" {
            slug.removeLast()
        }
        return slug.count >= 3 ? slug : "org-\(UUID().uuidString.prefix(8).lowercased())"
    }
}

/// A person in an organization, with the address only an administrator sees.
/// Returned by `list_org_members`, which is why this decodes flat rather than
/// through an embedded join.
struct OrgMember: Decodable, Identifiable, Equatable {
    let userID: UUID
    let email: String
    let displayName: String?
    let role: OrgRole
    let status: String
    let joinedAt: Date?

    var id: UUID {
        userID
    }

    var isActive: Bool {
        status == "active"
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case email
        case displayName = "display_name"
        case role
        case status
        case joinedAt = "joined_at"
    }
}

/// An invite that has been sent and not yet used.
///
/// Carries its token so an administrator can hand the link over themselves when
/// the email did not arrive — a bounce or a spam folder otherwise strands an
/// invite that is perfectly valid, with no way to reach it.
///
/// The token is not a bearer credential. `accept_org_invite` also requires the
/// signed-in address to be the invited one, so a token in the hands of anybody
/// else opens nothing; the administrator holding it is the person who issued it.
struct OrgInvite: Decodable, Identifiable, Equatable {
    let id: UUID
    let email: String
    let role: OrgRole
    let token: UUID
    let expiresAt: Date?

    var url: String {
        "https://hellonod.app/invite/\(token.uuidString.lowercased())"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case role
        case token
        case expiresAt = "expires_at"
    }
}

enum TeamRole: String, Codable, Equatable, CaseIterable, Identifiable {
    case lead
    case member

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .lead: "Lead"
        case .member: "Member"
        }
    }
}

/// Somebody in a team, with the address only an administrator sees. Separate
/// from `OrgMember` because team membership carries its own role and says
/// nothing about standing in the organization — a team lead is not an
/// administrator, and an administrator need not be in the team at all.
struct TeamMember: Decodable, Identifiable, Equatable {
    let userID: UUID
    let email: String
    let displayName: String?
    let role: TeamRole

    var id: UUID {
        userID
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case email
        case displayName = "display_name"
        case role
    }
}
