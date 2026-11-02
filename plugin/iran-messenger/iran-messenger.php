<?php
/**
 * Plugin Name:       IRAN Messenger
 * Description:       Self-hosted private messenger server. Stores and relays ciphertext only; keys and decryption live in the client apps.
 * Version:           1.0.0
 * Requires at least: 6.2
 * Requires PHP:      7.4
 * License:           GPL-3.0-or-later
 * Text Domain:       iran-messenger
 */

defined( 'ABSPATH' ) || exit;

define( 'IRM_VERSION', '1.0.0' );
define( 'IRM_DB_VERSION', 8 );
define( 'IRM_FILE', __FILE__ );
define( 'IRM_DIR', plugin_dir_path( __FILE__ ) );
define( 'IRM_REST_NS', 'irm/v1' );
define( 'IRM_ROLE', 'irm_member' );

// Limits. Per-install capacity is intentionally small (see roadmap).
define( 'IRM_MAX_MEMBERS', 15 );
define( 'IRM_MAX_PENDING', 30 );
define( 'IRM_MAX_ENVELOPES_PER_MESSAGE', 50 );
define( 'IRM_MAX_CIPHERTEXT_B64', 90000 );
define( 'IRM_MAX_PREKEYS', 100 );
define( 'IRM_SYNC_BATCH', 50 );
define( 'IRM_TEXT_TTL', 30 * DAY_IN_SECONDS );
define( 'IRM_INVITE_TTL', 2 * DAY_IN_SECONDS );
define( 'IRM_CLOCK_WINDOW', 300 );

// Encrypted attachments: kept at most 48 hours, then removed.
define( 'IRM_MEDIA_TTL', 2 * DAY_IN_SECONDS );
// 40 MB files plus the encryption overhead.
define( 'IRM_MEDIA_MAX_BYTES', 41 * 1024 * 1024 );
// Upload/download piece size. Small enough that one piece finishes well
// within proxy timeouts on a slow mobile uplink. Each upload keeps the size
// it started with, so changing this never breaks one in progress.
define( 'IRM_MEDIA_CHUNK', 256 * 1024 );
define( 'IRM_MEDIA_QUOTA_BYTES', 150 * 1024 * 1024 );

require_once IRM_DIR . 'includes/class-irm-schema.php';
require_once IRM_DIR . 'includes/class-irm-auth.php';
require_once IRM_DIR . 'includes/class-irm-accounts.php';
require_once IRM_DIR . 'includes/class-irm-keys.php';
require_once IRM_DIR . 'includes/class-irm-messages.php';
require_once IRM_DIR . 'includes/class-irm-media.php';
require_once IRM_DIR . 'includes/class-irm-discovery.php';
require_once IRM_DIR . 'includes/class-irm-signing.php';
require_once IRM_DIR . 'includes/class-irm-push.php';
require_once IRM_DIR . 'includes/class-irm-gateway.php';
require_once IRM_DIR . 'includes/class-irm-gifs.php';
require_once IRM_DIR . 'includes/class-irm-rest.php';
require_once IRM_DIR . 'includes/class-irm-admin.php';

register_activation_hook( __FILE__, array( 'IRM_Schema', 'activate' ) );
register_deactivation_hook( __FILE__, array( 'IRM_Schema', 'deactivate' ) );

add_action( 'plugins_loaded', array( 'IRM_Schema', 'maybe_upgrade' ) );
add_action( 'rest_api_init', array( 'IRM_Rest', 'register_routes' ) );
add_filter( 'rest_pre_echo_response', array( 'IRM_Signing', 'sign_response' ), 999, 3 );
add_action( 'irm_cleanup', array( 'IRM_Schema', 'cleanup' ) );
add_filter( 'authenticate', array( 'IRM_Accounts', 'block_wp_login' ), 100 );
add_action( 'init', array( 'IRM_Push', 'short_link' ) );

if ( is_admin() ) {
	add_action( 'admin_menu', array( 'IRM_Admin', 'menu' ) );
}
