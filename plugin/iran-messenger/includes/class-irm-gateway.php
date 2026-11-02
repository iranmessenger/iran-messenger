<?php
defined( 'ABSPATH' ) || exit;

/**
 * Instant alerts for phones with Google services, through a push gateway
 * gateway on a site outside Iran. This server never talks to Google: it
 * sends the gateway a signed list of push tokens, and the gateway sends
 * each phone the same empty wake-up. The phone then fetches its messages
 * from here as usual.
 */
class IRM_Gateway {

	/**
	 * Set after the gateway could not be reached (for example when the
	 * international connection is cut). While it is set no message waits
	 * for the gateway; phones still poll. It expires on its own, and the
	 * next message then tries again.
	 */
	const PAUSE = 'irm_gateway_pause';
	const PAUSE_SECONDS = 300;

	/**
	 * POST /push/fcm — { token } from a phone with Google services, or an
	 * empty token to stop. The token only lets the gateway wake this phone.
	 */
	public static function register( WP_REST_Request $request ) {
		global $wpdb;
		$device = IRM_Auth::device();
		$token  = (string) ( $request->get_json_params()['token'] ?? '' );
		if ( '' === $token ) {
			$wpdb->delete( IRM_Schema::table( 'fcm' ), array( 'device_id' => $device->id ) );
			return array( 'registered' => false );
		}
		if ( ! preg_match( '/^[A-Za-z0-9_:\-]{20,400}$/', $token ) ) {
			return new WP_Error( 'irm_bad_token', 'Push token is malformed.', array( 'status' => 400 ) );
		}
		// A token belongs to one installation; a reinstall may reuse it.
		$wpdb->delete( IRM_Schema::table( 'fcm' ), array( 'token' => $token ) );
		$wpdb->replace(
			IRM_Schema::table( 'fcm' ),
			array(
				'device_id'  => $device->id,
				'token'      => $token,
				'created_at' => time(),
			)
		);
		return array(
			'registered' => true,
			'gateway'    => '' !== self::settings()['url'],
		);
	}

	/** Where the push gateway gateway is and the key it expects. */
	public static function settings() {
		return wp_parse_args(
			(array) get_option( 'irm_push_gateway', array() ),
			array(
				'url' => '',
				'key' => '',
			)
		);
	}

	public static function save( $url, $key ) {
		$url = untrailingslashit( esc_url_raw( $url, array( 'https' ) ) );
		update_option(
			'irm_push_gateway',
			array(
				'url' => $url,
				'key' => '' === $url ? '' : preg_replace( '/[^A-Za-z0-9_\-]/', '', $key ),
			),
			false
		);
	}

	/**
	 * Signed request to another route of the same gateway (for example
	 * "giphy"). Returns the decoded answer, or null if there is no gateway
	 * or it did not answer with 200.
	 */
	public static function call( $route, array $payload, $timeout = 10 ) {
		$g = self::settings();
		if ( '' === $g['url'] ) {
			return null;
		}
		$url  = preg_replace( '#/wake$#', '/' . $route, $g['url'] );
		$body = wp_json_encode( array_merge( array( 'ts' => time(), 'n' => bin2hex( random_bytes( 6 ) ) ), $payload ) );
		$res  = wp_remote_post(
			$url,
			array(
				'timeout'     => $timeout,
				'redirection' => 0,
				'headers'     => array(
					'Content-Type' => 'application/json',
					'X-Gateway-Sig'   => hash_hmac( 'sha256', $body, $g['key'] ),
				),
				'body'        => $body,
			)
		);
		if ( is_wp_error( $res ) || 200 !== (int) wp_remote_retrieve_response_code( $res ) ) {
			return null;
		}
		$data = json_decode( wp_remote_retrieve_body( $res ), true );
		return is_array( $data ) ? $data : null;
	}

