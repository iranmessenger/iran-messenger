<?php
defined( 'ABSPATH' ) || exit;

/**
 * Ciphertext mailbox.
 *
 * Delivery is at-least-once: a device keeps receiving an envelope until it
 * acknowledges it after durable storage; clients de-duplicate. The server
 * never interprets envelope bodies.
 */
class IRM_Messages {

	/** POST /envelopes — store one logical message as per-device envelopes. */
	public static function send( WP_REST_Request $request ) {
		global $wpdb;
		$device = IRM_Auth::device();
		$p      = (array) $request->get_json_params();
		$msg_id = is_string( $p['client_msg_id'] ?? null ) ? $p['client_msg_id'] : '';
		$list   = $p['envelopes'] ?? null;

		if ( ! preg_match( '/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/', $msg_id ) ) {
			return new WP_Error( 'irm_bad_msg_id', 'client_msg_id must be a lowercase UUID.', array( 'status' => 400 ) );
		}
		if ( ! is_array( $list ) || ! $list || count( $list ) > IRM_MAX_ENVELOPES_PER_MESSAGE ) {
			return new WP_Error( 'irm_bad_envelopes', 'Envelope list is missing or too long.', array( 'status' => 400 ) );
		}

		$envelopes = array();
		foreach ( $list as $e ) {
			$to   = is_array( $e ) ? ( $e['to_device'] ?? null ) : null;
			$type = is_array( $e ) ? ( $e['type'] ?? null ) : null;
			$body = is_array( $e ) ? ( $e['body'] ?? null ) : null;
			if ( ! is_int( $to ) || $to < 1 || ! in_array( $type, array( 2, 3 ), true )
				|| ! is_string( $body ) || strlen( $body ) > IRM_MAX_CIPHERTEXT_B64
				|| false === IRM_Auth::b64( $body ) || isset( $envelopes[ $to ] ) ) {
				return new WP_Error( 'irm_bad_envelopes', 'An envelope is malformed or duplicated.', array( 'status' => 400 ) );
			}
			$envelopes[ $to ] = array( $type, $body );
		}
		ksort( $envelopes );
		$hash = hash( 'sha256', wp_json_encode( $envelopes ) );

		$t_msg = IRM_Schema::table( 'messages' );
		$t_del = IRM_Schema::table( 'deliveries' );
		$now   = time();

		// Idempotent retry: same id + same payload is a success, never a second message.
		$existing = $wpdb->get_row(
			$wpdb->prepare( "SELECT id, payload_hash, created_at FROM $t_msg WHERE sender_device_id = %d AND client_msg_id = %s", $device->id, $msg_id )
		);
		if ( $existing ) {
			return self::duplicate_result( $existing, $hash );
		}

		// Every recipient must be an active device of an active member.
		$ids    = array_map( 'intval', array_keys( $envelopes ) );
		$marks  = implode( ',', array_fill( 0, count( $ids ), '%d' ) );
		$active = (int) $wpdb->get_var(
			$wpdb->prepare(
				'SELECT COUNT(*) FROM ' . IRM_Schema::table( 'devices' ) . ' d
				 JOIN ' . IRM_Schema::table( 'identities' ) . " i ON i.id = d.identity_id
				 WHERE d.status = 'active' AND i.status = 'active' AND d.id IN ($marks)",
				$ids
			)
		);
		if ( count( $ids ) !== $active ) {
			return new WP_Error( 'irm_stale_devices', 'A recipient device is unknown or revoked. Refresh keys and retry.', array( 'status' => 409 ) );
		}

		// Ephemeral signals (e.g. typing) ask for a short life so they never pile up.
		$ttl     = is_int( $p['ttl'] ?? null ) ? max( 10, min( IRM_TEXT_TTL, $p['ttl'] ) ) : IRM_TEXT_TTL;
		$expires = $now + $ttl;
		$wpdb->query( 'START TRANSACTION' );
		$suppress = $wpdb->suppress_errors( true );
		$ok       = $wpdb->query(
			$wpdb->prepare(
				"INSERT INTO $t_msg (sender_device_id, client_msg_id, payload_hash, created_at, expires_at) VALUES (%d, %s, %s, %d, %d)",
				$device->id,
				$msg_id,
				$hash,
				$now,
				$expires
			)
		);
		$wpdb->suppress_errors( $suppress );
		if ( 1 !== $ok ) {
			$wpdb->query( 'ROLLBACK' );
			// Lost a race with a concurrent retry of the same message.
			$existing = $wpdb->get_row(
				$wpdb->prepare( "SELECT id, payload_hash, created_at FROM $t_msg WHERE sender_device_id = %d AND client_msg_id = %s", $device->id, $msg_id )
			);
			return $existing
				? self::duplicate_result( $existing, $hash )
				: new WP_Error( 'irm_db', 'Could not store message.', array( 'status' => 500 ) );
		}
		$message_id = (int) $wpdb->insert_id;

		foreach ( $envelopes as $to => $e ) {
			$ok = $wpdb->query(
				$wpdb->prepare(
					"INSERT INTO $t_del (message_id, sender_device_id, recipient_device_id, env_type, ciphertext, expires_at) VALUES (%d, %d, %d, %d, %s, %d)",
					$message_id,
					$device->id,
					$to,
					$e[0],
					$e[1],
					$expires
				)
			);
			if ( 1 !== $ok ) {
				$wpdb->query( 'ROLLBACK' );
				return new WP_Error( 'irm_db', 'Could not store message.', array( 'status' => 500 ) );
			}
		}
		// Success is reported only after the commit is durable.
		if ( false === $wpdb->query( 'COMMIT' ) ) {
			return new WP_Error( 'irm_db', 'Could not store message.', array( 'status' => 500 ) );
		}

		// Browser devices are woken up. Short-lived signals and the ones the
		// sender marks as quiet (reactions, edits) are not worth an alert.
		if ( ! is_int( $p['ttl'] ?? null ) && true !== ( $p['quiet'] ?? null ) ) {
			IRM_Push::queue( $ids );
		}

		return new WP_REST_Response(
			array(
				'client_msg_id' => $msg_id,
				'accepted_at'   => $now,
				'duplicate'     => false,
			),
			201
		);
	}

