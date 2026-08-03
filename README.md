# InstaBlog builds

| Build | Installed as | CloudKit | Use |
| --- | --- | --- | --- |
| Debug | InstaBlog Dev | Development | Normal Xcode development; red controls |
| Live Debug | InstaBlog Live | Production | Xcode debugging against the same data as TestFlight; warns on launch |
| Migration Export | InstaBlog Export | Development | One-time export of legacy development data; replaces TestFlight while installed |
| Release | InstaBlog | Production | TestFlight and App Store |

Debug, Live Debug, and TestFlight can coexist because they have different bundle identifiers. Settings shows `Version x.y (build) · Variant`; Release omits the variant.

See [DesignDecisions.md](DesignDecisions.md#build-and-cloudkit-environment-isolation) for setup and migration details.
