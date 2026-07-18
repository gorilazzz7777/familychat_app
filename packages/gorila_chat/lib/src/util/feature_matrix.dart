/// Feature matrix: Family Chat (reference) vs TeamCoach backend.
///
/// | Feature            | Family Chat | TeamCoach |
/// |--------------------|-------------|-----------|
/// | WS reconnect       | yes         | via gorila_chat |
/// | chat_message push  | yes         | yes       |
/// | typing             | yes         | no        |
/// | reactions          | yes         | no        |
/// | reply/edit/delete  | yes         | no        |
/// | forward            | yes         | no        |
/// | mentions           | yes         | no        |
/// | voice              | yes         | no        |
/// | location           | yes         | no        |
/// | family albums      | yes         | no        |
/// | attachments        | yes         | yes       |
/// | calls (WebRTC)     | yes         | yes       |
/// | read receipts      | yes         | yes       |
/// | workout sys cards  | no          | yes (app renderer) |
///
/// UI in shared package must gate on [ChatCapabilities].
library;