	/** Admin button: wakes every registered phone once. */
	public static function test() {
		global $wpdb;
		if ( '' === self::settings()['url'] ) {
			return __( 'No gateway is set.', 'iran-messenger' );
		}
		$phones = $wpdb->get_results( 'SELECT device_id, token FROM ' . IRM_Schema::table( 'fcm' ) );
		if ( ! $phones ) {
			return __( 'No phone has registered yet.', 'iran-messenger' );
		}
		self::wake( $phones, time(), true );
		return self::summary( (array) get_option( 'irm_gateway_last' ) );
	}

	public static function summary( array $last ) {
		$when = wp_date( 'Y-m-d H:i:s', (int) ( $last['time'] ?? 0 ) );
		if ( 200 === (int) ( $last['status'] ?? 0 ) ) {
			/* translators: 1: time, 2: phones accepted, 3: phones asked */
			return sprintf( __( 'Last wake-up: %1$s — %2$d of %3$d phones accepted by Google.', 'iran-messenger' ), $when, $last['sent'], $last['total'] );
		}
		if ( 404 === (int) ( $last['status'] ?? 0 ) ) {
			/* translators: %s: time */
			return sprintf( __( 'Last wake-up: %s — the gateway refused it. Check the address, the access key and that the gateway is enabled.', 'iran-messenger' ), $when );
		}
		$detail = $last['status'] ? 'HTTP ' . $last['status'] . ( $last['error'] ? ' — ' . $last['error'] : '' ) : $last['error'];
		/* translators: 1: time, 2: error */
		$text = sprintf( __( 'Last wake-up: %1$s — failed: %2$s', 'iran-messenger' ), $when, $detail );
		if ( get_transient( self::PAUSE ) ) {
			$text .= ' ' . __( 'Wake-ups are paused for a few minutes and then tried again; phones keep receiving through their background service meanwhile.', 'iran-messenger' );
		}
		return $text;
	}

	/**
	 * Asks the push gateway gateway to wake these phones through Google. The
	 * request names only push tokens and is signed with the shared key.
	 */
	public static function wake( array $phones, $now, $force = false ) {
		global $wpdb;
		if ( ! $force && get_transient( self::PAUSE ) ) {
			return;
		}
		$g     = self::settings();
		$table = IRM_Schema::table( 'fcm' );
		$ids   = implode( ',', array_map( 'intval', wp_list_pluck( $phones, 'device_id' ) ) );
		$wpdb->query( $wpdb->prepare( "UPDATE $table SET last_push_at = %d WHERE device_id IN ($ids)", $now ) ); // phpcs:ignore WordPress.DB.PreparedSQL.InterpolatedNotPrepared
		$body = wp_json_encode(
			array(
				'ts'     => $now,
				'tokens' => array_values( wp_list_pluck( $phones, 'token' ) ),
			)
		);
		$res  = wp_remote_post(
			$g['url'],
			array(
				'timeout'     => 6,
				'redirection' => 0,
				'headers'     => array(
					'Content-Type' => 'application/json',
					'X-Gateway-Sig'   => hash_hmac( 'sha256', $body, $g['key'] ),
				),
				'body'        => $body,
			)
		);
		$code = is_wp_error( $res ) ? 0 : (int) wp_remote_retrieve_response_code( $res );
		$data = $code ? json_decode( wp_remote_retrieve_body( $res ), true ) : null;
		update_option(
			'irm_gateway_last',
			array(
				'time'   => $now,
				'status' => $code,
				'sent'   => (int) ( $data['sent'] ?? 0 ),
				'total'  => count( $phones ),
				'error'  => is_wp_error( $res ) ? $res->get_error_message() : (string) ( $data['message'] ?? '' ),
			),
			false
		);
		if ( 0 === $code || $code >= 500 ) {
			set_transient( self::PAUSE, 1, self::PAUSE_SECONDS );
		} else {
			delete_transient( self::PAUSE );
		}
		foreach ( (array) ( $data['invalid'] ?? array() ) as $token ) {
			if ( is_string( $token ) ) {
				// The app was uninstalled or its token was replaced.
				$wpdb->delete( $table, array( 'token' => $token ) );
			}
		}
	}
}
