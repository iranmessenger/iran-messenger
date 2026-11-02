<?php
defined( 'ABSPATH' ) || exit;

/**
 * Tables, activation and periodic cleanup.
 *
 * Key material and ciphertext are stored as base64 text so every query is
 * plain ASCII and safe through $wpdb regardless of connection charset.
 * Times are unix seconds (UTC).
 */
class IRM_Schema {

	public static function table( $name ) {
		global $wpdb;
		return $wpdb->prefix . 'irm_' . $name;
	}

	public static function activate() {
		self::install();
		add_role( IRM_ROLE, 'Messenger member', array() );
		if ( ! wp_next_scheduled( 'irm_cleanup' ) ) {
			wp_schedule_event( time() + HOUR_IN_SECONDS, 'hourly', 'irm_cleanup' );
		}
	}

	public static function deactivate() {
		wp_clear_scheduled_hook( 'irm_cleanup' );
	}

	public static function maybe_upgrade() {
		if ( (int) get_option( 'irm_db_version' ) !== IRM_DB_VERSION ) {
			self::install();
		}
	}

	public static function install() {
		global $wpdb;
		require_once ABSPATH . 'wp-admin/includes/upgrade.php';
		$collate = $wpdb->get_charset_collate();
		$t       = array( __CLASS__, 'table' );

		dbDelta(
			'CREATE TABLE ' . $t( 'identities' ) . " (
			id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
			wp_user_id bigint(20) unsigned NOT NULL,
			display_name varchar(80) NOT NULL,
			mobile varchar(20) NOT NULL,
			username varchar(20) DEFAULT NULL,
			mobile_hash char(64) NOT NULL DEFAULT '',
			mobile_prefix char(6) NOT NULL DEFAULT '',
			status varchar(16) NOT NULL DEFAULT 'active',
			is_bot tinyint(1) unsigned NOT NULL DEFAULT 0,
			created_at bigint(20) unsigned NOT NULL,
			PRIMARY KEY  (id),
			UNIQUE KEY wp_user_id (wp_user_id),
			UNIQUE KEY mobile (mobile),
			UNIQUE KEY username (username),
			KEY mobile_prefix (mobile_prefix)
			) ENGINE=InnoDB $collate;"
		);

