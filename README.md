# Cairn

A MeshCore client built for Apple devices in Swift, by Christopher Van Hoose (CVH Visuals).
Disclaimer: Decisions are made by a human, but almost all code is created with AI.

Cairn is a modified version of [MeshCore One](https://github.com/Avi0n/MeshCoreOne) by Avi0n,
licensed under the GNU GPL v3.0. Modified by CVH Visuals; this version last changed November 2026.
See [NOTICE](NOTICE).

## Features

### Messaging
- Direct messages with delivery status and flood retry
- Channels (public, private, and hashtag)
- Room Server connections with guest/participant modes
- Heard repeats tracking
- Message reactions (emoji)
- View Path Hops (list and map)
- Link previews and inline images
- Coordinate map previews
- @Mentions
- Per-conversation notification levels
- Hashtag channel deep links
- Blocking (contacts and channel sender names)

### Contacts
- Auto-discovery on the mesh
- QR code and advert sharing
- Favorites
- Zero-hop ping
- Telemetry fetch
- Edit Out Path

### Map
- Contact positions
- Map layers (standard, satellite, topography)
- Offline download

### Network Tools
- **Trace Path** - Route through specific repeaters with option to save paths
- **Line of Sight** - Terrain analysis with Fresnel zone and RF parameters
- **RX Log** - Live packet capture
- **Noise Floor Monitor** - Live dBm chart with signal quality stats
- **CLI Terminal** - Remote command-line access to repeaters and rooms

### Remote Node Management
- Node status (telemetry such as battery and uptime. Neighbors for repeaters)
- Remote repeater/room configuration (radio, behavior, identity, reboot)
- Telemetry history charts
- Admin and guest authentication for repeaters/rooms

### Companion Device
- Bluetooth and WiFi pairing
- Radio presets and manual tuning (frequency, TX power, spreading factor, bandwidth)
- Battery monitoring with OCV curves
- Repeat mode

### General
- Live Activity
- Themes
- Offline mesh networking (no internet required)
- Push notifications with quick reply
- Location sharing controls
- Config import/export
- App data backup/restore


## Requirements

-   **iOS/iPadOS 18.0+, or Apple Silicon Mac**
-   **Xcode 26.0+**
-   **MeshCore-compatible hardware**

## Getting Started

1.  Install [XcodeGen](https://github.com/yonaskolb/XcodeGen).
2.  Run `make generate` (creates a gitignored `dev.yml` — set your Apple team ID there for local signing).
3.  Open `Cairn.xcodeproj`.


  
## License

Cairn - GNU General Public License v3.0 (see [LICENSE](LICENSE))  
Based on MeshCore One by Avi0n - GNU General Public License v3.0  
Swift MeshCore - MIT
