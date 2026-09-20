# InstaBlog builds

| Build | Installed as | CloudKit | Use |
| --- | --- | --- | --- |
| Debug | InstaBlog Dev | Development | Normal Xcode development; red controls |
| Live Debug | InstaBlog Live | Production | Xcode debugging against the same data as TestFlight; warns on launch |
| Release | InstaBlog | Production | TestFlight and App Store |

Debug, Live Debug, and TestFlight can coexist because they have different bundle identifiers. Settings shows `Version x.y (build) · Variant`; Release omits the variant.

Use the `InstaBlog Live` scheme's Archive action for production distribution archives. Its Run action uses Live Debug; Archive uses Release and checks that the CloudKit Development and Production schemas match.

See [DesignDecisions.md](DesignDecisions.md#build-and-cloudkit-environment-isolation) for setup and migration details.
