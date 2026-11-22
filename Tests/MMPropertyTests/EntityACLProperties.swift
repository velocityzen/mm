// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting
    import MMSchema
    import Testing

    /// How a peer is drawn against an ACL. The model, not the relation,
    /// decides the class: a drawn id can match by chance.
    enum PeerRelation: String, CaseIterable, Sendable {
        case owner = "the owner"
        case ownerInTheGroup = "the owner, in the group too"
        case primaryGroup = "the group, by primary gid"
        case supplementaryGroup = "the group, by a supplementary group"
        case other = "someone else"
    }

    /// The mode as `ls` shows it, `rwxr-x---`, read from the low nine bits.
    func symbolicMode(_ mode: UInt16) -> [Character] {
        let letters: [Character] = ["r", "w", "x"]
        return (0..<9).map { position in
            mode & (1 << (8 - position)) != 0 ? letters[position % 3] : "-"
        }
    }

    /// Whether the triple at `index` (0 owner, 1 group, 2 other) of the
    /// mode's `ls` form shows every letter the request asks for. A request
    /// with a bit past `rwx` asks for something no triple shows.
    func tripleGrants(_ mode: UInt16, _ index: Int, _ requested: AccessMode) -> Bool {
        let triple = symbolicMode(mode)[(index * 3)..<(index * 3 + 3)]
        let asked: [(AccessMode, Character)] = [(.read, "r"), (.write, "w"), (.execute, "x")]
        return requested.rawValue & ~AccessMode.all.rawValue == 0
            && asked.allSatisfy { mode, letter in
                !requested.contains(mode) || triple.contains(letter)
            }
    }

    /// The POSIX rule, written apart from the code: the first of owner,
    /// group, other that the peer matches is its class, and that class's
    /// triple alone decides.
    func posixPermits(_ acl: EntityACL, _ peer: PeerIdentity, _ requested: AccessMode) -> (
        index: Int, granted: Bool
    ) {
        let matches = [
            peer.uid == acl.owner,
            peer.gid == acl.group || peer.supplementaryGroups.contains(acl.group),
            true,
        ]
        let index = matches.firstIndex(of: true)!
        return (index, tripleGrants(acl.mode, index, requested))
    }

    enum EntityACLGenerators {
        /// Any id, often 0, a small one, or the top two.
        static let ids: Gen<UInt32> = .oneOf(
            .integer(),
            .element(of: [0, 1, 1000, .max - 1, .max])
        )

        /// Any 16-bit mode, high bits included, often one of the nine-bit
        /// modes, one granting `rwx` to the other class whatever the owner
        /// and group get, or a familiar one. The six drawn bits of the
        /// `rwx`-to-other branch land in the group (3–5) and owner (6–8)
        /// bits.
        static let modes: Gen<UInt16> = .oneOf(
            .integer(),
            .integer(in: 0...0o777),
            Gen<UInt16>.integer(in: 0...0o77).map { $0 << 3 | 0o007 },
            .element(of: [0o000, 0o007, 0o070, 0o700, 0o750, 0o644, 0o777, 0o1777, 0xFFFF])
        )

        /// Any request: two thirds within `rwx`, the rest any byte, unknown
        /// high bits included.
        static let requests: Gen<AccessMode> = Gen<UInt8>.oneOf(
            .integer(in: 0...7),
            .element(of: [0, 1, 2, 4, 7]),
            .oneOf(.integer(), .element(of: [8, 0xFF]))
        )
        .map { AccessMode(rawValue: $0) }

        static let acls: Gen<EntityACL> = Hegel.zip(ids, ids, modes).map {
            EntityACL(owner: $0, group: $1, mode: $2)
        }

        /// A peer related to the ACL as drawn, with any pid and label.
        static func peers(for acl: EntityACL) -> Gen<(PeerIdentity, PeerRelation)> {
            Gen { tc in
                let relation = try tc.draw(Gen<PeerRelation>.element(of: PeerRelation.allCases))
                let uid =
                    [.owner, .ownerInTheGroup].contains(relation) ? acl.owner : try tc.draw(ids)
                let gid =
                    [.ownerInTheGroup, .primaryGroup].contains(relation)
                    ? acl.group : try tc.draw(ids)
                var supplementary = try tc.draw(Gen<[UInt32]>.array(of: ids))
                if relation == .supplementaryGroup {
                    supplementary.insert(
                        acl.group,
                        at: try tc.draw(Gen<Int>.int(in: 0...supplementary.count))
                    )
                }
                let peer = PeerIdentity(
                    uid: uid,
                    gid: gid,
                    supplementaryGroups: supplementary,
                    pid: try tc.draw(Gen<Int32>.integer()),
                    label: try tc.draw(.optional(Gen<String>.string()))
                )
                return (peer, relation)
            }
        }
    }

    @Suite("EntityACL properties", .hegel)
    struct EntityACLProperties {
        /// `permitted` agrees with the POSIX rule read from the `ls` form of
        /// the mode: the first class the peer matches decides alone, even
        /// when it denies what another class would grant; mode bits past
        /// the ninth, the pid and the label change nothing; and a request
        /// with a bit past `rwx` is never granted.
        ///
        /// Mutation check: a group test that skips supplementary groups, an
        /// owner who loses to the group, the group bits read one place off,
        /// falling back to the other class when the matched one denies, or
        /// masking the request to `rwx`, fails here.
        @Test
        func permittedFollowsTheFirstMatchingClass() throws {
            try property(
                reaching: ["denied", "granted"],
                reachingAfter: [
                    "someone else": 1_000,
                    "the group denied though the other class would grant": 1_000,
                    "the group, by a supplementary group": 1_000,
                    "the group, by primary gid": 1_000, "the owner": 1_000,
                    "the owner denied though the other class would grant": 1_000,
                    "the owner, in the group too": 1_000,
                ]
            ) { tc in
                let acl = try #draw(EntityACLGenerators.acls, from: tc)
                let (peer, relation) = try #draw(EntityACLGenerators.peers(for: acl), from: tc)
                let requested = try #draw(EntityACLGenerators.requests, from: tc)
                let (index, granted) = posixPermits(acl, peer, requested)
                try tc.event(relation.rawValue)
                try tc.event(granted ? "granted" : "denied")
                if !granted && index != 2 && tripleGrants(acl.mode, 2, requested) {
                    try tc.event(
                        "the \(index == 0 ? "owner" : "group") denied though the other class would grant"
                    )
                }
                let classes: [EntityACL.PermissionClass] = [.owner, .group, .other]
                #expect(acl.permissionClass(for: peer) == classes[index])
                #expect(
                    acl.permitted(for: peer, requested) == granted,
                    "\(acl) \(peer) \(requested)"
                )
            }
        }

        /// For one ACL and peer, asking for two sets of bits at once is
        /// granted exactly when each set alone is, and asking for nothing is
        /// always granted; so granting is monotonic: whatever is granted,
        /// every part of it is too.
        ///
        /// Mutation check: granting only a request equal to the class's
        /// bits, rather than any part of them, fails here.
        @Test
        func permittedIsMonotonicInTheRequest() throws {
            try property(
                reaching: ["the union denied"],
                reachingAfter: [
                    "one part granted, the other denied": 1_000, "someone else": 1_000,
                    "the group, by a supplementary group": 1_000,
                    "the group, by primary gid": 1_000, "the owner": 1_000,
                    "the owner, in the group too": 1_000, "the union granted": 1_000,
                ]
            ) { tc in
                let acl = try #draw(EntityACLGenerators.acls, from: tc)
                let (peer, relation) = try #draw(EntityACLGenerators.peers(for: acl), from: tc)
                let first = try #draw(EntityACLGenerators.requests, from: tc)
                let second = try #draw(EntityACLGenerators.requests, from: tc)
                let both = acl.permitted(for: peer, first.union(second))
                try tc.event(relation.rawValue)
                try tc.event(both ? "the union granted" : "the union denied")
                if acl.permitted(for: peer, first) != acl.permitted(for: peer, second) {
                    try tc.event("one part granted, the other denied")
                }
                #expect(
                    both == (acl.permitted(for: peer, first) && acl.permitted(for: peer, second))
                )
                #expect(acl.permitted(for: peer, []))
            }
        }
    }

#endif
