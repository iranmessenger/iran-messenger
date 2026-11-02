<?php
defined( 'ABSPATH' ) || exit;

/**
 * Accounts: register (with or without an invite code), log in, profile.
 *
 * An account is a username and a password. Registering with a valid invite
 * code activates it at once; without one it waits for the administrator.
 * Logging in on a new installation replaces the previous device: the old
 * device's keys cannot be recovered, so its queued messages are dropped and
 * contacts are told the device changed.
 */
class IRM_Accounts {

	const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

	/** Messenger members authenticate only through this API, never wp-login. */
	public static function block_wp_login( $user ) {
		if ( $user instanceof WP_User && in_array( IRM_ROLE, (array) $user->roles, true ) ) {
			return new WP_Error( 'irm_no_login', __( 'This account cannot sign in here.', 'iran-messenger' ) );
		}
		return $user;
	}

	public static function normalize_code( $raw ) {
		return preg_replace( '/[^A-Z0-9]/', '', strtoupper( (string) $raw ) );
	}

	/** Creates a single-use invite code (shown once; only its hash is kept). */
	public static function create_invite( $note ) {
		global $wpdb;
		$code = '';
		$max  = strlen( self::CODE_ALPHABET ) - 1;
		for ( $i = 0; $i < 10; $i++ ) {
			$code .= self::CODE_ALPHABET[ random_int( 0, $max ) ];
		}
		$now = time();
		$wpdb->insert(
			IRM_Schema::table( 'invites' ),
			array(
				'token_hash' => hash( 'sha256', $code ),
				'note'       => $note,
				'created_by' => get_current_user_id(),
				'created_at' => $now,
				'expires_at' => $now + IRM_INVITE_TTL,
			)
		);
		return substr( $code, 0, 5 ) . '-' . substr( $code, 5 );
	}

	/**
	 * Validates the public key set a device uploads.
	 *
	 * @return array|WP_Error Normalised device fields.
	 */
	public static function parse_device( $d ) {
		$bad = new WP_Error( 'irm_bad_device', 'Device key data is missing or malformed.', array( 'status' => 400 ) );
		if ( ! is_array( $d ) || ! isset( $d['signed_prekey'] ) || ! is_array( $d['signed_prekey'] ) ) {
			return $bad;
		}
		$spk = $d['signed_prekey'];
		if ( false === IRM_Auth::b64( $d['auth_key'] ?? null, 32 )
			|| false === IRM_Auth::b64( $d['identity_key'] ?? null, 33 )
			|| false === IRM_Auth::b64( $spk['key'] ?? null, 33 )
			|| false === IRM_Auth::b64( $spk['sig'] ?? null, 64 )
			|| ! is_int( $d['registration_id'] ?? null ) || $d['registration_id'] < 1 || $d['registration_id'] > 16380
			|| ! is_int( $spk['id'] ?? null ) || $spk['id'] < 1 ) {
			return $bad;
		}
		$prekeys = IRM_Keys::parse_prekeys( $d['prekeys'] ?? array() );
		if ( is_wp_error( $prekeys ) ) {
			return $prekeys;
		}
		return array(
			'auth_key'        => $d['auth_key'],
			'registration_id' => $d['registration_id'],
			'identity_key'    => $d['identity_key'],
			'spk_id'          => $spk['id'],
			'spk_pub'         => $spk['key'],
			'spk_sig'         => $spk['sig'],
			'prekeys'         => $prekeys,
		);
	}

	private static function session_payload( $identity_id, $device_id ) {
		global $wpdb;
		$row = $wpdb->get_row(
			$wpdb->prepare( 'SELECT display_name, username, status FROM ' . IRM_Schema::table( 'identities' ) . ' WHERE id = %d', $identity_id )
		);
		return array(
			'identity_id'  => (int) $identity_id,
			'device_id'    => (int) $device_id,
			'display_name' => $row->display_name,
			'username'     => $row->username,
			'status'       => $row->status,
			'server_key'   => IRM_Signing::public_key(),
			'server_time'  => time(),
		);
	}