	private static function duplicate_result( $existing, $hash ) {
		if ( ! hash_equals( $existing->payload_hash, $hash ) ) {
			return new WP_Error( 'irm_msg_id_conflict', 'This client_msg_id was already used with different content.', array( 'status' => 409 ) );
		}
		return array(
			'accepted_at' => (int) $existing->created_at,
			'duplicate'   => true,
		);
	}

	/**
	 * GET /sync — the caller's unacknowledged envelopes plus delivery
	 * receipts for messages it sent. Stateless: repeat until both are empty.
	 */
	public static function sync() {
		global $wpdb;
		$device = IRM_Auth::device();
		$t_del  = IRM_Schema::table( 'deliveries' );
		$t_dev  = IRM_Schema::table( 'devices' );
		$t_msg  = IRM_Schema::table( 'messages' );
		$now    = time();

		$rows = $wpdb->get_results(
			$wpdb->prepare(
				"SELECT x.id, x.env_type, x.ciphertext, x.sender_device_id, s.identity_id AS sender_identity, m.created_at
				 FROM $t_del x
				 JOIN $t_dev s ON s.id = x.sender_device_id
				 JOIN $t_msg m ON m.id = x.message_id
				 WHERE x.recipient_device_id = %d AND x.acked_at = 0 AND x.expires_at > %d
				 ORDER BY x.id LIMIT %d",
				$device->id,
				$now,
				IRM_SYNC_BATCH + 1
			)
		);
		$more = count( $rows ) > IRM_SYNC_BATCH;
		$rows = array_slice( $rows, 0, IRM_SYNC_BATCH );

		$receipts = $wpdb->get_results(
			$wpdb->prepare(
				"SELECT x.id, x.recipient_device_id, x.acked_at, m.client_msg_id
				 FROM $t_del x JOIN $t_msg m ON m.id = x.message_id
				 WHERE x.sender_device_id = %d AND x.sender_seen = 0 AND x.acked_at > 0
				 ORDER BY x.id LIMIT %d",
				$device->id,
				IRM_SYNC_BATCH
			)
		);

		return array(
			'envelopes'   => array_map(
				static function ( $r ) {
					return array(
						'delivery_id'     => (int) $r->id,
						'from_identity'   => (int) $r->sender_identity,
						'from_device'     => (int) $r->sender_device_id,
						'type'            => (int) $r->env_type,
						'body'            => $r->ciphertext,
						'server_received' => (int) $r->created_at,
					);
				},
				$rows
			),
			'receipts'    => array_map(
				static function ( $r ) {
					return array(
						'receipt_id'    => (int) $r->id,
						'client_msg_id' => $r->client_msg_id,
						'to_device'     => (int) $r->recipient_device_id,
						'stored_at'     => (int) $r->acked_at,
					);
				},
				$receipts
			),
			'more'        => $more,
			'server_time' => $now,
		);
	}

	/**
	 * POST /receipts — acknowledge envelopes the caller has durably stored
	 * (their ciphertext is then erased) and receipts it has recorded.
	 */
	public static function ack( WP_REST_Request $request ) {
		global $wpdb;
		$device = IRM_Auth::device();
		$p      = (array) $request->get_json_params();
		$t_del  = IRM_Schema::table( 'deliveries' );
		$now    = time();
		$result = array(
			'acked'    => 0,
			'receipts' => 0,
		);

		$stored = self::id_list( $p['stored'] ?? array() );
		$seen   = self::id_list( $p['receipts_seen'] ?? array() );
		if ( null === $stored || null === $seen ) {
			return new WP_Error( 'irm_bad_ids', 'Id lists are malformed.', array( 'status' => 400 ) );
		}

		// The recipient / sender column in each WHERE is the authorisation check.
		if ( $stored ) {
			$marks           = implode( ',', array_fill( 0, count( $stored ), '%d' ) );
			$result['acked'] = (int) $wpdb->query(
				$wpdb->prepare(
					"UPDATE $t_del SET acked_at = %d, ciphertext = NULL WHERE recipient_device_id = %d AND acked_at = 0 AND id IN ($marks)",
					array_merge( array( $now, (int) $device->id ), $stored )
				)
			);
		}
		if ( $seen ) {
			$marks              = implode( ',', array_fill( 0, count( $seen ), '%d' ) );
			$result['receipts'] = (int) $wpdb->query(
				$wpdb->prepare(
					"UPDATE $t_del SET sender_seen = 1 WHERE sender_device_id = %d AND acked_at > 0 AND id IN ($marks)",
					array_merge( array( (int) $device->id ), $seen )
				)
			);
		}
		return $result;
	}

	/** @return int[]|null */
	private static function id_list( $value ) {
		if ( ! is_array( $value ) || count( $value ) > 200 ) {
			return null;
		}
		foreach ( $value as $v ) {
			if ( ! is_int( $v ) || $v < 1 ) {
				return null;
			}
		}
		return array_values( array_unique( $value ) );
	}
}
