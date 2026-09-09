#ifndef CUBACADABRA_ENGINE_H
#define CUBACADABRA_ENGINE_H

#include <stdint.h>

typedef struct CubacadabraEngine CubacadabraEngine;
typedef struct CubacadabraRenderer CubacadabraRenderer;
typedef struct CubacadabraClient CubacadabraClient;
typedef struct CubacadabraApp CubacadabraApp;

#define CUBACADABRA_CLIENT_ACTION_NONE 0
#define CUBACADABRA_CLIENT_ACTION_SET_WORLD 1
#define CUBACADABRA_CLIENT_ACTION_SEND_TEXT 2

CubacadabraClient *client_create(
    const uint8_t *manifest,
    uintptr_t manifest_length,
    const uint8_t *script,
    uintptr_t script_length
);
void client_destroy(CubacadabraClient *client);
CubacadabraEngine *client_engine(CubacadabraClient *client);
void client_transport_connected(CubacadabraClient *client);
void client_transport_disconnected(CubacadabraClient *client);
void client_request_transport(CubacadabraClient *client);
uint8_t client_receive_text(
    CubacadabraClient *client,
    const uint8_t *message,
    uintptr_t message_length
);
uint8_t client_set_ignored_player_ids_json(
    CubacadabraClient *client,
    const uint8_t *player_ids,
    uintptr_t player_ids_length
);
uint8_t client_poll_action(CubacadabraClient *client);
const uint8_t *client_action_ptr(const CubacadabraClient *client);
uintptr_t client_action_len(const CubacadabraClient *client);

#define CUBACADABRA_APP_EFFECT_NONE 0
#define CUBACADABRA_APP_EFFECT_SAVE_USERNAME 1

CubacadabraApp *cubacadabra_app_create(
    const uint8_t *username,
    uintptr_t username_length
);
void cubacadabra_app_destroy(CubacadabraApp *app);
uint8_t cubacadabra_app_replace_profile(
    CubacadabraApp *app,
    const uint8_t *username,
    uintptr_t username_length
);
uint8_t cubacadabra_app_username_changed(
    CubacadabraApp *app,
    const uint8_t *value,
    uintptr_t value_length
);
void cubacadabra_app_save_username(CubacadabraApp *app);
uint8_t cubacadabra_app_username_saved(
    CubacadabraApp *app,
    uint32_t effect_id,
    const uint8_t *username,
    uintptr_t username_length
);
uint8_t cubacadabra_app_username_save_failed(
    CubacadabraApp *app,
    uint32_t effect_id,
    const uint8_t *server_code,
    uintptr_t server_code_length
);
void cubacadabra_app_clear_username_feedback(CubacadabraApp *app);
uint8_t cubacadabra_app_snapshot_json(CubacadabraApp *app);
uint8_t cubacadabra_app_poll_effect(CubacadabraApp *app);
uint32_t cubacadabra_app_effect_id(const CubacadabraApp *app);
const uint8_t *cubacadabra_app_output_ptr(const CubacadabraApp *app);
uintptr_t cubacadabra_app_output_len(const CubacadabraApp *app);

#define CUBACADABRA_UI_POINTER_DOWN 0
#define CUBACADABRA_UI_POINTER_MOVE 1
#define CUBACADABRA_UI_POINTER_UP 2
#define CUBACADABRA_UI_POINTER_CANCEL 3
#define CUBACADABRA_MAX_APPEARANCE_BYTES 4096
#define CUBACADABRA_MAX_REMOTE_UPDATE_BYTES 65536
#define CUBACADABRA_IDENTITY_INVALID 0
#define CUBACADABRA_IDENTITY_APPLIED 1
#define CUBACADABRA_IDENTITY_STALE 2
#define CUBACADABRA_IDENTITY_FALLBACK 3
#define CUBACADABRA_IDENTITY_DUPLICATE 4

