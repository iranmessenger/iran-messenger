<?php
defined( 'ABSPATH' ) || exit;

/**
 * Wake-up alerts for the web app (iPhone and desktop browsers).
 *
 * A browser cannot keep a connection open in the background the way the
 * Android app does, so the server asks the browser vendor's push service
 * (Apple, Google, Mozilla) to wake the device. What is sent says only
 * "something new arrived": no sender, no text, and the server could not
 * add them anyway, because it never sees message contents.
 *
 * Standards used as specified: VAPID (RFC 8292) and message encryption
 * for Web Push (RFC 8291, aes128gcm) with OpenSSL primitives.
 */
class IRM_Push {

	/** Device ids that received something during this request. */
	private static $pending = array();

	// ---------------------------------------------------------------
	// Encoding helpers
	// ---------------------------------------------------------------

	public static function b64u( $bin ) {
		return rtrim( strtr( base64_encode( $bin ), '+/', '-_' ), '=' );
	}

	public static function b64u_decode( $text ) {
		if ( ! is_string( $text ) || ! preg_match( '/^[A-Za-z0-9_-]+={0,2}$/', $text ) ) {
			return false;
		}
		return base64_decode( strtr( rtrim( $text, '=' ), '-_', '+/' ), true );
	}

	/** PEM public key for an uncompressed P-256 point (65 bytes). */
	private static function point_to_pem( $point ) {
		$der = hex2bin( '3059301306072a8648ce3d020106082a8648ce3d030107034200' ) . $point;
		return "-----BEGIN PUBLIC KEY-----\n" . chunk_split( base64_encode( $der ), 64, "\n" ) . "-----END PUBLIC KEY-----\n";
	}

	/** Uncompressed point (65 bytes) of an OpenSSL EC key. */
	private static function key_point( $key ) {
		$d = openssl_pkey_get_details( $key );
		if ( ! $d || empty( $d['ec']['x'] ) ) {
			return false;
		}
		return "\x04" . str_pad( $d['ec']['x'], 32, "\0", STR_PAD_LEFT ) . str_pad( $d['ec']['y'], 32, "\0", STR_PAD_LEFT );
	}

	private static function new_key() {
		return openssl_pkey_new(
			array(
				'curve_name'       => 'prime256v1',
				'private_key_type' => OPENSSL_KEYTYPE_EC,
			)
		);
	}

	// ---------------------------------------------------------------
	// Server identity towards push services (VAPID)
	// ---------------------------------------------------------------

	/** [ private PEM, public point as base64url ], created on first use. */
	private static function vapid() {
		$v = get_option( 'irm_vapid' );
		if ( is_array( $v ) && ! empty( $v['pem'] ) && ! empty( $v['pub'] ) ) {
			return $v;
		}
		if ( ! function_exists( 'openssl_pkey_new' ) ) {
			return null;
		}
		$key = self::new_key();
		$pem = '';
		if ( ! $key || ! openssl_pkey_export( $key, $pem ) ) {
			return null;
		}
		$v = array(
			'pem' => $pem,
			'pub' => self::b64u( self::key_point( $key ) ),
		);
		// Not autoloaded: only read when a subscription is made or used.
		update_option( 'irm_vapid', $v, false );
		return $v;
	}

	/** Public key the browser needs to subscribe, or '' if unavailable. */
	public static function public_key() {
		$v = self::vapid();
		return $v ? $v['pub'] : '';
	}

