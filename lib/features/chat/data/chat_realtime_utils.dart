/// Re-export shared utils so existing Family Chat imports keep working.
library;

export 'package:gorila_chat/gorila_chat.dart'
    show
        chatAsInt,
        chatAsIntList,
        chatNormalizeMap,
        chatNormalizeValue,
        chatAttachmentsOf,
        chatMessageIsPending,
        chatMessageIsMine,
        chatSenderUserIdOf,
        chatEnsureMessageOwnership,
        chatPendingMatchesServer,
        chatPendingToReinject,
        chatReconcilePendingDuplicates,
        sortChatMessages,
        chatUpsertMessage,
        chatMergeMessageLists,
        chatMergeReadStatus,
        chatMessageDisplayEquals,
        chatMessageListsDisplayEqual,
        chatNewestServerMessageId,
        chatMessageBelongsToThread;
