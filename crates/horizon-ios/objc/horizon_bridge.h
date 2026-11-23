// horizon-ios: C ABI between the native Objective-C overlay (`objc/`) and Rust (`src/bridge.rs`).
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Input modes (HorizonInputMode)
enum {
    HORIZON_INPUT_MODE_TOUCH = 0,
    HORIZON_INPUT_MODE_GAMEPAD = 1,
    HORIZON_INPUT_MODE_KEYBOARD_MOUSE = 2,
};

// Screen categories
enum {
    HORIZON_SCREEN_MENU = 0,
    HORIZON_SCREEN_PLAYING = 1,
    HORIZON_SCREEN_INVENTORY = 2,
    HORIZON_SCREEN_CREATIVE = 3,
    HORIZON_SCREEN_CONTAINER = 4,
    HORIZON_SCREEN_CHAT = 5,
    HORIZON_SCREEN_LOADING = 6,
};

// Gamepad glyph styles
enum {
    HORIZON_GLYPH_AUTO = 0,
    HORIZON_GLYPH_XBOX = 1,
    HORIZON_GLYPH_PLAYSTATION = 2,
    HORIZON_GLYPH_NINTENDO = 3,
};

// Attack target kind
enum {
    HORIZON_ATTACK_NONE = 0,
    HORIZON_ATTACK_BREAK = 1,
    HORIZON_ATTACK_ENTITY = 2,
    HORIZON_ATTACK_SPECTATE = 3,
};

// Contextual use verb (matches gameplay_guide::Verb)
enum {
    HORIZON_VERB_NONE = 0,
    HORIZON_VERB_USE = 1,
    HORIZON_VERB_OPEN = 2,
    HORIZON_VERB_RIDE = 3,
    HORIZON_VERB_TRADE = 4,
    HORIZON_VERB_FEED = 5,
    HORIZON_VERB_PLACE = 6,
    HORIZON_VERB_EAT = 7,
    HORIZON_VERB_DRINK = 8,
    HORIZON_VERB_SHOOT = 9,
    HORIZON_VERB_LOAD = 10,
    HORIZON_VERB_THROW = 11,
    HORIZON_VERB_RAISE = 12,
    HORIZON_VERB_EQUIP = 13,
    HORIZON_VERB_FISH = 14,
    HORIZON_VERB_ZOOM = 15,
    HORIZON_VERB_BOOST = 16,
};

// Active item-in-use state
enum {
    HORIZON_ACTIVE_NONE = 0,
    HORIZON_ACTIVE_SHOOT = 1,
    HORIZON_ACTIVE_THROW = 2,
    HORIZON_ACTIVE_STOP = 3,
};

// Gameplay feedback haptics
enum {
    HORIZON_FEEDBACK_BLOCK_BROKEN = 1,
    HORIZON_FEEDBACK_EXPLOSION = 2,
    HORIZON_FEEDBACK_TOTEM = 3,
    HORIZON_FEEDBACK_ITEM_STACK_SPLIT = 4,
};

// TouchFacts bit flags
enum {
    HORIZON_FACT_FLYING         = 1u << 0,
    HORIZON_FACT_MAY_FLY        = 1u << 1,
    HORIZON_FACT_IN_WATER       = 1u << 2,
    HORIZON_FACT_ON_GROUND      = 1u << 3,
    HORIZON_FACT_GLIDING        = 1u << 4,
    HORIZON_FACT_CAN_GLIDE      = 1u << 5,
    HORIZON_FACT_RIDING         = 1u << 6,
    HORIZON_FACT_VEHICLE_JUMPS  = 1u << 7,
    HORIZON_FACT_SNEAKING       = 1u << 8,
    HORIZON_FACT_SPRINTING      = 1u << 9,
    HORIZON_FACT_SPECTATOR      = 1u << 10,
    HORIZON_FACT_CREATIVE       = 1u << 11,
    HORIZON_FACT_HANDS_BUSY     = 1u << 12,
    HORIZON_FACT_CAN_SPRINT     = 1u << 13,
    HORIZON_FACT_MAIN_HAND_ITEM = 1u << 14,
    HORIZON_FACT_OFF_HAND_ITEM  = 1u << 15,
    HORIZON_FACT_TARGET_BLOCK   = 1u << 16,
    HORIZON_FACT_TARGET_ENTITY  = 1u << 17,
};