	/** Signed token proving to the push service who is sending. */
	public static function vapid_jwt( $audience, $subject, $private_pem, $now ) {
		$head = self::b64u( '{"typ":"JWT","alg":"ES256"}' );
		$body = self::b64u(
			json_encode(
				array(
					'aud' => $audience,
					'exp' => $now + 12 * 3600,
					'sub' => $subject,
				),
				JSON_UNESCAPED_SLASHES
			)
		);
		$der = '';
		if ( ! openssl_sign( "$head.$body", $der, $private_pem, OPENSSL_ALGO_SHA256 ) ) {
			return false;
		}
		// OpenSSL returns ASN.1; JWT wants the two 32-byte numbers side by side.
		$pos = 2 + ( ord( $der[1] ) > 0x80 ? ord( $der[1] ) - 0x80 : 0 );
		$raw = '';
		for ( $i = 0; $i < 2; $i++ ) {
			$len  = ord( $der[ $pos + 1 ] );
			$raw .= str_pad( ltrim( substr( $der, $pos + 2, $len ), "\0" ), 32, "\0", STR_PAD_LEFT );
			$pos += 2 + $len;
		}
		return "$head.$body." . self::b64u( $raw );
	}

	// ---------------------------------------------------------------
	// Message encryption (RFC 8291)
	// ---------------------------------------------------------------

	/**
	 * Seals $plain for one browser. $ua_public (65 bytes) and $auth
	 * (16 bytes) come from its subscription. The last two arguments exist
	 * for the known-answer test only.
	 */
	public static function encrypt( $plain, $ua_public, $auth, $sender_key = null, $salt = null ) {
		$sender = $sender_key ? $sender_key : self::new_key();
		$salt   = $salt ? $salt : random_bytes( 16 );
		if ( ! $sender ) {
			return false;
		}
		$as_public = self::key_point( $sender );
		$shared    = openssl_pkey_derive( self::point_to_pem( $ua_public ), $sender, 32 );
		if ( false === $as_public || false === $shared ) {
			return false;
		}
		$ikm   = hash_hkdf( 'sha256', $shared, 32, "WebPush: info\0" . $ua_public . $as_public, $auth );
		$key   = hash_hkdf( 'sha256', $ikm, 16, "Content-Encoding: aes128gcm\0", $salt );
		$nonce = hash_hkdf( 'sha256', $ikm, 12, "Content-Encoding: nonce\0", $salt );
		$tag   = '';
		// One record; 0x02 marks it as the last.
		$sealed = openssl_encrypt( $plain . "\x02", 'aes-128-gcm', $key, OPENSSL_RAW_DATA, $nonce, $tag );
		if ( false === $sealed ) {
			return false;
		}
		return $salt . pack( 'N', 4096 ) . chr( 65 ) . $as_public . $sealed . $tag;
	}

	// ---------------------------------------------------------------
	// Subscriptions
	// ---------------------------------------------------------------

	/** Only real push services may be contacted, never an arbitrary URL. */
	public static function endpoint_allowed( $url ) {
		$parts = wp_parse_url( $url );
		if ( ! $parts || 'https' !== ( $parts['scheme'] ?? '' ) || empty( $parts['host'] ) || isset( $parts['user'] ) ) {
			return false;
		}
		if ( isset( $parts['port'] ) && 443 !== (int) $parts['port'] ) {
			return false;
		}
		$host    = strtolower( $parts['host'] );
		$allowed = apply_filters(
			'irm_push_hosts',
			array( 'push.apple.com', 'fcm.googleapis.com', 'push.services.mozilla.com', 'notify.windows.com' )
		);
		foreach ( $allowed as $suffix ) {
			if ( $host === $suffix || substr( $host, -strlen( $suffix ) - 1 ) === '.' . $suffix ) {
				return true;
			}
		}
		return false;
	}