CubacadabraEngine *engine_create(void);
void engine_set_input(
    CubacadabraEngine *engine,
    float forward,
    float strafe,
    uint8_t sprint,
    uint8_t jump,
    uint8_t climb,
    float look_x,
    float look_y,
    float zoom_delta
);
void engine_set_ui_viewport(
    CubacadabraEngine *engine,
    float width,
    float height,
    float scale,
    float safe_top,
    float safe_right,
    float safe_bottom,
    float safe_left
);
void engine_set_authenticated(CubacadabraEngine *engine, uint8_t authenticated);
uint8_t *engine_ui_document_buffer_ptr(CubacadabraEngine *engine, uintptr_t length);
uint8_t engine_load_ui_document_buffer(CubacadabraEngine *engine);
uint8_t engine_ui_pointer(
    CubacadabraEngine *engine,
    uint64_t pointer_id,
    uint8_t phase,
    float x,
    float y
);
uint8_t engine_ui_poll_event(CubacadabraEngine *engine);
const uint8_t *engine_ui_event_ptr(const CubacadabraEngine *engine);
uintptr_t engine_ui_event_len(const CubacadabraEngine *engine);
uintptr_t engine_ui_node_count(const CubacadabraEngine *engine);
void engine_step(CubacadabraEngine *engine, float delta);
void engine_reset_view(CubacadabraEngine *engine);
void engine_reconcile_player(
    CubacadabraEngine *engine,
    float x,
    float y,
    float z,
    float yaw
);
void engine_set_build_block_count(CubacadabraEngine *engine, uintptr_t count);
void engine_set_build_block(
    CubacadabraEngine *engine,
    uintptr_t index,
    float x,
    float y,
    float z,
    float width,
    float height,
    float depth,
    uint32_t color,
    uint8_t rotation
);
void engine_set_launch_pad(
    CubacadabraEngine *engine,
    uintptr_t index,
    float x,
    float z,
    float radius,
    float countdown
);
void engine_set_launch_pad_count(CubacadabraEngine *engine, uintptr_t count);
void engine_set_obstacle(
    CubacadabraEngine *engine,
    uintptr_t index,
    float x,
    float y,
    float z,
    float width,
    float height,
    float depth
);
void engine_set_obstacle_count(CubacadabraEngine *engine, uintptr_t count);
void engine_set_world_count(CubacadabraEngine *engine, uintptr_t count);
void engine_set_world_spawn(
    CubacadabraEngine *engine,
    uintptr_t world,
    float x,
    float y,
    float z
);
void engine_set_world_launch_pad_count(
    CubacadabraEngine *engine,
    uintptr_t world,
    uintptr_t count
);
void engine_set_world_launch_pad(
    CubacadabraEngine *engine,
    uintptr_t world,
    uintptr_t index,
    float x,
    float z,
    float radius,
    float countdown
);
void engine_set_world_launch_destination(
    CubacadabraEngine *engine,
    uintptr_t world,
    uintptr_t pad,
    int32_t destination
);
void engine_set_world_obstacle_count(
    CubacadabraEngine *engine,
    uintptr_t world,
    uintptr_t count
);
void engine_set_world_obstacle(
    CubacadabraEngine *engine,
    uintptr_t world,
    uintptr_t index,
    float x,
    float y,
    float z,
    float width,
    float height,
    float depth
);
uint8_t engine_start_world(CubacadabraEngine *engine, uintptr_t world);
uintptr_t engine_enter_session(
    CubacadabraEngine *engine,
    uintptr_t launch_pad_index,
    float spawn_x,
    float spawn_y,
    float spawn_z
);
uint8_t *engine_script_buffer_ptr(CubacadabraEngine *engine, uintptr_t length);
uint8_t engine_load_script_buffer(CubacadabraEngine *engine);
const uint8_t *engine_script_error_ptr(const CubacadabraEngine *engine);
uintptr_t engine_script_error_len(const CubacadabraEngine *engine);
uint8_t engine_receive_network_message_json(
    CubacadabraEngine *engine,
    const uint8_t *source,
    uintptr_t length
);
uint8_t *engine_network_receive_buffer_ptr(CubacadabraEngine *engine, uintptr_t length);
uint8_t engine_load_network_receive_buffer(CubacadabraEngine *engine);
uint8_t engine_network_poll_message(CubacadabraEngine *engine);
const uint8_t *engine_network_message_ptr(const CubacadabraEngine *engine);
uintptr_t engine_network_message_len(const CubacadabraEngine *engine);
uint8_t engine_audio_poll_message(CubacadabraEngine *engine);
const uint8_t *engine_audio_message_ptr(const CubacadabraEngine *engine);
uintptr_t engine_audio_message_len(const CubacadabraEngine *engine);
uint8_t *engine_package_buffer_ptr(CubacadabraEngine *engine, uintptr_t length);
uint8_t engine_load_package_buffer(CubacadabraEngine *engine);
uint8_t *engine_username_buffer_ptr(CubacadabraEngine *engine, uintptr_t length);
uint8_t engine_load_username_buffer(CubacadabraEngine *engine);
/* Engine-owned buffers remain valid until their next allocation or engine
 * destruction. Hosts write exactly the requested UTF-8 byte length. */