// Gamepad button bits (exact order of horizon_client_input::gamepad::Button)
enum {
    HORIZON_PAD_SOUTH         = 1u << 0,
    HORIZON_PAD_EAST          = 1u << 1,
    HORIZON_PAD_WEST          = 1u << 2,
    HORIZON_PAD_NORTH         = 1u << 3,
    HORIZON_PAD_LEFT_BUMPER   = 1u << 4,
    HORIZON_PAD_RIGHT_BUMPER  = 1u << 5,
    HORIZON_PAD_LEFT_TRIGGER  = 1u << 6,
    HORIZON_PAD_RIGHT_TRIGGER = 1u << 7,
    HORIZON_PAD_SELECT        = 1u << 8,
    HORIZON_PAD_START         = 1u << 9,
    HORIZON_PAD_LEFT_STICK    = 1u << 10,
    HORIZON_PAD_RIGHT_STICK   = 1u << 11,
    HORIZON_PAD_DPAD_UP       = 1u << 12,
    HORIZON_PAD_DPAD_DOWN     = 1u << 13,
    HORIZON_PAD_DPAD_LEFT     = 1u << 14,
    HORIZON_PAD_DPAD_RIGHT    = 1u << 15,
};

// Keyboard modifier bits
enum {
    HORIZON_MOD_SHIFT = 1u << 0,
    HORIZON_MOD_CTRL  = 1u << 1,
    HORIZON_MOD_ALT   = 1u << 2,
    HORIZON_MOD_SUPER = 1u << 3,
};

// Common USB HID usage constants used by touch actions
enum {
    HORIZON_HID_A           = 0x04,
    HORIZON_HID_D           = 0x07,
    HORIZON_HID_E           = 0x08,
    HORIZON_HID_F           = 0x09,
    HORIZON_HID_Q           = 0x14,
    HORIZON_HID_S           = 0x16,
    HORIZON_HID_T           = 0x17,
    HORIZON_HID_W           = 0x1A,
    HORIZON_HID_1           = 0x1E,
    HORIZON_HID_ENTER       = 0x28,
    HORIZON_HID_ESCAPE      = 0x29,
    HORIZON_HID_BACKSPACE   = 0x2A,
    HORIZON_HID_TAB         = 0x2B,
    HORIZON_HID_SPACE       = 0x2C,
    HORIZON_HID_SLASH       = 0x38,
    HORIZON_HID_F3          = 0x3C,
    HORIZON_HID_F5          = 0x3E,
    HORIZON_HID_RIGHT_ARROW = 0x4F,
    HORIZON_HID_LEFT_ARROW  = 0x50,
    HORIZON_HID_DOWN_ARROW  = 0x51,
    HORIZON_HID_UP_ARROW    = 0x52,
    HORIZON_HID_LEFT_CTRL   = 0xE0,
    HORIZON_HID_LEFT_SHIFT  = 0xE1,
};

typedef struct {
    bool grabbing;
    uint8_t screen_kind;
    bool text_field_focused;
    bool chat_open;
    uint64_t chat_revision;
    bool has_hotbar;
    uint8_t selected_slot;
    float hotbar_x;
    float hotbar_y;
    float hotbar_w;
    float hotbar_h;
    float gui_scale;
    float mining_progress;
    bool carrying_item;
    uint32_t facts_flags;
    uint8_t attack_kind;
    uint8_t use_verb;
    uint8_t active_use;
} HorizonOverlayState;

typedef struct {
    bool connected;
    uint8_t glyph_style;
    uint32_t buttons;
    float left_x;
    float left_y;
    float right_x;
    float right_y;
    float left_trigger;
    float right_trigger;
    float peak_left_x;
    float peak_left_y;
    float peak_right_x;
    float peak_right_y;
    const char *name;
} HorizonGamepadState;

typedef struct {
    float strong;
    float weak;
    float left_trigger;
    float right_trigger;
    uint32_t millis;
} HorizonRumbleEvent;

typedef struct {
    uint8_t kind;
    float intensity;
} HorizonFeedbackEvent;

// Obj-C -> Rust
void horizon_ios_set_input_mode(uint8_t mode);
void horizon_ios_set_touch_move(bool active, float left, float forward);
void horizon_ios_set_hide_crosshair(bool hide);
void horizon_ios_set_touch_auto_jump(bool enabled);
void horizon_ios_set_keyboard_inset_px(float px);
void horizon_ios_set_live_shader_pack(const char *pack_value);

void horizon_ios_send_key(uint16_t hid_usage, bool down);
void horizon_ios_send_modifiers(uint8_t mask);
void horizon_ios_send_text(const char *utf8);
void horizon_ios_send_chat_text(const char *utf8);
void horizon_ios_send_cursor(double x, double y);
void horizon_ios_send_mouse_button(uint8_t button, bool down);
void horizon_ios_send_look(double dx, double dy);
void horizon_ios_send_scroll(float dx, float dy);
void horizon_ios_tap_world(float nx, float ny);
void horizon_ios_hold_world(float nx, float ny, bool active);
void horizon_ios_move_world_hold(float nx, float ny);