	/** POST /auth/register — { username, password, invite_code?, device } */
	public static function register( WP_REST_Request $request ) {
		global $wpdb;
		if ( ! IRM_Auth::rate_limit( 'register', 8, HOUR_IN_SECONDS ) ) {
			return new WP_Error( 'irm_rate_limited', 'Too many attempts. Try again later.', array( 'status' => 429 ) );
		}
		$p     = (array) $request->get_json_params();
		$uname = strtolower( ltrim( trim( (string) ( $p['username'] ?? '' ) ), '@' ) );
		$pass  = is_string( $p['password'] ?? null ) ? $p['password'] : '';
		$code  = self::normalize_code( $p['invite_code'] ?? '' );

		if ( ! preg_match( IRM_Discovery::USERNAME_RE, $uname ) ) {
			return new WP_Error( 'irm_bad_username', 'Username must be 4-20 characters: a-z, 0-9 and underscore, starting with a letter.', array( 'status' => 400 ) );
		}
		if ( strlen( $pass ) < 8 || strlen( $pass ) > 200 ) {
			return new WP_Error( 'irm_weak_password', 'Password must be at least 8 characters.', array( 'status' => 400 ) );
		}
		$device = self::parse_device( $p['device'] ?? null );
		if ( is_wp_error( $device ) ) {
			return $device;
		}

		$t_inv = IRM_Schema::table( 'invites' );
		$t_ide = IRM_Schema::table( 'identities' );
		$now   = time();

		if ( $wpdb->get_var( $wpdb->prepare( "SELECT id FROM $t_ide WHERE username = %s", $uname ) ) ) {
			return new WP_Error( 'irm_username_taken', 'This username is not available.', array( 'status' => 409 ) );
		}
		if ( '' === $code ) {
			if ( ! get_option( 'irm_open_registration', 1 ) ) {
				return new WP_Error( 'irm_invite_required', 'Registration on this server needs an invite code.', array( 'status' => 403 ) );
			}
			$waiting = (int) $wpdb->get_var( "SELECT COUNT(*) FROM $t_ide WHERE status = 'pending'" );
			if ( $waiting >= IRM_MAX_PENDING ) {
				return new WP_Error( 'irm_full', 'Too many requests are waiting for approval. Try again later.', array( 'status' => 403 ) );
			}
		} else {
			$members = (int) $wpdb->get_var( "SELECT COUNT(*) FROM $t_ide WHERE status = 'active' AND is_bot = 0" );
			if ( $members >= IRM_MAX_MEMBERS ) {
				return new WP_Error( 'irm_full', 'This server has reached its member limit.', array( 'status' => 403 ) );
			}
		}

		$wpdb->query( 'START TRANSACTION' );
		if ( '' !== $code ) {
			// Atomic single use: only one request can flip used_at from 0.
			$claimed = $wpdb->query(
				$wpdb->prepare(
					"UPDATE $t_inv SET used_at = %d WHERE token_hash = %s AND used_at = 0 AND expires_at > %d",
					$now,
					hash( 'sha256', $code ),
					$now
				)
			);
			if ( 1 !== $claimed ) {
				$wpdb->query( 'ROLLBACK' );
				return new WP_Error( 'irm_bad_invite', 'Invite code is invalid, expired or already used.', array( 'status' => 403 ) );
			}
		}

		$user_id = wp_insert_user(
			array(
				'user_login'   => 'irm_' . $uname,
				'user_pass'    => $pass,
				'display_name' => $uname,
				'role'         => IRM_ROLE,
			)
		);
		if ( is_wp_error( $user_id ) ) {
			$wpdb->query( 'ROLLBACK' );
			return new WP_Error( 'irm_username_taken', 'This username is not available.', array( 'status' => 409 ) );
		}

		$ok = $wpdb->insert(
			$t_ide,
			array(
				'wp_user_id'   => $user_id,
				'display_name' => $uname,
				'username'     => $uname,
				// Unique placeholder until the member adds a number.
				'mobile'       => 'none:' . $user_id,
				'status'       => '' !== $code ? 'active' : 'pending',
				'created_at'   => $now,
			)
		);
		$identity_id = (int) $wpdb->insert_id;
		$device_id   = $ok ? IRM_Keys::insert_device( $identity_id, 'primary', $device ) : 0;
		if ( ! $device_id ) {
			$wpdb->query( 'ROLLBACK' );
			// wp_users may not be transactional on old installs; remove explicitly.
			require_once ABSPATH . 'wp-admin/includes/user.php';
			wp_delete_user( $user_id );
			return new WP_Error( 'irm_register_failed', 'Registration failed.', array( 'status' => 500 ) );
		}
		if ( '' !== $code ) {
			$wpdb->query(
				$wpdb->prepare( "UPDATE $t_inv SET used_by_identity = %d WHERE token_hash = %s", $identity_id, hash( 'sha256', $code ) )
			);
		}
		$wpdb->query( 'COMMIT' );
		return new WP_REST_Response( self::session_payload( $identity_id, $device_id ), 201 );
	}