uint8_t *engine_appearance_buffer_ptr(CubacadabraEngine *engine, uintptr_t length);
uint8_t engine_load_appearance_buffer(CubacadabraEngine *engine);
uint8_t engine_set_local_appearance_json(
    CubacadabraEngine *engine,
    const uint8_t *source,
    uintptr_t length
);
uint8_t engine_appearance_status(const CubacadabraEngine *engine);
uint32_t engine_appearance_revision(const CubacadabraEngine *engine);
uint8_t *engine_remote_update_buffer_ptr(CubacadabraEngine *engine, uintptr_t length);
uint8_t engine_apply_remote_update_buffer(CubacadabraEngine *engine);
uint8_t engine_apply_remote_update_json(
    CubacadabraEngine *engine,
    const uint8_t *source,
    uintptr_t length
);
uint8_t engine_remote_update_status(const CubacadabraEngine *engine);
uint64_t engine_remote_update_sequence(const CubacadabraEngine *engine);
void engine_reset_remote_session(CubacadabraEngine *engine);
uint8_t engine_script_loaded(const CubacadabraEngine *engine);
const float *engine_snapshot_ptr(const CubacadabraEngine *engine);
uintptr_t engine_snapshot_len(void);
uintptr_t engine_snapshot_stride(void);
float engine_camera_yaw(const CubacadabraEngine *engine);
/* Body heading for replication. Legacy snapshot slot 3 remains camera yaw. */
float engine_player_facing_yaw(const CubacadabraEngine *engine);
/* Monotonic signal authorizing a checkpoint-respawn movement teleport. */
uint32_t engine_player_respawn_event_id(const CubacadabraEngine *engine);
float engine_camera_pitch(const CubacadabraEngine *engine);
float engine_camera_distance(const CubacadabraEngine *engine);
uintptr_t engine_agent_count(const CubacadabraEngine *engine);
uintptr_t engine_local_agent_count(const CubacadabraEngine *engine);
uintptr_t engine_remote_player_count(const CubacadabraEngine *engine);
void engine_set_remote_player_count(CubacadabraEngine *engine, uintptr_t count);
void engine_set_remote_player(
    CubacadabraEngine *engine,
    uintptr_t index,
    float x,
    float y,
    float z,
    float yaw,
    uint8_t moving,
    uint8_t sprinting
);
uintptr_t engine_meeting_count(const CubacadabraEngine *engine, uintptr_t index);
uintptr_t engine_launch_pad_count(const CubacadabraEngine *engine);
uintptr_t engine_launch_pad_occupants(const CubacadabraEngine *engine, uintptr_t index);
float engine_launch_pad_seconds(const CubacadabraEngine *engine, uintptr_t index);
uint8_t engine_launch_pad_phase(const CubacadabraEngine *engine, uintptr_t index);
int32_t engine_player_launch_pad(const CubacadabraEngine *engine);
uint32_t engine_launch_event_id(const CubacadabraEngine *engine);
uintptr_t engine_last_launch_pad(const CubacadabraEngine *engine);
uintptr_t engine_last_launch_occupants(const CubacadabraEngine *engine);
uintptr_t engine_active_world(const CubacadabraEngine *engine);
uint8_t engine_settings_room_state(const CubacadabraEngine *engine);
uint32_t engine_world_event_id(const CubacadabraEngine *engine);
uintptr_t engine_last_world_source_pad(const CubacadabraEngine *engine);
uintptr_t engine_last_world_destination(const CubacadabraEngine *engine);
float engine_elapsed(const CubacadabraEngine *engine);
void engine_destroy(CubacadabraEngine *engine);

CubacadabraRenderer *engine_renderer_create(void *native_surface, float width, float height);
void engine_renderer_resize(CubacadabraRenderer *renderer, float width, float height);
/* Uploads the package-owned world image atlas and normalized image regions. */
uint8_t engine_renderer_set_package_image_atlas(
    CubacadabraRenderer *renderer,
    uint32_t width,
    uint32_t height,
    const uint8_t *pixels,
    uintptr_t pixel_len,
    const uint8_t *regions,
    uintptr_t regions_len
);
void engine_renderer_sync(CubacadabraRenderer *renderer, const CubacadabraEngine *engine);
void engine_renderer_draw(CubacadabraRenderer *renderer);
void engine_renderer_destroy(CubacadabraRenderer *renderer);

#endif
