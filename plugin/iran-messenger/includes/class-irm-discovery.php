<?php
defined( 'ABSPATH' ) || exit;

/**
 * Finding other members without a public directory.
 *
 * There is no "list everyone" call. A member becomes visible to another
 * only when one of these holds:
 *  - their phone number is in the asker's address book (contact match), or
 *  - the asker already knows their exact username.
 *
 * Contact match never receives phone numbers or full hashes. The client
 * sends only the first 24 bits of a salted hash of each number; dozens of
 * real numbers share every prefix, so the server cannot tell which one the
 * user has. The client confirms real matches on the device.
 */
class IRM_Discovery {

	const USERNAME_RE = '/^[a-z][a-z0-9_]{3,19}$/';

	/** Canonical digits-only form; Iranian numbers become 989xxxxxxxxx. */
	public static function normalize_mobile( $raw ) {
		$d = preg_replace( '/\D+/', '', (string) $raw );
		if ( 0 === strpos( $d, '00' ) ) {
			$d = substr( $d, 2 );
		}
		if ( 11 === strlen( $d ) && '09' === substr( $d, 0, 2 ) ) {
			$d = '98' . substr( $d, 1 );
		} elseif ( 10 === strlen( $d ) && '9' === $d[0] ) {
			$d = '98' . $d;
		}
		return $d;
	}

	/** Per-install random salt, so hashes are useless on any other server. */
	public static function salt() {
		$salt = get_option( 'irm_contact_salt' );
		if ( ! is_string( $salt ) || 32 !== strlen( $salt ) ) {
			$salt = bin2hex( random_bytes( 16 ) );
			update_option( 'irm_contact_salt', $salt, false );
		}
		return $salt;
	}

	public static function mobile_hash( $normalized ) {
		return hash( 'sha256', self::salt() . ':' . $normalized );
	}

	/** Fills hash columns for rows created before contact match existed. */
	public static function backfill() {
		global $wpdb;
		$t    = IRM_Schema::table( 'identities' );
		$rows = $wpdb->get_results( "SELECT id, mobile FROM $t WHERE mobile_hash = '' AND mobile NOT LIKE 'none:%'" );
		foreach ( $rows as $r ) {
			$n = self::normalize_mobile( $r->mobile );
			$h = self::mobile_hash( $n );
			$wpdb->update(
				$t,
				array(
					'mobile_hash'   => $h,
					'mobile_prefix' => substr( $h, 0, 6 ),
				),
				array( 'id' => $r->id )
			);
		}
	}

	private static function public_row( $r, $with_hash = false ) {
		$out = array(
			'identity_id'  => (int) $r->id,
			'display_name' => $r->display_name,
			'username'     => $r->username,
		);
		if ( $with_hash ) {
			$out['hash'] = $r->mobile_hash;
		}
		if ( ! empty( $r->is_bot ) ) {
			$out['bot'] = true;
		}
		return $out;
	}

	/** GET /config */
	public static function config() {
		return array(
			'contact_salt' => self::salt(),
			'version'      => IRM_VERSION,
			'media_ttl'    => IRM_MEDIA_TTL,
			'server_key'   => IRM_Signing::public_key(),
			// Only members ever see this list; it is never public.
			'relays'       => IRM_Signing::relays(),
			// Lets a browser subscribe to wake-up alerts from this server only.
			'vapid_key'    => IRM_Push::public_key(),
			// Members' apps never send chat content to these accounts.
			'bots'         => self::bots(),
		);
	}

	/** Ids of active bot accounts. */
	public static function bots() {
		global $wpdb;
		return array_map(
			'intval',
			$wpdb->get_col( 'SELECT id FROM ' . IRM_Schema::table( 'identities' ) . " WHERE status = 'active' AND is_bot = 1" )
		);
	}

	/**
	 * POST /caps — { mine: 3, ids: [12, 15] }
	 *
	 * Records what this device's app understands, and tells it the same
	 * about others. Apps only send newer kinds of control messages (delete
	 * for everyone, read receipts) to apps that understand them; without
	 * this they could only learn it from a message the other side wrote.
	 */
	public static function caps( WP_REST_Request $request ) {
		global $wpdb;
		$device = IRM_Auth::device();
		$p      = (array) $request->get_json_params();
		$mine   = $p['mine'] ?? null;
		$ids    = $p['ids'] ?? array();
		if ( ! is_int( $mine ) || $mine < 1 || $mine > 999 || ! is_array( $ids ) || count( $ids ) > 60 ) {
			return new WP_Error( 'irm_bad_caps', 'Malformed request.', array( 'status' => 400 ) );
		}
		$t_dev = IRM_Schema::table( 'devices' );
		if ( (int) ( $device->cap ?? 1 ) !== $mine ) {
			$wpdb->update( $t_dev, array( 'cap' => $mine ), array( 'id' => $device->id ) );
		}
		$ids = array_values( array_unique( array_filter( array_map( 'intval', $ids ), fn( $i ) => $i > 0 ) ) );
		$out = array();
		if ( $ids ) {
			$marks = implode( ',', array_fill( 0, count( $ids ), '%d' ) );
			$rows  = $wpdb->get_results(
				$wpdb->prepare( "SELECT identity_id, MIN(cap) AS cap FROM $t_dev WHERE status = 'active' AND identity_id IN ($marks) GROUP BY identity_id", $ids )
			);
			foreach ( $rows as $r ) {
				$out[ (string) $r->identity_id ] = (int) $r->cap;
			}
		}
		return array( 'caps' => (object) $out );
	}