void horizon_ios_gamepad_update(const HorizonGamepadState *state);
void horizon_ios_gamepad_connection(bool connected, uint8_t glyph_style);

// Rust -> Obj-C polling
void horizon_ios_poll_state(HorizonOverlayState *out_state, char *chat_buf, size_t chat_buf_len);
bool horizon_ios_poll_rumble(HorizonRumbleEvent *out_rumble);
bool horizon_ios_poll_feedback(HorizonFeedbackEvent *out_feedback);

// HangWatchdog.m
void horizon_ios_heartbeat(void);
void horizon_ios_start_watchdog(void);

// Overlay entry point (called from Rust host.rs)
void horizon_ios_attach_overlay(void *ui_view);

// Pre-Launcher lifecycle (HorizonPreLauncherAppDelegate.m)
void horizon_ios_run_prelauncher_or_launch(void (*launch_cb)(void));
void horizon_ios_dismiss_prelauncher_window(void *game_window);

// Auto-Login lookup (HorizonAutoLoginStore.m, called from Rust host.rs)
bool horizon_ios_lookup_autologin_parts(
    const char *normalized_addr,
    char *tmpl_buf,
    size_t tmpl_buf_len,
    char *pass_buf,
    size_t pass_buf_len,
    uint64_t *out_delay_ms
);

// Pre-Launcher Rust FFI (bridge.rs -> prelauncher.rs)
void horizon_ios_free_string(char *ptr);
char *horizon_ios_normalize_server_address(const char *address);
char *horizon_ios_load_player_name(const char *dir_path);
bool horizon_ios_save_player_name(const char *dir_path, const char *name, char *err_buf, size_t err_buf_len);
char *horizon_ios_load_servers_json(const char *servers_dat_path);
bool horizon_ios_upsert_server(const char *servers_dat_path, int32_t index, const char *name, const char *ip, char *err_buf, size_t err_buf_len);
bool horizon_ios_delete_server(const char *servers_dat_path, int32_t index, char *err_buf, size_t err_buf_len);
char *horizon_ios_ping_server_json(const char *address, uint32_t timeout_ms);
char *horizon_ios_load_options_json(const char *options_path);
bool horizon_ios_save_options(const char *options_path, int32_t render_distance, int32_t max_fps, int32_t gui_scale, int32_t fov, const char *lang);
char *horizon_ios_list_worlds_json(const char *saves_dir);
int32_t horizon_ios_extract_resources_zip(const char *zip_path, const char *dest_dir, char *err_buf, size_t err_buf_len);

// OTA installer kinds (matches HorizonOTAInstaller / prelauncher::OtaInstaller)
enum {
    HORIZON_OTA_INSTALLER_AUTO = 0,
    HORIZON_OTA_INSTALLER_FEATHER = 1,
    HORIZON_OTA_INSTALLER_SIDESTORE = 2,
    HORIZON_OTA_INSTALLER_ALTSTORE = 3,
    HORIZON_OTA_INSTALLER_DIRECT = 4,
};

// OTA Rust FFI (bridge.rs -> prelauncher.rs)
bool horizon_ios_ota_is_newer(
    const char *local_version,
    const char *local_build,
    const char *remote_version,
    const char *remote_build
);
char *horizon_ios_ota_install_url(uint8_t installer_kind, const char *ipa_url);
char *horizon_ios_ota_source_url(uint8_t installer_kind, const char *source_url);

// Mod & Pack Browser / Manager Rust FFI (bridge.rs -> mod_manager.rs)
// Safe to invoke on background queues; caller frees non-null return strings with horizon_ios_free_string.
char *horizon_ios_mods_search_json(const char *game_dir, const char *request_json);
char *horizon_ios_mods_details_json(
    const char *game_dir,
    const char *source,
    const char *project_id,
    const char *kind,
    const char *world_folder
);
char *horizon_ios_mods_install_json(const char *game_dir, const char *request_json);
char *horizon_ios_mods_list_installed_json(
    const char *game_dir,
    const char *world_folder,
    const char *updates_json
);
char *horizon_ios_mods_check_updates_json(const char *game_dir, bool force_refresh);
char *horizon_ios_mods_update_json(const char *game_dir, const char *request_json);
char *horizon_ios_mods_toggle_enabled_json(
    const char *game_dir,
    const char *kind,
    const char *key,
    const char *world_folder,
    bool enabled
);
char *horizon_ios_mods_reorder_rp_json(const char *game_dir, const char *file_name, bool move_up);
char *horizon_ios_mods_select_shader_json(const char *game_dir, const char *shader_key);
char *horizon_ios_mods_remove_json(
    const char *game_dir,
    const char *kind,
    const char *key,
    const char *world_folder
);
char *horizon_ios_mods_icon_path(const char *game_dir, const char *icon_url);

#ifdef __cplusplus
}
#endif