	/** POST /push/subscribe — { endpoint, p256dh, auth } */
	public static function subscribe( WP_REST_Request $request ) {
		global $wpdb;
		$device   = IRM_Auth::device();
		$p        = (array) $request->get_json_params();
		$endpoint = is_string( $p['endpoint'] ?? null ) ? $p['endpoint'] : '';
		$key      = self::b64u_decode( $p['p256dh'] ?? null );
		$auth     = self::b64u_decode( $p['auth'] ?? null );

		if ( '' === self::public_key() ) {
			return new WP_Error( 'irm_push_unavailable', 'This server cannot send alerts.', array( 'status' => 501 ) );
		}
		if ( strlen( $endpoint ) > 1000 || ! self::endpoint_allowed( $endpoint ) ) {
			return new WP_Error( 'irm_bad_endpoint', 'Unknown push service.', array( 'status' => 400 ) );
		}
		if ( false === $key || 65 !== strlen( $key ) || "\x04" !== $key[0] || false === $auth || 16 !== strlen( $auth ) ) {
			return new WP_Error( 'irm_bad_subscription', 'Subscription keys are malformed.', array( 'status' => 400 ) );
		}
		$wpdb->replace(
			IRM_Schema::table( 'push' ),
			array(
				'device_id'  => $device->id,
				'endpoint'   => $endpoint,
				'p256dh'     => self::b64u( $key ),
				'auth'       => self::b64u( $auth ),
				'created_at' => time(),
			)
		);
		return array( 'subscribed' => true );
	}

	/** POST /push/unsubscribe */
	public static function unsubscribe() {
		self::forget( IRM_Auth::device()->id );
		return array( 'subscribed' => false );
	}

	/**
	 * POST /push/idle — the app left the screen. From now on new messages
	 * raise an alert instead of waiting for the next poll.
	 */
	public static function idle() {
		global $wpdb;
		$wpdb->update( IRM_Schema::table( 'devices' ), array( 'last_seen_at' => 0 ), array( 'id' => IRM_Auth::device()->id ) );
		return array( 'idle' => true );
	}

	public static function forget( $device_id ) {
		global $wpdb;
		$wpdb->delete( IRM_Schema::table( 'push' ), array( 'device_id' => (int) $device_id ) );
	}

	/** Drops subscriptions whose device is gone or signed out. */
	public static function cleanup() {
		global $wpdb;
		$wpdb->query(
			'DELETE p FROM ' . IRM_Schema::table( 'push' ) . ' p
			 LEFT JOIN ' . IRM_Schema::table( 'devices' ) . " d ON d.id = p.device_id
			 WHERE d.id IS NULL OR d.status <> 'active' OR p.fails >= 20"
		);
		$wpdb->query(
			'DELETE f FROM ' . IRM_Schema::table( 'fcm' ) . ' f
			 LEFT JOIN ' . IRM_Schema::table( 'devices' ) . " d ON d.id = f.device_id
			 WHERE d.id IS NULL OR d.status <> 'active'"
		);
	}

	// ---------------------------------------------------------------
	// Sending
	// ---------------------------------------------------------------

	/** Remembers who to wake; the work happens after the answer is sent. */
	public static function queue( array $device_ids ) {
		if ( ! self::$pending ) {
			add_action( 'shutdown', array( __CLASS__, 'flush' ), 100 );
		}
		foreach ( $device_ids as $id ) {
			self::$pending[ (int) $id ] = true;
		}
	}

	public static function flush() {
		global $wpdb;
		$ids = array_keys( self::$pending );
		self::$pending = array();
		if ( ! $ids ) {
			return;
		}
		$now  = time();
		$in   = implode( ',', array_map( 'intval', $ids ) );
		$rows = $wpdb->get_results(
			'SELECT p.* FROM ' . IRM_Schema::table( 'push' ) . ' p
			 JOIN ' . IRM_Schema::table( 'devices' ) . " d ON d.id = p.device_id
			 WHERE d.status = 'active'
			   AND p.device_id IN ($in)
			   AND d.last_seen_at < " . ( $now - 20 ) . '
			   AND p.last_push_at < ' . ( $now - 20 )
		);
		// Phones are woken even while their background service polls: the
		// wake-up is what makes delivery immediate. One per 5 s at most.
		$phones = '' === IRM_Gateway::settings()['url'] ? array() : $wpdb->get_results(
			'SELECT f.device_id, f.token FROM ' . IRM_Schema::table( 'fcm' ) . ' f
			 JOIN ' . IRM_Schema::table( 'devices' ) . " d ON d.id = f.device_id
			 WHERE d.status = 'active'
			   AND f.device_id IN ($in)
			   AND f.last_push_at < " . ( $now - 5 )
		);
		if ( ! $rows && ! $phones ) {
			return;
		}
		// The sender already has its answer; it does not wait for this.
		if ( function_exists( 'fastcgi_finish_request' ) ) {
			fastcgi_finish_request();
		} elseif ( function_exists( 'litespeed_finish_request' ) ) {
			litespeed_finish_request();
		}
		if ( $phones ) {
			IRM_Gateway::wake( $phones, $now );
		}
		foreach ( $rows as $row ) {
			self::deliver( $row, $now );
		}
	}

