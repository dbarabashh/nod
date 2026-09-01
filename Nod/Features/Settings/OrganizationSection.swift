import AppKit
import SwiftUI

/// The organization pane: who you are administering, and three pages of it.
///
/// One scroll used to carry the context switcher, the roster, the teams and the
/// two ways out. That reads as a pile rather than a place — an administrator
/// looking for one person scrolls past team rosters to find them. The switcher
/// moved to the window's sidebar, where switching actually belongs, and what is
/// left splits along the three questions people arrive with: what is this
/// organization, who is in it, how is it divided.
struct OrganizationSection: View {
    @ObservedObject var service: OrganizationService
    /// Absent in previews and for a signed-out account. Only the tools table
    /// needs it, and that table is an administrator's surface anyway.
    var integrations: IntegrationService?

    @State private var page = Page.overview
    @State private var newName = ""
    /// The upload in flight, so the tile can say so and refuse a second pick.
    @State private var uploadingLogo = false

    enum Page: String, CaseIterable, Identifiable {
        case overview = "Organization"
        case people = "People"
        case teams = "Teams"
        var id: String {
            rawValue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let membership = service.activeMembership {
                identityStrip(membership)
                SegmentedControl(selection: $page, options: Page.allCases, title: \.rawValue)
                    .frame(maxWidth: 300)
                pageContent(membership)
            } else if service.memberships.isEmpty {
                createCard
            } else {
                // Belongs to something, working personally. Nothing here is
                // wrong — it just needs a context before it has a subject.
                switchHint
            }
            if let error = service.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.danger)
            }
        }
        .task {
            // `refresh` every time: opening this pane is the one
            // moment somebody is asking who is in the organization, and the
            // answer may have changed on a colleague's Mac since it was cached.
            await service.refresh()
            // Not only for the People page: the Overview reads the owners and
            // whether leaving would strand the organization out of the same
            // roster.
            if let active = service.activeMembership {
                await service.loadRoster(in: active.id, canAdminister: active.role.administers)
            }
        }
    }

    @ViewBuilder
    private func pageContent(_ membership: OrgMembership) -> some View {
        switch page {
        case .overview:
            OrganizationOverview(service: service, integrations: integrations, membership: membership)
        case .people:
            OrganizationPeople(service: service, membership: membership)
        case .teams:
            OrganizationTeams(service: service, membership: membership)
        }
    }

    private func identityStrip(_ membership: OrgMembership) -> some View {
        HStack(spacing: 11) {
            logoWell(membership)
            VStack(alignment: .leading, spacing: 1) {
                Text(membership.organization.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text("You're \(membership.role == .admin ? "an" : "a") \(membership.role.displayName.lowercased())")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
            }
            Spacer(minLength: 0)
        }
    }

    /// The mark, and — for the two roles that run the organization — the way to
    /// change it. A member sees the same tile with nothing to click: the company
    /// face is not theirs to set, and an affordance that fails on the server is
    /// worse than one that was never offered.
    @ViewBuilder
    private func logoWell(_ membership: OrgMembership) -> some View {
        let mark = OrgMonogram(
            name: membership.organization.name,
            size: 32,
            logo: service.logoURL(for: membership.organization)
        )
        if membership.role.administers {
            Button { chooseLogo(for: membership.organization) } label: {
                mark
                    .overlay(alignment: .bottomTrailing) {
                        Group {
                            if uploadingLogo {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image("nc-pen-writing")
                                    .icon(8)
                                    .foregroundStyle(Theme.Palette.ink)
                            }
                        }
                        .padding(3)
                        .background(Circle().fill(Theme.Palette.surfaceStrong))
                        .overlay(Circle().stroke(Theme.Palette.border, lineWidth: 0.5))
                        .offset(x: 3, y: 3)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .linkCursor()
            .disabled(uploadingLogo)
            .help(membership.organization.logoPath == nil ? "Add a logo" : "Change the logo")
            .contextMenu {
                if membership.organization.logoPath != nil {
                    Button(role: .destructive) {
                        Task { await service.removeLogo(for: membership.organization.id) }
                    } label: {
                        IconLabel(title: "Remove logo", icon: "nc-trash")
                    }
                }
            }
        } else {
            mark
        }
    }

    /// A standard open panel, restricted to what the bucket accepts. The image
    /// is squared and shrunk before it leaves the Mac — see
    /// `OrganizationService.setLogo`.
    private func chooseLogo(for organization: Organization) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use as logo"
        panel.message = "Pick a square image for \(organization.name)."
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        uploadingLogo = true
        Task {
            _ = await service.setLogo(image, for: organization.id)
            uploadingLogo = false
        }
    }

    private var switchHint: some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-users",
                title: "You're working personally",
                subtitle: "Switch to an organization in the sidebar to administer it."
            ) {
                EmptyView()
            }
        }
    }

    private var createCard: some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-users",
                title: "Create an organization",
                subtitle: "Shared billing and a shared place for your team's sessions."
            ) {
                EmptyView()
            }
            SettingsRowDivider()
            HStack(spacing: 10) {
                TextField("Organization name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5))
                Button {
                    createOrganization()
                } label: {
                    Text("Create")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.GlassButton.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .glassButtonSurface(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || service.isLoading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func createOrganization() {
        Task {
            if await service.createOrganization(named: newName) { newName = "" }
        }
    }
}

#if DEBUG
    private let previewOrg = Organization(id: UUID(), name: "Acme", slug: "acme")

    #Preview("Personal only") {
        OrganizationSection(service: .preview(memberships: []))
            .padding()
            .frame(width: 560)
            .background(WindowBackdrop())
    }

    #Preview("In an organization") {
        OrganizationSection(service: .preview(
            memberships: [OrgMembership(organization: previewOrg, role: .admin)],
            activeOrgID: previewOrg.id,
            teams: [Team(id: UUID(), orgID: previewOrg.id, name: "Platform")]
        ))
        .padding()
        .frame(width: 560)
        .background(WindowBackdrop())
    }
#endif
