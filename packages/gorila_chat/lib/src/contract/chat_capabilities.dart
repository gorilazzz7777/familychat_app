/// What the host backend/app supports. UI hides unsupported actions.
class ChatCapabilities {
  const ChatCapabilities({
    this.supportsTyping = false,
    this.supportsReactions = false,
    this.supportsReply = false,
    this.supportsEdit = false,
    this.supportsDelete = false,
    this.supportsForward = false,
    this.supportsMentions = false,
    this.supportsVoice = false,
    this.supportsLocation = false,
    this.supportsAlbums = false,
    this.supportsCalls = false,
    this.supportsAttachments = true,
    this.supportsReadReceipts = false,
    this.supportsScheduledSend = false,
    this.supportsOfflineOutbox = false,
  });

  /// Family Chat reference feature set.
  static const familyChat = ChatCapabilities(
    supportsTyping: true,
    supportsReactions: true,
    supportsReply: true,
    supportsEdit: true,
    supportsDelete: true,
    supportsForward: true,
    supportsMentions: true,
    supportsVoice: true,
    supportsLocation: true,
    supportsAlbums: true,
    supportsCalls: true,
    supportsAttachments: true,
    supportsReadReceipts: true,
    supportsScheduledSend: true,
    supportsOfflineOutbox: true,
  );

  /// TeamCoach current API surface (smaller than Family Chat).
  static const teamCoach = ChatCapabilities(
    supportsTyping: false,
    supportsReactions: false,
    supportsReply: false,
    supportsEdit: false,
    supportsDelete: false,
    supportsForward: false,
    supportsMentions: false,
    supportsVoice: false,
    supportsLocation: false,
    supportsAlbums: false,
    supportsCalls: true,
    supportsAttachments: true,
    supportsReadReceipts: true,
    supportsScheduledSend: false,
    supportsOfflineOutbox: false,
  );

  final bool supportsTyping;
  final bool supportsReactions;
  final bool supportsReply;
  final bool supportsEdit;
  final bool supportsDelete;
  final bool supportsForward;
  final bool supportsMentions;
  final bool supportsVoice;
  final bool supportsLocation;
  final bool supportsAlbums;
  final bool supportsCalls;
  final bool supportsAttachments;
  final bool supportsReadReceipts;
  final bool supportsScheduledSend;
  final bool supportsOfflineOutbox;
}
