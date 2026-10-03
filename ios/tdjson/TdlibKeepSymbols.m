// Keep TDLib C symbols linked into the app so Dart FFI can resolve them via
// DynamicLibrary.process() (static libtdjson.a — App Store safe).
#include <stdint.h>

extern int td_create_client_id(void);
extern void td_send(int client_id, char const* request);
extern char const* td_receive(double timeout);
extern char const* td_execute(char const* request);

__attribute__((used)) static void* const kFamilyChatTdlibKeep[] = {
    (void*)&td_create_client_id,
    (void*)&td_send,
    (void*)&td_receive,
    (void*)&td_execute,
};
