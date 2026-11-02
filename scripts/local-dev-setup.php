<?php
/**
 * Local development only (XAMPP). Installs the test WordPress if needed,
 * activates the plugin and prints N fresh invite tokens, one per line.
 *
 *   php scripts/local-dev-setup.php C:/xampp/htdocs/irm [count]
 */
if ( PHP_SAPI !== 'cli' ) { exit( 1 ); }
$root  = rtrim( str_replace( chr( 92 ), '/', $argv[1] ?? '' ), '/' );
$count = (int) ( $argv[2] ?? 2 );
$url   = 'http://localhost:8089';

if ( ! file_exists( "$root/wp-config.php" ) ) {
	$c = file_get_contents( "$root/wp-config-sample.php" );
	$c = str_replace( array( 'database_name_here', 'username_here', 'password_here' ), array( 'irm_local', 'root', '' ), $c );
	$c = preg_replace_callback( "/'put your unique phrase here'/", function () { return "'" . bin2hex( random_bytes( 32 ) ) . "'"; }, $c );
	$c = str_replace( "define( 'WP_DEBUG', false );", '', $c );
	$c = str_replace( "/* That's all, stop editing!", "define( 'WP_HOME', '$url' );\ndefine( 'WP_SITEURL', '$url' );\ndefine( 'WP_DEBUG', true );\ndefine( 'WP_DEBUG_LOG', true );\ndefine( 'WP_DEBUG_DISPLAY', false );\n\n/* That's all, stop editing!", $c );
	file_put_contents( "$root/wp-config.php", $c );
}

$_SERVER['HTTP_HOST']   = 'localhost:8089';
$_SERVER['REQUEST_URI'] = '/';
define( 'WP_INSTALLING', true );
require "$root/wp-load.php";
require_once ABSPATH . 'wp-admin/includes/upgrade.php';
require_once ABSPATH . 'wp-admin/includes/plugin.php';

if ( ! is_blog_installed() ) {
	wp_install( 'IRM local', 'localadmin', 'localadmin@example.invalid', false, '', wp_generate_password( 24 ) );
	fwrite( STDERR, "installed WordPress " . get_bloginfo( 'version' ) . "\n" );
}
update_option( 'permalink_structure', '/%postname%/' );

$main = 'iran-messenger/iran-messenger.php';
$r    = activate_plugin( $main );
if ( is_wp_error( $r ) ) { fwrite( STDERR, 'activate failed: ' . $r->get_error_message() . "\n" ); exit( 1 ); }
// Active plugins are not loaded while WP_INSTALLING is set.
if ( ! class_exists( 'IRM_Schema' ) ) {
	require_once WP_PLUGIN_DIR . '/' . $main;
}
IRM_Schema::activate();

if ( in_array( '--relay', $argv, true ) ) {
	// A second local server (port 8090) acts as a private relay to this one.
	$relay_main = 'iran-messenger-relay/iran-messenger-relay.php';
	$r          = activate_plugin( $relay_main );
	if ( is_wp_error( $r ) ) { fwrite( STDERR, 'relay activate failed: ' . $r->get_error_message() . "\n" ); exit( 1 ); }
	$key = 'localrelaykey0123456789abcdef';
	update_option( 'irm_relay', array( 'enabled' => 1, 'upstream' => 'http://localhost:8089', 'key' => $key ), false );
	update_option( 'irm_relays', array( array( 'url' => 'http://localhost:8090', 'key' => $key ) ), false );
}

foreach ( $argv as $arg ) {
	if ( 0 === strpos( $arg, '--bot=' ) ) {
		// What the admin page's "Make bot" button does.
		global $wpdb;
		$n = $wpdb->update( IRM_Schema::table( 'identities' ), array( 'is_bot' => 1 ), array( 'username' => substr( $arg, 6 ) ) );
		exit( 1 === $n ? 0 : 1 );
	}
	if ( 0 === strpos( $arg, '--approve=' ) ) {
		// What the admin page's "Approve" button does.
		global $wpdb;
		$n = $wpdb->update( IRM_Schema::table( 'identities' ), array( 'status' => 'active' ), array( 'username' => substr( $arg, 10 ), 'status' => 'pending' ) );
		exit( 1 === $n ? 0 : 1 );
	}
}
if ( in_array( '--reset', $argv, true ) ) {
	global $wpdb;
	foreach ( array( 'identities', 'devices', 'prekeys', 'messages', 'deliveries', 'invites', 'nonces' ) as $t ) {
		$wpdb->query( 'TRUNCATE TABLE ' . IRM_Schema::table( $t ) );
	}
	// Clear the registration rate limiter so repeated test runs are not throttled.
	$wpdb->query( "DELETE FROM {$wpdb->options} WHERE option_name LIKE '%irm_rl_%'" );
	wp_cache_flush();
	foreach ( get_users( array( 'role' => IRM_ROLE, 'fields' => 'ID' ) ) as $id ) {
		require_once ABSPATH . 'wp-admin/includes/user.php';
		wp_delete_user( $id );
	}
}
if ( in_array( '--gif', $argv, true ) ) {
	// One item in the shared GIF collection, for the tests.
	$dir = IRM_Media::dir() . '/gifs';
	wp_mkdir_p( $dir );
	$gif = base64_decode( 'R0lGODlhAQABAIAAAP///wAAACwAAAAAAQABAAACAkQBADs=' );
	file_put_contents( $dir . '/ptestgif00000001', $gif );
	update_option( 'irm_gif_pack', array( 'ptestgif00000001' => array( 'mime' => 'image/gif', 'size' => strlen( $gif ), 'name' => 'test.gif' ) ), false );
}
for ( $i = 0; $i < $count; $i++ ) {
	echo IRM_Accounts::create_invite( 'local test' ), "\n";
}
