<?php
defined( 'ABSPATH' ) || exit;

/**
 * Device authentication for REST calls.
 *
 * Each request is signed with the device's Ed25519 key over:
 *   "IRM1\n" METHOD "\n" route "\n" canonical-query "\n" time "\n" nonce "\n" sha256hex(body)
 * No password, cookie or bearer token is involved, so nothing reusable can
 * leak through host or WAF request logs.
 */
class IRM_Auth {

	/** @var object|null Device row of the authenticated caller. */
	private static $device = null;

	public static function device() {
		return self::$device;
	}

	/** Strict base64 decode that also checks the decoded length. */
	public static function b64( $value, $length = null ) {
		if ( ! is_string( $value ) || '' === $value ) {
			return false;
		}
		$raw = base64_decode( $value, true );
		if ( false === $raw || base64_encode( $raw ) !== $value ) {
			return false;
		}
		if ( null !== $length && strlen( $raw ) !== $length ) {
			return false;
		}
		return $raw;
	}

	public static function canonical_query( WP_REST_Request $request ) {
		$params = $request->get_query_params();
		unset( $params['rest_route'] );
		ksort( $params, SORT_STRING );
		$pairs = array();
		foreach ( $params as $k => $v ) {
			if ( is_scalar( $v ) ) {
				$pairs[] = rawurlencode( (string) $k ) . '=' . rawurlencode( (string) $v );
			}
		}
		return implode( '&', $pairs );
	}

	/** permission_callback for every authenticated route. */
	public static function require_device( WP_REST_Request $request ) {
		global $wpdb;
		self::$device = null;

		$device_id = $request->get_header( 'x_irm_device' );
		$time      = $request->get_header( 'x_irm_time' );
		$nonce     = $request->get_header( 'x_irm_nonce' );
		$sig       = self::b64( $request->get_header( 'x_irm_sig' ), 64 );

		if ( ! ctype_digit( (string) $device_id ) || ! ctype_digit( (string) $time )
			|| false === self::b64( $nonce, 16 ) || false === $sig ) {
			return new WP_Error( 'irm_auth_missing', 'Signed device headers are required.', array( 'status' => 401 ) );
		}

		$now = time();
		if ( abs( $now - (int) $time ) > IRM_CLOCK_WINDOW ) {
			return new WP_Error(
				'irm_clock_skew',
				'Request time is outside the accepted window.',
				array(
					'status'      => 401,
					'server_time' => $now,
				)
			);
		}

		$device = $wpdb->get_row(
			$wpdb->prepare(
				'SELECT d.*, i.status AS identity_status FROM ' . IRM_Schema::table( 'devices' ) . ' d
				 JOIN ' . IRM_Schema::table( 'identities' ) . ' i ON i.id = d.identity_id
				 WHERE d.id = %d',
				(int) $device_id
			)
		);
		// Same answer for unknown and revoked devices: do not reveal which.
		$denied = new WP_Error( 'irm_auth_failed', 'Authentication failed.', array( 'status' => 401 ) );
		if ( ! $device || 'active' !== $device->status
			|| ! in_array( $device->identity_status, array( 'active', 'pending' ), true ) ) {
			return $denied;
		}

		$canonical = implode(
			"\n",
			array(
				'IRM1',
				$request->get_method(),
				$request->get_route(),
				self::canonical_query( $request ),
				$time,
				$nonce,
				hash( 'sha256', (string) $request->get_body() ),
			)
		);
		$key = self::b64( $device->auth_key, 32 );
		if ( false === $key || ! sodium_crypto_sign_verify_detached( $sig, $canonical, $key ) ) {
			return $denied;
		}

		// Replay protection: a (device, nonce) pair is accepted once.
		$suppress = $wpdb->suppress_errors( true );
		$inserted = $wpdb->query(
			$wpdb->prepare(
				'INSERT INTO ' . IRM_Schema::table( 'nonces' ) . ' (device_id, nonce, ts) VALUES (%d, %s, %d)',
				(int) $device_id,
				$nonce,
				$now
			)
		);
		$wpdb->suppress_errors( $suppress );
		if ( 1 !== $inserted ) {
			return new WP_Error( 'irm_replay', 'Request was already used.', array( 'status' => 401 ) );
		}

		// A waiting account may only ask whether it has been approved yet.
		if ( 'pending' === $device->identity_status && '/' . IRM_REST_NS . '/me' !== $request->get_route() ) {
			return new WP_Error( 'irm_pending', 'This account is waiting for approval.', array( 'status' => 403 ) );
		}

		// Fresh enough to tell whether the device is on screen right now.
		if ( $now - (int) $device->last_seen_at > 10 ) {
			$wpdb->update( IRM_Schema::table( 'devices' ), array( 'last_seen_at' => $now ), array( 'id' => $device->id ) );
		}

		self::$device = $device;
		return true;
	}

	/** Small fixed-window limiter, per IP by default or per [$who]. */
	public static function rate_limit( $bucket, $max, $window, $who = null ) {
		if ( null === $who ) {
			$who = isset( $_SERVER['REMOTE_ADDR'] ) ? sanitize_text_field( wp_unslash( $_SERVER['REMOTE_ADDR'] ) ) : '';
		}
		$key = 'irm_rl_' . md5( $bucket . '|' . $who );
		$n   = (int) get_transient( $key );
		if ( $n >= $max ) {
			return false;
		}
		set_transient( $key, $n + 1, $window );
		return true;
	}
}
