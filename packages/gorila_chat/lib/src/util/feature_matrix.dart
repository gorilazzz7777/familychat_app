/// Feature matrix: Family Chat (reference) vs shared [GorilaConversationScreen]
/// vs TeamCoach adapter today.
///
/// | Feature                 | Family Chat app | gorila_chat UI | TeamCoach |
/// |-------------------------|-----------------|----------------|-----------|
/// | WS reconnect            | yes             | yes            | yes       |
/// | Basic text + attach     | yes             | yes            | yes       |
/// | Calls (WebRTC)          | yes (app copy)  | yes            | yes       |
/// | Message menu            | yes             | yes            | gated off |
/// | Select / multi-select   | yes             | yes            | gated off |
/// | Pin bar + cycle         | yes             | yes            | gated off |
/// | Delete for me           | yes             | yes            | gated off |
/// | Delete for everyone     | yes             | yes            | gated off |
/// | Row highlight           | yes             | yes            | gated off |
/// | Reactions               | yes             | menu only*     | no        |
/// | Reply / edit / forward  | yes             | menu stubs*    | no        |
/// | Mentions                | yes             | no             | no        |
/// | Voice                   | yes             | no             | no        |
/// | Location                | yes             | no             | no        |
/// | Family albums attach    | yes             | no             | no        |
/// | Offline outbox          | yes             | no             | no        |
/// | Scheduled send          | yes             | yes*           | gated off |
/// | AI compose assist       | yes (inline)    | yes (inline)   | gated off |
/// | Speak (TTS)             | yes (DM+Prem)   | yes            | gated off |
/// | In-thread search        | yes             | no             | no        |
/// | Birthday / system cards | yes             | hook only      | app card  |
/// | Friends premium hub     | yes             | n/a            | n/a       |
/// | Rich bubble / swipe     | yes             | basic bubble   | basic     |
///
/// \* Menu can emit actions; full reply/edit/forward/reaction apply needs
/// host repository methods beyond pin/hide/delete.
///
/// UI in shared package must gate on [ChatCapabilities].
library;