	/** POST /contacts/match — { prefixes: ["a1b2c3", ...] } */
	public static function match( WP_REST_Request $request ) {
		global $wpdb;
		// Turned off: no phone numbers are stored, so nothing can match.
		return array( 'matches' => array() );
		$device = IRM_Auth::device();
		if ( ! IRM_Auth::rate_limit( 'match', 6, HOUR_IN_SECONDS, 'd' . $device->id ) ) {
			return new WP_Error( 'irm_rate_limited', 'Contact matching is limited. Try again later.', array( 'status' => 429 ) );
		}
		$p    = (array) $request->get_json_params();
		$list = $p['prefixes'] ?? null;
		if ( ! is_array( $list ) || count( $list ) > 5000 ) {
			return new WP_Error( 'irm_bad_prefixes', 'Prefix list is missing or too long.', array( 'status' => 400 ) );
		}
		$prefixes = array();
		foreach ( $list as $x ) {
			if ( ! is_string( $x ) || ! preg_match( '/^[0-9a-f]{6}$/', $x ) ) {
				return new WP_Error( 'irm_bad_prefixes', 'A prefix is malformed.', array( 'status' => 400 ) );
			}
			$prefixes[ $x ] = true;
		}
		if ( ! $prefixes ) {
			return array( 'matches' => array() );
		}
		$prefixes = array_keys( $prefixes );
		$marks    = implode( ',', array_fill( 0, count( $prefixes ), '%s' ) );
		$rows     = $wpdb->get_results(
			$wpdb->prepare(
				'SELECT id, display_name, username, mobile_hash FROM ' . IRM_Schema::table( 'identities' ) . "
				 WHERE status = 'active' AND id != %d AND mobile_prefix IN ($marks)",
				array_merge( array( (int) $device->identity_id ), $prefixes )
			)
		);
		return array(
			'matches' => array_map(
				static function ( $r ) {
					return self::public_row( $r, true );
				},
				$rows
			),
		);
	}

	/** GET /users/lookup?username=... — exact match only, never a search. */
	public static function lookup( WP_REST_Request $request ) {
		global $wpdb;
		$device = IRM_Auth::device();
		if ( ! IRM_Auth::rate_limit( 'lookup', 40, HOUR_IN_SECONDS, 'd' . $device->id ) ) {
			return new WP_Error( 'irm_rate_limited', 'Too many lookups. Try again later.', array( 'status' => 429 ) );
		}
		$name = strtolower( ltrim( (string) $request->get_param( 'username' ), '@' ) );
		$row  = preg_match( self::USERNAME_RE, $name ) ? $wpdb->get_row(
			$wpdb->prepare(
				'SELECT id, display_name, username, is_bot FROM ' . IRM_Schema::table( 'identities' ) . " WHERE status = 'active' AND username = %s",
				$name
			)
		) : null;
		if ( ! $row ) {
			return new WP_Error( 'irm_not_found', 'No such username.', array( 'status' => 404 ) );
		}
		return self::public_row( $row );
	}

	/** POST /me/username — for accounts created before usernames existed. */
	public static function set_username( WP_REST_Request $request ) {
		global $wpdb;
		$device = IRM_Auth::device();
		$p      = (array) $request->get_json_params();
		$name   = strtolower( (string) ( $p['username'] ?? '' ) );
		if ( ! preg_match( self::USERNAME_RE, $name ) ) {
			return new WP_Error( 'irm_bad_username', 'Username must be 4-20 characters: a-z, 0-9 and underscore, starting with a letter.', array( 'status' => 400 ) );
		}
		$suppress = $wpdb->suppress_errors( true );
		$ok       = $wpdb->query(
			$wpdb->prepare(
				'UPDATE ' . IRM_Schema::table( 'identities' ) . ' SET username = %s WHERE id = %d AND username IS NULL',
				$name,
				$device->identity_id
			)
		);
		$wpdb->suppress_errors( $suppress );
		if ( 1 !== $ok ) {
			return new WP_Error( 'irm_username_taken', 'This username is not available.', array( 'status' => 409 ) );
		}
		return array( 'username' => $name );
	}
}