		dbDelta(
			'CREATE TABLE ' . $t( 'devices' ) . " (
			id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
			identity_id bigint(20) unsigned NOT NULL,
			role varchar(16) NOT NULL DEFAULT 'primary',
			auth_key varchar(64) NOT NULL,
			registration_id int(10) unsigned NOT NULL,
			identity_key varchar(64) NOT NULL,
			spk_id int(10) unsigned NOT NULL,
			spk_pub varchar(64) NOT NULL,
			spk_sig varchar(128) NOT NULL,
			status varchar(16) NOT NULL DEFAULT 'active',
			created_at bigint(20) unsigned NOT NULL,
			last_seen_at bigint(20) unsigned NOT NULL DEFAULT 0,
			revoked_at bigint(20) unsigned NOT NULL DEFAULT 0,
			cap smallint(5) unsigned NOT NULL DEFAULT 1,
			PRIMARY KEY  (id),
			KEY identity_id (identity_id)
			) ENGINE=InnoDB $collate;"
		);

		dbDelta(
			'CREATE TABLE ' . $t( 'prekeys' ) . " (
			id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
			device_id bigint(20) unsigned NOT NULL,
			key_id int(10) unsigned NOT NULL,
			pub varchar(64) NOT NULL,
			PRIMARY KEY  (id),
			UNIQUE KEY device_key (device_id,key_id)
			) ENGINE=InnoDB $collate;"
		);

		dbDelta(
			'CREATE TABLE ' . $t( 'messages' ) . " (
			id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
			sender_device_id bigint(20) unsigned NOT NULL,
			client_msg_id varchar(36) NOT NULL,
			payload_hash char(64) NOT NULL,
			created_at bigint(20) unsigned NOT NULL,
			expires_at bigint(20) unsigned NOT NULL,
			PRIMARY KEY  (id),
			UNIQUE KEY sender_msg (sender_device_id,client_msg_id),
			KEY expires_at (expires_at)
			) ENGINE=InnoDB $collate;"
		);

		dbDelta(
			'CREATE TABLE ' . $t( 'deliveries' ) . " (
			id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
			message_id bigint(20) unsigned NOT NULL,
			sender_device_id bigint(20) unsigned NOT NULL,
			recipient_device_id bigint(20) unsigned NOT NULL,
			env_type tinyint(3) unsigned NOT NULL,
			ciphertext mediumtext NULL,
			acked_at bigint(20) unsigned NOT NULL DEFAULT 0,
			sender_seen tinyint(1) unsigned NOT NULL DEFAULT 0,
			expires_at bigint(20) unsigned NOT NULL,
			PRIMARY KEY  (id),
			KEY inbox (recipient_device_id,acked_at,id),
			KEY receipts (sender_device_id,sender_seen,acked_at),
			KEY message_id (message_id),
			KEY expires_at (expires_at)
			) ENGINE=InnoDB $collate;"
		);

		dbDelta(
			'CREATE TABLE ' . $t( 'invites' ) . " (
			id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
			token_hash char(64) NOT NULL,
			note varchar(80) NOT NULL DEFAULT '',
			created_by bigint(20) unsigned NOT NULL,
			created_at bigint(20) unsigned NOT NULL,
			expires_at bigint(20) unsigned NOT NULL,
			used_at bigint(20) unsigned NOT NULL DEFAULT 0,
			used_by_identity bigint(20) unsigned NOT NULL DEFAULT 0,
			PRIMARY KEY  (id),
			UNIQUE KEY token_hash (token_hash)
			) ENGINE=InnoDB $collate;"
		);

		dbDelta(
			'CREATE TABLE ' . $t( 'nonces' ) . " (
			device_id bigint(20) unsigned NOT NULL,
			nonce varchar(24) NOT NULL,
			ts bigint(20) unsigned NOT NULL,
			PRIMARY KEY  (device_id,nonce),
			KEY ts (ts)
			) ENGINE=InnoDB $collate;"
		);

		dbDelta(
			'CREATE TABLE ' . $t( 'media' ) . " (
			id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
			public_id char(32) NOT NULL,
			owner_device bigint(20) unsigned NOT NULL,
			size int(10) unsigned NOT NULL,
			sha256 char(64) NOT NULL,
			chunks int(10) unsigned NOT NULL DEFAULT 0,
			chunk_size int(10) unsigned NOT NULL DEFAULT 524288,
			complete tinyint(1) unsigned NOT NULL DEFAULT 0,
			created_at bigint(20) unsigned NOT NULL,
			expires_at bigint(20) unsigned NOT NULL,
			PRIMARY KEY  (id),
			UNIQUE KEY public_id (public_id),
			KEY owner_device (owner_device),
			KEY expires_at (expires_at)
			) ENGINE=InnoDB $collate;"
		);

		dbDelta(
			'CREATE TABLE ' . $t( 'media_recipients' ) . " (
			media_id bigint(20) unsigned NOT NULL,
			device_id bigint(20) unsigned NOT NULL,
			done_at bigint(20) unsigned NOT NULL DEFAULT 0,
			PRIMARY KEY  (media_id,device_id)
			) ENGINE=InnoDB $collate;"
		);

		// Web push subscriptions of browser devices (one per device).
		dbDelta(
			'CREATE TABLE ' . $t( 'push' ) . " (
			device_id bigint(20) unsigned NOT NULL,
			endpoint text NOT NULL,
			p256dh varchar(100) NOT NULL,
			auth varchar(32) NOT NULL,
			created_at bigint(20) unsigned NOT NULL,
			last_push_at bigint(20) unsigned NOT NULL DEFAULT 0,
			fails int(10) unsigned NOT NULL DEFAULT 0,
			PRIMARY KEY  (device_id)
			) ENGINE=InnoDB $collate;"
		);

		// Phones woken through the push gateway gateway (one token per device).
		dbDelta(
			'CREATE TABLE ' . $t( 'fcm' ) . " (
			device_id bigint(20) unsigned NOT NULL,
			token varchar(400) NOT NULL,
			created_at bigint(20) unsigned NOT NULL,
			last_push_at bigint(20) unsigned NOT NULL DEFAULT 0,
			PRIMARY KEY  (device_id)
			) ENGINE=InnoDB $collate;"
		);

		IRM_Discovery::backfill();
		update_option( 'irm_db_version', IRM_DB_VERSION, false );
	}

	/** Hourly: drop expired rows. Expiry is also enforced at read time. */
	public static function cleanup() {
		global $wpdb;
		$now = time();
		IRM_Media::cleanup();
		IRM_Push::cleanup();
		$wpdb->query( $wpdb->prepare( 'DELETE FROM ' . self::table( 'deliveries' ) . ' WHERE expires_at < %d', $now ) );
		$wpdb->query( $wpdb->prepare( 'DELETE FROM ' . self::table( 'messages' ) . ' WHERE expires_at < %d', $now ) );
		$wpdb->query( $wpdb->prepare( 'DELETE FROM ' . self::table( 'nonces' ) . ' WHERE ts < %d', $now - 2 * IRM_CLOCK_WINDOW ) );
		$wpdb->query( $wpdb->prepare( 'DELETE FROM ' . self::table( 'invites' ) . ' WHERE used_at = 0 AND expires_at < %d', $now - WEEK_IN_SECONDS ) );
	}
}