	/** POST /auth/login — { username, password, device } */
	public static function login( WP_REST_Request $request ) {
		global $wpdb;
		$p     = (array) $request->get_json_params();
		$uname = strtolower( ltrim( trim( (string) ( $p['username'] ?? '' ) ), '@' ) );
		$pass  = is_string( $p['password'] ?? null ) ? $p['password'] : '';

		// Throttled per address and per account, so one name cannot be hammered.
		if ( ! IRM_Auth::rate_limit( 'login', 20, HOUR_IN_SECONDS )
			|| ! IRM_Auth::rate_limit( 'login_user', 10, HOUR_IN_SECONDS, 'u:' . $uname ) ) {
			return new WP_Error( 'irm_rate_limited', 'Too many attempts. Try again later.', array( 'status' => 429 ) );
		}
		$device = self::parse_device( $p['device'] ?? null );
		if ( is_wp_error( $device ) ) {
			return $device;
		}

		$denied = new WP_Error( 'irm_bad_login', 'Username or password is wrong.', array( 'status' => 403 ) );
		$row    = preg_match( IRM_Discovery::USERNAME_RE, $uname ) ? $wpdb->get_row(
			$wpdb->prepare( 'SELECT id, wp_user_id, status FROM ' . IRM_Schema::table( 'identities' ) . ' WHERE username = %s', $uname )
		) : null;
		$user   = $row ? get_userdata( (int) $row->wp_user_id ) : null;
		if ( ! $user || ! wp_check_password( $pass, $user->user_pass, $user->ID ) ) {
			return $denied;
		}
		if ( ! in_array( $row->status, array( 'active', 'pending' ), true ) ) {
			return new WP_Error( 'irm_blocked', 'This account has been disabled.', array( 'status' => 403 ) );
		}

		$t_dev = IRM_Schema::table( 'devices' );
		$now   = time();
		$wpdb->query( 'START TRANSACTION' );
		$old = $wpdb->get_col( $wpdb->prepare( "SELECT id FROM $t_dev WHERE identity_id = %d AND status = 'active'", $row->id ) );
		foreach ( $old as $id ) {
			$wpdb->update(
				$t_dev,
				array(
					'status'     => 'revoked',
					'revoked_at' => $now,
				),
				array( 'id' => $id )
			);
			// Encrypted for keys that no longer exist anywhere.
			$wpdb->delete( IRM_Schema::table( 'prekeys' ), array( 'device_id' => $id ) );
			IRM_Push::forget( $id );
			$wpdb->query(
				$wpdb->prepare( 'DELETE FROM ' . IRM_Schema::table( 'deliveries' ) . ' WHERE recipient_device_id = %d AND acked_at = 0', $id )
			);
		}
		$device_id = IRM_Keys::insert_device( (int) $row->id, 'primary', $device );
		if ( ! $device_id ) {
			$wpdb->query( 'ROLLBACK' );
			return new WP_Error( 'irm_db', 'Could not sign in.', array( 'status' => 500 ) );
		}
		$wpdb->query( 'COMMIT' );
		return self::session_payload( (int) $row->id, $device_id );
	}

	/** GET /me — also answers while the account is still waiting. */
	public static function me() {
		$device = IRM_Auth::device();
		$out    = self::session_payload( (int) $device->identity_id, (int) $device->id );
		$out['prekey_count'] = IRM_Keys::prekey_count( (int) $device->id );
		return $out;
	}

	/** POST /me/password — { current, new } */
	public static function password( WP_REST_Request $request ) {
		global $wpdb;
		$device = IRM_Auth::device();
		if ( ! IRM_Auth::rate_limit( 'password', 6, HOUR_IN_SECONDS, 'd' . $device->id ) ) {
			return new WP_Error( 'irm_rate_limited', 'Too many attempts. Try again later.', array( 'status' => 429 ) );
		}
		$p       = (array) $request->get_json_params();
		$current = is_string( $p['current'] ?? null ) ? $p['current'] : '';
		$new     = is_string( $p['new'] ?? null ) ? $p['new'] : '';
		if ( strlen( $new ) < 8 || strlen( $new ) > 200 ) {
			return new WP_Error( 'irm_weak_password', 'Password must be at least 8 characters.', array( 'status' => 400 ) );
		}
		$user_id = (int) $wpdb->get_var(
			$wpdb->prepare( 'SELECT wp_user_id FROM ' . IRM_Schema::table( 'identities' ) . ' WHERE id = %d', $device->identity_id )
		);
		$user    = get_userdata( $user_id );
		// A signed device request alone is not enough: the holder of an
		// unlocked phone must also know the current password.
		if ( ! $user || ! wp_check_password( $current, $user->user_pass, $user->ID ) ) {
			return new WP_Error( 'irm_bad_login', 'The current password is wrong.', array( 'status' => 403 ) );
		}
		wp_set_password( $new, $user->ID );
		return array( 'changed' => true );
	}

	/** POST /me/profile — { display_name?, mobile? } */
	public static function profile( WP_REST_Request $request ) {
		global $wpdb;
		$device = IRM_Auth::device();
		$p      = (array) $request->get_json_params();
		$set    = array();

		if ( isset( $p['display_name'] ) ) {
			$name = trim( sanitize_text_field( (string) $p['display_name'] ) );
			if ( '' === $name || mb_strlen( $name ) > 40 ) {
				return new WP_Error( 'irm_bad_name', 'Display name is required (max 40 characters).', array( 'status' => 400 ) );
			}
			$set['display_name'] = $name;
		}
		// Phone numbers are never stored: a seized server would hand over
		// every member's number. Any number sent is dropped.
		if ( isset( $p['mobile'] ) ) {
			$set['mobile']        = 'none:' . $device->identity_id . ':' . time();
			$set['mobile_hash']   = '';
			$set['mobile_prefix'] = '';
		}
		if ( $set ) {
			$suppress = $wpdb->suppress_errors( true );
			$ok       = $wpdb->update( IRM_Schema::table( 'identities' ), $set, array( 'id' => $device->identity_id ) );
			$wpdb->suppress_errors( $suppress );
			if ( false === $ok ) {
				return new WP_Error( 'irm_contact_in_use', 'This number cannot be used.', array( 'status' => 409 ) );
			}
		}
		return self::session_payload( (int) $device->identity_id, (int) $device->id );
	}
}