	private static function deliver( $row, $now ) {
		global $wpdb;
		$table = IRM_Schema::table( 'push' );
		$v     = self::vapid();
		$parts = wp_parse_url( $row->endpoint );
		if ( ! $v || ! self::endpoint_allowed( $row->endpoint ) ) {
			return;
		}
		$jwt  = self::vapid_jwt( 'https://' . $parts['host'], home_url( '/' ), $v['pem'], $now );
		$body = self::encrypt( '{"t":"new"}', self::b64u_decode( $row->p256dh ), self::b64u_decode( $row->auth ) );
		if ( ! $jwt || false === $body ) {
			return;
		}
		// Marked first, so a slow push service cannot cause a burst of retries.
		$wpdb->update( $table, array( 'last_push_at' => $now ), array( 'device_id' => $row->device_id ) );
		$res = wp_remote_post(
			$row->endpoint,
			array(
				'timeout'     => 4,
				'redirection' => 0,
				'headers'     => array(
					'Authorization'    => 'vapid t=' . $jwt . ', k=' . $v['pub'],
					'Content-Encoding' => 'aes128gcm',
					'Content-Type'     => 'application/octet-stream',
					'TTL'              => '86400',
					'Urgency'          => 'high',
				),
				'body'        => $body,
			)
		);
		$code = is_wp_error( $res ) ? 0 : (int) wp_remote_retrieve_response_code( $res );
		// For the admin page: is this host able to reach the push services?
		update_option(
			'irm_push_last',
			array(
				'time'   => $now,
				'host'   => $parts['host'],
				'status' => $code,
				'error'  => is_wp_error( $res ) ? $res->get_error_message() : '',
			),
			false
		);
		if ( 404 === $code || 410 === $code ) {
			// The browser dropped this subscription.
			self::forget( $row->device_id );
		} elseif ( $code < 200 || $code >= 300 ) {
			$wpdb->query( $wpdb->prepare( "UPDATE $table SET fails = fails + 1 WHERE device_id = %d", $row->device_id ) );
		} elseif ( $row->fails ) {
			$wpdb->update( $table, array( 'fails' => 0 ), array( 'device_id' => $row->device_id ) );
		}
	}

	// ---------------------------------------------------------------
	// Short address for the web app
	// ---------------------------------------------------------------

	public static function app_url() {
		return plugins_url( 'app/', IRM_FILE );
	}

	/** /app on the site opens the web app. */
	public static function short_link() {
		$path = wp_parse_url( $_SERVER['REQUEST_URI'] ?? '', PHP_URL_PATH );
		$base = wp_parse_url( home_url( '/' ), PHP_URL_PATH );
		if ( is_string( $path ) && rtrim( $path, '/' ) === rtrim( (string) $base, '/' ) . '/app' && is_dir( IRM_DIR . 'app' ) ) {
			// Always the https address (browsers refuse to store keys on plain
			// http), except on a developer's own machine.
			$local = in_array( wp_parse_url( home_url(), PHP_URL_HOST ), array( 'localhost', '127.0.0.1' ), true );
			wp_safe_redirect( $local ? self::app_url() : set_url_scheme( self::app_url(), 'https' ), 302 );
			exit;
		}
	}
}
